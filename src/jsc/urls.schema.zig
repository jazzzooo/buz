const b = @import("bindgen_schema");

const url = b.nominalHandle("URL", .{
    .cpp_type = .{ .pointer = &.{ .named = "WTF::URL" } },
    .cpp_declarations = &.{.{ .class = "WTF::URL" }},
    .ownership = .owned,
    .cpp_release = "releaseURL",
    .access_thread = .any,
    .destroy_thread = .any,
});

const dom_url = b.nominalHandle("DOMURL", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::DOMURL" } },
    .cpp_declarations = &.{.{ .class = "WebCore::DOMURL" }},
    .ownership = .owned,
    .cpp_release = "releaseDOMURL",
    .access_thread = .vm,
    .destroy_thread = .vm,
});
const dom_url_creation = b.unionType("DOMURLCreation", .{
    b.unionMember("url", dom_url),
    b.unionMember("invalid", b.dom_string),
}, .{});
pub const invalid_url_errors = b.domainErrors(.{b.domainError("invalid_url", b.dom_string, .{
    .class = .type_error,
    .code = "ERR_INVALID_URL",
    .message = .payload,
})});
const dom_url_component = b.enumerationWithOptions("DOMURLComponent", .{
    b.enumerationValue("href", "href"),
    b.enumerationValue("origin", "origin"),
    b.enumerationValue("protocol", "protocol"),
    b.enumerationValue("username", "username"),
    b.enumerationValue("password", "password"),
    b.enumerationValue("host", "host"),
    b.enumerationValue("hostname", "hostname"),
    b.enumerationValue("port", "port"),
    b.enumerationValue("pathname", "pathname"),
    b.enumerationValue("search", "search"),
    b.enumerationValue("hash", "hash"),
}, .{ .cpp_name = "DOMURLComponent" });
const dom_url_mutable_component = b.enumerationWithOptions("DOMURLMutableComponent", .{
    b.enumerationValue("protocol", "protocol"),
    b.enumerationValue("username", "username"),
    b.enumerationValue("password", "password"),
    b.enumerationValue("host", "host"),
    b.enumerationValue("hostname", "hostname"),
    b.enumerationValue("port", "port"),
    b.enumerationValue("pathname", "pathname"),
    b.enumerationValue("search", "search"),
    b.enumerationValue("hash", "hash"),
}, .{ .cpp_name = "DOMURLMutableComponent" });
const dom_url_input = .{
    b.argument("url", b.dom_string, .{}),
    b.argument("base", b.optional(b.dom_string), .{}),
};

pub const url_search_params = b.nominalHandle("URLSearchParams", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::URLSearchParams" } },
    .cpp_declarations = &.{.{ .class = "WebCore::URLSearchParams" }},
    .zig_type = "jsc.URLSearchParams",
    .access_thread = .vm,
});

