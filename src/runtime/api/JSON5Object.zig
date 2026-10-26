fn throwStackOverflow(context: anytype) bun.JSError {
    context.engineIn("errors", "throwStackOverflow").call(.{}) catch |err| return err;
    unreachable;
}

pub fn parseGraph(
    context: bun.bindgen.CallContext(ParseGraphSchema),
    args: bun.bindgen.Args(ParseGraphSchema),
) bun.bindgen.CallError(ParseGraphSchema)!bun.bindgen.Return(ParseGraphSchema) {
    var arena: bun.ArenaAllocator = .init(bun.default_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const ast_memory_allocator = try allocator.create(ast.ASTMemoryAllocator);
    var ast_scope = ast_memory_allocator.enter(allocator);
    defer ast_scope.exit();

    const input_value = args.input orelse {
        return context.fail(.missing_input, {});
    };
    var encoded_string = bun.String.Slice.empty;
    defer encoded_string.deinit();
    const input = switch (input_value) {
        .blob => |blob| blob.get().sharedView(),
        .buffer => |buffer| buffer.unsafePtr("the generated entry frame owns the byte lease until JSON5 parsing and value-graph conversion finish"),
        .string => |string| input: {
            encoded_string = try string.toUTF8(allocator);
            break :input encoded_string.slice();
        },
    };
    if (input.len > std.math.maxInt(i32)) {
        return context.fail(.input_too_large, try ParsedValueGraph.inputTooLargeMessage(input.len));
    }

    var log = logger.Log.init(bun.default_allocator);
    defer log.deinit();

    const source = &logger.Source.initPathString("input.json5", input);

    const root = json5.JSON5Parser.parse(source, &log, allocator) catch |err| return switch (err) {
        error.OutOfMemory => |oom| oom,
        error.StackOverflow => throwStackOverflow(context),
        else => {
            const message = if (log.msgs.items.len > 0)
                log.msgs.items[0].data.text
            else
                "JSON5 Parse error: Unable to parse JSON5 string";
            return context.fail(.parse_error, try bun.bindgen.DOMString.fromUTF8(message));
        },
    };
    return ParsedValueGraph.fromExpr(bun.bindgen.Return(ParseGraphSchema), root, allocator) catch |err| switch (err) {
        error.OutOfMemory => |oom| oom,
        error.GraphTooLarge => context.fail(.input_too_large, try ParsedValueGraph.inputTooLargeMessage(input.len)),
        error.UnsupportedExpression => context.fail(.unsupported_value, {}),
    };
}

const std = @import("std");

const bun = @import("bun");
const logger = bun.logger;
const json5 = bun.interchange.json5;

const ast = bun.ast;
const ParsedValueGraph = @import("ParsedValueGraph.zig");

const JSON5ObjectBindings = bun.bindgen.Module("JSON5Object");
const ParseGraphSchema = JSON5ObjectBindings.function("parseGraph");

comptime {
    _ = bun.bindgen.Fn(ParseGraphSchema, parseGraph);
}
