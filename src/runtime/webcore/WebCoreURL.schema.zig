const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const native_urls = @import("binding_schema_urls");
const console_object = @import("binding_schema_ConsoleObject");

const missing_arguments_failure = b.ConversionFailure{
    .kind = .{ .code = "ERR_MISSING_ARGS" },
    .message = "Not enough arguments",
};

fn URLMembers(comptime class_name: []const u8, comptime accessor_message: ?[]const u8) type {
    return struct {
        fn method(comptime name: []const u8, comptime args: anytype, comptime result: b.Type, comptime options: b.ClassMemberOptions) b.ClassMember {
            var declared = options;
            declared.invalid_this = .{ .failure = .{
                .kind = .{ .code = "ERR_INVALID_THIS" },
                .message = "Can only call " ++ class_name ++ "." ++ name ++ " on instances of " ++ class_name,
            } };
            if (declared.missing_required_arguments == .profile_default) {
                declared.missing_required_arguments = .{ .failure = missing_arguments_failure };
            }
            return b.method(name, args, result, declared);
        }

        fn accessorOptions(comptime name: []const u8, comptime kind: []const u8, comptime options: b.ClassMemberOptions) b.ClassMemberOptions {
            var declared = options;
            declared.invalid_this = .{ .failure = .{
                .kind = .type_error,
                .message = accessor_message orelse "The " ++ class_name ++ "." ++ name ++ " " ++ kind ++ " can only be used on instances of " ++ class_name,
            } };
            return declared;
        }

        fn getter(comptime name: []const u8, comptime result: b.Type, comptime options: b.ClassMemberOptions) b.ClassMember {
            return b.getter(name, result, accessorOptions(name, "getter", options));
        }

        fn setter(comptime name: []const u8, comptime value: b.Type, comptime options: b.ClassMemberOptions) b.ClassMember {
            return b.setter(name, value, accessorOptions(name, "setter", options));
        }
    };
}

const url_members = URLMembers("URL", null);
const params_members = URLMembers("URLSearchParams", "Type error");

const required_url_errors = b.domainErrors(.{b.domainError("missing_url", b.none, .{
    .class = .type_error,
    .code = "ERR_MISSING_ARGS",
    .message = .{ .literal = "Not enough arguments" },
})});

const object_url_blob = b.unionType("ObjectURLBlob", .{
    b.unionMember("blob", b.blob),
    b.unionMember("artifact", b.classRefByName("BuildArtifact", "BuildArtifact")),
}, .{ .no_match_error = .{
    .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
    .message = "createObjectURL expects a Blob object",
} });

const url_search_params_init = b.unionType("URLSearchParamsInit", .{
    b.unionMember("sequence", b.sequenceWithOptions(archetypes.usv_string_pair_iterable, .{ .container = .iterable })),
    b.unionMember("record", b.record(b.usv_string, b.usv_string)),
    b.unionMember("string", b.usv_string),
}, .{ .ordered = true, .fallback_member = "string" });
const url_search_params_iterator_item = b.unionType("URLSearchParamsIteratorItem", .{
    b.unionMember("entry", b.sequence(b.usv_string)),
    b.unionMember("string", b.usv_string),
}, .{ .cpp_name = "URLSearchParamsIteratorItem" });
const url_search_params_iterator_result = b.dictionaryWithOptions(
    "URLSearchParamsIteratorResult",
    .{
        b.dictionaryField("value", b.optionalUndefined(url_search_params_iterator_item), .{ .required = true }),
        b.dictionaryField("done", b.boolean, .{ .required = true }),
    },
    .{ .cpp_name = "URLSearchParamsIteratorResultDictionary" },
);
const url_search_params_iterator_class = b.classWithDataProperties(
    "URLSearchParamsIterator",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("next", .{}, url_search_params_iterator_result, .{
            .length = 0,
            .configurable = true,
            .invalid_this = .{ .failure = .{
                .kind = .{ .code = "ERR_INVALID_THIS" },
                .message = "Cannot call next() on a non-Iterator object",
            } },
        }),
    },
    .{},
    .{b.dataProperty("toStringTag", .{ .string = "URLSearchParams Iterator" }, .{ .symbol = .to_string_tag, .enumerable = false })},
    .{
        .backend = .zig,
        .profile = .webidl,
        .display_name = "URLSearchParams Iterator",
        .ownership = .unique,
        .identity = .fresh,
        .prototype_base = .iterator,
    },
);
const url_search_params_iterator_value = b.classRefByName("WebCoreURL", "URLSearchParamsIterator");
const url_search_params_json_value = b.unionType("URLSearchParamsJSONValue", .{
    b.unionMember("value", b.usv_string),
    b.unionMember("values", b.sequence(b.usv_string)),
}, .{ .cpp_name = "URLSearchParamsJSONValue" });
const url_search_params_json_result = b.recordWithOptions(
    b.usv_string,
    url_search_params_json_value,
    .{ .result_to_string_tag = "URLSearchParams" },
);
const url_search_params_for_each_callback = b.callback("URLSearchParamsForEachCallback", .{
    b.argument("value", b.usv_string, .{}),
    b.argument("key", b.usv_string, .{}),
    b.argument("searchParams", b.classRefByName("WebCoreURL", "URLSearchParams"), .{}),
}, b.none, .{
    .receiver = b.optionalUndefined(b.invocation_any),
});

