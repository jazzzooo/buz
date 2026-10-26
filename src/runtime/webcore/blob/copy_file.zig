pub const CopyFileResult = @import("./write_file.zig").WriteFileResultType;

pub const CopyFileCompletion = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, CopyFileResult) void,

    pub fn init(comptime Context: type, context: *Context, comptime callback: *const fn (*Context, CopyFileResult) void) CopyFileCompletion {
        const Adapter = struct {
            fn run(opaque_context: *anyopaque, result: CopyFileResult) void {
                callback(@ptrCast(@alignCast(opaque_context)), result);
            }
        };
        return .{ .context = context, .callback = Adapter.run };
    }

    pub fn complete(this: CopyFileCompletion, result: CopyFileResult) void {
        this.callback(this.context, result);
    }
};

pub const CopyFile = struct {
    source: StoreRange.Owned,
    destination: StoreRange.Owned,
    plan: CopyPlan,
    source_fd: bun.FD = .invalid,
    destination_fd: bun.FD = .invalid,
    source_regular: bool = false,
    source_socket: bool = false,
    destination_regular: bool = false,
    destination_append: bool = false,
    kernel_copy: bool = false,
    skip_remaining: u64 = 0,
    buffer: []u8 = &.{},
    chunk: ?CopyPlan.Chunk = null,
    loaded: usize = 0,
    sent: usize = 0,
    stage: enum { reading, writing } = .reading,
    failure: ?Failure = null,
    cancelled: std.atomic.Value(bool) = .init(false),
    source_io: FileIO.AsyncIO(@This(), "source_io") = .{},
    destination_io: FileIO.AsyncIO(@This(), "destination_io") = .{},
    delivery: ?bun.WorkTaskContext = null,
    completion: CopyFileCompletion,
    mkdirp_if_not_exists: bool,
    destination_mode: ?bun.Mode,

    const Failure = bun.io.Failure;

    pub fn create(destination: StoreRange, source: StoreRange, completion: CopyFileCompletion, mkdirp: bool, mode: ?bun.Mode) bun.OOM!*CopyFile {
        const this = try bun.default_allocator.create(CopyFile);
        this.* = .{
            .source = .init(source),
            .destination = .init(destination),
            .plan = .init(source, destination),
            .completion = completion,
            .mkdirp_if_not_exists = mkdirp,
            .destination_mode = mode,
        };
        this.prepareDescriptor(.source);
        if (this.failure == null) this.prepareDescriptor(.destination);
        return this;
    }

    const Which = enum { source, destination };

    fn pathlike(this: *const CopyFile, comptime which: Which) @import("../../node/types.zig").PathOrFileDescriptor {
        return @field(this, @tagName(which)).storePtr().data.file.pathlike;
    }

    fn fdPointer(this: *CopyFile, comptime which: Which) *bun.FD {
        return &@field(this, @tagName(which) ++ "_fd");
    }

    fn prepareDescriptor(this: *CopyFile, comptime which: Which) void {
        const path = this.pathlike(which);
        if (path != .fd) return;
        switch (FileIO.duplicate(path.fd)) {
            .result => |fd| this.fdPointer(which).* = fd,
            .err => |err| this.setError(err, which),
        }
    }

    fn setError(this: *CopyFile, err: bun.sys.Error, comptime which: Which) void {
        if (this.failure == null) this.failure = .fromSystem(err.withPathLike(this.pathlike(which)));
    }

    fn consumeIOFailure(this: *CopyFile, comptime which: Which) void {
        const failure = @field(this, @tagName(which) ++ "_io").takeError() orelse return;
        switch (failure) {
            .system => |err| this.setError(err, which),
            .out_of_memory, .concurrency_unavailable => if (this.failure == null) {
                this.failure = failure;
            },
        }
    }

    pub fn setFileOpenerError(this: *CopyFile, err: bun.sys.Error) void {
        this.setError(err, .destination);
    }

    fn open(this: *CopyFile, comptime which: Which) bool {
        const fd = this.fdPointer(which);
        if (fd.isValid()) return true;
        var path_buffer: bun.PathBuffer = undefined;
        var path_string = this.pathlike(which).path;
        const path = path_string.sliceZ(&path_buffer);
        const flags = bun.O.CLOEXEC | bun.O.NONBLOCK | (if (which == .source) bun.O.RDONLY else bun.O.WRONLY | bun.O.CREAT);
        while (!this.isCancelled()) {
            switch (bun.sys.open(path, flags, this.destination_mode orelse NodeFSCore.default_permission)) {
                .result => |opened| {
                    fd.* = opened;
                    return true;
                },
                .err => |err| {
                    if (comptime which == .destination) {
                        switch (FileIO.mkdirIfNotExists(this, err, path, path_string.slice())) {
                            .@"continue" => continue,
                            .fail => return false,
                            .no => {},
                        }
                    }
                    this.setError(err, which);
                    return false;
                },
            }
        }
        return false;
    }

    pub fn run(this: *CopyFile, delivery: bun.WorkTaskContext) void {
        this.delivery = delivery;
        if (this.failure != null or this.isCancelled() or !this.prepare()) return this.onFinish();
        this.update();
    }

    fn prepare(this: *CopyFile) bool {
        if (!this.open(.source)) return false;
        const source_stat = switch (bun.sys.fstat(this.source_fd)) {
            .result => |value| value,
            .err => |err| {
                this.setError(err, .source);
                return false;
            },
        };
        if (bun.S.ISDIR(@intCast(source_stat.mode))) {
            this.setError(bun.sys.Error.fromCode(.ISDIR, .fstat), .source);
            return false;
        }
        if (!this.open(.destination)) return false;
        const destination_stat = switch (bun.sys.fstat(this.destination_fd)) {
            .result => |value| value,
            .err => |err| {
                this.setError(err, .destination);
                return false;
            },
        };
        if (bun.S.ISDIR(@intCast(destination_stat.mode))) {
            this.setError(bun.sys.Error.fromCode(.ISDIR, .fstat), .destination);
            return false;
        }
        this.source_regular = bun.isRegularFile(source_stat.mode);
        this.source_socket = std.posix.S.ISSOCK(@intCast(source_stat.mode));
        this.destination_regular = bun.isRegularFile(destination_stat.mode);
        if (this.destination_regular) {
            this.destination_append = switch (FileIO.isAppend(this.destination_fd)) {
                .result => |value| value,
                .err => |err| {
                    this.setError(err, .destination);
                    return false;
                },
            };
            if (this.destination_append) this.plan.destination_offset = @intCast(@max(destination_stat.size, 0));
        }
        if (this.source_regular and this.destination_regular and
            source_stat.dev == destination_stat.dev and source_stat.ino == destination_stat.ino)
        {
            this.plan.setSameFile(@intCast(@max(source_stat.size, 0)));
        }
        this.kernel_copy = Environment.isLinux and this.source_regular and this.destination_regular and
            !this.destination_append and !this.plan.in_place and bun.canUseCopyFileRangeSyscall();
        if (!this.source_regular) this.skip_remaining = this.source.offset;
        return true;
    }

    pub fn requestCancel(this: *CopyFile) void {
        this.cancelled.store(true, .release);
        this.source_io.requestCancel();
        this.destination_io.requestCancel();
    }

    fn isCancelled(this: *const CopyFile) bool {
        return this.cancelled.load(.acquire) or this.source_io.isCancelled() or this.destination_io.isCancelled();
    }

    pub fn onScheduleError(this: *CopyFile, err: anyerror) void {
        if (this.failure == null) this.failure = if (err == error.OutOfMemory) .out_of_memory else .concurrency_unavailable;
    }

    fn copyKernelChunk(this: *CopyFile) bool {
        if (comptime !Environment.isLinux) return false;
        const chunk = this.plan.next(16 * 1024 * 1024) orelse return false;
        var source_offset: std.os.linux.off_t = @intCast(chunk.source_offset);
        var destination_offset: std.os.linux.off_t = @intCast(chunk.destination_offset);
        const result = std.os.linux.copy_file_range(this.source_fd.native(), &source_offset, this.destination_fd.native(), &destination_offset, chunk.length, 0);
        switch (bun.sys.getErrno(result)) {
            .SUCCESS => {
                if (result > 0) {
                    this.plan.advance(result);
                    return true;
                }
            },
            .INTR => return true,
            .NOSYS, .XDEV, .OPNOTSUPP, .INVAL, .BADF => {},
            else => |err| {
                this.setError(bun.sys.Error.fromCode(err, .copy_file_range), .source);
                return false;
            },
        }
        this.kernel_copy = false;
        return false;
    }

    pub fn update(this: *CopyFile) void {
        this.consumeIOFailure(.source);
        this.consumeIOFailure(.destination);
        copying: while (!this.isCancelled() and this.failure == null) {
            switch (this.stage) {
                .reading => {
                    if (this.plan.written == this.plan.limit) break;
                    if (this.kernel_copy) {
                        if (this.copyKernelChunk()) continue;
                        if (this.failure != null) break;
                    }
                    if (this.buffer.len == 0) {
                        this.buffer = bun.default_allocator.alloc(u8, 64 * 1024) catch {
                            this.failure = .out_of_memory;
                            break;
                        };
                    }
                    if (this.chunk == null) {
                        this.chunk = if (this.skip_remaining > 0) .{
                            .source_offset = 0,
                            .destination_offset = 0,
                            .length = @intCast(@min(this.skip_remaining, this.buffer.len)),
                        } else this.plan.next(this.buffer.len).?;
                        this.loaded = 0;
                        this.sent = 0;
                    }
                    if (!this.source_regular and bun.isReadable(this.source_fd) == .not_ready) {
                        if (this.source_io.wait(this.source_fd, .readable)) return;
                        break;
                    }
                    const chunk = this.chunk.?;
                    const buffer = this.buffer[this.loaded..chunk.length];
                    const result = if (this.source_regular)
                        bun.sys.pread(this.source_fd, buffer, @intCast(chunk.source_offset + this.loaded))
                    else if (this.source_socket)
                        bun.sys.recvNonBlock(this.source_fd, buffer)
                    else
                        bun.sys.read(this.source_fd, buffer);
                    const amount = switch (result) {
                        .result => |value| value,
                        .err => |err| {
                            if (err.getErrno() == .AGAIN and !this.source_regular) {
                                if (this.source_io.wait(this.source_fd, .readable)) return;
                            } else this.setError(err, .source);
                            break :copying;
                        },
                    };
                    if (amount == 0) {
                        if (this.plan.backward) this.setError(bun.sys.Error.fromCode(.IO, .read), .source);
                        break;
                    }
                    if (this.skip_remaining > 0) {
                        this.skip_remaining -= amount;
                        this.chunk = null;
                        continue;
                    }
                    this.loaded += amount;
                    if (this.plan.backward and this.loaded < chunk.length) continue;
                    this.stage = .writing;
                },
                .writing => {
                    if (!this.destination_regular and bun.isWritable(this.destination_fd) == .not_ready) {
                        if (this.destination_io.wait(this.destination_fd, .writable)) return;
                        break;
                    }
                    const buffer = this.buffer[this.sent..this.loaded];
                    const result = if (this.destination_regular and !this.destination_append)
                        bun.sys.pwrite(this.destination_fd, buffer, @intCast(this.chunk.?.destination_offset + this.sent))
                    else
                        bun.sys.write(this.destination_fd, buffer);
                    const amount = switch (result) {
                        .result => |value| value,
                        .err => |err| {
                            if (err.getErrno() == .AGAIN and !this.destination_regular) {
                                if (this.destination_io.wait(this.destination_fd, .writable)) return;
                            } else this.setError(err, .destination);
                            break :copying;
                        },
                    };
                    if (amount == 0) {
                        this.setError(bun.sys.Error.fromCode(.IO, .write), .destination);
                        break;
                    }
                    this.sent += amount;
                    this.plan.advance(amount);
                    if (this.sent == this.loaded) {
                        this.chunk = null;
                        this.stage = .reading;
                    }
                },
            }
        }
        this.onFinish();
    }

    pub fn onFinish(this: *CopyFile) void {
        this.consumeIOFailure(.source);
        this.consumeIOFailure(.destination);
        if (this.source_io.finish()) return;
        if (this.destination_io.finish()) return;
        if (!this.isCancelled() and this.failure == null and this.destination_fd.isValid()) {
            if (this.destination_regular and this.pathlike(.destination) == .path and this.destination.offset == 0) {
                switch (bun.sys.ftruncate(this.destination_fd, @intCast(this.plan.written))) {
                    .result => {},
                    .err => |err| this.setError(err, .destination),
                }
            }
            if (this.destination_mode) |mode| {
                if (this.failure == null) switch (bun.sys.fchmod(this.destination_fd, mode)) {
                    .result => {},
                    .err => |err| this.setError(err, .destination),
                };
            }
        }
        this.close(.source);
        this.close(.destination);
        const delivery = this.delivery.?;
        this.delivery = null;
        delivery.finish();
    }

    fn close(this: *CopyFile, comptime which: Which) void {
        const fd = this.fdPointer(which);
        if (fd.isValid()) {
            const owned = fd.*;
            fd.* = .invalid;
            if (owned.closeAllowingStandardIo(null)) |err| this.setError(err, which);
        }
    }

    pub fn then(this: *CopyFile) void {
        const completion = this.completion;
        const result: CopyFileResult = if (this.failure) |failure| switch (failure) {
            .out_of_memory => .out_of_memory,
            .concurrency_unavailable => .concurrency_unavailable,
            .system => |err| result: {
                const payload = bun.bindgen.SystemError.fromSysError(err) catch break :result .out_of_memory;
                break :result .{ .system_error = payload };
            },
        } else .{ .written = @intCast(this.plan.written) };
        this.deinitUnscheduled();
        completion.complete(result);
    }

    pub fn discard(this: *CopyFile) void {
        const completion = this.completion;
        this.deinitUnscheduled();
        completion.complete(.cancelled);
    }

    pub fn deinitUnscheduled(this: *CopyFile) void {
        bun.assert(this.delivery == null);
        this.close(.source);
        this.close(.destination);
        this.source.deinit();
        this.destination.deinit();
        bun.default_allocator.free(this.buffer);
        bun.destroy(this);
    }
};

const std = @import("std");
const bun = @import("bun");
const Environment = bun.Environment;
const FileIO = @import("./FileIO.zig");
const CopyPlan = @import("./CopyPlan.zig");
const StoreRange = @import("./StoreRange.zig");
const NodeFSCore = @import("../../node/NodeFSCore.zig");
