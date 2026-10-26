pub const ReadFileOnReadFileCallback = *const fn (ctx: *anyopaque, bytes: ReadFileResultType) void;
pub const ReadFileRead = struct { buf: []u8, total_size: SizeType = 0 };

/// Success transfers a default-allocator byte slice; failure transfers its owned payload.
pub const ReadFileResultType = union(enum) {
    result: ReadFileRead,
    err: bun.bindgen.SystemError,
    out_of_memory,
    cancelled,

    pub fn deinit(this: *ReadFileResultType) void {
        switch (this.*) {
            .result => |read| bun.default_allocator.free(read.buf),
            .err => |*err| err.deinit(),
            .out_of_memory, .cancelled => {},
        }
        this.* = .cancelled;
    }
};

pub const Failure = union(enum) {
    system: bun.sys.Error,
    directory,
    out_of_memory,
    concurrency: anyerror,

    pub fn toResult(this: Failure, pathlike: anytype) ReadFileResultType {
        if (this == .out_of_memory) return .out_of_memory;
        if (this == .concurrency) return .{ .err = bun.bindgen.SystemError.init(.{
            .errno = 0,
            .code = "ERR_CONCURRENCY_UNAVAILABLE",
            .message = @errorName(this.concurrency),
            .syscall = "read",
        }) catch return .out_of_memory };

        var native_error = if (this == .directory)
            bun.sys.Error.fromCode(.ISDIR, .read)
        else
            this.system;
        if (native_error.path.len == 0) native_error = native_error.withPathLike(pathlike);
        var payload = bun.bindgen.SystemError.fromSysError(native_error) catch return .out_of_memory;
        if (this == .directory) {
            const message = bun.bindgen.OwnedBytes.fromSlice("Directories cannot be read like files") catch {
                payload.deinit();
                return .out_of_memory;
            };
            payload.message.deinit();
            payload.message = message;
        }
        return .{ .err = payload };
    }
};

