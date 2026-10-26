pub fn BindingMethods(comptime Native: type, comptime Schema: type, comptime class_name: []const u8) type {
    return struct {
        const ColumnSchema = Schema.member("column");
        const LevelSchema = Schema.member("level");
        const LineSchema = Schema.member("line");
        const MessageSchema = Schema.member("message");
        const PositionSchema = Schema.member("position");
        const ToPrimitiveSchema = Schema.member("toPrimitive");
        const ToStringSchema = Schema.member("toString");
        const InspectCustomSchema = Schema.member("inspectCustom");

        pub fn stringValue(this: *Native) bun.OOM!bindgen.DOMString {
            const text = std.fmt.allocPrint(bun.default_allocator, class_name ++ ": {s}", .{this.message.data.text.slice()}) catch {
                return error.OutOfMemory;
            };
            defer bun.default_allocator.free(text);
            return bindgen.DOMString.fromUTF8(text);
        }

        pub fn toString(
            this: *Native,
            _: bindgen.CallContext(ToStringSchema),
            _: bindgen.Args(ToStringSchema),
        ) bun.JSError!bindgen.DOMString {
            return stringValue(this);
        }

        pub fn inspectCustom(
            this: *Native,
            _: bindgen.CallContext(InspectCustomSchema),
            args: bindgen.Args(InspectCustomSchema),
        ) bun.JSError!bindgen.DOMString {
            return format(this.loggerMessage(), if (args.options) |options| options.colors else false);
        }

        pub fn toPrimitive(
            this: *Native,
            _: bindgen.CallContext(ToPrimitiveSchema),
            args: bindgen.Args(ToPrimitiveSchema),
        ) bun.JSError!?bindgen.DOMString {
            const hint = args.hint orelse return null;
            return switch (hint) {
                .default_hint, .string => try stringValue(this),
                .number => null,
            };
        }

        pub fn getColumn(
            this: *Native,
            _: bindgen.CallContext(ColumnSchema),
            _: bindgen.Args(ColumnSchema),
        ) bun.JSError!i32 {
            return if (this.message.data.location) |location| @max(location.column - 1, 0) else 0;
        }

        pub fn getLine(
            this: *Native,
            _: bindgen.CallContext(LineSchema),
            _: bindgen.Args(LineSchema),
        ) bun.JSError!i32 {
            return if (this.message.data.location) |location| @max(location.line - 1, 0) else 0;
        }

        pub fn getPosition(
            this: *Native,
            _: bindgen.CallContext(PositionSchema),
            _: bindgen.Args(PositionSchema),
        ) bun.JSError!bindgen.Return(PositionSchema) {
            return try bun.api.BuildMessage.generatePosition(this.message.data.view().location);
        }

        pub fn getMessage(
            this: *Native,
            _: bindgen.CallContext(MessageSchema),
            _: bindgen.Args(MessageSchema),
        ) bun.JSError!bindgen.DOMString {
            return bindgen.DOMString.fromUTF8(this.message.data.text.slice());
        }

        pub fn getLevel(
            this: *Native,
            _: bindgen.CallContext(LevelSchema),
            _: bindgen.Args(LevelSchema),
        ) bun.JSError!bindgen.Return(LevelSchema) {
            return level(this);
        }

        pub fn level(this: *Native) bindgen.Return(LevelSchema) {
            return switch (this.message.kind) {
                .err => .err,
                .warn => .warn,
                .note => .note,
                .debug => .debug,
                .verbose => .verbose,
            };
        }
    };
}

pub fn format(message: *const bun.logger.OwnedMessage, colors: bool) bun.OOM!bun.bindgen.DOMString {
    var output = std.Io.Writer.Allocating.init(bun.default_allocator);
    defer output.deinit();
    if (colors) {
        message.writeFormat(&output.writer, true) catch return error.OutOfMemory;
    } else {
        message.writeFormat(&output.writer, false) catch return error.OutOfMemory;
    }
    return bun.bindgen.DOMString.fromUTF8(output.written());
}

const std = @import("std");
const bun = @import("bun");

const bindgen = bun.bindgen;
