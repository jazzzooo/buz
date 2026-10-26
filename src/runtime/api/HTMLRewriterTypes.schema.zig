const b = @import("bindgen_schema");

pub const handler_result = b.unionType("HTMLRewriterHandlerResult", .{
    b.unionMember("error_value", b.js_error_instance),
    b.unionMember("exception", b.js_exception),
    b.unionMember("promise", b.void_promise),
    b.unionMember("ignored", b.discardAny(.ignored)),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub const content_options = b.dictionary("HTMLRewriterContentOptions", .{
    b.dictionaryField("html", b.boolean, .{ .default_value = .{ .boolean = false } }),
});

pub const content_arguments = .{
    b.argument("content", b.dom_string, .{}),
    b.argument("options", b.optionalNullish(content_options), .{
        .presence = .optional,
        .missing = .undefined_or_null,
    }),
};

pub fn attachedStringSetter(comptime name: []const u8, comptime implementation: []const u8) b.ClassMember {
    return b.setter(name, b.lazy(b.dom_string), .{
        .errors = operation_errors,
        .implementation = implementation,
        .deferred_reason = "Detached callback wrappers ignore assigned values without invoking string coercion",
    });
}

pub const operation_error = b.domainError("operation_failed", b.dom_string, .{
    .class = .generic_error,
    .message = .payload,
    .name_override = "HTMLRewriterError",
});

pub const operation_errors = b.domainErrors(.{operation_error});

pub const schema = b.module("HTMLRewriterTypes", .{});
