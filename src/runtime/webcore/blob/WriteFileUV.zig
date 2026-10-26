const WriteFileUV = @This();

loop: *uv.Loop,
file_blob: Core.RetainedStoreRange,
bytes_blob: Core.RetainedStoreRange,
completion: ?Completion,
path: ?[:0]u8 = null,
opened_fd: bun.FD = bun.invalid_fd,
failure: ?Failure = null,
phase: enum { idle, opening, stating, mkdir, writing, truncating, chmod, closing } = .idle,
cancelled: bool = false,
regular_file: bool = false,
append: bool = false,
metadata_finished: bool = false,
mkdirp_if_not_exists: bool,
parent_directories: ?ParentDirectories = null,
creation_mode: ?bun.Mode,
total_written: usize = 0,
request: uv.fs_t = std.mem.zeroes(uv.fs_t),
write_buffer: [1]uv.uv_buf_t = undefined,

const Failure = union(enum) { system: bun.sys.Error, out_of_memory };

pub const Completion = struct {
    context: *anyopaque,
    callback: Core.WriteFileOnWriteFileCallback,
};

pub fn create(loop: *uv.Loop, file: Core.StoreRange, bytes: Core.StoreRange, completion: Completion, mkdirp: bool, mode: ?bun.Mode) bun.OOM!*WriteFileUV {
    const this = try bun.default_allocator.create(WriteFileUV);
    this.* = .{
        .loop = loop,
        .file_blob = .init(file),
        .bytes_blob = .init(bytes),
        .completion = completion,
        .mkdirp_if_not_exists = mkdirp,
        .creation_mode = mode,
    };
    errdefer this.destroy();
    switch (file.store.data.file.pathlike) {
        .path => |path| this.path = try bun.default_allocator.dupeSentinel(u8, path.slice(), 0),
        .fd => FileIO.prepareBorrowedFd(this),
    }
    return this;
}

pub fn start(this: *WriteFileUV) void {
    bun.assert(this.phase == .idle and !this.cancelled);
    if (this.failure != null) return this.finish();
    if (this.opened_fd != bun.invalid_fd) return this.stat();
    this.open();
}

pub fn detach(this: *WriteFileUV) void {
    this.completion = null;
    this.cancelled = true;
    switch (this.phase) {
        .idle => this.finish(),
        .opening, .stating, .mkdir, .writing, .truncating, .chmod => _ = uv.uv_cancel(@ptrCast(&this.request)),
        .closing => {},
    }
}

pub fn setFileOpenerError(this: *WriteFileUV, err: bun.sys.Error) void {
    if (this.failure == null) this.failure = if (err.getErrno() == .NOMEM)
        .out_of_memory
    else
        .{ .system = err.withPathLike(this.file_blob.storePtr().data.file.pathlike) };
}

fn setError(this: *WriteFileUV, err: bun.sys.E, comptime syscall: bun.sys.Tag) void {
    if (this.failure != null) return;
    if (err == .NOMEM) {
        this.failure = .out_of_memory;
        return;
    }
    var failure = bun.sys.Error.fromCode(err, syscall);
    if (syscall == .mkdir) {
        failure = failure.withPath(this.path.?[0..this.parent_directories.?.current]);
    } else {
        failure = failure.withPathLike(this.file_blob.storePtr().data.file.pathlike);
    }
    this.failure = .{ .system = failure };
}

fn open(this: *WriteFileUV) void {
    if (this.cancelled) return this.finish();
    this.request.data = this;
    this.phase = .opening;
    const result = uv.uv_fs_open(this.loop, &this.request, this.path.?.ptr, uv.O.CREAT | uv.O.WRONLY | uv.O.NOCTTY | uv.O.NONBLOCK | uv.O.SEQUENTIAL, this.creation_mode orelse 0o644, onOpen);
    if (result.errEnum()) |err| {
        this.request.deinit();
        this.phase = .idle;
        this.setError(err, .open);
        this.finish();
    }
}

fn onOpen(request: *uv.fs_t) callconv(.c) void {
    const this: *WriteFileUV = @fieldParentPtr("request", request);
    const result = request.result;
    request.deinit();
    this.phase = .idle;
    if (result.errEnum()) |err| {
        if (!this.cancelled and err == .NOENT and this.mkdirp_if_not_exists) {
            this.mkdirp_if_not_exists = false;
            this.parent_directories = ParentDirectories.init(this.path.?);
            if (this.parent_directories != null) return this.mkdir();
        }
        this.setError(err, .open);
    } else {
        this.opened_fd = result.toFD();
    }
    if (this.cancelled or this.failure != null) return this.finish();
    this.stat();
}

fn stat(this: *WriteFileUV) void {
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
    const this: *WriteFileUV = @fieldParentPtr("request", request);
    const failure = request.result.errEnum();
    if (this.cancelled or failure != null) {
        request.deinit();
        this.phase = .idle;
        if (failure) |err| this.setError(err, .fstat);
        return this.finish();
    }
    const mode = request.statbuf.mode;
    request.deinit();
    this.phase = .idle;
    if (bun.S.ISDIR(@intCast(mode))) {
        this.setError(.ISDIR, .write);
        return this.finish();
    }
    this.regular_file = bun.isRegularFile(mode);
    if (this.regular_file) {
        this.append = switch (FileIO.isAppend(this.opened_fd)) {
            .result => |append| append,
            .err => |err| {
                this.setFileOpenerError(err);
                return this.finish();
            },
        };
    }
    this.write();
}

