//! Readiness notifications for file operations running in the native worker pool.

pub const heap = @import("./heap.zig");
pub const BackgroundTaskGroup = @import("./BackgroundTaskGroup.zig");
pub const BackgroundExecutor = BackgroundTaskGroup.Executor;
pub const BackgroundWork = @import("./BackgroundWork.zig").BackgroundWork;
pub const openForWriting = @import("./openForWriting.zig").openForWriting;
pub const openForWritingImpl = @import("./openForWriting.zig").openForWritingImpl;
pub const Source = @import("./source.zig").Source;

pub const Readiness = enum { readable, writable };

pub const Failure = union(enum) {
    system: bun.sys.Error,
    out_of_memory,
    concurrency_unavailable,

    pub fn fromSystem(err: bun.sys.Error) Failure {
        return if (err.getErrno() == .NOMEM) .out_of_memory else .{ .system = err };
    }
};

pub const Loop = struct {
    pending: Request.Queue = .{},
    waker: ?Waker = null,
    poll_fd: bun.FD = .invalid,

    var loop: Loop = undefined;
    var initialization_mutex: std.Io.Mutex = .init;
    var initialized: bool = false;

    fn initialize() ?Failure {
        loop = .{};
        loop.waker = switch (Waker.create(true)) {
            .result => |waker| waker,
            .err => |err| return .fromSystem(err),
        };
        if (comptime Environment.isLinux) {
            loop.poll_fd = switch (bun.sys.epoll_create1(linux.EPOLL.CLOEXEC)) {
                .result => |fd| fd,
                .err => |err| return .fromSystem(err),
            };
            var event: linux.epoll_event = .{
                .events = linux.EPOLL.IN | linux.EPOLL.ET,
                .data = .{ .u64 = 0 },
            };
            while (true) {
                const result = linux.epoll_ctl(loop.poll_fd.native(), linux.EPOLL.CTL_ADD, loop.waker.?.getFd().native(), &event);
                if (bun.sys.getErrno(result) == .INTR) continue;
                if (bun.sys.Maybe(void).errnoSys(result, .epoll_ctl)) |failure| return .fromSystem(failure.err);
                break;
            }
        } else {
            loop.poll_fd = loop.waker.?.getFd();
        }
        const thread = std.Thread.spawn(.{
            .allocator = bun.default_allocator,
            .stack_size = 2 * 1024 * 1024,
        }, onSpawnIOThread, .{}) catch |err| return switch (err) {
            error.OutOfMemory => .out_of_memory,
            else => .concurrency_unavailable,
        };
        thread.detach();
        return null;
    }

    pub fn get(io: std.Io) union(enum) { ready: *Loop, err: Failure } {
        if (Environment.isWindows) @panic("file readiness polling requires epoll or kqueue");
        initialization_mutex.lockUncancelable(io);
        defer initialization_mutex.unlock(io);
        if (!initialized) {
            if (initialize()) |failure| {
                if (loop.poll_fd.isValid() and (loop.waker == null or loop.poll_fd.native() != loop.waker.?.getFd().native())) {
                    _ = loop.poll_fd.closeAllowingStandardIo(null);
                }
                if (loop.waker) |*waker| waker.deinit();
                return .{ .err = failure };
            }
            initialized = true;
        }
        return .{ .ready = &loop };
    }

    fn onSpawnIOThread() void {
        bun.Output.Source.configureNamedThread("IO Watcher");
        loop.tick();
    }

    pub fn schedule(this: *Loop, request: *Request) void {
        this.pending.push(request);
        this.waker.?.wake();
    }

    fn processRequests(this: *Loop) void {
        const batch = this.pending.popBatch();
        var requests = batch.iterator();
        while (requests.next()) |request| {
            switch (request.callback(request)) {
                .wait => |wait| switch (wait.poll.register(this, wait.fd, wait.interest)) {
                    .result => {},
                    .err => |err| wait.poll.callback(wait.poll, err),
                },
                .close => |close| {
                    close.poll.unregister(this, close.fd);
                    close.onDone(close.poll);
                },
            }
        }
    }

    pub fn tick(this: *Loop) void {
        while (true) {
            this.processRequests();
            if (comptime Environment.isLinux) {
                var events: [256]linux.epoll_event = undefined;
                const result = linux.epoll_wait(this.poll_fd.native(), &events, events.len, -1);
                switch (bun.sys.getErrno(result)) {
                    .INTR => continue,
                    .SUCCESS => {},
                    else => |err| bun.Output.panic("file epoll wait failed: {s}", .{@tagName(err)}),
                }
                for (events[0..result]) |event| {
                    if (event.data.ptr == 0) {
                        this.waker.?.drain();
                        continue;
                    }
                    const poll: *Poll = @ptrFromInt(event.data.ptr);
                    // EPOLLERR carries no errno; the subsequent I/O observes it.
                    poll.callback(poll, null);
                }
            } else {
                var events: [256]KEvent = undefined;
                const count = switch (Kqueue.wait(this.poll_fd, &events)) {
                    .result => |count| count,
                    .err => |err| bun.Output.panic("file kqueue wait failed: {s}", .{@tagName(err.getErrno())}),
                };
                for (events[0..count]) |event| {
                    if (event.udata == 0) continue;
                    const poll: *Poll = @ptrFromInt(event.udata);
                    poll.registered = false;
                    const err: ?bun.sys.Error = if (event.flags & std.c.EV.ERROR != 0)
                        bun.sys.Error.fromCode(@fromBackingInt(@intCast(event.data)), .kevent)
                    else
                        null;
                    poll.callback(poll, err);
                }
            }
        }
    }
};

