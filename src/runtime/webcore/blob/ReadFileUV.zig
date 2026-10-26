const ReadFileUV = @This();

loop: *uv.Loop,
store: bun.bindgen.RefNative(Core.Store, .any),
file_store: Core.Store.File,
completion: ?Completion,
offset: Core.SizeType,
max_length: Core.SizeType,
total_size: Core.SizeType = 0,
read_off: Core.SizeType = 0,
last_modified: ?Core.Store.Timestamp = null,
opened_fd: bun.FD = bun.invalid_fd,
buffer: std.ArrayListUnmanaged(u8) = .empty,
failure: ?Core.Failure = null,
phase: enum { idle, opening, stating, reading, closing } = .idle,
cancelled: bool = false,
regular_file: bool = false,
request: uv.fs_t = std.mem.zeroes(uv.fs_t),
read_buffer: [1]uv.uv_buf_t = undefined,

pub const Completion = struct {
    context: *anyopaque,
    callback: Core.ReadFileOnReadFileCallback,
};

pub fn create(loop: *uv.Loop, store: *Core.Store, offset: Core.SizeType, max_length: Core.SizeType, completion: Completion) bun.OOM!*ReadFileUV {
    const this = try bun.default_allocator.create(ReadFileUV);
    this.* = .{
        .loop = loop,
        .store = .init(store),
        .file_store = store.data.file,
        .completion = completion,
        .offset = offset,
        .max_length = max_length,
    };
    FileIO.prepareBorrowedFd(this);
    return this;
}

pub fn start(this: *ReadFileUV) void {
    bun.assert(this.phase == .idle and !this.cancelled);
    if (this.failure != null) return this.finish();
    if (this.opened_fd != bun.invalid_fd) return this.stat();
    var path_buffer: bun.PathBuffer = undefined;
    const path = this.file_store.pathlike.path.sliceZ(&path_buffer);
    this.request.data = this;
    this.phase = .opening;
    const result = uv.uv_fs_open(this.loop, &this.request, path, uv.O.RDONLY | uv.O.NONBLOCK | uv.O.SEQUENTIAL, 0, onOpen);
    if (result.errEnum()) |err| {
        this.request.deinit();
        this.phase = .idle;
        this.setError(err, .open);
        this.finish();
    }
}

pub fn detach(this: *ReadFileUV) void {
    this.completion = null;
    this.cancelled = true;
    switch (this.phase) {
        .idle => this.finish(),
        .opening, .stating, .reading => _ = uv.uv_cancel(@ptrCast(&this.request)),
        .closing => {},
    }
}

pub fn setFileOpenerError(this: *ReadFileUV, err: bun.sys.Error) void {
    if (this.failure == null) this.failure = .{ .system = err };
}

fn setError(this: *ReadFileUV, err: bun.sys.E, comptime syscall: bun.sys.Tag) void {
    if (this.failure != null) return;
    this.failure = if (err == .NOMEM) .out_of_memory else .{ .system = bun.sys.Error.fromCode(err, syscall) };
}

fn onOpen(request: *uv.fs_t) callconv(.c) void {
    const this: *ReadFileUV = @fieldParentPtr("request", request);
    const result = request.result;
    request.deinit();
    this.phase = .idle;
    if (result.errEnum()) |err| this.setError(err, .open) else this.opened_fd = result.toFD();
    if (this.cancelled or this.failure != null) return this.finish();
    this.stat();
}

fn stat(this: *ReadFileUV) void {
    this.request.data = this;
    this.phase = .stating;
    const result = uv.uv_fs_fstat(this.loop, &this.request, this.opened_fd.uv(), onStat);
    if (result.errEnum()) |err| {
        this.request.deinit();
        this.phase = .idle;
        this.setError(err, .fstat);
        this.finish();
    }
}

