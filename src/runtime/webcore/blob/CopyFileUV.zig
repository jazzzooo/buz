const CopyFileUV = @This();

loop: *uv.Loop,
source: StoreRange.Owned,
destination: StoreRange.Owned,
source_path: ?[:0]u8 = null,
destination_path: ?[:0]u8 = null,
source_fd: bun.FD = .invalid,
destination_fd: bun.FD = .invalid,
source_regular: bool = false,
destination_regular: bool = false,
destination_append: bool = false,
source_device: u64 = 0,
source_inode: u64 = 0,
source_size: u64 = 0,
plan: CopyPlan,
skip_remaining: u64 = 0,
buffer: []u8 = &.{},
chunk: ?CopyPlan.Chunk = null,
loaded: usize = 0,
sent: usize = 0,
completion: ?Core.CopyFileCompletion,
failure: ?Failure = null,
cancelled: bool = false,
mkdirp_if_not_exists: bool,
parent_directories: ?ParentDirectories = null,
destination_mode: ?bun.Mode,
truncated: bool = false,
mode_applied: bool = false,
phase: Phase = .idle,
request: uv.fs_t = std.mem.zeroes(uv.fs_t),
io_buffer: [1]uv.uv_buf_t = undefined,

const Failure = union(enum) { system: bun.sys.Error, out_of_memory };
const Which = enum { source, destination };
const Phase = enum {
    idle,
    opening_source,
    opening_destination,
    stating_source,
    stating_destination,
    mkdir,
    reading,
    writing,
    truncating,
    chmod,
    closing_source,
    closing_destination,
};

pub fn create(loop: *uv.Loop, destination: StoreRange, source: StoreRange, completion: Core.CopyFileCompletion, mkdirp: bool, mode: ?bun.Mode) bun.OOM!*CopyFileUV {
    const this = try bun.default_allocator.create(CopyFileUV);
    this.* = .{
        .loop = loop,
        .source = .init(source),
        .destination = .init(destination),
        .plan = .init(source, destination),
        .completion = completion,
        .mkdirp_if_not_exists = mkdirp,
        .destination_mode = mode,
    };
    errdefer this.destroy();
    inline for (.{ Which.source, Which.destination }) |which| {
        switch (this.pathlike(which)) {
            .path => |file_path| @field(this, @tagName(which) ++ "_path") = try bun.default_allocator.dupeSentinel(u8, file_path.slice(), 0),
            .fd => |fd| if (this.failure == null) {
                switch (FileIO.duplicate(fd)) {
                    .result => |owned| this.fdPointer(which).* = owned,
                    .err => |err| this.setNativeError(err, which),
                }
            },
        }
    }
    return this;
}

fn pathlike(this: *const CopyFileUV, which: Which) @import("../../node/types.zig").PathOrFileDescriptor {
    return (if (which == .source) &this.source else &this.destination).storePtr().data.file.pathlike;
}

fn path(this: *const CopyFileUV, which: Which) [:0]u8 {
    return if (which == .source) this.source_path.? else this.destination_path.?;
}

fn fdPointer(this: *CopyFileUV, which: Which) *bun.FD {
    return if (which == .source) &this.source_fd else &this.destination_fd;
}

fn setNativeError(this: *CopyFileUV, err: bun.sys.Error, which: Which) void {
    if (this.failure == null) this.failure = .{ .system = err.withPathLike(this.pathlike(which)) };
}

fn setError(this: *CopyFileUV, err: bun.sys.E, which: Which, comptime syscall: bun.sys.Tag) void {
    if (this.failure != null) return;
    if (err == .NOMEM) {
        this.failure = .out_of_memory;
        return;
    }
    var failure = bun.sys.Error.fromCode(err, syscall);
    failure = if (syscall == .mkdir)
        failure.withPath(this.destination_path.?[0..this.parent_directories.?.current])
    else
        failure.withPathLike(this.pathlike(which));
    this.failure = .{ .system = failure };
}

pub fn start(this: *CopyFileUV) void {
    if (this.failure != null) return this.finish();
    this.open(.source);
}

