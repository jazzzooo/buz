const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const headers_init = b.headersInit(.share);
pub const cloned_headers_init = b.headersInit(.clone);

pub const http_method_or_ignored = archetypes.http_method_or_ignored;

pub const response_init_fields = b.dictionaryWithOptions("ResponseInitFields", .{
    b.dictionaryField("headers", cloned_headers_init, .{}),
    b.dictionaryField("status", b.int64, .{ .integer_conversion = .coerce }),
    b.dictionaryField("statusText", archetypes.coerced_dom_string_or_nullish, .{ .js_name = "statusText" }),
    b.dictionaryField("method", http_method_or_ignored, .{}),
}, .{ .user_facing_name = "ResponseInit" });

pub const boolean_or_count = archetypes.boolean_or_int32_or_ignored;

const fetch_protocol = b.enumerationWithOptions("FetchProtocol", .{
    b.enumerationValueWithOptions("http1", "http1.1", .{ .aliases = &.{"h1"} }),
    b.enumerationValueWithOptions("http2", "http2", .{ .aliases = &.{"h2"} }),
    b.enumerationValueWithOptions("http3", "http3", .{ .aliases = &.{"h3"} }),
}, .{ .invalid_value_failure = .{
    .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
    .message = "fetch: 'protocol' must be \"http2\", \"h2\", \"http3\", \"h3\", \"http1.1\", or \"h1\"",
} });

