const b = @import("bindgen_schema");
const deferred_rewriter_listener = "CSS selector parsing must fail before any handler property getter runs";
const archetypes = @import("binding_schema_archetypes");
const comment = @import("binding_schema_Comment");
const doc_end = @import("binding_schema_DocEnd");
const doc_type = @import("binding_schema_DocType");
const element = @import("binding_schema_Element");
const response = @import("binding_schema_Response");
const text_chunk = @import("binding_schema_TextChunk");
const shared = @import("binding_schema_HTMLRewriterTypes");

const transform_input = b.unionType("HTMLRewriterTransformInput", .{
    b.unionMember("response", b.classRef(response.response)),
    b.unionMember("body", archetypes.string_or_buffer),
}, .{
    .ordered = true,
    .no_match_error = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "Expected Response or Body" },
});

const transform_result = b.unionType("HTMLRewriterTransformResult", .{
    b.unionMember("response", b.classRef(response.response)),
    b.unionMember("text", b.dom_string),
    b.unionMember("array_buffer", b.array_buffer_result),
}, .{});

const transform_errors = b.domainErrors(.{
    b.domainError("body_already_used", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Response body already used" },
    }),
    b.domainError("stream_already_used", b.none, .{
        .class = .generic_error,
        .code = "ERR_STREAM_ALREADY_FINISHED",
        .message = .{ .literal = "Stream already used, please create a new one" },
    }),
});

const listener_errors = b.domainErrors(.{
    b.domainError("missing_argument", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Missing argument" },
    }),
    shared.operation_error,
});

fn handlerCallback(
    comptime name: []const u8,
    comptime argument_name: []const u8,
    comptime class: b.BoundClass,
) b.Type {
    return b.callback(
        name,
        .{b.argument(argument_name, b.classRef(class), .{})},
        shared.handler_result,
        .{
            .receiver = b.js_object,
            .profile = .exact,
        },
    );
}

fn handlerField(comptime field_name: []const u8, comptime name: []const u8, comptime callback: b.Type) b.DictionaryField {
    const input = b.unionType(name, .{
        b.unionMember("callback", callback),
        b.unionMember("absent", b.undefined_literal),
    }, .{
        .ordered = true,
        .no_match_error = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = field_name ++ " must be a function" },
    });
    return b.dictionaryField(field_name, input, .{ .required = true, .missing_required = .convert_undefined });
}

const element_handler_callback = handlerCallback("HTMLRewriterElementHandler", "element", element.element);
const comment_handler_callback = handlerCallback("HTMLRewriterCommentHandler", "comment", comment.comment);
const text_handler_callback = handlerCallback("HTMLRewriterTextHandler", "text_chunk", text_chunk.text_chunk);
const doctype_handler_callback = handlerCallback("HTMLRewriterDoctypeHandler", "doctype", doc_type.doc_type);
const document_end_handler_callback = handlerCallback("HTMLRewriterDocumentEndHandler", "doc_end", doc_end.doc_end);

const element_content_handlers = b.dictionaryWithOptions("HTMLRewriterElementHandlers", .{
    b.dictionaryField("listener_identity", b.js_object, .{ .source = .dictionary, .required = true }),
    handlerField("element", "HTMLRewriterElementHandlerInput", element_handler_callback),
    handlerField("comments", "HTMLRewriterElementCommentHandlerInput", comment_handler_callback),
    handlerField("text", "HTMLRewriterElementTextHandlerInput", text_handler_callback),
}, .{
    .user_facing_name = "handlers",
    .object_error = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "Expected object" },
});

const document_content_handlers = b.dictionaryWithOptions("HTMLRewriterDocumentHandlers", .{
    b.dictionaryField("listener_identity", b.js_object, .{ .source = .dictionary, .required = true }),
    handlerField("doctype", "HTMLRewriterDoctypeHandlerInput", doctype_handler_callback),
    handlerField("comments", "HTMLRewriterDocumentCommentHandlerInput", comment_handler_callback),
    handlerField("text", "HTMLRewriterDocumentTextHandlerInput", text_handler_callback),
    handlerField("end", "HTMLRewriterDocumentEndHandlerInput", document_end_handler_callback),
}, .{
    .user_facing_name = "handlers",
    .object_error = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "Expected object" },
});

const html_rewriter_class = b.class(
    "HTMLRewriter",
    b.constructor(.{}, .{ .length = 0 }),
    .{
        b.method(
            "on",
            .{
                b.argument("selector", b.dom_string, .{ .presence = .optional, .missing = .omitted }),
                b.argument("listener", b.lazy(element_content_handlers), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_rewriter_listener }),
            },
            archetypes.self_ref,
            .{ .errors = listener_errors, .length = 2, .this_value_type = b.this_class_ref },
        ),
        b.method(
            "onDocument",
            .{b.argument("listener", document_content_handlers, .{ .presence = .optional, .missing = .omitted })},
            archetypes.self_ref,
            .{ .errors = listener_errors, .length = 1, .this_value_type = b.this_class_ref },
        ),
        b.method(
            "transform",
            .{b.argument("input", transform_input, .{})},
            transform_result,
            .{
                .length = 1,
                .errors = transform_errors,
                .missing_required_arguments = .{ .failure = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "Missing argument" } },
            },
        ),
    },
    .{},
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("HTMLRewriter"),
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
    },
);

const engine_shims = .{
    b.engineShim("createHTMLRewriterError", .{b.argument("message", b.dom_string, .{})}, b.js_error_instance, .current_realm_throwing),
};

pub const schema = b.moduleWithClassesAndEngineShims("HTMLRewriter", .{}, .{html_rewriter_class}, engine_shims);
pub const html_rewriter = schema.class("HTMLRewriter");
