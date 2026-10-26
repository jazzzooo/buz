//! Error type that preserves useful information from the operating system
const Error = @This();

const retry_errno = if (Environment.isWindows)
    @as(Int, @intCast(@backingInt(E.INTR)))
else
    @as(Int, @intCast(@backingInt(E.AGAIN)));

const todo_errno = std.math.maxInt(Int) - 1;

pub const Int = u16;

/// TODO: convert to function
pub const oom = fromCode(E.NOMEM, .read);

errno: Int = todo_errno,
fd: bun.FD = bun.invalid_fd,
from_libuv: if (Environment.isWindows) bool else void = if (Environment.isWindows) false else undefined,
path: []const u8 = "",
syscall: sys.Tag = sys.Tag.TODO,
dest: []const u8 = "",
/// Node reports some failures with a documented `ERR_*` code and wording that
/// owes nothing to the failing syscall. When set, these replace both for
/// JavaScript; the shell keeps the errno presentation either way.
node_code: ?NodeErrorCode = null,
node_message: []const u8 = "",

pub fn clone(this: *const Error, allocator: std.mem.Allocator) Error {
    return bun.handleOom(this.cloneFallible(allocator));
}

pub fn cloneFallible(this: *const Error, allocator: std.mem.Allocator) bun.OOM!Error {
    var copy = this.*;
    copy.path = try allocator.dupe(u8, this.path);
    errdefer allocator.free(copy.path);
    copy.dest = try allocator.dupe(u8, this.dest);
    errdefer allocator.free(copy.dest);
    copy.node_message = try allocator.dupe(u8, this.node_message);
    return copy;
}

pub fn fromCode(errno: E, syscall_tag: sys.Tag) Error {
    return .{
        .errno = @as(Int, @intCast(@backingInt(errno))),
        .syscall = syscall_tag,
    };
}

pub fn fromCodeInt(errno: anytype, syscall_tag: sys.Tag) Error {
    return .{
        .errno = @as(Int, @intCast(if (Environment.isWindows) @abs(errno) else errno)),
        .syscall = syscall_tag,
    };
}

/// `access_denied` varies because some APIs expose permission failures as
/// `EACCES` while others, such as `rmdir`, require `EPERM` compatibility.
pub fn errnoFromStdIo(err: anyerror, access_denied: E) E {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => access_denied,
        error.FileTooBig => .FBIG,
        error.SymLinkLoop => .LOOP,
        error.NameTooLong => .NAMETOOLONG,
        error.ProcessFdQuotaExceeded => .MFILE,
        error.SystemFdQuotaExceeded => .NFILE,
        error.SystemResources, error.OutOfMemory => .NOMEM,
        error.ReadOnlyFileSystem => .ROFS,
        error.FileSystem, error.InputOutput, error.HardwareFailure => .IO,
        error.FileBusy, error.DeviceBusy => .BUSY,
        error.NoDevice => .NXIO,
        error.Canceled => .INTR,
        error.NotDir => .NOTDIR,
        error.InvalidUtf8, error.InvalidWtf8, error.BadPathName => .INVAL,
        error.FileNotFound => .NOENT,
        error.PathAlreadyExists => .EXIST,
        error.IsDir => .ISDIR,
        error.CrossDevice => .XDEV,
        error.NoSpaceLeft => .NOSPC,
        error.DiskQuota => .DQUOT,
        error.LinkQuotaExceeded => .MLINK,
        error.OperationUnsupported => if (comptime Environment.isWindows) .NOTSUP else .OPNOTSUPP,
        else => .FAULT,
    };
}

pub fn fromStdIo(err: anyerror, syscall_tag: sys.Tag) Error {
    return fromCode(errnoFromStdIo(err, .ACCES), syscall_tag);
}

