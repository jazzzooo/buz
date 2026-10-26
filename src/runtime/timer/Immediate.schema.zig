const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const immediate_class = b.class(
    "Immediate",
    b.illegalConstructor(),
    .{
        b.getter("_destroyed", b.boolean, .{ .implementation = "getDestroyed" }),
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
    },
    .{
        .illegal_constructor_errors = .{
            .call = archetypes.constructorRequiresNew("Immediate"),
            .construct = .{ .kind = .generic_error, .message = "Immediate is not constructible" },
        },
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
    },
);

pub const schema = b.moduleWithClasses("Immediate", .{}, .{immediate_class});
pub const immediate = schema.class("Immediate");
