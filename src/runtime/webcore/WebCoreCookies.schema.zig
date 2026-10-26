const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const cookie_date = b.js_date;
pub const cookie_same_site = b.enumerationWithOptions("CookieSameSite", .{
    b.enumerationValue("strict", "strict"),
    b.enumerationValue("lax", "lax"),
    b.enumerationValue("none", "none"),
}, .{
    .cpp_name = "CookieSameSite",
    .ascii_case_insensitive = true,
    .invalid_value_failure = .{
        .kind = .type_error,
        .message = "Invalid sameSite value. Must be 'strict', 'lax', or 'none'",
    },
});
const cookie_expires = archetypes.cookie_expires;
const cookie_options_fields = .{
    b.dictionaryField("domain", b.optionalNullish(b.usv_string), .{}),
    b.dictionaryField("path", b.optionalNullish(b.usv_string), .{}),
    b.dictionaryField("expires", cookie_expires, .{ .profile = .node }),
    b.dictionaryField("secure", b.boolean, .{}),
    b.dictionaryField("same_site", b.optionalNullish(cookie_same_site), .{ .js_name = "sameSite" }),
    b.dictionaryField("http_only", b.boolean, .{ .js_name = "httpOnly" }),
    b.dictionaryField("max_age", b.optionalNullish(b.double), .{ .js_name = "maxAge" }),
    b.dictionaryField("partitioned", b.boolean, .{}),
};
const cookie_options = b.dictionaryWithOptions(
    "CookieOptions",
    cookie_options_fields,
    .{ .cpp_name = "CookieOptionsDictionary" },
);
const cookie_init = b.dictionaryWithOptions(
    "CookieInit",
    .{
        b.dictionaryField("name", b.usv_string, .{
            .required = true,
            .missing = .absent,
            .missing_required = .{ .failure = .{ .kind = .type_error, .message = "name is required" } },
        }),
        b.dictionaryField("value", b.usv_string, .{}),
    } ++ cookie_options_fields,
    .{ .cpp_name = "CookieInitDictionary" },
);
const cookie_ref = b.classRefByName("WebCoreCookies", "Cookie");
const cookie_result = cookie_ref;
const cookie_expires_result = b.optionalUndefined(cookie_date);
pub const cookie_json_result = b.dictionaryWithOptions(
    "CookieJSON",
    .{
        b.dictionaryField("name", b.usv_string, .{ .required = true }),
        b.dictionaryField("value", b.usv_string, .{ .required = true }),
        b.dictionaryField("domain", b.usv_string, .{}),
        b.dictionaryField("path", b.usv_string, .{ .required = true }),
        b.dictionaryField("expires", cookie_date, .{}),
        b.dictionaryField("max_age", b.double, .{ .js_name = "maxAge" }),
        b.dictionaryField("secure", b.boolean, .{ .required = true }),
        b.dictionaryField("same_site", cookie_same_site, .{ .required = true, .js_name = "sameSite" }),
        b.dictionaryField("http_only", b.boolean, .{ .required = true, .js_name = "httpOnly" }),
        b.dictionaryField("partitioned", b.boolean, .{ .required = true }),
    },
    .{ .cpp_name = "CookieJSONDictionary", .result_prototype = .null },
);
const cookie_class = b.class(
    "Cookie",
    b.constructor(b.overloads(.{
        b.overloadCase("parse", .{b.argument("cookieString", b.usv_string, .{})}),
        b.overloadCase("init", .{b.argument("init", cookie_init, .{})}),
        b.overloadCase("pair", .{
            b.argument("name", b.usv_string, .{}),
            b.argument("value", b.usv_string, .{}),
            b.argument("options", cookie_options, .{ .presence = .optional, .missing = .undefined_or_null }),
        }),
    }, .{ .ordered = true, .accept_extra_arguments = true }), .{ .length = 2 }),
    .{
        b.getter("name", b.usv_string, .{ .implementation = "getName", .configurable = true, .getter_assignment = .ignore }),
        b.getter("value", b.usv_string, .{ .implementation = "getValue", .configurable = true }),
        b.setter("value", b.usv_string, .{ .implementation = "setValue", .configurable = true }),
        b.getter("domain", b.optionalNullish(b.usv_string), .{ .implementation = "getDomain", .configurable = true }),
        b.setter("domain", b.usv_string, .{ .implementation = "setDomain", .configurable = true }),
        b.getter("path", b.usv_string, .{ .implementation = "getPath", .configurable = true }),
        b.setter("path", b.usv_string, .{ .implementation = "setPath", .configurable = true }),
        b.getter("expires", cookie_expires_result, .{ .profile = .node, .implementation = "getExpires", .cache = "expires", .configurable = true }),
        b.setter("expires", cookie_expires, .{ .profile = .node, .implementation = "setExpires", .configurable = true, .this_value_type = b.this_class_ref }),
        b.getter("secure", b.boolean, .{ .implementation = "getSecure", .configurable = true }),
        b.setter("secure", b.boolean, .{ .implementation = "setSecure", .configurable = true }),
        b.getter("sameSite", cookie_same_site, .{ .implementation = "getSameSite", .configurable = true }),
        b.setter("sameSite", cookie_same_site, .{ .implementation = "setSameSite", .configurable = true }),
        b.getter("httpOnly", b.boolean, .{ .implementation = "getHttpOnly", .configurable = true }),
        b.setter("httpOnly", b.boolean, .{ .implementation = "setHttpOnly", .configurable = true }),
        b.getter("maxAge", b.optionalUndefined(b.double), .{ .implementation = "getMaxAge", .configurable = true }),
        b.setter("maxAge", b.optionalNullish(b.double), .{ .implementation = "setMaxAge", .configurable = true }),
        b.getter("partitioned", b.boolean, .{ .implementation = "getPartitioned", .configurable = true }),
        b.setter("partitioned", b.boolean, .{ .implementation = "setPartitioned", .configurable = true }),
        b.method("isExpired", .{}, b.boolean, .{ .length = 0, .configurable = true }),
        b.method("toString", .{}, b.byte_string, .{ .length = 0, .configurable = true }),
        b.method("serialize", .{}, b.byte_string, .{ .length = 0, .configurable = true }),
        b.method("toJSON", .{}, cookie_json_result, .{
            .length = 0,
            .configurable = true,
        }),
        b.method("inspectCustom", .{}, cookie_json_result, .{
            .length = 0,
            .symbol = .inspect_custom,
            .enumerable = false,
        }),
        b.staticMethod("parse", .{b.argument("cookieString", b.usv_string, .{})}, cookie_result, .{ .length = 1 }),
        b.staticMethod("from", .{
            b.argument("name", b.usv_string, .{}),
            b.argument("value", b.usv_string, .{}),
            b.argument("options", cookie_options, .{ .presence = .optional, .missing = .undefined_or_null }),
        }, cookie_result, .{ .length = 3 }),
    },
    .{b.cachedSlot("expires", cookie_expires_result, .{ .exposed = false, .writable = true })},
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("Cookie", "ERR_ILLEGAL_CONSTRUCTOR"),
        .backend = .zig,
        .profile = .webidl,
        .ownership = .unique,
        .identity = .fresh,
        .memory_usage = .vm,
    },
);