pub fn format(self: Error, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const data = self.withoutPath().toShellSystemErrorData();
    const code = if (data.system_errno) |system_errno| @tagName(system_errno) else "";
    if (self.path.len > 0) {
        switch (bun.Output.enable_ansi_colors_stderr) {
            inline else => |enable_colors| try writer.print(
                comptime bun.Output.prettyFmt(
                    "<r><red>{s}<r><d>:<r> <b>{s}<r>: {s} <d>({s}())<r>",
                    enable_colors,
                ),
                .{
                    code,
                    self.path,
                    data.message,
                    data.syscall,
                },
            ),
        }
    } else {
        switch (bun.Output.enable_ansi_colors_stderr) {
            inline else => |enable_colors| try writer.print(
                comptime bun.Output.prettyFmt(
                    "<r><red>{s}<r><d>:<r> {s} <d>({s}())<r>",
                    enable_colors,
                ),
                .{ code, data.message, data.syscall },
            ),
        }
    }
}

pub inline fn getErrno(this: Error) E {
    return @as(E, @fromBackingInt(@intCast(this.errno)));
}

pub inline fn isRetry(this: *const Error) bool {
    return this.getErrno() == .AGAIN;
}

pub const retry = Error{
    .errno = retry_errno,
    .syscall = .read,
};

pub inline fn withFd(this: Error, fd: anytype) Error {
    if (Environment.allow_assert) bun.assert(fd != bun.invalid_fd);
    return Error{
        .errno = this.errno,
        .syscall = this.syscall,
        .fd = fd,
    };
}

pub inline fn withPath(this: Error, path: anytype) Error {
    if (std.meta.Child(@TypeOf(path)) == u16) {
        @compileError("Do not pass WString path to withPath, it needs the path encoded as utf8");
    }
    return Error{
        .errno = this.errno,
        .syscall = this.syscall,
        .path = bun.span(path),
    };
}

pub inline fn withPathAndSyscall(this: Error, path: anytype, syscall_: sys.Tag) Error {
    if (std.meta.Child(@TypeOf(path)) == u16) {
        @compileError("Do not pass WString path to withPath, it needs the path encoded as utf8");
    }
    return Error{
        .errno = this.errno,
        .syscall = syscall_,
        .path = bun.span(path),
    };
}

pub fn deinit(this: *Error) void {
    this.deinitWithAllocator(bun.default_allocator);
}

/// Only call this after it's been .clone()'d
pub fn deinitWithAllocator(this: *Error, allocator: std.mem.Allocator) void {
    if (this.path.len > 0) {
        allocator.free(this.path);
        this.path = "";
    }
    if (this.dest.len > 0) {
        allocator.free(this.dest);
        this.dest = "";
    }
    if (this.node_message.len > 0) {
        allocator.free(this.node_message);
        this.node_message = "";
    }
}

pub inline fn withPathDest(this: Error, path: anytype, dest: anytype) Error {
    if (std.meta.Child(@TypeOf(path)) == u16) {
        @compileError("Do not pass WString path to withPathDest, it needs the path encoded as utf8 (path)");
    }
    if (std.meta.Child(@TypeOf(dest)) == u16) {
        @compileError("Do not pass WString path to withPathDest, it needs the path encoded as utf8 (dest)");
    }
    return Error{
        .errno = this.errno,
        .syscall = this.syscall,
        .path = bun.span(path),
        .dest = bun.span(dest),
    };
}

pub inline fn withPathLike(this: Error, pathlike: anytype) Error {
    return switch (pathlike) {
        .fd => |fd| this.withFd(fd),
        .path => |path| this.withPath(path.slice()),
    };
}

/// When the memory of the path/dest buffer is unsafe to use, call this function to clone the error without the path/dest.
pub fn withoutPath(this: *const Error) Error {
    var copy = this.*;
    copy.path = "";
    copy.dest = "";
    return copy;
}