fn onStat(request: *uv.fs_t) callconv(.c) void {
    const this: *ReadFileUV = @fieldParentPtr("request", request);
    const failure = request.result.errEnum();
    if (this.cancelled or failure != null) {
        request.deinit();
        this.phase = .idle;
        if (failure) |err| this.setError(err, .fstat);
        return this.finish();
    }
    const metadata = request.statbuf;
    request.deinit();
    this.phase = .idle;
    if (bun.S.ISDIR(@intCast(metadata.mode))) {
        this.failure = .directory;
        return this.finish();
    }
    this.regular_file = bun.isRegularFile(metadata.mode);
    this.total_size = @intCast(@min(@max(metadata.size, 0), BlobSize.max_size));
    this.last_modified = Core.timestampMilliseconds(metadata.mtime().sec, metadata.mtime().nsec);
    if (!this.regular_file) this.offset = 0;
    this.read();
}

fn read(this: *ReadFileUV) void {
    if (this.cancelled or this.read_off == this.max_length) return this.finish();
    const remaining = this.max_length - this.read_off;
    const amount: usize = @intCast(@min(remaining, 64 * 1024));
    this.buffer.ensureUnusedCapacity(bun.default_allocator, amount) catch {
        this.failure = .out_of_memory;
        return this.finish();
    };
    this.read_buffer[0] = .init(this.buffer.unusedCapacitySlice()[0..amount]);
    this.request.data = this;
    this.phase = .reading;
    const offset: i64 = if (this.regular_file) @intCast(@as(u64, this.offset) + this.read_off) else -1;
    const result = uv.uv_fs_read(this.loop, &this.request, this.opened_fd.uv(), &this.read_buffer, 1, offset, onRead);
    if (result.errEnum()) |err| {
        this.request.deinit();
        this.phase = .idle;
        this.setError(err, .read);
        this.finish();
    }
}

fn onRead(request: *uv.fs_t) callconv(.c) void {
    const this: *ReadFileUV = @fieldParentPtr("request", request);
    const result = request.result;
    request.deinit();
    this.phase = .idle;
    if (result.errEnum()) |err| this.setError(err, .read);
    if (this.cancelled or this.failure != null or result.int() == 0) return this.finish();
    const amount: usize = @intCast(result.int());
    bun.assert(amount <= this.read_buffer[0].len);
    this.buffer.items.len += amount;
    this.read_off += @intCast(amount);
    this.read();
}

fn finish(this: *ReadFileUV) void {
    bun.assert(this.phase == .idle);
    if (this.opened_fd == bun.invalid_fd) return this.finalize();
    const fd = this.opened_fd;
    this.opened_fd = bun.invalid_fd;
    this.request.data = this;
    this.phase = .closing;
    const result = uv.uv_fs_close(this.loop, &this.request, fd.uv(), onClose);
    if (result.errEnum() != null) {
        this.request.deinit();
        this.phase = .idle;
        if (fd.closeAllowingStandardIo(null)) |err| this.setFileOpenerError(err);
        this.finalize();
    }
}

fn onClose(request: *uv.fs_t) callconv(.c) void {
    const this: *ReadFileUV = @fieldParentPtr("request", request);
    const result = request.result;
    request.deinit();
    this.phase = .idle;
    if (result.errEnum()) |err| this.setError(err, .close);
    this.finalize();
}

fn finalize(this: *ReadFileUV) void {
    const completion = this.completion;
    if (completion != null) {
        if (this.last_modified) |timestamp| this.store.get().data.file.last_modified = timestamp;
    }
    const result: Core.ReadFileResultType = if (completion == null)
        .cancelled
    else if (this.failure) |failure|
        failure.toResult(this.file_store.pathlike)
    else result: {
        const bytes = this.buffer.toOwnedSlice(bun.default_allocator) catch break :result .out_of_memory;
        const observed_size = if (this.read_off > 0) this.offset +| this.read_off else 0;
        break :result .{ .result = .{ .buf = bytes, .total_size = @max(this.total_size, observed_size) } };
    };
    this.buffer.deinit(bun.default_allocator);
    this.store.deinit();
    bun.destroy(this);
    if (completion) |done| done.callback(done.context, result);
}

const std = @import("std");
const bun = @import("bun");
const uv = bun.windows.libuv;
const Core = @import("./read_file.zig");
const FileIO = @import("./FileIO.zig");
const BlobSize = @import("../BlobSize.zig");
