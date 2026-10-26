const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const fetch_types = @import("binding_schema_FetchTypes");
const console_object = @import("binding_schema_ConsoleObject");

const headers_string_list = b.sequence(b.byte_string);
const headers_string_list_result = headers_string_list;
const headers_iterator_value = b.unionType("HeadersIteratorValue", .{
    b.unionMember("entry", headers_string_list),
    b.unionMember("string", b.byte_string),
}, .{});
const headers_iterator_result = b.dictionary("HeadersIteratorResult", .{
    b.dictionaryField("value", b.optionalUndefined(headers_iterator_value), .{ .required = true }),
    b.dictionaryField("done", b.boolean, .{ .required = true }),
});
const headers_iterator_class = b.classWithDataProperties(
    "HeadersIterator",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("next", .{}, headers_iterator_result, .{ .length = 0, .configurable = true }),
    },
    .{},
    .{b.dataProperty("toStringTag", .{ .string = "Headers Iterator" }, .{ .symbol = .to_string_tag, .enumerable = false })},
    .{
        .backend = .zig,
        .profile = .exact,
        .display_name = "Headers Iterator",
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .prototype_base = .iterator,
    },
);
const headers_json_value = b.unionType("HeadersJSONValue", .{
    b.unionMember("value", b.byte_string),
    b.unionMember("set_cookie", headers_string_list),
}, .{ .cpp_name = "HeadersJSONValue" });
pub const headers_json_result = b.record(b.byte_string, headers_json_value);
const headers_for_each_callback = b.callback("HeadersForEachCallback", .{
    b.argument("value", b.byte_string, .{}),
    b.argument("key", b.byte_string, .{}),
    b.argument("headers", b.classRefByName("WebCoreHeaders", "Headers"), .{}),
}, b.none, .{
    .receiver = b.optionalUndefined(b.invocation_any),
});

const headers_class = b.class(
    "Headers",
    b.constructor(.{b.argument("init", fetch_types.cloned_headers_init, .{})}, .{
        .length = 0,
        .missing_required_arguments = .convert_undefined,
    }),
    .{
        b.method("append", .{
            b.argument("name", b.byte_string, .{}),
            b.argument("value", b.byte_string, .{}),
        }, b.none, .{ .backend = .zig, .implementation = "bindAppend", .length = 2, .configurable = true }),
        b.method("delete", .{b.argument("name", b.byte_string, .{})}, b.none, .{ .backend = .zig, .implementation = "bindDelete", .length = 1, .configurable = true }),
        b.method("get", .{b.argument("name", b.byte_string, .{})}, b.optionalNullish(b.byte_string), .{ .backend = .zig, .implementation = "bindGet", .length = 1, .configurable = true }),
        b.method("getAll", .{b.argument("name", b.byte_string, .{})}, headers_string_list_result, .{
            .backend = .zig,
            .length = 1,
            .configurable = true,
            .errors = b.domainErrors(.{b.domainError("unsupported_name", b.none, .{
                .class = .type_error,
                .message = .{ .literal = "Only \"set-cookie\" is supported." },
            })}),
        }),
        b.method("has", .{b.argument("name", b.byte_string, .{})}, b.boolean, .{ .backend = .zig, .implementation = "bindHas", .length = 1, .configurable = true }),
        b.method("set", .{
            b.argument("name", b.byte_string, .{}),
            b.argument("value", b.byte_string, .{}),
        }, b.none, .{ .backend = .zig, .implementation = "bindSet", .length = 2, .configurable = true }),
        b.method("entries", .{}, b.classRefByName("WebCoreHeaders", "HeadersIterator"), .{
            .backend = .zig,
            .length = 0,
            .configurable = true,
            .aliases = &.{b.memberSymbolAlias(.iterator, .{ .enumerable = false })},
        }),
        b.method("keys", .{}, b.classRefByName("WebCoreHeaders", "HeadersIterator"), .{ .backend = .zig, .length = 0, .configurable = true }),
        b.method("values", .{}, b.classRefByName("WebCoreHeaders", "HeadersIterator"), .{ .backend = .zig, .length = 0, .configurable = true }),
        b.method("forEach", .{
            b.argument("callback", headers_for_each_callback, .{}),
            b.argument("thisArg", b.any, .{ .presence = .optional, .missing = .undefined }),
        }, b.none, .{ .backend = .zig, .length = 1, .configurable = true, .this_value_type = b.this_class_ref }),
        b.method("toJSON", .{}, headers_json_result, .{ .backend = .zig, .native_reference = true, .length = 0, .configurable = true }),
        b.getter("count", b.uint32, .{ .backend = .zig, .implementation = "getCount", .invalid_this = .no_op }),
        b.method("getSetCookie", .{}, headers_string_list_result, .{ .backend = .zig, .length = 0, .configurable = true }),
        console_object.native_inspect,
    },
    .{},
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("Headers", "ERR_ILLEGAL_CONSTRUCTOR"),
        .backend = .zig,
        .profile = .webidl,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .vm,
    },
);

pub const schema = b.moduleWithClasses("WebCoreHeaders", .{}, .{ headers_iterator_class, headers_class });
pub const headers_iterator = schema.class("HeadersIterator");
pub const headers = schema.class("Headers");
