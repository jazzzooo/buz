const b = @import("bindgen_schema");

fn invalidArgument(comptime message: []const u8) b.ConversionFailure {
    return .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = message };
}

const string_input = b.unionType("SecretsStringInput", .{
    b.unionMember("string", b.thread_safe_dom_string),
    b.unionMember("other", b.discardAny(.classification)),
}, .{ .ordered = true, .fallback_member = "other" });

const key_string = b.strictString(b.thread_safe_dom_string, invalidArgument("Expected service and name to be strings"));
const key_fields = .{
    b.dictionaryField("service", b.lazy(key_string), .{
        .required = true,
        .missing_required = .convert_undefined,
        .lazy_property_read = .eager,
        .deferred_reason = "Both key properties are read before either string is validated",
    }),
    b.dictionaryField("name", b.lazy(key_string), .{
        .required = true,
        .missing_required = .convert_undefined,
        .lazy_property_read = .eager,
        .deferred_reason = "Both key properties are read before either string is validated",
    }),
};
const dictionary_options = b.DictionaryOptions{
    .object_error = invalidArgument("Expected options to be an object"),
};
const key_options = b.dictionaryWithOptions("SecretsKeyOptions", key_fields, dictionary_options);
const set_options = b.dictionaryWithOptions("SecretsSetOptions", key_fields ++ .{
    b.dictionaryField("value", b.lazy(b.optionalNullish(b.strictString(b.thread_safe_dom_string, invalidArgument("Expected 'value' to be a string")))), .{
        .required = true,
        .missing_required = .convert_undefined,
        .deferred_reason = "The value is read and validated after both key strings are validated",
    }),
    b.dictionaryField("allow_unrestricted_access", b.lazy(b.boolean), .{
        .required = true,
        .missing_required = .convert_undefined,
        .boolean_conversion = .truthy,
        .js_name = "allowUnrestrictedAccess",
        .deferred_reason = "The access flag is read after value validation and before empty-key validation",
    }),
}, dictionary_options);

const errors = b.domainErrors(.{
    b.domainError("invalid_options", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected options to be an object" },
    }),
    b.domainError("invalid_key", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected service and name to not be empty" },
    }),
    b.domainError("missing_value", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected 'value' to be a string. To delete the secret, call secrets.delete instead." },
    }),
    b.domainError("not_available", b.none, .{
        .class = .generic_error,
        .code = "ERR_SECRETS_NOT_AVAILABLE",
        .message = .{ .literal = "Secrets background work is unavailable" },
    }),
    b.domainError("not_found", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .code = "ERR_SECRETS_NOT_FOUND",
        .message = .payload,
    }),
    b.domainError("access_denied", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .code = "ERR_SECRETS_ACCESS_DENIED",
        .message = .payload,
    }),
    b.domainError("user_canceled", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .code = "ERR_SECRETS_USER_CANCELED",
        .message = .payload,
    }),
    b.domainError("interaction_not_allowed", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .code = "ERR_SECRETS_INTERACTION_NOT_ALLOWED",
        .message = .payload,
    }),
    b.domainError("authentication_failed", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .code = "ERR_SECRETS_AUTH_FAILED",
        .message = .payload,
    }),
    b.domainError("interaction_required", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .code = "ERR_SECRETS_INTERACTION_REQUIRED",
        .message = .payload,
    }),
    b.domainError("platform_error", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .code = "ERR_SECRETS_PLATFORM_ERROR",
        .message = .payload,
    }),
});

const positional_arguments = .{
    b.argument("input", string_input, .{}),
    b.argument("name", string_input, .{ .presence = .optional, .missing = .omitted }),
};

fn optionsArgument(comptime options: b.Type) b.Argument {
    return b.argument("options", b.lazy(options), .{
        .source = .{ .argument = "input" },
        .presence = .optional,
        .missing = .omitted,
        .deferred_reason = "Options are read only when the positional strings do not select the shorthand form",
    });
}

const key_arguments = positional_arguments ++ .{optionsArgument(key_options)};
const set_arguments = positional_arguments ++ .{
    b.argument("value", string_input, .{ .presence = .optional, .missing = .omitted }),
    optionsArgument(set_options),
};

const completion = b.CompletionOptions{
    .retention = .pending_activity,
    .sender_drop = .cancel,
};

pub const schema = b.module("Secrets", .{
    b.function("get", key_arguments, b.optional(b.thread_safe_dom_string), .{
        .backend = .zig,
        .completion = completion,
        .errors = errors,
        .length = 1,
        .profile = .exact,
        .missing_required_arguments = .{ .failure = invalidArgument("secrets.get requires an options object") },
    }),
    b.function(
        "set",
        set_arguments,
        b.none,
        .{
            .backend = .zig,
            .completion = completion,
            .errors = errors,
            .length = 2,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function("delete", key_arguments, b.boolean, .{
        .backend = .zig,
        .completion = completion,
        .errors = errors,
        .length = 1,
        .profile = .exact,
        .missing_required_arguments = .{ .failure = invalidArgument("secrets.delete requires an options object") },
    }),
});