pub const cookie_map_pairs = b.sequenceWithOptions(archetypes.usv_string_pair_iterable, .{ .container = .iterable });
pub const cookie_map_record = b.record(b.usv_string, b.usv_string);
const cookie_map_init = b.unionType("CookieMapInit", .{
    b.unionMember("sequence", cookie_map_pairs),
    b.unionMember("record", cookie_map_record),
    b.unionMember("string", b.usv_string),
}, .{ .ordered = true, .fallback_member = "string" });
const cookie_delete_options_fields = .{
    b.dictionaryField("domain", b.optionalNullish(b.usv_string), .{}),
    b.dictionaryField("path", b.optionalNullish(b.usv_string), .{}),
};
const cookie_delete_options = b.dictionaryWithOptions(
    "CookieDeleteOptions",
    cookie_delete_options_fields,
    .{ .cpp_name = "CookieDeleteOptionsDictionary" },
);
const cookie_delete_init = b.dictionaryWithOptions(
    "CookieDeleteInit",
    .{b.dictionaryField("name", b.optionalMatch(b.usv_string), .{ .required = true, .missing_required = .convert_undefined })} ++ cookie_delete_options_fields,
    .{ .cpp_name = "CookieDeleteInitDictionary" },
);
const cookie_map_iterator_item = b.unionType("CookieMapIteratorItem", .{
    b.unionMember("entry", b.sequence(b.usv_string)),
    b.unionMember("string", b.usv_string),
}, .{ .cpp_name = "CookieMapIteratorItem" });
const cookie_map_iterator_result = b.dictionaryWithOptions(
    "CookieMapIteratorResult",
    .{
        b.dictionaryField("value", b.optionalUndefined(cookie_map_iterator_item), .{ .required = true }),
        b.dictionaryField("done", b.boolean, .{ .required = true }),
    },
    .{ .cpp_name = "CookieMapIteratorResultDictionary" },
);
const cookie_map_iterator_class = b.classWithDataProperties(
    "CookieMapIterator",
    b.constructor(.{}, .{ .exposure = .never }),
    .{b.method("next", .{}, cookie_map_iterator_result, .{ .length = 0, .configurable = true })},
    .{},
    .{b.dataProperty("toStringTag", .{ .string = "CookieMap Iterator" }, .{ .symbol = .to_string_tag, .enumerable = false })},
    .{
        .backend = .zig,
        .profile = .webidl,
        .display_name = "CookieMap Iterator",
        .ownership = .unique,
        .identity = .fresh,
        .prototype_base = .iterator,
    },
);
const cookie_map_iterator_value = b.classRefByName("WebCoreCookies", "CookieMapIterator");
const cookie_map_for_each_callback = b.callback("CookieMapForEachCallback", .{
    b.argument("value", b.usv_string, .{}),
    b.argument("key", b.usv_string, .{}),
    b.argument("cookieMap", b.classRefByName("WebCoreCookies", "CookieMap"), .{}),
}, b.none, .{
    .receiver = b.optionalUndefined(b.invocation_any),
});
const cookie_map_class = b.class(
    "CookieMap",
    b.constructor(.{
        b.argument("init", cookie_map_init, .{ .presence = .optional, .missing = .undefined_or_null }),
    }, .{
        .length = 1,
        .errors = b.domainErrors(.{b.domainError("invalid_pair", b.none, .{
            .class = .type_error,
            .message = .{ .literal = "Expected arrays of exactly two strings" },
        })}),
    }),
    .{
        b.method("get", .{
            b.argument("name", b.usv_string, .{ .presence = .optional, .missing = .omitted }),
        }, b.optional(b.usv_string), .{ .length = 1, .configurable = true }),
        b.method("toSetCookieHeaders", .{}, b.sequence(b.byte_string), .{ .length = 0, .configurable = true }),
        b.method("has", .{
            b.argument("name", b.usv_string, .{ .presence = .optional, .missing = .omitted }),
        }, b.boolean, .{ .length = 1, .configurable = true }),
        b.method("set", b.overloads(.{
            b.overloadCase("cookie", .{b.argument("cookie", cookie_ref, .{})}),
            b.overloadCase("init", .{b.argument("init", cookie_init, .{})}),
            b.overloadCase("pair", .{
                b.argument("name", b.usv_string, .{}),
                b.argument("value", b.usv_string, .{}),
                b.argument("options", cookie_options, .{ .presence = .optional, .missing = .undefined_or_null }),
            }),
        }, .{ .ordered = true, .accept_extra_arguments = true }), b.none, .{ .length = 2, .configurable = true }),
        b.method("delete", b.overloads(.{
            b.overloadCase("init", .{b.argument("init", cookie_delete_init, .{})}),
            b.overloadCase("name", .{
                b.argument("name", b.optionalMatch(b.usv_string), .{
                    .presence = .default_value,
                    .missing = .omitted,
                    .default_value = .null,
                }),
                b.argument("options", cookie_delete_options, .{ .presence = .optional, .missing = .undefined_or_null }),
            }),
        }, .{ .ordered = true, .accept_extra_arguments = true, .fallback_case = "name" }), b.none, .{
            .length = 1,
            .configurable = true,
            .errors = b.domainErrors(.{b.domainError("name_required", b.none, .{
                .class = .type_error,
                .message = .{ .literal = "Cookie name is required" },
            })}),
        }),
        b.method("entries", .{}, cookie_map_iterator_value, .{
            .backend = .zig,
            .length = 0,
            .configurable = true,
            .aliases = &.{b.memberSymbolAlias(.iterator, .{ .enumerable = false })},
        }),
        b.method("keys", .{}, cookie_map_iterator_value, .{ .backend = .zig, .length = 0, .configurable = true }),
        b.method("values", .{}, cookie_map_iterator_value, .{ .backend = .zig, .length = 0, .configurable = true }),
        b.method("forEach", .{
            b.argument("callback", cookie_map_for_each_callback, .{}),
            b.argument("thisArg", b.any, .{ .presence = .optional, .missing = .omitted }),
        }, b.none, .{ .backend = .zig, .length = 1, .configurable = true, .this_value_type = b.this_class_ref }),
        b.method("toJSON", .{}, cookie_map_record, .{
            .length = 0,
            .configurable = true,
        }),
        b.method("inspectCustom", .{}, cookie_map_record, .{
            .length = 0,
            .symbol = .inspect_custom,
            .enumerable = false,
        }),
        b.getter("size", b.size, .{ .implementation = "getSize" }),
    },
    .{},
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("CookieMap", "ERR_ILLEGAL_CONSTRUCTOR"),
        .backend = .zig,
        .profile = .webidl,
        .ownership = .unique,
        .identity = .fresh,
        .memory_usage = .vm,
    },
);

pub const schema = b.moduleWithClasses("WebCoreCookies", .{}, .{ cookie_class, cookie_map_iterator_class, cookie_map_class });
pub const cookie = schema.class("Cookie");
pub const cookie_map_iterator = schema.class("CookieMapIterator");
pub const cookie_map = schema.class("CookieMap");
