const b = @import("bindgen_schema");
const url = @import("binding_schema_WebCoreURL");

const pattern = b.nominalHandle("URLPatternOwner", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::URLPattern" } },
    .cpp_declarations = &.{.{ .class = "WebCore::URLPattern" }},
    .ownership = .owned,
    .cpp_release = "releaseURLPattern",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

fn get(comptime name: []const u8, comptime value: b.Type) b.EngineShim {
    return b.engineShim(name, .{b.argument("pattern", pattern, .{})}, value, .current_realm_throwing);
}

const match_arguments = .{
    b.argument("pattern", pattern, .{}),
    b.argument("input", b.optional(url.url_pattern_input), .{}),
    b.argument("baseURL", b.optional(b.usv_string), .{}),
};

const engine_shims = .{
    b.engineShim("urlPatternCreate", .{
        b.argument("input", b.optional(url.url_pattern_input), .{}),
        b.argument("ignoreCase", b.boolean, .{}),
    }, pattern, .current_realm_throwing),
    b.engineShim("urlPatternCreateWithBase", .{
        b.argument("input", url.url_pattern_input, .{}),
        b.argument("baseURL", b.usv_string, .{}),
        b.argument("ignoreCase", b.boolean, .{}),
    }, pattern, .current_realm_throwing),
    get("urlPatternProtocol", b.usv_string),
    get("urlPatternUsername", b.usv_string),
    get("urlPatternPassword", b.usv_string),
    get("urlPatternHostname", b.usv_string),
    get("urlPatternPort", b.usv_string),
    get("urlPatternPathname", b.usv_string),
    get("urlPatternSearch", b.usv_string),
    get("urlPatternHash", b.usv_string),
    get("urlPatternHasRegExpGroups", b.boolean),
    b.engineShim("urlPatternTest", match_arguments, b.boolean, .current_realm_throwing),
    b.engineShim("urlPatternExec", match_arguments, url.url_pattern_exec_result, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("url_pattern", .{}, .{}, engine_shims, .{});