pub const Request = struct {
    next: ?*Request = null,
    callback: *const fn (*Request) Action,

    pub const Queue = bun.UnboundedQueue(Request, .next);
};

pub const Action = union(enum) {
    wait: struct {
        fd: bun.FD,
        poll: *Poll,
        interest: Readiness,
    },
    close: struct {
        fd: bun.FD,
        poll: *Poll,
        onDone: *const fn (*Poll) void,
    },
};

pub const Poll = struct {
    callback: *const fn (*Poll, ?bun.sys.Error) void,
    registered: bool = false,
    interest: Readiness = .readable,

    fn register(this: *Poll, loop_: *Loop, fd: bun.FD, interest: Readiness) bun.sys.Maybe(void) {
        if (comptime Environment.isLinux) {
            var event: linux.epoll_event = .{
                .events = (if (interest == .readable) @as(u32, linux.EPOLL.IN) else linux.EPOLL.OUT) |
                    linux.EPOLL.ERR | linux.EPOLL.HUP | linux.EPOLL.ONESHOT,
                .data = .{ .ptr = @intFromPtr(this) },
            };
            const operation: u32 = if (this.registered) linux.EPOLL.CTL_MOD else linux.EPOLL.CTL_ADD;
            while (true) {
                const result = linux.epoll_ctl(loop_.poll_fd.native(), operation, fd.native(), &event);
                if (bun.sys.getErrno(result) == .INTR) continue;
                if (bun.sys.Maybe(void).errnoSys(result, .epoll_ctl)) |err| return err;
                break;
            }
        } else {
            var change = this.kqueueEvent(fd, interest, std.c.EV.ADD | std.c.EV.ONESHOT);
            switch (Kqueue.change(loop_.poll_fd, &change)) {
                .result => {},
                .err => |err| return .{ .err = err },
            }
        }
        this.registered = true;
        this.interest = interest;
        return .success;
    }

    fn unregister(this: *Poll, loop_: *Loop, fd: bun.FD) void {
        if (!this.registered) return;
        if (comptime Environment.isLinux) {
            while (true) {
                const result = linux.epoll_ctl(loop_.poll_fd.native(), linux.EPOLL.CTL_DEL, fd.native(), null);
                switch (bun.sys.getErrno(result)) {
                    .INTR => continue,
                    .SUCCESS, .NOENT => break,
                    else => |err| bun.Output.panic("failed to remove owned file poll: {s}", .{@tagName(err)}),
                }
            }
        } else {
            var change = this.kqueueEvent(fd, this.interest, std.c.EV.DELETE);
            switch (Kqueue.change(loop_.poll_fd, &change)) {
                .result => {},
                .err => |err| if (err.getErrno() != .NOENT) {
                    bun.Output.panic("failed to remove owned file poll: {s}", .{@tagName(err.getErrno())});
                },
            }
        }
        this.registered = false;
    }

    fn kqueueEvent(this: *Poll, fd: bun.FD, interest: Readiness, flags: u16) KEvent {
        var event = std.mem.zeroes(KEvent);
        event.ident = @intCast(fd.native());
        event.filter = if (interest == .readable) std.c.EVFILT.READ else std.c.EVFILT.WRITE;
        event.flags = flags;
        event.udata = @intFromPtr(this);
        return event;
    }
};

const Kqueue = @import("./Kqueue.zig");
const KEvent = Kqueue.Event;
pub const Waker = @import("./Waker.zig");

pub const retry = bun.sys.E.AGAIN;
pub const ReadState = @import("./pipes.zig").ReadState;
pub const PipeReader = @import("./PipeReader.zig").PipeReader;
pub const BufferedReader = @import("./PipeReader.zig").BufferedReader;
pub const BufferedWriter = @import("./PipeWriter.zig").BufferedWriter;
pub const WriteResult = @import("./PipeWriter.zig").WriteResult;
pub const WriteStatus = @import("./PipeWriter.zig").WriteStatus;
pub const WriterStartOptions = @import("./PipeWriter.zig").WriterStartOptions;
pub const StreamingWriter = @import("./PipeWriter.zig").StreamingWriter;
pub const StreamBuffer = @import("./PipeWriter.zig").StreamBuffer;
pub const FileType = @import("./pipes.zig").FileType;
pub const MaxBuf = @import("./MaxBuf.zig");

const std = @import("std");
const bun = @import("bun");
const Environment = bun.Environment;
const linux = std.os.linux;