pub const ReadFile = struct {
    file_store: Store.File,
    store: bun.bindgen.RefNative(Store, .any),
    offset: SizeType,
    max_length: SizeType,
    total_size: SizeType = 0,
    read_off: SizeType = 0,
    last_modified: ?Store.Timestamp = null,
    opened_fd: bun.FD = .invalid,
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    failure: ?Failure = null,
    onCompleteCtx: *anyopaque,
    onCompleteCallback: ReadFileOnReadFileCallback,
    delivery: ?bun.WorkTaskContext = null,
    async_io: FileIO.AsyncIO(ReadFile, "async_io") = .{},
    could_block: bool = false,
    socket: bool = false,

    const getFd = FileIO.FileOpener(@This()).getFd;

    pub fn createWithCtx(store: *Store, context: *anyopaque, callback: ReadFileOnReadFileCallback, offset: SizeType, max_length: SizeType) bun.OOM!*ReadFile {
        if (comptime bun.Environment.isWindows) @compileError("use ReadFileUV on Windows");
        const this = try bun.default_allocator.create(ReadFile);
        this.* = .{
            .file_store = store.data.file,
            .offset = offset,
            .max_length = max_length,
            .store = .init(store),
            .onCompleteCtx = context,
            .onCompleteCallback = callback,
        };
        FileIO.prepareBorrowedFd(this);
        return this;
    }

    pub fn create(store: *Store, offset: SizeType, max_length: SizeType, comptime Context: type, context: Context, comptime callback: fn (Context, ReadFileResultType) void) bun.OOM!*ReadFile {
        const Handler = struct {
            fn run(ptr: *anyopaque, result: ReadFileResultType) void {
                callback(@ptrCast(@alignCast(ptr)), result);
            }
        };
        return createWithCtx(store, @ptrCast(context), Handler.run, offset, max_length);
    }

    pub fn deinitUnscheduled(this: *ReadFile) void {
        bun.assert(this.delivery == null);
        FileIO.closeOwnedFd(this);
        this.buffer.deinit(bun.default_allocator);
        this.store.deinit();
        bun.destroy(this);
    }

    pub fn setFileOpenerError(this: *ReadFile, err: bun.sys.Error) void {
        if (this.failure == null) this.failure = if (err.getErrno() == .NOMEM) .out_of_memory else .{ .system = err };
    }

    fn consumeIOFailure(this: *ReadFile) void {
        const failure = this.async_io.takeError() orelse return;
        if (this.failure == null) this.failure = switch (failure) {
            .system => |err| .{ .system = err },
            .out_of_memory => .out_of_memory,
            .concurrency_unavailable => .{ .concurrency = error.ConcurrencyUnavailable },
        };
    }

    pub fn requestCancel(this: *ReadFile) void {
        this.async_io.requestCancel();
    }

    pub fn run(this: *ReadFile, delivery: bun.WorkTaskContext) void {
        bun.assert(this.delivery == null);
        this.delivery = delivery;
        if (this.failure != null or this.async_io.isCancelled()) return this.onFinish();
        this.getFd(runWithFD);
    }

    pub fn onScheduleError(this: *ReadFile, err: anyerror) void {
        if (this.failure == null) this.failure = if (err == error.OutOfMemory) .out_of_memory else .{ .concurrency = err };
    }

    fn runWithFD(this: *ReadFile, fd: bun.FD) void {
        if (this.failure != null or this.async_io.isCancelled()) return this.onFinish();
        const stat = switch (bun.sys.fstat(fd)) {
            .result => |stat| stat,
            .err => |err| {
                this.setFileOpenerError(err);
                return this.onFinish();
            },
        };
        this.last_modified = timestampMilliseconds(stat.mtime().sec, stat.mtime().nsec);
        if (bun.S.ISDIR(@intCast(stat.mode))) {
            this.failure = .directory;
            return this.onFinish();
        }
        this.could_block = !bun.isRegularFile(stat.mode);
        this.socket = std.posix.S.ISSOCK(@intCast(stat.mode));
        this.total_size = @intCast(@min(@max(stat.size, 0), max_size));
        if (this.could_block) this.offset = 0;
        this.update();
    }

    pub fn update(this: *ReadFile) void {
        this.consumeIOFailure();
        while (!this.async_io.isCancelled() and this.failure == null and this.read_off < this.max_length) {
            if (this.could_block and bun.isReadable(this.opened_fd) == .not_ready) {
                if (this.async_io.wait(this.opened_fd, .readable)) return;
                break;
            }
            var stack_buffer: [64 * 1024]u8 = undefined;
            const remaining = this.max_length - this.read_off;
            const bytes = stack_buffer[0..@min(remaining, stack_buffer.len)];
            const result = if (!this.could_block)
                bun.sys.pread(this.opened_fd, bytes, @intCast(@as(u64, this.offset) + this.read_off))
            else if (this.socket)
                bun.sys.recvNonBlock(this.opened_fd, bytes)
            else
                bun.sys.read(this.opened_fd, bytes);
            const amount = switch (result) {
                .result => |amount| amount,
                .err => |err| {
                    if (err.getErrno() == .INTR) continue;
                    if (err.getErrno() == .AGAIN and this.could_block) {
                        if (this.async_io.wait(this.opened_fd, .readable)) return;
                    } else {
                        this.setFileOpenerError(err);
                    }
                    break;
                },
            };
            if (amount == 0) break;
            this.buffer.appendSlice(bun.default_allocator, bytes[0..amount]) catch {
                this.failure = .out_of_memory;
                break;
            };
            this.read_off += @intCast(amount);
        }
        this.onFinish();
    }

    pub fn onFinish(this: *ReadFile) void {
        this.consumeIOFailure();
        if (this.async_io.finish()) return;
        if (this.opened_fd.isValid()) {
            const fd = this.opened_fd;
            this.opened_fd = .invalid;
            if (fd.closeAllowingStandardIo(null)) |err| this.setFileOpenerError(err);
        }
        const delivery = this.delivery.?;
        this.delivery = null;
        delivery.finish();
    }

    pub fn then(this: *ReadFile) void {
        const callback = this.onCompleteCallback;
        const context = this.onCompleteCtx;
        if (this.last_modified) |timestamp| this.store.get().data.file.last_modified = timestamp;
        const result: ReadFileResultType = if (this.failure) |failure|
            failure.toResult(this.file_store.pathlike)
        else result: {
            const bytes = this.buffer.toOwnedSlice(bun.default_allocator) catch break :result .out_of_memory;
            const observed_size = if (this.read_off > 0) this.offset +| this.read_off else 0;
            break :result .{ .result = .{ .buf = bytes, .total_size = @max(this.total_size, observed_size) } };
        };
        this.deinitUnscheduled();
        callback(context, result);
    }

    pub fn discard(this: *ReadFile) void {
        const callback = this.onCompleteCallback;
        const context = this.onCompleteCtx;
        this.deinitUnscheduled();
        callback(context, .cancelled);
    }
};

pub const ReadFileUV = @import("./ReadFileUV.zig");

pub fn timestampMilliseconds(sec: isize, nsec: isize) u52 {
    const milliseconds = @as(u64, @intCast(@divTrunc(nsec, std.time.ns_per_ms)));
    return @truncate(@as(u64, @intCast(sec * std.time.ms_per_s)) + milliseconds);
}

pub const Store = @import("./Store.zig");
pub const SizeType = BlobSize.SizeType;

const std = @import("std");
const bun = @import("bun");
const BlobSize = @import("../BlobSize.zig");
const FileIO = @import("./FileIO.zig");
const max_size = BlobSize.max_size;