const url_search_params_callback_input = b.unionType("URLSearchParamsCallbackInput", .{
    b.unionMember("callback", url_search_params_for_each_callback),
    b.unionMember("invalid", b.discardAny(.classification)),
}, .{ .ordered = true, .fallback_member = "invalid" });

const url_search_params_class = b.class(
    "URLSearchParams",
    b.constructor(.{
        b.argument("init", url_search_params_init, .{ .presence = .optional, .missing = .undefined }),
    }, .{
        .length = 0,
        .errors = b.domainErrors(.{b.domainError("invalid_pair", b.none, .{
            .class = .type_error,
            .message = .{ .literal = "Each URLSearchParams entry must contain exactly two values" },
        })}),
    }),
    .{
        params_members.method("append", .{
            b.argument("name", b.usv_string, .{}),
            b.argument("value", b.usv_string, .{}),
        }, b.none, .{ .length = 2, .configurable = true }),
        params_members.method("delete", .{
            b.argument("name", b.usv_string, .{}),
            b.argument("value", b.usv_string, .{ .presence = .optional, .missing = .undefined }),
        }, b.none, .{ .length = 1, .configurable = true }),
        params_members.method("get", .{b.argument("name", b.usv_string, .{})}, b.optionalNullish(b.usv_string), .{
            .length = 1,
            .configurable = true,
        }),
        params_members.method("getAll", .{b.argument("name", b.usv_string, .{})}, b.sequence(b.usv_string), .{
            .length = 1,
            .configurable = true,
        }),
        params_members.method("has", .{
            b.argument("name", b.usv_string, .{}),
            b.argument("value", b.usv_string, .{ .presence = .optional, .missing = .undefined }),
        }, b.boolean, .{ .length = 1, .configurable = true }),
        params_members.method("set", .{
            b.argument("name", b.usv_string, .{}),
            b.argument("value", b.usv_string, .{}),
        }, b.none, .{ .length = 2, .configurable = true }),
        params_members.method("sort", .{}, b.none, .{ .length = 0, .configurable = true }),
        params_members.method("entries", .{}, url_search_params_iterator_value, .{
            .backend = .zig,
            .length = 0,
            .configurable = true,
            .aliases = &.{b.memberSymbolAlias(.iterator, .{ .enumerable = false })},
        }),
        params_members.method("keys", .{}, url_search_params_iterator_value, .{ .backend = .zig, .length = 0, .configurable = true }),
        params_members.method("values", .{}, url_search_params_iterator_value, .{ .backend = .zig, .length = 0, .configurable = true }),
        params_members.method("forEach", .{
            b.argument("callback", url_search_params_callback_input, .{}),
            b.argument("thisArg", b.any, .{ .presence = .optional, .missing = .undefined }),
        }, b.none, .{
            .backend = .zig,
            .length = 1,
            .configurable = true,
            .this_value_type = b.this_class_ref,
            .missing_required_arguments = .convert_undefined,
            .errors = b.domainErrors(.{b.domainError("invalid_callback", b.none, .{
                .class = .type_error,
                .code = "ERR_INVALID_ARG_TYPE",
                .message = .{ .literal = "Cannot call callback on a non-function" },
            })}),
        }),
        params_members.method("toString", .{}, b.dom_string, .{ .length = 0, .configurable = true }),
        params_members.method("toJSON", .{}, url_search_params_json_result, .{ .length = 0, .configurable = true }),
        console_object.native_inspect,
        params_members.getter("length", b.size, .{ .implementation = "getLength", .enumerable = false }),
        params_members.getter("size", b.size, .{ .implementation = "getSize", .configurable = true }),
    },
    .{},
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("URLSearchParams", "ERR_ILLEGAL_CONSTRUCTOR"),
        .backend = .zig,
        .profile = .webidl,
        .ownership = .unique,
        .identity = .fresh,
        .memory_usage = .vm,
    },
);

