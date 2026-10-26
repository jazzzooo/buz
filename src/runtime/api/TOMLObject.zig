pub fn stringifyDate(
    context: bun.bindgen.CallContext(StringifyDateSchema),
    args: bun.bindgen.Args(StringifyDateSchema),
) bun.bindgen.CallError(StringifyDateSchema)!bun.bindgen.Return(StringifyDateSchema) {
    return switch (args.value) {
        .other => null,
        .date => |date| date: {
            const iso = try context.engineIn("date_time", "dateToISOString").call(.{ .value = date.operand(context).asEngine() });
            if (iso.length() == 0) return context.fail(.invalid_date, {});
            if (iso.length() != 24) return context.fail(.date_out_of_range, {});
            break :date iso.toOwned();
        },
    };
}

pub fn parseGraph(
    context: bun.bindgen.CallContext(ParseGraphSchema),
    args: bun.bindgen.Args(ParseGraphSchema),
) bun.bindgen.CallError(ParseGraphSchema)!bun.bindgen.Return(ParseGraphSchema) {
    var arena = bun.ArenaAllocator.init(bun.default_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    const ast_memory_allocator = try allocator.create(ast.ASTMemoryAllocator);
    var ast_scope = ast_memory_allocator.enter(allocator);
    defer ast_scope.exit();

    var log = logger.Log.init(default_allocator);
    defer log.deinit();
    const input = args.input orelse {
        return context.fail(.missing_input, {});
    };

    var input_slice = try input.toUTF8(bun.default_allocator);
    defer input_slice.deinit();
    if (input_slice.slice().len > std.math.maxInt(i32)) {
        return context.fail(.input_too_large, try ParsedValueGraph.inputTooLargeMessage(input_slice.slice().len));
    }
    const source = &logger.Source.initPathString("input.toml", input_slice.slice());
    const parse_result = TOML.parse(source, &log, allocator, false) catch |err| {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StackOverflow => return throwStackOverflow(context),
            else => {},
        }
        const message = if (log.msgs.items.len > 0)
            try bun.String.createFormat("TOML Parse error: {s}", .{log.msgs.items[0].data.text})
        else
            bun.String.static("TOML Parse error: Failed to parse TOML");
        return context.fail(.parse_error, try bun.bindgen.DOMString.fromBunString(message));
    };
    return ParsedValueGraph.fromExpr(bun.bindgen.Return(ParseGraphSchema), parse_result, allocator) catch |err| switch (err) {
        error.OutOfMemory => |oom| oom,
        error.GraphTooLarge => context.fail(.input_too_large, try ParsedValueGraph.inputTooLargeMessage(input_slice.slice().len)),
        error.UnsupportedExpression => context.fail(.unsupported_value, {}),
    };
}

fn throwStackOverflow(context: anytype) bun.JSError {
    context.engineIn("errors", "throwStackOverflow").call(.{}) catch |err| return err;
    unreachable;
}

const bun = @import("bun");
const ast = bun.ast;
const default_allocator = bun.default_allocator;
const logger = bun.logger;
const TOML = bun.interchange.toml.TOML;
const std = @import("std");
const ParsedValueGraph = @import("ParsedValueGraph.zig");

const TOMLObjectBindings = bun.bindgen.Module("TOMLObject");
const ParseGraphSchema = TOMLObjectBindings.function("parseGraph");
const StringifyDateSchema = TOMLObjectBindings.function("stringifyDate");

comptime {
    _ = bun.bindgen.Fn(ParseGraphSchema, parseGraph);
    _ = bun.bindgen.Fn(StringifyDateSchema, stringifyDate);
}
