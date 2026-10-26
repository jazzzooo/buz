const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const shared = @import("binding_schema_HTMLRewriterTypes");

const text_chunk_class = b.class(
    "TextChunk",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("after", shared.content_arguments, archetypes.self_ref, .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref }),
        b.method("before", shared.content_arguments, archetypes.self_ref, .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref }),
        b.getter("lastInTextNode", archetypes.optional_boolean, .{ .cache = "lastInTextNode" }),
        b.method("remove", .{}, archetypes.self_ref, .{ .this_value_type = b.this_class_ref }),
        b.getter("removed", archetypes.optional_boolean, .{}),
        b.method("replace", shared.content_arguments, archetypes.self_ref, .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref }),
        b.getter("text", archetypes.optional_dom_string, .{ .implementation = "getText" }),
    },
    .{
        b.cachedSlot("lastInTextNode", archetypes.optional_boolean, .{}),
    },
    .{
        .backend = .zig,
        .profile = .webidl,
        .ownership = .shared,
        .identity = .fresh,
        .fresh_identity_reason = "rewrite callback tokens are event-scoped facades and are never re-wrapped",
        .reference_thread = .vm,
    },
);

pub const schema = b.moduleWithClasses("TextChunk", .{}, .{text_chunk_class});
pub const text_chunk = schema.class("TextChunk");
