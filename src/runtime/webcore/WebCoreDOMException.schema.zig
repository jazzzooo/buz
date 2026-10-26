const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const webcore_bindings = @import("binding_schema_WebCoreBindings");

const dom_exception_codes = .{
    .{ "INDEX_SIZE_ERR", 1 },
    .{ "DOMSTRING_SIZE_ERR", 2 },
    .{ "HIERARCHY_REQUEST_ERR", 3 },
    .{ "WRONG_DOCUMENT_ERR", 4 },
    .{ "INVALID_CHARACTER_ERR", 5 },
    .{ "NO_DATA_ALLOWED_ERR", 6 },
    .{ "NO_MODIFICATION_ALLOWED_ERR", 7 },
    .{ "NOT_FOUND_ERR", 8 },
    .{ "NOT_SUPPORTED_ERR", 9 },
    .{ "INUSE_ATTRIBUTE_ERR", 10 },
    .{ "INVALID_STATE_ERR", 11 },
    .{ "SYNTAX_ERR", 12 },
    .{ "INVALID_MODIFICATION_ERR", 13 },
    .{ "NAMESPACE_ERR", 14 },
    .{ "INVALID_ACCESS_ERR", 15 },
    .{ "VALIDATION_ERR", 16 },
    .{ "TYPE_MISMATCH_ERR", 17 },
    .{ "SECURITY_ERR", 18 },
    .{ "NETWORK_ERR", 19 },
    .{ "ABORT_ERR", 20 },
    .{ "URL_MISMATCH_ERR", 21 },
    .{ "QUOTA_EXCEEDED_ERR", 22 },
    .{ "TIMEOUT_ERR", 23 },
    .{ "INVALID_NODE_TYPE_ERR", 24 },
    .{ "DATA_CLONE_ERR", 25 },
};

fn domExceptionCodeConstants(comptime storage: b.DataPropertyStorage) [dom_exception_codes.len]b.DataProperty {
    var result: [dom_exception_codes.len]b.DataProperty = undefined;
    for (dom_exception_codes, 0..) |entry, index| {
        result[index] = archetypes.integerDataProperty(entry[0], entry[1], storage);
    }
    return result;
}

const dom_exception_options = b.dictionary("DOMExceptionOptions", .{
    b.dictionaryField("name", b.dom_string, .{}),
    b.dictionaryField("cause", b.retained_any, .{ .missing = .absent }),
});
const dom_exception_name_or_options = b.unionType("DOMExceptionNameOrOptions", .{
    b.unionMember("options", dom_exception_options),
    b.unionMember("name", b.dom_string),
}, .{ .ordered = true, .fallback_member = "name", .cpp_name = "DOMExceptionNameOrOptions" });

const dom_exception_class = webcore_bindings.wrapperClassWithDataProperties(
    "DOMException",
    b.constructor(.{
        b.argument("message", b.dom_string, .{
            .presence = .default_value,
            .missing = .undefined,
            .default_value = .{ .string = "" },
        }),
        b.argument("second", dom_exception_name_or_options, .{ .presence = .optional, .missing = .omitted }),
    }, .{ .length = 0 }),
    .{
        b.getter("code", b.uint16, .{ .configurable = true }),
        b.getter("name", b.dom_string, .{ .configurable = true }),
        b.getter("message", b.dom_string, .{ .configurable = true }),
    },
    .{},
    domExceptionCodeConstants(.prototype) ++ domExceptionCodeConstants(.constructor),
    "WebCore DOMException error identity, stack behavior, and GC tracing",
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("DOMException", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = b.engineParent(.{
            .cpp_class = .{ .specialization = .{ .name = "WebCore::JSDOMWrapper", .arguments = &.{.{ .named = "WebCore::DOMException" }} } },
            .cpp_impl = "WebCore::DOMException",
            .header = "JSDOMWrapper.h",
            .prototype = .error_object,
            .constructor = .function,
        }),
        .engine_native = .{ .cpp_type = "WebCore::DOMException", .header = "DOMExceptionOwner.h" },
        .identity = .per_realm,
    },
);

pub const schema = b.moduleWithClasses("WebCoreDOMException", .{}, .{dom_exception_class});
pub const dom_exception = schema.class("DOMException");