pub fn detach(this: *CopyFileUV) void {
    this.completion = null;
    this.cancelled = true;
    switch (this.phase) {
        .idle => this.finish(),
        .closing_source, .closing_destination => {},
        else => _ = uv.uv_cancel(@ptrCast(&this.request)),
    }
}

fn open(this: *CopyFileUV, which: Which) void {
    if (this.cancelled) return this.finish();
    if (this.fdPointer(which).* != .invalid) return this.stat(which);
    this.request.data = this;
    this.phase = if (which == .source) .opening_source else .opening_destination;
    const flags = uv.O.NONBLOCK | uv.O.SEQUENTIAL | (if (which == .source) uv.O.RDONLY else uv.O.WRONLY | uv.O.CREAT);
    const result = uv.uv_fs_open(this.loop, &this.request, this.path(which).ptr, flags, this.destination_mode orelse 0o644, onOpen);
    if (result.errEnum()) |err| {
        this.request.deinit();
        this.phase = .idle;
        this.setError(err, which, .open);
        this.finish();
    }
}

fn onOpen(request: *uv.fs_t) callconv(.c) void {
    const this: *CopyFileUV = @fieldParentPtr("request", request);
    const which: Which = if (this.phase == .opening_source) .source else .destination;
    const result = request.result;
    request.deinit();
    this.phase = .idle;
    if (result.errEnum()) |err| {
        if (!this.cancelled and which == .destination and err == .NOENT and this.mkdirp_if_not_exists) {
            this.mkdirp_if_not_exists = false;
            this.parent_directories = ParentDirectories.init(this.destination_path.?);
            if (this.parent_directories != null) return this.mkdir();
        }
        this.setError(err, which, .open);
    } else {
        this.fdPointer(which).* = result.toFD();
    }
    if (this.cancelled or this.failure != null) return this.finish();
    this.stat(which);
}

fn stat(this: *CopyFileUV, which: Which) void {
    this.request.data = this;
    this.phase = if (which == .source) .stating_source else .stating_destination;
    const result = uv.uv_fs_fstat(this.loop, &this.request, this.fdPointer(which).*.uv(), onStat);
    if (result.errEnum()) |err| {
        this.request.deinit();
        this.phase = .idle;
        this.setError(err, which, .fstat);
        this.finish();
    }
}

fn onStat(request: *uv.fs_t) callconv(.c) void {
    const this: *CopyFileUV = @fieldParentPtr("request", request);
    const which: Which = if (this.phase == .stating_source) .source else .destination;
    const failure = request.result.errEnum();
    if (this.cancelled or failure != null) {
        request.deinit();
        this.phase = .idle;
        if (failure) |err| this.setError(err, which, .fstat);
        return this.finish();
    }
    const metadata = request.statbuf;
    request.deinit();
    this.phase = .idle;
    if (bun.S.ISDIR(@intCast(metadata.mode))) {
        this.setError(.ISDIR, which, .fstat);
        return this.finish();
    }
    if (which == .source) {
        this.source_regular = bun.isRegularFile(metadata.mode);
        this.source_device = metadata.dev;
        this.source_inode = metadata.ino;
        this.source_size = metadata.size;
        if (!this.source_regular) this.skip_remaining = this.source.offset;
        return this.open(.destination);
    }
    this.destination_regular = bun.isRegularFile(metadata.mode);
    if (this.destination_regular) {
        this.destination_append = switch (FileIO.isAppend(this.destination_fd)) {
            .result => |append| append,
            .err => |err| {
                this.setNativeError(err, .destination);
                return this.finish();
            },
        };
        if (this.destination_append) this.plan.destination_offset = metadata.size;
    }
    if (this.source_regular and this.destination_regular and this.source_device == metadata.dev and this.source_inode == metadata.ino) {
        this.plan.setSameFile(this.source_size);
    }
    this.read();
}

