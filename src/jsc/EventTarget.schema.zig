const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const event_target_match = b.brandedValueWithBrand(b.cppDynamicCastBrand("EventTargetHostValue", .{
    .type_name = "WebCore::JSEventTarget",
    .header = "webcore/JSEventTarget.h",
}, "EventTarget"), .{
    .no_match_error = .{
        .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
        .message = "ERR_INVALID_ARG_TYPE: first argument must be of type EventEmitter",
    },
});
const event_target = event_target_match;
const optional_event_target = b.optionalMatch(event_target_match);

fn stringDefault(comptime name: []const u8) b.Argument {
    return b.argument(name, archetypes.coerced_dom_string, .{
        .presence = .default_value,
        .default_value = .{ .string = "undefined" },
    });
}

const functions = .{
    b.function(
        "getEventListeners",
        .{
            b.argument("target", event_target, .{}),
            stringDefault("event_type"),
        },
        b.js_array,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
            .conversion_program = &.{ .{ .convert = "event_type" }, .{ .convert = "target" } },
        },
    ),
    b.function(
        "getEventListenersCount",
        .{ b.argument("target", optional_event_target, .{}), stringDefault("event_type") },
        archetypes.optional_size,
        .{ .backend = .cpp, .length = 2, .profile = .exact, .missing_required_arguments = .convert_undefined },
    ),
};

pub const schema = b.module("EventTarget", functions);
