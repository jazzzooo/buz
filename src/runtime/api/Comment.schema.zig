const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const shared = @import("binding_schema_HTMLRewriterTypes");

const comment_class = b.class(
    "Comment",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("after", shared.content_arguments, archetypes.self_ref, .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref }),
        b.method("before", shared.content_arguments, archetypes.self_ref, .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref }),
        b.method("remove", .{}, archetypes.self_ref, .{ .this_value_type = b.this_class_ref }),
        b.getter("removed", archetypes.optional_boolean, .{}),
        b.method("replace", shared.content_arguments, archetypes.self_ref, .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref }),
        b.getter("text", archetypes.nullable_dom_string, .{ .implementation = "getText" }),
        shared.attachedStringSetter("text", "setText"),
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

pub const schema = b.moduleWithClasses("Comment", .{}, .{comment_class});
pub const comment = schema.class("Comment");
