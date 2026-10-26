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

    var encoded_string = bun.String.Slice.empty;
    defer encoded_string.deinit();
    const input = switch (args.input) {
        .blob => |blob| blob.get().sharedView(),
        .buffer => |buffer| buffer.unsafePtr("the generated entry frame owns the byte lease until YAML parsing and value-graph conversion finish"),
        .string => |string| input: {
            encoded_string = try string.toUTF8(allocator);
            break :input encoded_string.slice();
        },
    };

    const input_len = input.len;
    if (input_len > std.math.maxInt(i32)) {
        return context.fail(.input_too_large, try ParsedValueGraph.inputTooLargeMessage(input_len));
    }

    var log = logger.Log.init(bun.default_allocator);
    defer log.deinit();

    const source = &logger.Source.initPathString("input.yaml", input);

    const root = YAML.parse(source, &log, arena.allocator()) catch |err| return switch (err) {
        error.OutOfMemory => |oom| oom,
        error.StackOverflow => throwStackOverflow(context),
        else => {
            const message = if (log.msgs.items.len > 0)
                try bun.String.createFormat("YAML Parse error: {s}", .{log.msgs.items[0].data.text})
            else
                bun.String.static("YAML Parse error: Unable to parse YAML string");
            return context.fail(.parse_error, try bun.bindgen.DOMString.fromBunString(message));
        },
    };
    return ParsedValueGraph.fromExpr(bun.bindgen.Return(ParseGraphSchema), root, allocator) catch |err| switch (err) {
        error.OutOfMemory => |oom| oom,
        error.GraphTooLarge => context.fail(.input_too_large, try ParsedValueGraph.inputTooLargeMessage(input_len)),
        error.UnsupportedExpression => context.fail(.unsupported_value, {}),
    };
}

const std = @import("std");

const bun = @import("bun");
const default_allocator = bun.default_allocator;
const logger = bun.logger;
const YAML = bun.interchange.yaml.YAML;

const ast = bun.ast;
const ParsedValueGraph = @import("ParsedValueGraph.zig");

const YAMLObjectBindings = bun.bindgen.Module("YAMLObject");
const ParseGraphSchema = YAMLObjectBindings.function("parseGraph");

comptime {
    _ = bun.bindgen.Fn(ParseGraphSchema, parseGraph);
}
