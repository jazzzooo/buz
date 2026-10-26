const Retry = enum { @"continue", fail, no };

fn setFileError(this: anytype, err: bun.sys.Error) void {
    const This = @TypeOf(this.*);
    if (comptime @hasDecl(This, "setFileOpenerError")) {
        this.setFileOpenerError(err);
    } else {
        this.system_error = err;
    }
}

fn setFileOpenerError(this: anytype, err: bun.sys.Error) void {
    setFileError(this, err);
    if (comptime @hasField(@TypeOf(this.*), "opened_fd")) {
        this.opened_fd = invalid_fd;
    }
}

pub fn prepareBorrowedFd(this: anytype) void {
    const pathlike = if (@hasField(@TypeOf(this.*), "file_store"))
        this.file_store.pathlike
    else
        this.file_blob.storePtr().data.file.pathlike;
    if (pathlike != .fd) return;
    switch (duplicate(pathlike.fd)) {
        .result => |fd| this.opened_fd = fd,
        .err => |err| setFileOpenerError(this, err),
    }
}

pub const duplicate = bun.sys.dupForLibUV;

pub fn isAppend(fd: bun.FD) bun.sys.Maybe(bool) {
    if (comptime Environment.isWindows) {
        var info: bun.c.PUBLIC_OBJECT_BASIC_INFORMATION = undefined;
        const status = std.os.windows.ntdll.NtQueryObject(fd.native(), .Basic, &info, @sizeOf(@TypeOf(info)), null);
        if (status != .SUCCESS) return .{ .err = bun.sys.Error.fromCode(bun.sys.SystemErrno.fromNtStatus(status).toE(), .fstat).withFd(fd) };
        return .{ .result = info.GrantedAccess & bun.windows.FILE_APPEND_DATA != 0 and info.GrantedAccess & bun.windows.FILE_WRITE_DATA == 0 };
    }
    const flags = switch (bun.sys.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0))) {
        .result => |value| value,
        .err => |err| return .{ .err = err },
    };
    return .{ .result = flags & bun.O.APPEND != 0 };
}

pub fn closeOwnedFd(this: anytype) void {
    if (this.opened_fd != invalid_fd) {
        _ = this.opened_fd.closeAllowingStandardIo(null);
        this.opened_fd = invalid_fd;
    }
}

pub noinline fn mkdirIfNotExists(this: anytype, err: bun.sys.Error, path_string: [:0]const u8, err_path: []const u8) Retry {
    if (err.getErrno() == .NOENT and this.mkdirp_if_not_exists) {
        if (std.fs.path.dirname(path_string)) |dirname| {
            var mkdir_error_buffer: bun.PathBuffer = undefined;
            switch (NodeFSCore.mkdir(&mkdir_error_buffer, .{
                .path = .{ .string = bun.PathString.init(dirname) },
                .recursive = true,
                .always_return_none = true,
            })) {
                .result => {
                    this.mkdirp_if_not_exists = false;
                    return .@"continue";
                },
                .err => |err2| {
                    setFileOpenerError(this, err2.withPath(err_path));
                    return .fail;
                },
            }
        }
    }
    return .no;
}

pub fn FileOpener(comptime This: type) type {
    const Impl = struct {
        const opener_flags = bun.O.NONBLOCK | bun.O.CLOEXEC;
        const open_flags = if (@hasDecl(This, "open_flags"))
            This.open_flags | opener_flags
        else
            bun.O.RDONLY | opener_flags;

        fn getFdByOpening(this: *This, comptime Callback: OpenCallback) void {
            var buf: bun.PathBuffer = undefined;
            var path_string = if (@hasField(This, "file_store"))
                this.file_store.pathlike.path
            else
                this.file_blob.storePtr().data.file.pathlike.path;

            const path = path_string.sliceZ(&buf);
            const mode = if (@hasField(This, "creation_mode"))
                this.creation_mode orelse NodeFSCore.default_permission
            else
                NodeFSCore.default_permission;

            while (true) {
                this.opened_fd = switch (bun.sys.open(path, open_flags, mode)) {
                    .result => |fd| fd,
                    .err => |err| {
                        if (comptime @hasField(This, "mkdirp_if_not_exists")) {
                            if (err.errno == @backingInt(bun.sys.E.NOENT)) {
                                switch (mkdirIfNotExists(this, err, path, path_string.slice())) {
                                    .@"continue" => continue,
                                    .fail => {
                                        this.opened_fd = invalid_fd;
                                        break;
                                    },
                                    .no => {},
                                }
                            }
                        }

                        setFileOpenerError(this, err.withPath(path_string.slice()));
                        break;
                    },
                };
                break;
            }

            Callback(this, this.opened_fd);
        }

        const OpenCallback = *const fn (*This, bun.FD) void;

        fn useBorrowedFd(this: *This, fd: bun.FD, comptime Callback: OpenCallback) void {
            if (@hasField(This, "async_io")) @panic("asynchronous file descriptor was not prepared");
            this.opened_fd = fd;
            Callback(this, this.opened_fd);
        }

        pub fn getFd(this: *This, comptime Callback: OpenCallback) void {
            if (this.opened_fd != invalid_fd) {
                Callback(this, this.opened_fd);
                return;
            }

            if (@hasField(This, "file_store")) {
                const pathlike = this.file_store.pathlike;
                if (pathlike == .fd) {
                    useBorrowedFd(this, pathlike.fd, Callback);
                    return;
                }
            } else {
                const pathlike = this.file_blob.storePtr().data.file.pathlike;
                if (pathlike == .fd) {
                    useBorrowedFd(this, pathlike.fd, Callback);
                    return;
                }
            }

            getFdByOpening(this, Callback);
        }
    };
    return Impl;
}

