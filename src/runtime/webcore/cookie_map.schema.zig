const b = @import("bindgen_schema");
const cookies = @import("binding_schema_WebCoreCookies");
const cookie_resource = @import("binding_schema_cookie");

pub const cookie_map = b.nominalHandle("CookieMap", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::CookieMap" } },
    .cpp_declarations = &.{.{ .class = "WebCore::CookieMap" }},
    .zig_type = "webcore.CookieMap",
    .access_thread = .vm,
});

const owned_cookie_map = b.nominalHandle("CookieMapOwner", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::CookieMap" } },
    .cpp_declarations = &.{.{ .class = "WebCore::CookieMap" }},
    .zig_type = "webcore.CookieMap",
    .ownership = .owned,
    .cpp_release = "releaseCookieMap",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const cookie_map_iterator = b.nominalHandle("CookieMapIterator", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::CookieMap::Iterator" } },
    .cpp_declarations = &.{.{ .include = .{ .path = "CookieMap.h", .system = false } }},
    .ownership = .owned,
    .cpp_release = "releaseCookieMapIterator",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const iterator_entry = b.dictionary("CookieMapIteratorEntry", .{
    b.dictionaryField("key", b.usv_string, .{ .required = true }),
    b.dictionaryField("value", b.usv_string, .{ .required = true }),
});

const engine_shims = .{
    b.engineShim("cookieMapCreate", .{}, owned_cookie_map, .current_realm_throwing),
    b.engineShim("cookieMapCreateString", .{b.argument("input", b.usv_string, .{})}, owned_cookie_map, .current_realm_throwing),
    b.engineShim("cookieMapCreatePairs", .{b.argument("input", cookies.cookie_map_pairs, .{})}, owned_cookie_map, .current_realm_throwing),
    b.engineShim("cookieMapCreateRecord", .{b.argument("input", cookies.cookie_map_record, .{})}, owned_cookie_map, .current_realm_throwing),
    b.engineShim("cookieMapClone", .{b.argument("cookieMap", cookie_map, .{})}, owned_cookie_map, .current_realm_throwing),
    b.engineShim("cookieMapGet", .{
        b.argument("cookieMap", cookie_map, .{}),
        b.argument("name", b.usv_string, .{}),
    }, b.optional(b.usv_string), .vm_thread_nonthrowing),
    b.engineShim("cookieMapSize", .{b.argument("cookieMap", cookie_map, .{})}, b.size, .vm_thread_nonthrowing),
    b.engineShim("cookieMapMemoryCost", .{b.argument("cookieMap", cookie_map, .{})}, b.size, .vm_thread_nonthrowing),
    b.engineShim("cookieMapSetCookie", .{
        b.argument("cookieMap", cookie_map, .{}),
        b.argument("cookie", cookie_resource.cookie, .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("cookieMapDelete", .{
        b.argument("cookieMap", cookie_map, .{}),
        b.argument("name", b.usv_string, .{}),
        b.argument("domain", b.optional(b.usv_string), .{}),
        b.argument("path", b.optional(b.usv_string), .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("cookieMapJSON", .{b.argument("cookieMap", cookie_map, .{})}, cookies.cookie_map_record, .vm_thread_allocating),
    b.engineShim("cookieMapIteratorCreate", .{b.argument("cookieMap", cookie_map, .{})}, cookie_map_iterator, .vm_thread_allocating),
    b.engineShim("cookieMapIteratorNext", .{b.argument("iterator", cookie_map_iterator, .{})}, b.optional(iterator_entry), .vm_thread_allocating),
    b.engineShim(
        "cookieMapPrepareHeaders",
        .{b.argument("cookieMap", cookie_map, .{})},
        b.sequence(b.byte_string),
        .current_realm_throwing,
    ),
    b.engineShim(
        "cookieMapRetain",
        .{b.argument("cookieMap", cookie_map, .{})},
        owned_cookie_map,
        .vm_thread_nonthrowing,
    ),
};

const native_exports = .{
    b.nativeExportWithOptions("cookieMapWrap", .{b.argument("cookieMap", cookie_map, .{})}, b.classRefByName("WebCoreCookies", "CookieMap"), .current_realm_throwing),
    b.nativeExportWithOptions("cookieMapCloneWrapper", .{b.argument("value", b.classRefByName("WebCoreCookies", "CookieMap"), .{})}, b.classRefByName("WebCoreCookies", "CookieMap"), .current_realm_throwing),
    b.nativeExportWithOptions("cookieMapRetainFromWrapper", .{b.argument("value", b.classRefByName("WebCoreCookies", "CookieMap"), .{})}, owned_cookie_map, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("cookie_map", .{}, .{}, engine_shims, native_exports);