const invalid_url = native_urls.invalid_url_errors;
const dom_url_value = b.optional(b.classRefByName("WebCoreURL", "URL"));
const dom_url_search_params_value = b.classRefByName("WebCoreURL", "URLSearchParams");
const dom_url = b.class(
    "URL",
    b.constructor(.{
        b.argument("url", b.usv_string, .{}),
        b.argument("base", b.usv_string, .{ .presence = .optional, .missing = .undefined }),
    }, .{
        .length = 1,
        .errors = invalid_url,
        .missing_required_arguments = .{ .failure = missing_arguments_failure },
    }),
    .{
        url_members.getter("href", b.usv_string, .{ .implementation = "getHref", .configurable = true }),
        url_members.setter("href", b.usv_string, .{ .implementation = "setHref", .configurable = true, .errors = invalid_url }),
        url_members.getter("origin", b.usv_string, .{ .implementation = "getOrigin", .configurable = true }),
        url_members.getter("protocol", b.usv_string, .{ .implementation = "getProtocol", .configurable = true }),
        url_members.setter("protocol", b.usv_string, .{ .implementation = "setProtocol", .configurable = true }),
        url_members.getter("username", b.usv_string, .{ .implementation = "getUsername", .configurable = true }),
        url_members.setter("username", b.usv_string, .{ .implementation = "setUsername", .configurable = true }),
        url_members.getter("password", b.usv_string, .{ .implementation = "getPassword", .configurable = true }),
        url_members.setter("password", b.usv_string, .{ .implementation = "setPassword", .configurable = true }),
        url_members.getter("host", b.usv_string, .{ .implementation = "getHost", .configurable = true }),
        url_members.setter("host", b.usv_string, .{ .implementation = "setHost", .configurable = true }),
        url_members.getter("hostname", b.usv_string, .{ .implementation = "getHostname", .configurable = true }),
        url_members.setter("hostname", b.usv_string, .{ .implementation = "setHostname", .configurable = true }),
        url_members.getter("port", b.usv_string, .{ .implementation = "getPort", .configurable = true }),
        url_members.setter("port", b.usv_string, .{ .implementation = "setPort", .configurable = true }),
        url_members.getter("pathname", b.usv_string, .{ .implementation = "getPathname", .configurable = true }),
        url_members.setter("pathname", b.usv_string, .{ .implementation = "setPathname", .configurable = true }),
        url_members.getter("hash", b.usv_string, .{ .implementation = "getHash", .configurable = true }),
        url_members.setter("hash", b.usv_string, .{ .implementation = "setHash", .configurable = true }),
        url_members.getter("search", b.usv_string, .{ .implementation = "getSearch", .configurable = true }),
        url_members.setter("search", b.usv_string, .{ .implementation = "setSearch", .configurable = true }),
        url_members.getter("searchParams", dom_url_search_params_value, .{ .implementation = "getSearchParams", .cache = "searchParams", .configurable = true }),
        url_members.method("toJSON", .{}, b.usv_string, .{ .length = 0, .configurable = true }),
        url_members.method("toString", .{}, b.usv_string, .{ .length = 0, .configurable = true }),
        b.staticMethod("parse", .{
            b.argument("url", b.usv_string, .{ .presence = .optional, .missing = .omitted }),
            b.argument("base", b.usv_string, .{ .presence = .optional, .missing = .undefined }),
        }, dom_url_value, .{ .length = 1, .configurable = true, .errors = required_url_errors }),
        b.staticMethod("canParse", .{
            b.argument("url", b.usv_string, .{ .presence = .optional, .missing = .omitted }),
            b.argument("base", b.usv_string, .{ .presence = .optional, .missing = .undefined }),
        }, b.boolean, .{ .length = 1, .configurable = true, .errors = required_url_errors }),
        b.staticMethod("createObjectURL", .{
            b.argument("blob", object_url_blob, .{}),
        }, b.dom_string, .{
            .backend = .zig,
            .profile = .exact,
            .length = 1,
            .missing_required_arguments = .{ .failure = .{
                .kind = .{ .code = "ERR_MISSING_ARGS" },
                .message = "Not enough arguments to 'createObjectURL'. Expected 1, got 0.",
            } },
            .configurable = true,
        }),
        b.staticMethod("revokeObjectURL", .{
            b.argument("url", b.strictString(b.dom_string, .{
                .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
                .message = "revokeObjectURL expects a string",
            }), .{}),
        }, b.none, .{
            .backend = .zig,
            .profile = .exact,
            .length = 1,
            .missing_required_arguments = .{ .failure = .{
                .kind = .{ .code = "ERR_MISSING_ARGS" },
                .message = "Not enough arguments to 'revokeObjectURL'. Expected 1, got 0.",
            } },
            .configurable = true,
        }),
    },
    .{b.cachedSlot("searchParams", dom_url_search_params_value, .{ .exposed = false })},
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("URL", "ERR_ILLEGAL_CONSTRUCTOR"),
        .backend = .zig,
        .profile = .webidl,
        .ownership = .unique,
        .identity = .fresh,
        .memory_usage = .vm,
    },
);

