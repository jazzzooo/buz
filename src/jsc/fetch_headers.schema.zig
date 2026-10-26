const b = @import("bindgen_schema");
const http_types = @import("binding_schema_http_types");
const node_http_response = @import("binding_schema_NodeHTTPResponse");
const webcore_headers = @import("binding_schema_WebCoreHeaders");

const headers_value = b.classRefByName("WebCoreHeaders", "Headers");

const fetch_headers = http_types.fetch_headers;
const owned_fetch_headers = http_types.owned_fetch_headers;

const fetch_headers_iterator = b.nominalHandle("FetchHeadersIterator", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::FetchHeaders::Iterator" } },
    .cpp_declarations = &.{.{ .include = .{ .path = "FetchHeaders.h", .system = false } }},
    .ownership = .owned,
    .cpp_release = "fetchHeadersIteratorRelease",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const h3_http_request = b.nominalHandle("H3HTTPRequest", .{
    .cpp_type = .{ .pointer = &.{ .named = "uWS::Http3Request" } },
    .cpp_declarations = &.{.{ .structure = "uWS::Http3Request" }},
    .access_thread = .vm,
});

const header_entry = b.dictionary("FetchHeaderEntry", .{
    b.dictionaryField("name", b.buffer(.copy), .{ .required = true }),
    b.dictionaryField("value", b.buffer(.copy), .{ .required = true }),
});

const iterator_entry = b.dictionary("FetchHeadersIteratorEntry", .{
    b.dictionaryField("key", b.byte_string, .{ .required = true }),
    b.dictionaryField("value", b.byte_string, .{ .required = true }),
});

const engine_shims = .{
    b.engineShim("fetchHeadersAppend", .{
        b.argument("headers", fetch_headers, .{}),
        b.argument("name", b.byte_string, .{}),
        b.argument("value", b.byte_string, .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("fetchHeadersRemove", .{
        b.argument("headers", fetch_headers, .{}),
        b.argument("name", b.byte_string, .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("fetchHeadersGetByName", .{
        b.argument("headers", fetch_headers, .{}),
        b.argument("name", b.byte_string, .{}),
    }, b.optionalNullish(b.byte_string), .current_realm_throwing),
    b.engineShim("fetchHeadersHas", .{
        b.argument("headers", fetch_headers, .{}),
        b.argument("name", b.byte_string, .{}),
    }, b.boolean, .current_realm_throwing),
    b.engineShim("fetchHeadersSet", .{
        b.argument("headers", fetch_headers, .{}),
        b.argument("name", b.byte_string, .{}),
        b.argument("value", b.byte_string, .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("fetchHeadersGetSetCookie", .{b.argument("headers", fetch_headers, .{})}, b.sequence(b.byte_string), .vm_thread_allocating),
    b.engineShim("fetchHeadersJSON", .{b.argument("headers", fetch_headers, .{})}, webcore_headers.headers_json_result, .vm_thread_allocating),
    b.engineShim("fetchHeadersCount", .{b.argument("headers", fetch_headers, .{})}, b.uint32, .vm_thread_allocating),
    b.engineShim("fetchHeadersRetain", .{b.argument("headers", fetch_headers, .{})}, owned_fetch_headers, .vm_thread_nonthrowing),
    b.engineShim("fetchHeadersMemoryCost", .{b.argument("headers", fetch_headers, .{})}, b.size, .vm_thread_nonthrowing),
    b.engineShim("fetchHeadersRawKeys", .{b.argument("headers", fetch_headers, .{})}, b.sequence(b.byte_string), .vm_thread_allocating),
    b.engineShim("fetchHeadersCreateEmpty", .{}, owned_fetch_headers, .vm_thread_allocating),
    b.engineShim("fetchHeadersCreateFromEntries", .{b.argument("entries", b.sequence(header_entry), .{})}, owned_fetch_headers, .current_realm_throwing),
    b.engineShim("fetchHeadersCreateFromPicoHeaders", .{b.argument("headers", b.sequence(header_entry), .{})}, owned_fetch_headers, .vm_thread_allocating),
    b.engineShim("fetchHeadersCreateFromUWS", .{b.argument("request", node_http_response.request_handle, .{})}, owned_fetch_headers, .vm_thread_allocating),
    b.engineShim("fetchHeadersCreateFromH3", .{b.argument("request", h3_http_request, .{})}, owned_fetch_headers, .vm_thread_allocating),
    b.engineShim("fetchHeadersIteratorCreate", .{b.argument("headers", fetch_headers, .{})}, fetch_headers_iterator, .vm_thread_allocating),
    b.engineShim("fetchHeadersIteratorNext", .{b.argument("iterator", fetch_headers_iterator, .{})}, b.optional(iterator_entry), .vm_thread_allocating),
    b.engineShim(
        "fetchHeadersFastHas",
        .{
            b.argument("headers", fetch_headers, .{}),
            b.argument("name", http_types.http_header_name, .{}),
        },
        b.boolean,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "fetchHeadersFastGet",
        .{
            b.argument("headers", fetch_headers, .{}),
            b.argument("name", http_types.http_header_name, .{}),
        },
        b.optional(b.byte_string),
        .vm_thread_allocating,
    ),
    b.engineShim(
        "fetchHeadersFastRemove",
        .{
            b.argument("headers", fetch_headers, .{}),
            b.argument("name", http_types.http_header_name, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim("fetchHeadersIsEmpty", .{b.argument("headers", fetch_headers, .{})}, b.boolean, .vm_thread_nonthrowing),
    b.engineShim(
        "fetchHeadersGet",
        .{
            b.argument("headers", fetch_headers, .{}),
            b.argument("name", b.buffer(.copy), .{}),
        },
        b.optional(b.byte_string),
        .current_realm_throwing,
    ),
    b.engineShim(
        "fetchHeadersPut",
        .{
            b.argument("headers", fetch_headers, .{}),
            b.argument("name", http_types.http_header_name, .{}),
            b.argument("value", b.buffer(.copy), .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim("fetchHeadersSnapshotForHTTP", .{b.argument("headers", fetch_headers, .{})}, b.sequence(iterator_entry), .vm_thread_allocating),
    b.engineShim("fetchHeadersCloneNative", .{b.argument("headers", fetch_headers, .{})}, owned_fetch_headers, .vm_thread_allocating),
};

const native_exports = .{
    b.nativeExportWithOptions("fetchHeadersRetainFromWrapper", .{b.argument("value", headers_value, .{})}, owned_fetch_headers, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("fetch_headers", .{}, .{}, engine_shims, native_exports);
