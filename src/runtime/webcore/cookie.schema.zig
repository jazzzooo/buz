const b = @import("bindgen_schema");
const cookies = @import("binding_schema_WebCoreCookies");

pub const cookie = b.nominalHandle("CookieOwner", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::Cookie" } },
    .cpp_declarations = &.{.{ .class = "WebCore::Cookie" }},
    .ownership = .owned,
    .cpp_release = "releaseCookie",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

fn get(comptime name: []const u8, comptime value: b.Type, comptime options: b.EngineShimOptions) b.EngineShim {
    return b.engineShim(name, .{b.argument("cookie", cookie, .{})}, value, options);
}

fn set(comptime name: []const u8, comptime value: b.Type, comptime options: b.EngineShimOptions) b.EngineShim {
    return b.engineShim(name, .{
        b.argument("cookie", cookie, .{}),
        b.argument("value", value, .{}),
    }, b.none, options);
}

const engine_shims = .{
    b.engineShim("cookieCreate", .{
        b.argument("name", b.usv_string, .{}),
        b.argument("value", b.optional(b.usv_string), .{}),
        b.argument("domain", b.optional(b.usv_string), .{}),
        b.argument("path", b.optional(b.usv_string), .{}),
        b.argument("expires", b.optional(b.int64), .{}),
        b.argument("secure", b.boolean, .{}),
        b.argument("same_site", cookies.cookie_same_site, .{}),
        b.argument("http_only", b.boolean, .{}),
        b.argument("max_age", b.optional(b.double), .{}),
        b.argument("partitioned", b.boolean, .{}),
    }, cookie, .current_realm_throwing),
    b.engineShim("cookieParse", .{b.argument("input", b.usv_string, .{})}, cookie, .current_realm_throwing),
    get("cookieRetain", cookie, .vm_thread_nonthrowing),
    get("cookieMemoryCost", b.size, .vm_thread_nonthrowing),
    get("cookieName", b.usv_string, .vm_thread_nonthrowing),
    get("cookieValue", b.usv_string, .vm_thread_nonthrowing),
    set("cookieSetValue", b.usv_string, .vm_thread_nonthrowing),
    get("cookieDomain", b.optional(b.usv_string), .vm_thread_nonthrowing),
    set("cookieSetDomain", b.usv_string, .current_realm_throwing),
    get("cookiePath", b.usv_string, .vm_thread_nonthrowing),
    set("cookieSetPath", b.usv_string, .current_realm_throwing),
    get("cookieExpires", b.optionalUndefined(b.js_date), .current_realm_throwing),
    set("cookieSetExpires", b.optional(b.int64), .current_realm_throwing),
    get("cookieSecure", b.boolean, .vm_thread_nonthrowing),
    set("cookieSetSecure", b.boolean, .vm_thread_nonthrowing),
    get("cookieSameSite", cookies.cookie_same_site, .vm_thread_nonthrowing),
    set("cookieSetSameSite", cookies.cookie_same_site, .vm_thread_nonthrowing),
    get("cookieHttpOnly", b.boolean, .vm_thread_nonthrowing),
    set("cookieSetHttpOnly", b.boolean, .vm_thread_nonthrowing),
    get("cookieMaxAge", b.optionalUndefined(b.double), .vm_thread_nonthrowing),
    set("cookieSetMaxAge", b.optional(b.double), .vm_thread_nonthrowing),
    get("cookiePartitioned", b.boolean, .vm_thread_nonthrowing),
    set("cookieSetPartitioned", b.boolean, .vm_thread_nonthrowing),
    get("cookieIsExpired", b.boolean, .vm_thread_nonthrowing),
    get("cookieToString", b.byte_string, .current_realm_throwing),
    get("cookieJSON", cookies.cookie_json_result, .current_realm_throwing),
};

const native_exports = .{
    b.nativeExportWithOptions("cookieRetainFromWrapper", .{
        b.argument("value", b.classRefByName("WebCoreCookies", "Cookie"), .{}),
    }, cookie, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("cookie", .{}, .{}, engine_shims, native_exports);
