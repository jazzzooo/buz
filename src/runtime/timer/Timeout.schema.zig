const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const timeout_class = b.class(
    "Timeout",
    b.illegalConstructor(),
    .{
        b.getter("_destroyed", b.boolean, .{ .implementation = "getDestroyed" }),
        b.getter("_idleStart", b.retained_any, .{ .implementation = "getIdleStart", .cache = "idleStart", .writable = true }),
        b.getter("_idleTimeout", b.retained_any, .{ .implementation = "getIdleTimeout", .cache = "idleTimeout", .writable = true }),
        b.getter("_onTimeout", b.retained_any, .{ .implementation = "getOnTimeout", .cache = "callback", .writable = true }),
        b.getter("_repeat", b.retained_any, .{ .implementation = "getRepeat", .cache = "repeat", .writable = true }),
        b.method(
            "dispose",
            .{},
            b.none,
            .{
                .symbol = .dispose,
                .length = 0,
                .invalid_this = .no_op,
            },
        ),
        b.method(
            "toPrimitive",
            .{archetypes.optionalPrimitiveHint("hint")},
            b.int32,
            .{ .symbol = .to_primitive, .length = 1, .invalid_this = .no_op },
        ),
        b.method("close", .{}, archetypes.self_ref, .{
            .length = 0,
            .this_value_type = b.this_class_ref,
            .invalid_this = .no_op,
        }),
        b.method("hasRef", .{}, b.boolean, .{ .length = 0, .invalid_this = .no_op }),
        b.method(
            "ref",
            .{},
            archetypes.self_ref,
            .{
                .implementation = "doRef",
                .length = 0,
                .this_value_type = b.this_class_ref,
                .invalid_this = .no_op,
            },
        ),
        b.method(
            "refresh",
            .{},
            archetypes.self_ref,
            .{
                .implementation = "doRefresh",
                .length = 0,
                .this_value_type = b.this_class_ref,
                .invalid_this = .no_op,
            },
        ),
        b.method(
            "unref",
            .{},
            archetypes.self_ref,
            .{
                .implementation = "doUnref",
                .length = 0,
                .this_value_type = b.this_class_ref,
                .invalid_this = .no_op,
            },
        ),
    },
    .{
        b.cachedSlot("callback", b.retained_any, .{ .writable = true, .exposed = false }),
        b.cachedSlot("arguments", b.optionalUndefined(b.js_array), .{ .writable = true, .exposed = false }),
        b.cachedSlot("idleTimeout", b.retained_any, .{ .writable = true, .exposed = false }),
        b.cachedSlot("repeat", b.retained_any, .{ .writable = true, .exposed = false }),
        b.cachedSlot("idleStart", b.retained_any, .{ .writable = true, .exposed = false }),
    },
    .{
        .illegal_constructor_errors = .{
            .call = archetypes.constructorRequiresNew("Timeout"),
            .construct = .{ .kind = .generic_error, .message = "Timeout is not constructible" },
        },
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
    },
);

pub const schema = b.moduleWithClasses("Timeout", .{}, .{timeout_class});
pub const timeout = schema.class("Timeout");
