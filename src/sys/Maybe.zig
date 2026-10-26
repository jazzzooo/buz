pub fn Maybe(comptime System: type, comptime ReturnTypeT: type, comptime ErrorTypeT: type) type {
    const has_any_decls = ErrorTypeT != void and ErrorTypeT != anyerror;
    const has_retry = has_any_decls and @hasDecl(ErrorTypeT, "retry");
    const has_todo = has_any_decls and @hasDecl(ErrorTypeT, "todo");

    return union(Tag) {
        pub const ErrorType = ErrorTypeT;
        pub const ReturnType = ReturnTypeT;

        err: ErrorType,
        result: ReturnType,

        pub const Tag = enum { err, result };

        pub const retry: @This() = if (has_retry) .{ .err = ErrorType.retry } else .{ .err = .{} };
        pub const success: @This() = .{
            .result = std.mem.zeroes(ReturnType),
        };
        pub const aborted: @This() = .{ .err = .{
            .errno = @backingInt(posix.E.INTR),
            .syscall = .access,
        } };

        pub inline fn todo() @This() {
            if (Environment.allow_assert) {
                if (comptime ReturnType == void) {
                    @panic("TODO called!");
                }
                @panic(comptime "TODO: Maybe(" ++ bun.meta.typeName(ReturnType) ++ ")");
            }
            if (has_todo) {
                return .{ .err = ErrorType.todo() };
            }
            return .{ .err = ErrorType{} };
        }

        pub fn isTrue(this: @This()) bool {
            if (comptime ReturnType != bool) @compileError("This function can only be called on bool");
            return switch (this) {
                .result => |result| result,
                .err => false,
            };
        }

        pub fn unwrap(this: @This()) !ReturnType {
            return switch (this) {
                .result => |result| result,
                .err => |err| bun.errnoToZigErr(err.errno),
            };
        }

        pub inline fn unwrapOr(this: @This(), default_value: ReturnType) ReturnType {
            return switch (this) {
                .result => |value| value,
                .err => default_value,
            };
        }

        pub inline fn initErr(err: ErrorType) @This() {
            return .{ .err = err };
        }

        pub inline fn initErrWithP(err: System.SystemErrno, syscall: System.Tag, file_path: anytype) @This() {
            return .{ .err = .{
                .errno = @backingInt(err),
                .syscall = syscall,
                .path = file_path,
            } };
        }

        pub inline fn asErr(this: *const @This()) ?ErrorType {
            return switch (this.*) {
                .err => |err| err,
                .result => null,
            };
        }

        pub inline fn asValue(this: *const @This()) ?ReturnType {
            return switch (this.*) {
                .result => |result| result,
                .err => null,
            };
        }

        pub inline fn isOk(this: *const @This()) bool {
            return this.* == .result;
        }

        pub inline fn isErr(this: *const @This()) bool {
            return this.* == .err;
        }

        pub inline fn initResult(result: ReturnType) @This() {
            return .{ .result = result };
        }

        pub inline fn mapErr(this: @This(), comptime MappedError: type, map: *const fn (ErrorTypeT) MappedError) Maybe(System, ReturnType, MappedError) {
            return switch (this) {
                .result => |value| .{ .result = value },
                .err => |err| .{ .err = map(err) },
            };
        }

        pub fn getErrno(this: @This()) posix.E {
            return switch (this) {
                .result => posix.E.SUCCESS,
                .err => |err| @fromBackingInt(@intCast(err.errno)),
            };
        }

        pub fn errnoSys(rc: anytype, syscall: System.Tag) ?@This() {
            if (successfulWindowsResult(rc)) return null;
            return switch (System.getErrno(rc)) {
                .SUCCESS => null,
                else => |err| .{ .err = .{
                    .errno = translateToErrInt(System, err),
                    .syscall = syscall,
                } },
            };
        }

        pub fn errno(err: anytype, syscall: System.Tag) @This() {
            return .{ .err = .{
                .errno = translateToErrInt(System, err),
                .syscall = syscall,
            } };
        }

        pub fn errnoSysFd(rc: anytype, syscall: System.Tag, fd: bun.FD) ?@This() {
            if (successfulWindowsResult(rc)) return null;
            return switch (System.getErrno(rc)) {
                .SUCCESS => null,
                else => |err| .{ .err = .{
                    .errno = translateToErrInt(System, err),
                    .syscall = syscall,
                    .fd = fd,
                } },
            };
        }

        pub fn errnoSysP(rc: anytype, syscall: System.Tag, file_path: anytype) ?@This() {
            if (bun.meta.Item(@TypeOf(file_path)) == u16) {
                @compileError("Do not pass WString path to errnoSysP, it needs the path encoded as utf8");
            }
            if (successfulWindowsResult(rc)) return null;
            return switch (System.getErrno(rc)) {
                .SUCCESS => null,
                else => |err| .{ .err = .{
                    .errno = translateToErrInt(System, err),
                    .syscall = syscall,
                    .path = bun.asByteSlice(file_path),
                } },
            };
        }

        pub fn errnoSysFP(rc: anytype, syscall: System.Tag, fd: bun.FD, file_path: anytype) ?@This() {
            if (successfulWindowsResult(rc)) return null;
            return switch (System.getErrno(rc)) {
                .SUCCESS => null,
                else => |err| .{ .err = .{
                    .errno = translateToErrInt(System, err),
                    .syscall = syscall,
                    .fd = fd,
                    .path = bun.asByteSlice(file_path),
                } },
            };
        }

        pub fn errnoSysPD(rc: anytype, syscall: System.Tag, file_path: anytype, dest: anytype) ?@This() {
            if (bun.meta.Item(@TypeOf(file_path)) == u16) {
                @compileError("Do not pass WString path to errnoSysPD, it needs the path encoded as utf8");
            }
            if (successfulWindowsResult(rc)) return null;
            return switch (System.getErrno(rc)) {
                .SUCCESS => null,
                else => |err| .{ .err = .{
                    .errno = translateToErrInt(System, err),
                    .syscall = syscall,
                    .path = bun.asByteSlice(file_path),
                    .dest = bun.asByteSlice(dest),
                } },
            };
        }

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            switch (this) {
                .result => try writer.print("Result(...)", .{}),
                .err => |err| {
                    if (comptime std.meta.hasMethod(ErrorType, "format")) {
                        try writer.print("Error({f})", .{err});
                    } else {
                        try writer.print("Error({any})", .{err});
                    }
                },
            }
        }

        fn successfulWindowsResult(rc: anytype) bool {
            if (!Environment.isWindows) return false;
            if (@TypeOf(rc) == std.os.windows.NTSTATUS) return false;
            if (@TypeOf(rc) == std.os.windows.BOOL) return rc.toBool();
            return rc != 0;
        }
    };
}

fn translateToErrInt(comptime System: type, err: anytype) System.Error.Int {
    return switch (@TypeOf(err)) {
        bun.windows.NTSTATUS => @backingInt(System.SystemErrno.fromNtStatus(err)),
        else => @truncate(@backingInt(err)),
    };
}

const std = @import("std");
const posix = std.posix;

const bun = @import("bun");
const Environment = bun.Environment;
