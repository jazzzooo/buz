const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const doc_type_class = b.class(
    "DocType",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.getter("name", archetypes.nullable_dom_string, .{ .cache = "name" }),
        b.getter("publicId", archetypes.nullable_dom_string, .{ .cache = "publicId" }),
        b.method("remove", .{}, archetypes.self_ref, .{ .this_value_type = b.this_class_ref }),
        b.getter("removed", archetypes.optional_boolean, .{}),
        b.getter("systemId", archetypes.nullable_dom_string, .{ .cache = "systemId" }),
    },
    .{
        b.cachedSlot("name", archetypes.nullable_dom_string, .{}),
        b.cachedSlot("publicId", archetypes.nullable_dom_string, .{}),
        b.cachedSlot("systemId", archetypes.nullable_dom_string, .{}),
    },
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .shared,
        .identity = .fresh,
        .fresh_identity_reason = "rewrite callback tokens are event-scoped facades and are never re-wrapped",
        .reference_thread = .vm,
    },
);

pub const schema = b.moduleWithClasses("DocType", .{}, .{doc_type_class});
pub const doc_type = schema.class("DocType");