pub fn name(this: *const Error) []const u8 {
    if (comptime Environment.isWindows) {
        const system_errno = brk: {
            // setRuntimeSafety(false) because we use tagName function, which will be null on invalid enum value.
            @setRuntimeSafety(false);
            if (this.from_libuv) {
                break :brk @as(SystemErrno, @fromBackingInt(@intCast(@backingInt(bun.windows.libuv.translateUVErrorToE(-@as(c_int, this.errno))))));
            }

            break :brk @as(SystemErrno, @fromBackingInt(@intCast(this.errno)));
        };
        if (std.enums.tagName(SystemErrno, system_errno)) |errname| {
            return errname;
        }
    } else if (this.errno > 0 and this.errno < SystemErrno.max) {
        const system_errno = @as(SystemErrno, @fromBackingInt(@intCast(this.errno)));
        if (std.enums.tagName(SystemErrno, system_errno)) |errname| {
            return errname;
        }
    }

    return "UNKNOWN";
}

pub fn toZigErr(this: Error) anyerror {
    return bun.errnoToZigErr(this.errno);
}

/// 1. Convert libuv errno values into libc ones.
/// 2. Get the tag name as a string for printing.
pub fn getErrorCodeTagName(err: *const Error) ?struct { [:0]const u8, SystemErrno } {
    if (!Environment.isWindows) {
        if (err.errno > 0 and err.errno < SystemErrno.max) {
            const system_errno = @as(SystemErrno, @fromBackingInt(@intCast(err.errno)));
            return .{ @tagName(system_errno), system_errno };
        }
    } else {
        const system_errno: SystemErrno = brk: {
            // setRuntimeSafety(false) because we use tagName function, which will be null on invalid enum value.
            @setRuntimeSafety(false);
            if (err.from_libuv) {
                break :brk @fromBackingInt(@intCast(@backingInt(bun.windows.libuv.translateUVErrorToE(@as(c_int, err.errno) * -1))));
            }

            break :brk @fromBackingInt(@intCast(err.errno));
        };
        if (std.enums.tagName(SystemErrno, system_errno)) |errname| {
            return .{ errname, system_errno };
        }
    }
    return null;
}

pub fn msg(this: Error) ?[]const u8 {
    if (this.getErrorCodeTagName()) |resolved_errno| {
        const code, const system_errno = resolved_errno;
        if (coreutils_error_map.get(system_errno)) |label| {
            return label;
        }
        return code;
    }
    return null;
}

pub const system_error_message_capacity = 4096;

pub const ShellSystemErrorData = struct {
    errno: c_int,
    system_errno: ?SystemErrno = null,
    message: []const u8 = "",
    path: []const u8 = "",
    syscall: [:0]const u8,
    fd: c_int = std.math.minInt(c_int),
    dest: []const u8 = "",
};

pub fn toShellSystemErrorData(this: Error) ShellSystemErrorData {
    var result = ShellSystemErrorData{
        .errno = -%@as(c_int, this.errno),
        .syscall = @tagName(this.syscall),
        .path = this.path,
        .dest = this.dest,
    };
    if (this.getErrorCodeTagName()) |resolved_errno| {
        _, const system_errno = resolved_errno;
        result.system_errno = system_errno;
        result.message = coreutils_error_map.get(system_errno) orelse "";
    }
    if (this.fd.unwrapValid()) |valid| {
        if (!Environment.isWindows or valid.kind == .uv) result.fd = valid.uv();
    }
    return result;
}

pub fn toShellSystemError(this: Error) sys.SystemError {
    @setEvalBranchQuota(1_000_000);
    const data = this.toShellSystemErrorData();
    var err = sys.SystemError{
        .errno = data.errno,
        .syscall = bun.String.staticTagName(this.syscall),
        .message = .empty,
        .fd = data.fd,
    };

    if (data.system_errno) |system_errno| {
        err.code = bun.String.staticTagName(system_errno);
        switch (system_errno) {
            inline else => |errno_tag| {
                if (comptime coreutils_error_map.get(errno_tag)) |label| {
                    err.message = bun.String.static(label);
                }
            },
        }
    }

    if (data.path.len > 0) err.path = bun.String.cloneUTF8(data.path);
    if (data.dest.len > 0) err.dest = bun.String.cloneUTF8(data.dest);
    return err;
}

