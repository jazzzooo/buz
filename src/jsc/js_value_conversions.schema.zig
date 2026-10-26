const b = @import("bindgen_schema");

const engine_shims = .{
    b.engineShim(
        "jsValueCoerceToInt32",
        .{b.argument("value", b.engine_value, .{})},
        b.int32,
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsValueCoerceToInt64",
        .{b.argument("value", b.engine_value, .{})},
        b.int64,
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsValueToInt64",
        .{b.argument("value", b.engine_value, .{})},
        b.int64,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "jsValuePureToBoolean",
        .{b.argument("value", b.engine_value, .{})},
        b.boolean,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "jsValueToNumber",
        .{b.argument("value", b.engine_value, .{})},
        b.double,
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsValueToObject",
        .{b.argument("value", b.engine_value, .{})},
        b.js_object,
        .current_realm_throwing,
    ),
};

const functions = .{
    b.function(
        "unwrapBoxedPrimitive",
        .{b.argument("value", b.engine_value, .{})},
        b.engine_value,
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
};

pub const schema = b.moduleWithDeclarations("js_value_conversions", functions, .{}, engine_shims, .{});
