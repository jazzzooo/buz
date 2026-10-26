pub const WriteFileResultType = union(enum) {
    written: SizeType,
    system_error: bindgen.SystemError,
    concurrency_unavailable,
    out_of_memory,
    cancelled,

    pub fn deinit(this: *WriteFileResultType) void {
        switch (this.*) {
            .system_error => |*err| err.deinit(),
            .written, .concurrency_unavailable, .out_of_memory, .cancelled => {},
        }
        this.* = .cancelled;
    }
};
pub const WriteFileOnWriteFileCallback = *const fn (ctx: *anyopaque, count: WriteFileResultType) void;

pub const StoreRange = @import("./StoreRange.zig");
pub const RetainedStoreRange = StoreRange.Owned;

pub const WriteFile = struct {
    file_blob: RetainedStoreRange,
    bytes_blob: RetainedStoreRange,

    opened_fd: bun.FD = invalid_fd,
    failure: ?bun.io.Failure = null,
    delivery: ?bun.WorkTaskContext = null,
    async_io: FileIO.AsyncIO(WriteFile, "async_io") = .{},

    onCompleteCtx: *anyopaque = undefined,
    onCompleteCallback: WriteFileOnWriteFileCallback = undefined,
    total_written: usize = 0,

    could_block: bool = false,
    append: bool = false,
    mkdirp_if_not_exists: bool = false,
    creation_mode: ?bun.Mode = null,

    pub const getFd = FileOpener(@This()).getFd;
    pub const open_flags = bun.O.WRONLY | bun.O.CREAT;

    pub fn deinitUnscheduled(this: *WriteFile) void {
        bun.assert(this.delivery == null);
        FileIO.closeOwnedFd(this);
        this.bytes_blob.deinit();
        this.file_blob.deinit();
        bun.destroy(this);
    }

    pub fn requestCancel(this: *WriteFile) void {
        this.async_io.requestCancel();
    }

    pub fn createWithCtx(
        file_blob: StoreRange,
        bytes_blob: StoreRange,
        onWriteFileContext: *anyopaque,
        onCompleteCallback: WriteFileOnWriteFileCallback,
        mkdirp_if_not_exists: bool,
        mode: ?bun.Mode,
    ) bun.OOM!*WriteFile {
        const write_file = try bun.default_allocator.create(WriteFile);
        write_file.* = .{
            .file_blob = .init(file_blob),
            .bytes_blob = .init(bytes_blob),
            .onCompleteCtx = onWriteFileContext,
            .onCompleteCallback = onCompleteCallback,
            .mkdirp_if_not_exists = mkdirp_if_not_exists,
            .creation_mode = mode,
        };
        FileIO.prepareBorrowedFd(write_file);
        return write_file;
    }

    pub fn create(
        file_blob: StoreRange,
        bytes_blob: StoreRange,
        comptime Context: type,
        context: Context,
        comptime callback: fn (ctx: Context, bytes: WriteFileResultType) void,
        mkdirp_if_not_exists: bool,
        mode: ?bun.Mode,
    ) bun.OOM!*WriteFile {
        const Handler = struct {
            pub fn run(ptr: *anyopaque, bytes: WriteFileResultType) void {
                callback(bun.cast(Context, ptr), bytes);
            }
        };

        return try WriteFile.createWithCtx(
            file_blob,
            bytes_blob,
            @as(*anyopaque, @ptrCast(context)),
            Handler.run,
            mkdirp_if_not_exists,
            mode,
        );
    }

    pub fn then(this: *WriteFile) void {
        FileIO.closeOwnedFd(this);
        const cb = this.onCompleteCallback;
        const cb_ctx = this.onCompleteCtx;

        const result: WriteFileResultType = if (this.failure) |failure| switch (failure) {
            .out_of_memory => .out_of_memory,
            .concurrency_unavailable => .concurrency_unavailable,
            .system => |err| result: {
                const payload = bindgen.SystemError.fromSysError(err) catch break :result .out_of_memory;
                break :result .{ .system_error = payload };
            },
        } else .{ .written = @intCast(this.total_written) };
        this.bytes_blob.deinit();
        this.file_blob.deinit();
        bun.destroy(this);
        cb(cb_ctx, result);
    }

    pub fn run(this: *WriteFile, delivery: bun.WorkTaskContext) void {
        if (Environment.isWindows) {
            @panic("todo");
        }
        bun.assert(this.delivery == null);
        this.delivery = delivery;
        if (this.failure != null or this.async_io.isCancelled()) return this.onFinish();
        this.runAsync();
    }

    pub fn discard(this: *WriteFile) void {
        bun.assert(this.delivery == null);
        FileIO.closeOwnedFd(this);
        const cb = this.onCompleteCallback;
        const cb_ctx = this.onCompleteCtx;
        this.bytes_blob.deinit();
        this.file_blob.deinit();
        bun.destroy(this);
        cb(cb_ctx, .cancelled);
    }

    pub fn onScheduleError(this: *WriteFile, err: anyerror) void {
        if (this.failure == null) this.failure = if (err == error.OutOfMemory) .out_of_memory else .concurrency_unavailable;
    }

    pub fn setFileOpenerError(this: *WriteFile, err: bun.sys.Error) void {
        if (this.failure == null) this.failure = .fromSystem(err.withPathLike(this.file_blob.storePtr().data.file.pathlike));
    }

    fn consumeIOFailure(this: *WriteFile) void {
        const failure = this.async_io.takeError() orelse return;
        switch (failure) {
            .system => |err| this.setFileOpenerError(err),
            .out_of_memory, .concurrency_unavailable => if (this.failure == null) {
                this.failure = failure;
            },
        }
    }

    fn runAsync(this: *WriteFile) void {
        this.getFd(runWithFD);
    }

    pub fn onFinish(this: *WriteFile) void {
        this.consumeIOFailure();
        if (this.async_io.finish()) return;
        if (this.opened_fd != invalid_fd) {
            const fd = this.opened_fd;
            if (this.failure == null and !this.async_io.isCancelled()) {
                if (!this.could_block and this.file_blob.storePtr().data.file.pathlike == .path and this.file_blob.offset == 0) {
                    switch (bun.sys.ftruncate(fd, @intCast(this.total_written))) {
                        .result => {},
                        .err => |err| this.setFileOpenerError(err),
                    }
                }
                if (this.creation_mode) |mode| {
                    if (this.failure == null) switch (bun.sys.fchmod(fd, mode)) {
                        .result => {},
                        .err => |err| this.setFileOpenerError(err),
                    };
                }
            }
            this.opened_fd = invalid_fd;
            if (fd.closeAllowingStandardIo(null)) |err| this.setFileOpenerError(err);
        }
        const delivery = this.delivery.?;
        this.delivery = null;
        delivery.finish();
    }

    fn runWithFD(this: *WriteFile, fd_: bun.FD) void {
        if (fd_ == invalid_fd or this.failure != null) {
            this.onFinish();
            return;
        }

        const fd = this.opened_fd;

        const stat = switch (bun.sys.fstat(fd)) {
            .result => |value| value,
            .err => |err| {
                this.setFileOpenerError(err);
                this.onFinish();
                return;
            },
        };
        if (bun.S.ISDIR(@intCast(stat.mode))) {
            this.setFileOpenerError(bun.sys.Error.fromCode(.ISDIR, .write));
            return this.onFinish();
        }
        this.could_block = !bun.isRegularFile(stat.mode);
        if (!this.could_block) {
            this.append = switch (FileIO.isAppend(fd)) {
                .result => |append| append,
                .err => |err| {
                    this.setFileOpenerError(err);
                    return this.onFinish();
                },
            };
        }

        this.doWriteLoop();
    }

    pub fn update(this: *WriteFile) void {
        this.consumeIOFailure();
        this.doWriteLoop();
    }

    fn doWriteLoop(this: *WriteFile) void {
        while (!this.async_io.isCancelled()) {
            var remain = this.bytes_blob.sharedView();
            remain = remain[0..@min(remain.len, this.file_blob.size)];
            remain = remain[this.total_written..];
            remain = remain[0..@min(remain.len, 1024 * 1024)];
            if (remain.len == 0 or this.failure != null) break;
            if (this.could_block and bun.isWritable(this.opened_fd) == .not_ready) {
                if (this.async_io.wait(this.opened_fd, .writable)) return;
                break;
            }
            const result = if (!this.could_block and !this.append)
                bun.sys.pwrite(this.opened_fd, remain, @intCast(@as(u64, this.file_blob.offset) + this.total_written))
            else
                bun.sys.write(this.opened_fd, remain);
            switch (result) {
                .result => |written| {
                    if (written == 0) {
                        this.setFileOpenerError(bun.sys.Error.fromCode(.IO, .write));
                        break;
                    }
                    this.total_written += written;
                },
                .err => |err| {
                    if (err.getErrno() == .INTR) continue;
                    if (err.getErrno() == bun.io.retry and this.could_block) {
                        if (this.async_io.wait(this.opened_fd, .writable)) return;
                    } else {
                        this.setFileOpenerError(err);
                    }
                    break;
                },
            }
        }

        this.onFinish();
    }
};

const bun = @import("bun");
const bindgen = bun.bindgen;
const Environment = bun.Environment;
const invalid_fd = bun.invalid_fd;

const BlobSize = @import("../BlobSize.zig");
const FileIO = @import("./FileIO.zig");
const FileOpener = FileIO.FileOpener;
const SizeType = BlobSize.SizeType;
