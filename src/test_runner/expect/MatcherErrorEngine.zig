const BindingEscape = bun.bindgen.Escape(@This());
const bun = @import("bun");
const std = @import("std");
const ExpectState = @import("./State.zig");

const bindgen = bun.bindgen;
const JSGlobalObject = bun.jsc.JSGlobalObject;
const Output = bun.Output;

pub fn throwNamed(
    global: *JSGlobalObject,
    message: *const bindgen.DOMString,
    comptime name: []const u8,
) bun.JSError {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    const error_value = try scope.engineIn("errors", "createError").call(.{ .message = message.operand() });
    var error_name = try bindgen.DOMString.fromUTF8(name);
    defer error_name.deinit();
    try scope.engineIn("errors", "errorSetName").call(.{
        .errorValue = error_value.operand(&scope).asEngine(),
        .name = error_name.operand(),
    });
    return error_value.throwException(&scope);
}

pub fn throwPretty(
    global: *JSGlobalObject,
    custom_label: bun.String,
    matcher_name: anytype,
    matcher_arguments: anytype,
    flags: ExpectState.Flags,
    comptime message_format: []const u8,
    message_arguments: anytype,
) bun.JSError {
    switch (Output.enable_ansi_colors_stderr) {
        inline else => |colors| {
            const chain = switch (flags.promise) {
                .resolves => if (flags.not) Output.prettyFmt("resolves<d>.<r>not<d>.<r>", colors) else Output.prettyFmt("resolves<d>.<r>", colors),
                .rejects => if (flags.not) Output.prettyFmt("rejects<d>.<r>not<d>.<r>", colors) else Output.prettyFmt("rejects<d>.<r>", colors),
                .none => if (flags.not) Output.prettyFmt("not<d>.<r>", colors) else "",
            };
            if (custom_label.isEmpty()) {
                const format = comptime Output.prettyFmt("<d>expect(<r><red>received<r><d>).<r>{f}{f}<d>(<r>{f}<d>)<r>\n\n" ++ message_format, colors);
                return global.throwPretty(format, .{
                    labelPart(chain),
                    labelPart(matcher_name),
                    labelPart(matcher_arguments),
                } ++ message_arguments);
            }
            const format = comptime Output.prettyFmt("{f}\n\n" ++ message_format, colors);
            return global.throwPretty(format, .{custom_label} ++ message_arguments);
        },
    }
}

pub fn throwPrettyValue(
    context: anytype,
    custom_label: bun.String,
    matcher_name: anytype,
    matcher_arguments: anytype,
    flags: ExpectState.Flags,
    comptime message_format: []const u8,
    value: bindgen.EngineValueResult,
) bun.JSError {
    const global = context.viewToken().globalObject();
    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    return throwPretty(
        global,
        custom_label,
        matcher_name,
        matcher_arguments,
        flags,
        message_format,
        .{formatter.toScopedFmt(context, value.operand(context).engineView())},
    );
}

pub fn throwInvalidMatcherFunction(context: anytype, name: *const bindgen.DOMString, value: bindgen.EngineValueResult) bun.JSError {
    const global = context.viewToken().globalObject();
    const is_null = context.engineIn("js_value_inspection", "jsValueEqual").call(.{
        .operands = .{ .left = value.operand(context).asEngine(), .right = bindgen.EngineValueResult.initNull(context).operand(context).asEngine() },
    });
    var type_name = if (is_null)
        try bindgen.DOMString.fromUTF8("null")
    else
        try context.engineIn("js_value_inspection", "jsTypeStringForValue").call(.{ .value = value.operand(context).asEngine() });
    defer type_name.deinit();
    return global.throwInvalidArguments("expect.extend: `{f}` is not a valid matcher. Must be a function, is \"{f}\"", .{ name, type_name });
}

pub fn throwInvalidMatcherResult(context: anytype, matcher_name: anytype, result: bindgen.EngineValueResult) bun.JSError {
    const global = context.viewToken().globalObject();
    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const fmt =
        "Unexpected return from matcher function `{f}`.\n" ++
        "Matcher functions should return an object in the following format:\n" ++
        "  {{message?: string | function, pass: boolean}}\n" ++
        "'{f}' was returned";
    switch (Output.enable_ansi_colors_stderr) {
        inline else => |colors| {
            var message = try global.formatErrorMessage(comptime Output.prettyFmt(fmt, colors), .{
                matcher_name,
                formatter.toScopedFmt(context, result.operand(context).engineView()),
            });
            defer message.deinit();
            return throwNamed(global, &message, "InvalidMatcherError");
        },
    }
}

fn LabelPart(comptime T: type) type {
    return std.fmt.Alt(T, struct {
        fn format(value: T, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (comptime std.meta.hasMethod(T, "format")) {
                try value.format(writer);
            } else {
                try writer.print("{s}", .{value});
            }
        }
    }.format);
}

fn labelPart(value: anytype) LabelPart(@TypeOf(value)) {
    return .{ .data = value };
}
