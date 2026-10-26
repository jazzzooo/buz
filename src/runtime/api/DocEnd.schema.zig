const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const shared = @import("binding_schema_HTMLRewriterTypes");

const doc_end_class = b.class(
    "DocEnd",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method(
            "append",
            shared.content_arguments,
            archetypes.self_ref,
            .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref },
        ),
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

pub const schema = b.moduleWithClasses("DocEnd", .{}, .{doc_end_class});
pub const doc_end = schema.class("DocEnd");