const fetch_protocol_input = b.unionType("FetchProtocolInput", .{
    b.unionMember("name", fetch_protocol),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const fetch_verbose_input = b.unionType("FetchVerboseInput", .{
    b.unionMember("flag", b.boolean),
    b.unionMember("name", b.dom_string),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const string_or_ignored = b.unionType("StringOrIgnored", .{
    b.unionMember("text", b.dom_string),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const fetch_proxy_url = b.unionType("FetchProxyURL", .{
    b.unionMember("text", b.dom_string),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const fetch_proxy_config = b.dictionaryWithOptions("FetchProxyConfig", .{
    b.dictionaryField("url", b.optionalNullish(fetch_proxy_url), .{}),
    b.dictionaryField("headers", cloned_headers_init, .{}),
}, .{ .user_facing_name = "proxy" });

const fetch_proxy_input = b.unionType("FetchProxyInput", .{
    b.unionMember("text", b.dom_string),
    b.unionMember("config", fetch_proxy_config),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub const abort_signal_or_ignored = b.unionType("AbortSignalOrIgnored", .{
    b.unionMember("signal", b.abort_signal),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const fetch_redirect_errors = b.EnumerationErrors{
    .invalid_type = .{
        .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
        .message = "redirect must be a string",
    },
    .invalid_value = .{
        .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
        .message = "redirect must be one of 'follow', 'manual' or 'error'",
    },
};

const fetch_redirect_option = b.enumerationWithOptions("FetchRedirectOption", fetch_redirect.enumeration.values, .{
    .strict_errors = fetch_redirect_errors,
});

const fetch_redirect_input = archetypes.enumerationOrNullIgnoredWithOptions("FetchRedirectInput", fetch_redirect_option, .{
    .no_match_error = fetch_redirect_errors.invalid_type,
});

fn fetchField(comptime name: []const u8, comptime value_type: b.Type, comptime js_name: ?[]const u8, comptime preserve_null: bool) b.DictionaryField {
    return b.dictionaryField(name, b.lazy(if (preserve_null) b.optionalUndefined(value_type) else b.optionalNullish(value_type)), .{
        .required = true,
        .missing_required = .convert_undefined,
        .js_name = js_name,
        .deferred_reason = "fetch selects init values before reading fallback input properties",
    });
}

pub const fetch_input_url = b.dictionary("FetchInputURL", .{
    b.dictionaryField("url", archetypes.coerced_dom_string_or_nullish, .{ .required = true, .missing_required = .convert_undefined }),
});

pub const fetch_request_properties = b.dictionary("FetchRequestProperties", .{
    b.dictionaryField("url", archetypes.coerced_dom_string, .{ .required = true, .missing_required = .convert_undefined }),
    fetchField("method", http_method_or_ignored, null, false),
    fetchField("headers", cloned_headers_init, null, true),
});

pub fn fetchInitFields(comptime tls_input: b.Type, comptime body_input: b.Type, comptime s3_input: b.Type) b.Type {
    return b.dictionaryWithOptions("FetchRequestInit", .{
        fetchField("method", http_method_or_ignored, null, false),
        fetchField("decompress", boolean_or_count, null, false),
        fetchField("tls", tls_input, null, false),
        fetchField("unix_path", string_or_ignored, "unix", false),
        fetchField("protocol", fetch_protocol_input, null, false),
        fetchField("timeout", boolean_or_count, null, false),
        fetchField("redirect", fetch_redirect_input, null, false),
        fetchField("keepalive", boolean_or_count, null, false),
        fetchField("verbose", fetch_verbose_input, null, false),
        fetchField("proxy", fetch_proxy_input, null, false),
        fetchField("signal", abort_signal_or_ignored, null, false),
        fetchField("body_presence", b.discardAny(.presence), "body", true),
        b.dictionaryField("body", b.lazy(b.optionalUndefined(body_input)), .{
            .required = true,
            .missing_required = .convert_undefined,
            .source_field = "body_presence",
            .deferred_reason = "body conversion and buffer preparation follow all selected option getters",
        }),
        fetchField("headers", cloned_headers_init, null, true),
        fetchField("s3", s3_input, null, false),
    }, .{ .user_facing_name = "fetch options" });
}

pub fn responseInitInput(comptime request_ref: b.Type, comptime response_ref: b.Type) b.Type {
    return b.unionType("ResponseInitInput", .{
        b.unionMember("request", request_ref),
        b.unionMember("response", response_ref),
        b.unionMember("fields", response_init_fields),
    }, .{ .ordered = true });
}

fn responseInitWithStatus(
    comptime name: []const u8,
    comptime request_ref: b.Type,
    comptime response_ref: b.Type,
    comptime status_member: b.UnionMember,
    comptime allow_ignored: bool,
) b.Type {
    return b.unionType(name, .{
        status_member,
        b.unionMember("request", request_ref),
        b.unionMember("response", response_ref),
        b.unionMember("fields", response_init_fields),
    } ++ if (allow_ignored) .{b.unionMember("ignored", b.discardAny(.ignored))} else .{}, .{
        .ordered = true,
        .fallback_member = if (allow_ignored) "ignored" else null,
    });
}

pub fn responseJSONInitInput(comptime request_ref: b.Type, comptime response_ref: b.Type) b.Type {
    return responseInitWithStatus(
        "ResponseJSONInitInput",
        request_ref,
        response_ref,
        b.unionMemberWithOptions("status", b.uint16, .{ .integer_conversion = .coerce_saturate }),
        false,
    );
}

pub fn responseRedirectInitInput(comptime request_ref: b.Type, comptime response_ref: b.Type) b.Type {
    return responseInitWithStatus(
        "ResponseRedirectInitInput",
        request_ref,
        response_ref,
        b.unionMemberWithOptions("status", b.int32, .{ .integer_conversion = .webidl }),
        true,
    );
}

const fetch_headers_or_ignored = b.optionalMatch(b.fetch_headers);

pub fn optionalFetchHeadersOrIgnored(comptime name: []const u8) b.Argument {
    return b.argument(name, fetch_headers_or_ignored, .{ .presence = .optional, .missing = .omitted });
}

pub const http_status_code = b.uint16;
pub const http_method = archetypes.http_method;

pub const fetch_cache_mode = b.enumeration("FetchCacheMode", .{
    b.enumerationValueWithOptions("default_mode", "default", .{ .native_value = 0 }),
    b.enumerationValueWithOptions("no_store", "no-store", .{ .native_value = 1 }),
    b.enumerationValueWithOptions("reload", "reload", .{ .native_value = 2 }),
    b.enumerationValueWithOptions("no_cache", "no-cache", .{ .native_value = 3 }),
    b.enumerationValueWithOptions("force_cache", "force-cache", .{ .native_value = 4 }),
    b.enumerationValueWithOptions("only_if_cached", "only-if-cached", .{ .native_value = 5 }),
});

pub const fetch_request_mode = b.enumeration("FetchRequestMode", .{
    b.enumerationValueWithOptions("same_origin", "same-origin", .{ .native_value = 0 }),
    b.enumerationValueWithOptions("no_cors", "no-cors", .{ .native_value = 1 }),
    b.enumerationValueWithOptions("cors", "cors", .{ .native_value = 2 }),
    b.enumerationValueWithOptions("navigate", "navigate", .{ .native_value = 3 }),
});

pub const fetch_redirect = b.enumeration("FetchRedirect", .{
    b.enumerationValueWithOptions("follow", "follow", .{ .native_value = 0 }),
    b.enumerationValueWithOptions("manual", "manual", .{ .native_value = 1 }),
    b.enumerationValueWithOptions("error", "error", .{ .native_value = 2 }),
});

pub const request_credentials = b.enumeration("RequestCredentials", .{
    b.enumerationValue("omit", "omit"),
    b.enumerationValue("same_origin", "same-origin"),
    b.enumerationValue("include", "include"),
});

pub const request_destination = b.enumeration("RequestDestination", .{
    b.enumerationValue("empty", ""),
    b.enumerationValue("audio", "audio"),
    b.enumerationValue("audioworklet", "audioworklet"),
    b.enumerationValue("document", "document"),
    b.enumerationValue("embed", "embed"),
    b.enumerationValue("font", "font"),
    b.enumerationValue("frame", "frame"),
    b.enumerationValue("iframe", "iframe"),
    b.enumerationValue("image", "image"),
    b.enumerationValue("json", "json"),
    b.enumerationValue("manifest", "manifest"),
    b.enumerationValue("object", "object"),
    b.enumerationValue("paintworklet", "paintworklet"),
    b.enumerationValue("report", "report"),
    b.enumerationValue("script", "script"),
    b.enumerationValue("sharedworker", "sharedworker"),
    b.enumerationValue("style", "style"),
    b.enumerationValue("text", "text"),
    b.enumerationValue("track", "track"),
    b.enumerationValue("video", "video"),
    b.enumerationValue("worker", "worker"),
    b.enumerationValue("xslt", "xslt"),
});

pub const referrer_policy = b.enumeration("ReferrerPolicy", .{
    b.enumerationValue("empty", ""),
    b.enumerationValue("no_referrer", "no-referrer"),
    b.enumerationValue("no_referrer_when_downgrade", "no-referrer-when-downgrade"),
    b.enumerationValue("origin", "origin"),
    b.enumerationValue("origin_when_cross_origin", "origin-when-cross-origin"),
    b.enumerationValue("same_origin", "same-origin"),
    b.enumerationValue("strict_origin", "strict-origin"),
    b.enumerationValue("strict_origin_when_cross_origin", "strict-origin-when-cross-origin"),
    b.enumerationValue("unsafe_url", "unsafe-url"),
});

pub const schema = b.module("FetchTypes", .{});
