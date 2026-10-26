const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const shared = @import("binding_schema_HTMLRewriterTypes");

const end_tag_class = b.class(
    "EndTag",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("after", shared.content_arguments, archetypes.self_ref, .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref }),
        b.method("before", shared.content_arguments, archetypes.self_ref, .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref }),
        b.getter("name", archetypes.optional_dom_string, .{ .implementation = "getName" }),
        shared.attachedStringSetter("name", "setName"),
        b.method("remove", .{}, archetypes.self_ref, .{ .this_value_type = b.this_class_ref }),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .webidl,
        .ownership = .shared,
        .identity = .fresh,
        .fresh_identity_reason = "rewrite callback tokens are event-scoped facades and are never re-wrapped",
        .reference_thread = .vm,
    },
);

pub const schema = b.moduleWithClasses("EndTag", .{}, .{end_tag_class});
pub const end_tag = schema.class("EndTag");