pub const SystemErrorData = struct {
    errno: c_int,
    code: ?[:0]const u8 = null,
    code_tag: ?SystemErrorCode = null,
    message: []const u8,
    path: []const u8 = "",
    syscall: [:0]const u8,
    fd: c_int = std.math.minInt(c_int),
    dest: []const u8 = "",
};

pub fn toSystemErrorData(this: Error, message_buffer: *[system_error_message_capacity]u8) SystemErrorData {
    var result = SystemErrorData{
        .errno = -%@as(c_int, this.errno),
        .syscall = @tagName(this.syscall),
        .message = "",
        .path = this.path,
        .dest = this.dest,
    };

    if (this.node_code) |node_code| {
        result.code = @tagName(node_code);
        result.code_tag = .{ .node = node_code };
        result.message = this.node_message;
        return result;
    }

    // errno label
    var label: ?[]const u8 = null;
    if (this.getErrorCodeTagName()) |resolved_errno| {
        const code, const system_errno = resolved_errno;
        result.code = code;
        result.code_tag = .{ .system = system_errno };
        label = libuv_error_map.get(system_errno);
    }

    // format taken from Node.js 'exceptions.cc'
    result.message = message: {
        var writer_state = std.Io.Writer.fixed(message_buffer);
        const writer = &writer_state;
        brk: {
            if (result.code) |code| {
                writer.writeAll(code) catch break :brk;
                writer.writeAll(": ") catch break :brk;
            }
            writer.writeAll(label orelse "Unknown Error") catch break :brk;
            writer.writeAll(", ") catch break :brk;
            writer.writeAll(@tagName(this.syscall)) catch break :brk;
            if (this.path.len > 0) {
                writer.writeAll(" '") catch break :brk;
                writer.writeAll(this.path) catch break :brk;
                writer.writeAll("'") catch break :brk;

                if (this.dest.len > 0) {
                    writer.writeAll(" -> '") catch break :brk;
                    writer.writeAll(this.dest) catch break :brk;
                    writer.writeAll("'") catch break :brk;
                }
            }
        }
        break :message writer.buffered();
    };

    if (this.fd.unwrapValid()) |valid| {
        // When the FD is a windows handle, there is no sane way to report this.
        if (!Environment.isWindows or valid.kind == .uv) {
            result.fd = valid.uv();
        }
    }

    return result;
}

pub fn toSystemError(this: Error) sys.SystemError {
    var message_buffer: [system_error_message_capacity]u8 = undefined;
    const data = this.toSystemErrorData(&message_buffer);
    var err = sys.SystemError{
        .errno = data.errno,
        .syscall = bun.String.staticTagName(this.syscall),
        .message = bun.String.cloneUTF8(data.message),
        .fd = data.fd,
    };
    if (data.code_tag) |code_tag| {
        err.code = switch (code_tag) {
            .node => |code| bun.String.staticTagName(code),
            .system => |code| bun.String.staticTagName(code),
        };
    }
    if (data.path.len > 0) err.path = bun.String.cloneUTF8(data.path);
    if (data.dest.len > 0) err.dest = bun.String.cloneUTF8(data.dest);
    return err;
}

pub const SystemErrorCode = union(enum) {
    node: NodeErrorCode,
    system: SystemErrno,
};

pub inline fn todo() Error {
    if (Environment.isDebug) {
        @panic("Error.todo() was called");
    }
    return Error{ .errno = todo_errno, .syscall = .TODO };
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const NodeErrorCode = @import("../runtime/node/nodejs_error_code.zig").Code;
const sys = bun.sys;
const E = sys.E;
const SystemErrno = sys.SystemErrno;
const coreutils_error_map = sys.coreutils_error_map;
const libuv_error_map = sys.libuv_error_map;