fn mkdir(this: *WriteFileUV) void {
    if (this.cancelled) return this.finish();
    this.request.data = this;
    this.phase = .mkdir;
    const path = this.path.?;
    const length = this.parent_directories.?.current;
    const terminator = path[length];
    path[length] = 0;
    const result = uv.uv_fs_mkdir(this.loop, &this.request, path.ptr, 0o777, onMkdir);
    // libuv copies the path during submission; later opens need the full path.
    path[length] = terminator;
    if (result.errEnum()) |err| {
        this.request.deinit();
        this.phase = .idle;
        this.setError(err, .mkdir);
        this.finish();
    }
}

fn onMkdir(request: *uv.fs_t) callconv(.c) void {
    const this: *WriteFileUV = @fieldParentPtr("request", request);
    const result = request.result;
    request.deinit();
    this.phase = .idle;
    if (this.cancelled) return this.finish();
    switch (this.parent_directories.?.advance(this.path.?, result.errEnum())) {
        .more => this.mkdir(),
        .done => this.open(),
        .failed => {
            this.setError(result.errEnum().?, .mkdir);
            this.finish();
        },
    }
}

fn write(this: *WriteFileUV) void {
    var bytes = this.bytes_blob.sharedView();
    bytes = bytes[0..@min(bytes.len, this.file_blob.size)];
    if (this.cancelled or this.total_written == bytes.len) return this.finish();
    const amount = @min(bytes.len - this.total_written, 1024 * 1024);
    this.write_buffer[0] = .init(bytes[this.total_written..][0..amount]);
    this.request.data = this;
    this.phase = .writing;
    const offset: i64 = if (this.regular_file and !this.append) @intCast(@as(u64, this.file_blob.offset) + this.total_written) else -1;
    const result = uv.uv_fs_write(this.loop, &this.request, this.opened_fd.uv(), &this.write_buffer, 1, offset, onWrite);
    if (result.errEnum()) |err| {
        this.request.deinit();
        this.phase = .idle;
        this.setError(err, .write);
        this.finish();
    }
}

fn onWrite(request: *uv.fs_t) callconv(.c) void {
    const this: *WriteFileUV = @fieldParentPtr("request", request);
    const result = request.result;
    request.deinit();
    this.phase = .idle;
    if (result.errEnum()) |err| this.setError(err, .write);
    if (this.cancelled or this.failure != null) return this.finish();
    const amount: usize = @intCast(result.int());
    if (amount == 0) {
        this.setError(.IO, .write);
        return this.finish();
    }
    bun.assert(amount <= this.write_buffer[0].len);
    this.total_written += amount;
    this.write();
}

fn finish(this: *WriteFileUV) void {
    bun.assert(this.phase == .idle);
    if (this.opened_fd == bun.invalid_fd) return this.finalize();
    if (this.failure == null and !this.cancelled and !this.metadata_finished) {
        this.metadata_finished = true;
        if (this.regular_file and this.path != null and this.file_blob.offset == 0) {
            this.request.data = this;
            this.phase = .truncating;
            const result = uv.uv_fs_ftruncate(this.loop, &this.request, this.opened_fd.uv(), @intCast(this.total_written), onTruncate);
            if (result.errEnum()) |err| {
                this.request.deinit();
                this.phase = .idle;
                this.setError(err, .ftruncate);
                this.close();
            }
            return;
        }
        return this.chmod();
    }
    this.close();
}

fn onTruncate(request: *uv.fs_t) callconv(.c) void {
    const this: *WriteFileUV = @fieldParentPtr("request", request);
    const result = request.result;
    request.deinit();
    this.phase = .idle;
    if (result.errEnum()) |err| this.setError(err, .ftruncate);
    if (this.cancelled or this.failure != null) return this.close();
    this.chmod();
}

fn chmod(this: *WriteFileUV) void {
    const mode = this.creation_mode orelse return this.close();
    this.request.data = this;
    this.phase = .chmod;
    const result = uv.uv_fs_fchmod(this.loop, &this.request, this.opened_fd.uv(), mode, onChmod);
    if (result.errEnum()) |err| {
        this.request.deinit();
        this.phase = .idle;
        this.setError(err, .fchmod);
        this.close();
    }
}

fn onChmod(request: *uv.fs_t) callconv(.c) void {
    const this: *WriteFileUV = @fieldParentPtr("request", request);
    const result = request.result;
    request.deinit();
    this.phase = .idle;
    if (result.errEnum()) |err| this.setError(err, .fchmod);
    this.close();
}

fn close(this: *WriteFileUV) void {
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
    const this: *WriteFileUV = @fieldParentPtr("request", request);
    const result = request.result;
    request.deinit();
    this.phase = .idle;
    if (result.errEnum()) |err| this.setError(err, .close);
    this.finalize();
}

fn finalize(this: *WriteFileUV) void {
    const completion = this.completion;
    const result: Core.WriteFileResultType = if (completion == null)
        .cancelled
    else if (this.failure) |failure| switch (failure) {
        .out_of_memory => .out_of_memory,
        .system => |err| error_result: {
            const payload = bun.bindgen.SystemError.fromSysError(err) catch break :error_result .out_of_memory;
            break :error_result .{ .system_error = payload };
        },
    } else .{ .written = @intCast(this.total_written) };
    this.destroy();
    if (completion) |done| done.callback(done.context, result);
}

fn destroy(this: *WriteFileUV) void {
    FileIO.closeOwnedFd(this);
    this.bytes_blob.deinit();
    this.file_blob.deinit();
    if (this.path) |path| bun.default_allocator.free(path);
    bun.destroy(this);
}

const std = @import("std");
const bun = @import("bun");
const uv = bun.windows.libuv;
const Core = @import("./write_file.zig");
const FileIO = @import("./FileIO.zig");
const ParentDirectories = @import("./ParentDirectories.zig");
