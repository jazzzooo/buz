const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const attribute_iterator = @import("binding_schema_AttributeIterator");
const end_tag = @import("binding_schema_EndTag");
const shared = @import("binding_schema_HTMLRewriterTypes");

pub const end_tag_handler = b.callback(
    "HTMLRewriterEndTagHandler",
    .{b.argument("end_tag", b.classRef(end_tag.end_tag), .{})},
    shared.handler_result,
    .{
        .receiver = null,
        .profile = .exact,
    },
);

const element_class = b.class(
    "Element",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("after", shared.content_arguments, archetypes.self_ref, .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref }),
        b.method("append", shared.content_arguments, archetypes.self_ref, .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref }),
        b.getter("attributes", b.optionalUndefined(b.classRef(attribute_iterator.attribute_iterator)), .{
            .errors = shared.operation_errors,
            .implementation = "getAttributes",
        }),
        b.method("before", shared.content_arguments, archetypes.self_ref, .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref }),
        b.getter("canHaveContent", archetypes.optional_boolean, .{ .implementation = "getCanHaveContent" }),
        b.method("getAttribute", .{b.argument("name", b.dom_string, .{})}, archetypes.nullable_dom_string, .{ .errors = shared.operation_errors }),
        b.method("hasAttribute", .{b.argument("name", b.dom_string, .{})}, b.boolean, .{ .errors = shared.operation_errors }),
        b.getter("namespaceURI", archetypes.optional_dom_string, .{ .implementation = "getNamespaceURI", .cache = "namespaceURI" }),
        b.method(
            "onEndTag",
            .{b.argument("callback", end_tag_handler, .{})},
            archetypes.self_ref,
            .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref },
        ),
        b.method("prepend", shared.content_arguments, archetypes.self_ref, .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref }),
        b.method("remove", .{}, archetypes.self_ref, .{ .this_value_type = b.this_class_ref }),
        b.method("removeAndKeepContent", .{}, archetypes.self_ref, .{ .this_value_type = b.this_class_ref }),
        b.method("removeAttribute", .{b.argument("name", b.dom_string, .{})}, archetypes.self_ref, .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref }),
        b.getter("removed", archetypes.optional_boolean, .{ .implementation = "getRemoved" }),
        b.method("replace", shared.content_arguments, archetypes.self_ref, .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref }),
        b.getter("selfClosing", archetypes.optional_boolean, .{ .implementation = "getSelfClosing" }),
        b.method(
            "setAttribute",
            .{
                b.argument("name", b.dom_string, .{}),
                b.argument("value", b.dom_string, .{}),
            },
            archetypes.self_ref,
            .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref },
        ),
        b.method("setInnerContent", shared.content_arguments, archetypes.self_ref, .{ .errors = shared.operation_errors, .this_value_type = b.this_class_ref }),
        b.getter("tagName", archetypes.optional_dom_string, .{ .implementation = "getTagName" }),
        shared.attachedStringSetter("tagName", "setTagName"),
    },
    .{
        b.cachedSlot("namespaceURI", archetypes.optional_dom_string, .{}),
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

pub const schema = b.moduleWithClasses("Element", .{}, .{element_class});
pub const element = schema.class("Element");