fn mkdir(this: *CopyFileUV) void {
    if (this.cancelled) return this.finish();
    this.request.data = this;
    this.phase = .mkdir;
    const path_bytes = this.destination_path.?;
    const length = this.parent_directories.?.current;
    const terminator = path_bytes[length];
    path_bytes[length] = 0;
    const result = uv.uv_fs_mkdir(this.loop, &this.request, path_bytes.ptr, 0o777, onMkdir);
    path_bytes[length] = terminator;
    if (result.errEnum()) |err| {
        this.request.deinit();
        this.phase = .idle;
        this.setError(err, .destination, .mkdir);
        this.finish();
    }
}

fn onMkdir(request: *uv.fs_t) callconv(.c) void {
    const this: *CopyFileUV = @fieldParentPtr("request", request);
    const result = request.result;
    request.deinit();
    this.phase = .idle;
    if (this.cancelled) return this.finish();
    switch (this.parent_directories.?.advance(this.destination_path.?, result.errEnum())) {
        .more => this.mkdir(),
        .done => this.open(.destination),
        .failed => {
            this.setError(result.errEnum().?, .destination, .mkdir);
            this.finish();
        },
    }
}

fn read(this: *CopyFileUV) void {
    if (this.cancelled or this.plan.written == this.plan.limit) return this.finish();
    if (this.buffer.len == 0) {
        this.buffer = bun.default_allocator.alloc(u8, 64 * 1024) catch {
            this.failure = .out_of_memory;
            return this.finish();
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
    const chunk = this.chunk.?;
    this.io_buffer[0] = .init(this.buffer[this.loaded..chunk.length]);
    this.request.data = this;
    this.phase = .reading;
    const offset: i64 = if (this.source_regular) @intCast(chunk.source_offset + this.loaded) else -1;
    const result = uv.uv_fs_read(this.loop, &this.request, this.source_fd.uv(), &this.io_buffer, 1, offset, onRead);
    if (result.errEnum()) |err| {
        this.request.deinit();
        this.phase = .idle;
        this.setError(err, .source, .read);
        this.finish();
    }
}

fn onRead(request: *uv.fs_t) callconv(.c) void {
    const this: *CopyFileUV = @fieldParentPtr("request", request);
    const result = request.result;
    request.deinit();
    this.phase = .idle;
    if (result.errEnum()) |err| this.setError(err, .source, .read);
    if (this.cancelled or this.failure != null) return this.finish();
    const amount: usize = @intCast(result.int());
    bun.assert(amount <= this.io_buffer[0].len);
    if (amount == 0) {
        if (this.plan.backward) this.setError(.IO, .source, .read);
        return this.finish();
    }
    if (this.skip_remaining > 0) {
        this.skip_remaining -= amount;
        this.chunk = null;
        return this.read();
    }
    this.loaded += amount;
    if (this.plan.backward and this.loaded < this.chunk.?.length) return this.read();
    this.write();
}

fn write(this: *CopyFileUV) void {
    if (this.cancelled) return this.finish();
    this.io_buffer[0] = .init(this.buffer[this.sent..this.loaded]);
    this.request.data = this;
    this.phase = .writing;
    const offset: i64 = if (this.destination_regular and !this.destination_append) @intCast(this.chunk.?.destination_offset + this.sent) else -1;
    const result = uv.uv_fs_write(this.loop, &this.request, this.destination_fd.uv(), &this.io_buffer, 1, offset, onWrite);
    if (result.errEnum()) |err| {
        this.request.deinit();
        this.phase = .idle;
        this.setError(err, .destination, .write);
        this.finish();
    }
}

fn onWrite(request: *uv.fs_t) callconv(.c) void {
    const this: *CopyFileUV = @fieldParentPtr("request", request);
    const result = request.result;
    request.deinit();
    this.phase = .idle;
    if (result.errEnum()) |err| this.setError(err, .destination, .write);
    if (this.cancelled or this.failure != null) return this.finish();
    const amount: usize = @intCast(result.int());
    bun.assert(amount <= this.io_buffer[0].len);
    if (amount == 0) {
        this.setError(.IO, .destination, .write);
        return this.finish();
    }
    this.sent += amount;
    this.plan.advance(amount);
    if (this.sent < this.loaded) return this.write();
    this.chunk = null;
    this.read();
}

fn finish(this: *CopyFileUV) void {
    bun.assert(this.phase == .idle);
    if (!this.cancelled and this.failure == null and this.destination_fd != .invalid) {
        if (!this.truncated) {
            this.truncated = true;
            if (this.destination_regular and this.destination_path != null and this.destination.offset == 0) {
                this.phase = .truncating;
                this.request.data = this;
                const result = uv.uv_fs_ftruncate(this.loop, &this.request, this.destination_fd.uv(), @intCast(this.plan.written), onMetadata);
                if (result.errEnum()) |err| {
                    this.request.deinit();
                    this.phase = .idle;
                    this.setError(err, .destination, .ftruncate);
                    this.finish();
                }
                return;
            }
        }
        if (this.destination_mode) |mode| {
            if (!this.mode_applied) {
                this.mode_applied = true;
                this.phase = .chmod;
                this.request.data = this;
                const result = uv.uv_fs_fchmod(this.loop, &this.request, this.destination_fd.uv(), @intCast(mode), onMetadata);
                if (result.errEnum()) |err| {
                    this.request.deinit();
                    this.phase = .idle;
                    this.setError(err, .destination, .fchmod);
                    this.finish();
                }
                return;
            }
        }
    }
    if (this.source_fd != .invalid) return this.close(.source);
    if (this.destination_fd != .invalid) return this.close(.destination);
    this.finalize();
}

fn onMetadata(request: *uv.fs_t) callconv(.c) void {
    const this: *CopyFileUV = @fieldParentPtr("request", request);
    const phase = this.phase;
    const result = request.result;
    request.deinit();
    this.phase = .idle;
    if (result.errEnum()) |err| switch (phase) {
        .truncating => this.setError(err, .destination, .ftruncate),
        .chmod => this.setError(err, .destination, .fchmod),
        else => unreachable,
    };
    this.finish();
}

fn close(this: *CopyFileUV, which: Which) void {
    const fd = this.fdPointer(which).*;
    this.fdPointer(which).* = .invalid;
    this.phase = if (which == .source) .closing_source else .closing_destination;
    this.request.data = this;
    const result = uv.uv_fs_close(this.loop, &this.request, fd.uv(), onClose);
    if (result.errEnum() != null) {
        this.request.deinit();
        this.phase = .idle;
        if (fd.closeAllowingStandardIo(null)) |err| this.setNativeError(err, which);
        this.finish();
    }
}

fn onClose(request: *uv.fs_t) callconv(.c) void {
    const this: *CopyFileUV = @fieldParentPtr("request", request);
    const which: Which = if (this.phase == .closing_source) .source else .destination;
    const result = request.result;
    request.deinit();
    this.phase = .idle;
    if (result.errEnum()) |err| this.setError(err, which, .close);
    this.finish();
}

fn finalize(this: *CopyFileUV) void {
    const completion = this.completion;
    const result: Core.CopyFileResult = if (completion == null)
        .cancelled
    else if (this.failure) |failure| switch (failure) {
        .out_of_memory => .out_of_memory,
        .system => |err| result: {
            const payload = bun.bindgen.SystemError.fromSysError(err) catch break :result .out_of_memory;
            break :result .{ .system_error = payload };
        },
    } else .{ .written = @intCast(this.plan.written) };
    this.destroy();
    if (completion) |done| done.complete(result);
}

fn destroy(this: *CopyFileUV) void {
    if (this.source_fd != .invalid) _ = this.source_fd.closeAllowingStandardIo(null);
    if (this.destination_fd != .invalid) _ = this.destination_fd.closeAllowingStandardIo(null);
    if (this.source_path) |value| bun.default_allocator.free(value);
    if (this.destination_path) |value| bun.default_allocator.free(value);
    this.source.deinit();
    this.destination.deinit();
    bun.default_allocator.free(this.buffer);
    bun.destroy(this);
}

const std = @import("std");
const bun = @import("bun");
const uv = bun.windows.libuv;
const Core = @import("./copy_file.zig");
const StoreRange = @import("./StoreRange.zig");
const CopyPlan = @import("./CopyPlan.zig");
const FileIO = @import("./FileIO.zig");
const ParentDirectories = @import("./ParentDirectories.zig");