const url_pattern_init = b.dictionaryWithOptions(
    "URLPatternInit",
    .{
        b.dictionaryField("protocol", b.usv_string, .{}),
        b.dictionaryField("username", b.usv_string, .{}),
        b.dictionaryField("password", b.usv_string, .{}),
        b.dictionaryField("hostname", b.usv_string, .{}),
        b.dictionaryField("port", b.usv_string, .{}),
        b.dictionaryField("pathname", b.usv_string, .{}),
        b.dictionaryField("search", b.usv_string, .{}),
        b.dictionaryField("hash", b.usv_string, .{}),
        b.dictionaryField("baseURL", b.usv_string, .{}),
    },
    .{ .cpp_name = "URLPatternInitDictionary" },
);
const url_pattern_options = b.dictionaryWithOptions(
    "URLPatternOptions",
    .{b.dictionaryField("ignoreCase", b.boolean, .{})},
    .{ .cpp_name = "URLPatternOptionsDictionary" },
);
pub const url_pattern_input = b.unionType("URLPatternInput", .{
    b.unionMember("string", b.usv_string),
    b.unionMember("init", url_pattern_init),
}, .{ .cpp_name = "URLPatternInputValue" });
const url_pattern_component_result = b.dictionaryWithOptions(
    "URLPatternComponentResult",
    .{
        b.dictionaryField("input", b.usv_string, .{ .required = true }),
        b.dictionaryField("groups", b.record(b.usv_string, b.optionalUndefined(b.usv_string)), .{ .required = true }),
    },
    .{ .cpp_name = "URLPatternComponentResultDictionary" },
);
const url_pattern_result = b.dictionaryWithOptions(
    "URLPatternResult",
    .{
        b.dictionaryField("inputs", b.sequence(url_pattern_input), .{ .required = true }),
        b.dictionaryField("protocol", url_pattern_component_result, .{ .required = true }),
        b.dictionaryField("username", url_pattern_component_result, .{ .required = true }),
        b.dictionaryField("password", url_pattern_component_result, .{ .required = true }),
        b.dictionaryField("hostname", url_pattern_component_result, .{ .required = true }),
        b.dictionaryField("port", url_pattern_component_result, .{ .required = true }),
        b.dictionaryField("pathname", url_pattern_component_result, .{ .required = true }),
        b.dictionaryField("search", url_pattern_component_result, .{ .required = true }),
        b.dictionaryField("hash", url_pattern_component_result, .{ .required = true }),
    },
    .{ .cpp_name = "URLPatternResultDictionary" },
);
pub const url_pattern_exec_result = b.optional(url_pattern_result);
const url_pattern_class = b.class(
    "URLPattern",
    b.constructor(b.overloads(.{
        b.overloadCase("base_url", .{
            b.argument("input", url_pattern_input, .{}),
            b.argument("baseURL", b.usv_string, .{}),
            b.argument("options", url_pattern_options, .{ .presence = .optional, .missing = .undefined_or_null }),
        }),
        b.overloadCase("options", .{
            b.argument("input", url_pattern_input, .{ .presence = .optional, .missing = .undefined }),
            b.argument("options", url_pattern_options, .{ .presence = .optional, .missing = .undefined_or_null }),
        }),
    }, .{ .ordered = true, .accept_extra_arguments = true }), .{ .length = 0 }),
    .{
        b.getter("protocol", b.usv_string, .{ .implementation = "getProtocol", .configurable = true }),
        b.getter("username", b.usv_string, .{ .implementation = "getUsername", .configurable = true }),
        b.getter("password", b.usv_string, .{ .implementation = "getPassword", .configurable = true }),
        b.getter("hostname", b.usv_string, .{ .implementation = "getHostname", .configurable = true }),
        b.getter("port", b.usv_string, .{ .implementation = "getPort", .configurable = true }),
        b.getter("pathname", b.usv_string, .{ .implementation = "getPathname", .configurable = true }),
        b.getter("search", b.usv_string, .{ .implementation = "getSearch", .configurable = true }),
        b.getter("hash", b.usv_string, .{ .implementation = "getHash", .configurable = true }),
        b.getter("hasRegExpGroups", b.boolean, .{ .implementation = "getHasRegExpGroups", .configurable = true }),
        b.method("test", .{
            b.argument("input", url_pattern_input, .{ .presence = .optional, .missing = .undefined }),
            b.argument("baseURL", b.usv_string, .{ .presence = .optional, .missing = .undefined }),
        }, b.boolean, .{ .length = 0, .configurable = true }),
        b.method("exec", .{
            b.argument("input", url_pattern_input, .{ .presence = .optional, .missing = .undefined }),
            b.argument("baseURL", b.usv_string, .{ .presence = .optional, .missing = .undefined }),
        }, url_pattern_exec_result, .{ .length = 0, .configurable = true }),
    },
    .{},
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("URLPattern", "ERR_ILLEGAL_CONSTRUCTOR"),
        .backend = .zig,
        .profile = .webidl,
        .ownership = .unique,
        .identity = .fresh,
    },
);

