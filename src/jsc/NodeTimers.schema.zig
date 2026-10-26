const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const immediate = @import("binding_schema_Immediate");
const timer = @import("binding_schema_Timer");
const timeout = @import("binding_schema_Timeout");
const time_types = @import("binding_schema_TimeTypes");

const timer_clear_input = b.unionType("TimerClearInput", .{
    b.unionMember("immediate", b.classRef(immediate.immediate)),
    b.unionMember("timeout", b.classRef(timeout.timeout)),
    archetypes.matchingInt32Member("number"),
    b.unionMember("string", archetypes.timer_identifier_string),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

fn clearFunction(comptime name: []const u8) b.Function {
    return b.function(
        name,
        .{b.argument("timer", timer_clear_input, .{})},
        b.none,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    );
}

fn createFunction(
    comptime name: []const u8,
    comptime arguments: anytype,
    comptime result: b.Type,
) b.Function {
    return b.function(name, arguments, result, .{
        .backend = .zig,
        .length = 1,
        .profile = .node,
    });
}

pub const schema = b.module("NodeTimers", .{
    createFunction(
        "setTimeout",
        .{
            b.argument("job", timer.timer_callback, .{}),
            time_types.node_countdown("delay"),
            b.rest("arguments", b.invocation_any),
        },
        b.classRef(timeout.timeout),
    ),
    createFunction(
        "setInterval",
        .{
            b.argument("job", timer.timer_callback, .{}),
            time_types.node_countdown("delay"),
            b.rest("arguments", b.invocation_any),
        },
        b.classRef(timeout.timeout),
    ),
    createFunction(
        "setImmediate",
        .{
            b.argument("job", timer.timer_callback, .{}),
            b.rest("arguments", b.invocation_any),
        },
        b.classRef(immediate.immediate),
    ),
    clearFunction("clearImmediate"),
    clearFunction("clearInterval"),
    clearFunction("clearTimeout"),
});