pub fn AsyncIO(comptime Owner: type, comptime field_name: []const u8) type {
    const Impl = struct {
        mutex: std.atomic.Mutex = .unlocked,
        cancelled: std.atomic.Value(bool) = .init(false),
        phase: enum { working, waiting, closing, finished } = .working,
        request_queued: bool = false,
        needs_unregister: bool = false,
        finish_after_resume: bool = false,
        fd: bun.FD = .invalid,
        interest: io.Readiness = .readable,
        loop: ?*io.Loop = null,
        failure: ?io.Failure = null,
        poll: io.Poll = .{ .callback = onPoll },
        request: io.Request = .{ .callback = action },
        task: bun.BackgroundTaskGroup.Task = .{ .callback = onResume, .on_cancel = cancelResume },

        const Self = @This();

        fn lock(this: *Self) void {
            while (!this.mutex.tryLock()) std.atomic.spinLoopHint();
        }

        fn owner(this: *Self) *Owner {
            return @alignCast(@fieldParentPtr(field_name, this));
        }

        pub fn isCancelled(this: *const Self) bool {
            return this.cancelled.load(.acquire);
        }

        pub fn requestCancel(this: *Self) void {
            this.lock();
            defer this.mutex.unlock();
            this.cancelled.store(true, .release);
            if (this.phase == .waiting and !this.request_queued) this.scheduleRequest();
        }

        pub fn wait(this: *Self, fd: bun.FD, interest: io.Readiness) bool {
            this.lock();
            defer this.mutex.unlock();
            bun.assert(this.phase == .working);
            if (this.isCancelled()) return false;
            if (this.loop == null) {
                this.loop = switch (io.Loop.get(bun.fs.FileSystem.instance.io)) {
                    .ready => |loop| loop,
                    .err => |failure| {
                        this.failure = failure;
                        return false;
                    },
                };
            }
            bun.assert(!this.needs_unregister or this.fd == fd);
            this.fd = fd;
            this.interest = interest;
            this.phase = .waiting;
            this.needs_unregister = true;
            this.scheduleRequest();
            return true;
        }

        pub fn finish(this: *Self) bool {
            this.lock();
            defer this.mutex.unlock();
            if (this.phase == .finished) return false;
            bun.assert(this.phase == .working);
            if (this.needs_unregister) {
                this.phase = .closing;
                this.scheduleRequest();
                return true;
            }
            this.phase = .finished;
            return false;
        }

        pub fn takeError(this: *Self) ?io.Failure {
            return bun.take(&this.failure);
        }

        fn scheduleRequest(this: *Self) void {
            bun.assert(!this.request_queued);
            this.request_queued = true;
            this.loop.?.schedule(&this.request);
        }

        fn action(request: *io.Request) io.Action {
            const this: *Self = @fieldParentPtr("request", request);
            this.lock();
            defer this.mutex.unlock();
            bun.assert(this.request_queued);
            this.request_queued = false;
            if (this.phase == .closing or this.isCancelled()) {
                this.phase = .closing;
                return .{ .close = .{
                    .fd = this.fd,
                    .onDone = onClosed,
                    .poll = &this.poll,
                } };
            }
            bun.assert(this.phase == .waiting);
            return .{ .wait = .{ .fd = this.fd, .poll = &this.poll, .interest = this.interest } };
        }

        pub fn ready(this: *Self, err: ?bun.sys.Error) void {
            this.lock();
            if (this.phase != .waiting) {
                this.mutex.unlock();
                return;
            }
            const context = this.owner();
            if (err) |failure| this.failure = .fromSystem(failure);
            // A queued cancellation owns the next handoff, including any
            // readiness returned before the poll is removed.
            if (this.request_queued) {
                this.mutex.unlock();
                return;
            }
            this.phase = .working;
            this.finish_after_resume = false;
            this.mutex.unlock();
            context.delivery.?.scheduleContinuation(&this.task);
        }

        fn onPoll(poll: *io.Poll, err: ?bun.sys.Error) void {
            const this: *Self = @fieldParentPtr("poll", poll);
            this.ready(err);
        }

        fn onClosed(poll: *io.Poll) void {
            const this: *Self = @fieldParentPtr("poll", poll);
            this.lock();
            bun.assert(this.phase == .closing and !this.request_queued);
            this.needs_unregister = false;
            this.phase = .working;
            this.finish_after_resume = true;
            const parent = this.owner();
            this.mutex.unlock();
            parent.delivery.?.scheduleContinuation(&this.task);
        }

        fn onResume(task: *bun.BackgroundTaskGroup.Task) void {
            const this: *Self = @fieldParentPtr("task", task);
            const context = this.owner();
            if (this.finish_after_resume) context.onFinish() else context.update();
        }

        fn cancelResume(task: *bun.BackgroundTaskGroup.Task) void {
            const this: *Self = @fieldParentPtr("task", task);
            this.requestCancel();
            this.owner().onFinish();
        }
    };
    return Impl;
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const NodeFSCore = @import("../../node/NodeFSCore.zig");
const invalid_fd = bun.invalid_fd;
const io = bun.io;