const params_argument = b.argument("params", native_urls.url_search_params, .{});
const params_shims = .{
    b.engineShim("urlSearchParamsCreate", .{b.argument("init", b.optional(url_search_params_init), .{})}, native_urls.owned_url_search_params, .vm_thread_allocating),
    b.engineShim("urlSearchParamsAppend", .{ params_argument, b.argument("name", b.usv_string, .{}), b.argument("value", b.usv_string, .{}) }, b.none, .vm_thread_allocating),
    b.engineShim("urlSearchParamsDelete", .{ params_argument, b.argument("name", b.usv_string, .{}), b.argument("value", b.optional(b.usv_string), .{}) }, b.none, .vm_thread_allocating),
    b.engineShim("urlSearchParamsGet", .{ params_argument, b.argument("name", b.usv_string, .{}) }, b.optionalNullish(b.usv_string), .vm_thread_nonthrowing),
    b.engineShim("urlSearchParamsGetAll", .{ params_argument, b.argument("name", b.usv_string, .{}) }, b.sequence(b.usv_string), .vm_thread_allocating),
    b.engineShim("urlSearchParamsHas", .{ params_argument, b.argument("name", b.usv_string, .{}), b.argument("value", b.optional(b.usv_string), .{}) }, b.boolean, .vm_thread_nonthrowing),
    b.engineShim("urlSearchParamsSet", .{ params_argument, b.argument("name", b.usv_string, .{}), b.argument("value", b.usv_string, .{}) }, b.none, .vm_thread_allocating),
    b.engineShim("urlSearchParamsSort", .{params_argument}, b.none, .vm_thread_allocating),
    b.engineShim("urlSearchParamsJSON", .{params_argument}, url_search_params_json_result, .vm_thread_allocating),
    b.engineShim("urlSearchParamsSize", .{params_argument}, b.size, .vm_thread_nonthrowing),
};

pub const schema = b.moduleWithClassesAndEngineShims("WebCoreURL", .{}, .{
    url_search_params_iterator_class,
    url_search_params_class,
    dom_url,
    url_pattern_class,
}, params_shims);
pub const url_search_params_iterator = schema.class("URLSearchParamsIterator");
pub const url_search_params = schema.class("URLSearchParams");
pub const url = schema.class("URL");
pub const url_pattern = schema.class("URLPattern");