pub const owned_url_search_params = b.nominalHandle("OwnedURLSearchParams", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::URLSearchParams" } },
    .cpp_declarations = &.{.{ .class = "WebCore::URLSearchParams" }},
    .zig_type = "jsc.URLSearchParams",
    .ownership = .owned,
    .cpp_release = "releaseURLSearchParams",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const url_search_params_iterator = b.nominalHandle("URLSearchParamsIterator", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::URLSearchParams::Iterator" } },
    .cpp_declarations = &.{.{ .include = .{ .path = "URLSearchParams.h", .system = false } }},
    .ownership = .owned,
    .cpp_release = "releaseURLSearchParamsIterator",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const iterator_entry = b.dictionary("URLSearchParamsIteratorEntry", .{
    b.dictionaryField("key", b.usv_string, .{ .required = true }),
    b.dictionaryField("value", b.usv_string, .{ .required = true }),
});

const engine_shims = .{
    b.engineShim("domURLCreate", dom_url_input, dom_url_creation, .vm_thread_allocating),
    b.engineShim("domURLCreateFromFileSystemPath", .{b.argument("path", b.dom_string, .{})}, dom_url_creation, .vm_thread_allocating),
    b.engineShim("domURLParse", dom_url_input, b.optional(dom_url), .vm_thread_allocating),
    b.engineShim("domURLCanParse", dom_url_input, b.boolean, .vm_thread_allocating),
    b.engineShim("domURLRetain", .{b.argument("url", dom_url, .{})}, dom_url, .vm_thread_nonthrowing),
    b.engineShim("domURLMemoryCost", .{b.argument("url", dom_url, .{})}, b.size, .vm_thread_nonthrowing),
    b.engineShim("domURLGet", .{
        b.argument("url", dom_url, .{}),
        b.argument("component", dom_url_component, .{}),
    }, b.usv_string, .vm_thread_allocating),
    b.engineShim("domURLSet", .{
        b.argument("url", dom_url, .{}),
        b.argument("component", dom_url_mutable_component, .{}),
        b.argument("value", b.usv_string, .{}),
    }, b.none, .vm_thread_allocating),
    b.engineShim("domURLSetHref", .{
        b.argument("url", dom_url, .{}),
        b.argument("value", b.usv_string, .{}),
    }, b.optional(b.dom_string), .vm_thread_allocating),
    b.engineShim("domURLSearchParams", .{b.argument("url", dom_url, .{})}, owned_url_search_params, .vm_thread_allocating),
    b.engineShim("urlSearchParamsRetain", .{b.argument("params", url_search_params, .{})}, owned_url_search_params, .vm_thread_nonthrowing),
    b.engineShim("urlSearchParamsMemoryCost", .{b.argument("params", url_search_params, .{})}, b.size, .vm_thread_nonthrowing),
    b.engineShim("bunStringToJSDOMURL", .{b.argument("value", b.dom_string, .{})}, b.classRefByName("WebCoreURL", "URL"), .current_realm_throwing),
    b.engineShim("urlFromString", .{b.argument("input", b.thread_safe_dom_string, .{})}, b.optional(url), .realm_independent_allocating),
    b.engineShim("urlHrefFromString", .{b.argument("input", b.thread_safe_dom_string, .{})}, b.optional(b.thread_safe_dom_string), .realm_independent_allocating),
    b.engineShim("urlFileURLFromString", .{b.argument("input", b.thread_safe_dom_string, .{})}, b.thread_safe_dom_string, .realm_independent_allocating),
    b.engineShim(
        "urlJoin",
        .{
            b.argument("base", b.thread_safe_dom_string, .{}),
            b.argument("relative", b.thread_safe_dom_string, .{}),
        },
        b.optional(b.thread_safe_dom_string),
        .realm_independent_allocating,
    ),
    b.engineShim("urlPathFromFileURL", .{b.argument("input", b.thread_safe_dom_string, .{})}, b.optional(b.thread_safe_dom_string), .realm_independent_allocating),
    b.engineShim("urlHash", .{b.argument("url", url, .{})}, b.thread_safe_dom_string, .realm_independent_allocating),
    b.engineShim("urlFragmentIdentifier", .{b.argument("url", url, .{})}, b.thread_safe_dom_string, .realm_independent_allocating),
    b.engineShim("urlProtocol", .{b.argument("url", url, .{})}, b.thread_safe_dom_string, .realm_independent_allocating),
    b.engineShim("urlHref", .{b.argument("url", url, .{})}, b.thread_safe_dom_string, .realm_independent_allocating),
    b.engineShim("urlUsername", .{b.argument("url", url, .{})}, b.thread_safe_dom_string, .realm_independent_allocating),
    b.engineShim("urlPassword", .{b.argument("url", url, .{})}, b.thread_safe_dom_string, .realm_independent_allocating),
    b.engineShim("urlSearch", .{b.argument("url", url, .{})}, b.thread_safe_dom_string, .realm_independent_allocating),
    b.engineShim("urlHost", .{b.argument("url", url, .{})}, b.thread_safe_dom_string, .realm_independent_allocating),
    b.engineShim("urlHostname", .{b.argument("url", url, .{})}, b.thread_safe_dom_string, .realm_independent_allocating),
    b.engineShim("urlPort", .{b.argument("url", url, .{})}, b.optional(b.uint16), .realm_independent),
    b.engineShim("urlPathname", .{b.argument("url", url, .{})}, b.thread_safe_dom_string, .realm_independent_allocating),
    b.engineShim("urlOriginFromString", .{b.argument("input", b.thread_safe_dom_string, .{})}, b.optional(b.thread_safe_dom_string), .realm_independent_allocating),
    b.engineShim("urlSearchParamsToString", .{b.argument("params", url_search_params, .{})}, b.thread_safe_dom_string, .vm_thread_allocating),
    b.engineShim("urlSearchParamsIteratorCreate", .{b.argument("params", url_search_params, .{})}, url_search_params_iterator, .vm_thread_allocating),
    b.engineShim("urlSearchParamsIteratorNext", .{b.argument("iterator", url_search_params_iterator, .{})}, b.optional(iterator_entry), .vm_thread_allocating),
};

pub const schema = b.moduleWithDeclarations("urls", .{}, .{}, engine_shims, .{
    b.nativeExportWithOptions("domURLFromString", .{
        b.argument("url", b.dom_string, .{}),
    }, b.classRefByName("WebCoreURL", "URL"), .{
        .throws = .js_exception,
        .realm = .current,
        .errors = invalid_url_errors,
    }),
    b.nativeExportWithOptions("domURLFromFileSystemPath", .{
        b.argument("path", b.dom_string, .{}),
    }, b.classRefByName("WebCoreURL", "URL"), .{
        .throws = .js_exception,
        .realm = .current,
        .errors = invalid_url_errors,
    }),
    b.nativeExportWithOptions("domURLRetainFromWrapper", .{
        b.argument("value", b.classRefByName("WebCoreURL", "URL"), .{}),
    }, dom_url, .current_realm_throwing),
    b.nativeExportWithOptions("urlSearchParamsRetainFromWrapper", .{
        b.argument("value", b.classRefByName("WebCoreURL", "URLSearchParams"), .{}),
    }, owned_url_search_params, .current_realm_throwing),
});
