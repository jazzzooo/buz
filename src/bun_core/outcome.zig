pub fn Outcome(comptime Value: type, comptime Error: type) type {
    return union(enum) {
        err: Error,
        result: Value,

        pub const success: @This() = .{ .result = std.mem.zeroes(Value) };

        pub fn isTrue(this: @This()) bool {
            if (comptime Value != bool) @compileError("isTrue requires a boolean result");
            return switch (this) {
                .result => |result| result,
                .err => false,
            };
        }

        pub inline fn unwrapOr(this: @This(), default_value: Value) Value {
            return switch (this) {
                .result => |value| value,
                .err => default_value,
            };
        }

        pub inline fn initErr(err: Error) @This() {
            return .{ .err = err };
        }

        pub inline fn initResult(result: Value) @This() {
            return .{ .result = result };
        }

        pub inline fn asErr(this: *const @This()) ?Error {
            return switch (this.*) {
                .err => |err| err,
                .result => null,
            };
        }

        pub inline fn asValue(this: *const @This()) ?Value {
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

        pub inline fn mapErr(this: @This(), comptime MappedError: type, map: *const fn (Error) MappedError) Outcome(Value, MappedError) {
            return switch (this) {
                .result => |value| .{ .result = value },
                .err => |err| .{ .err = map(err) },
            };
        }

        pub fn format(this: @This(), writer: *std.Io.Writer) !void {
            switch (this) {
                .result => try writer.writeAll("Result(...)"),
                .err => |err| {
                    if (comptime std.meta.hasMethod(Error, "format")) {
                        try writer.print("Error({f})", .{err});
                    } else {
                        try writer.print("Error({any})", .{err});
                    }
                },
            }
        }
    };
}

const std = @import("std");
