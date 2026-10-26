const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const query_value = b.unionType("MatchedRouteQueryValue", .{
    b.unionMember("text", b.dom_string),
    b.unionMember("values", archetypes.dom_strings),
}, .{});

const query_record = b.record(b.dom_string, query_value);

const matched_route_class = b.class(
    "MatchedRoute",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.getter("filePath", b.dom_string, .{ .implementation = "getFilePath", .cache = "filePath" }),
        b.getter("kind", b.dom_string, .{ .implementation = "getKind", .cache = "kind" }),
        b.getter("name", b.dom_string, .{ .implementation = "getName", .cache = "name" }),
        b.getter("params", query_record, .{ .implementation = "getParams", .cache = "params" }),
        b.getter("pathname", b.dom_string, .{ .implementation = "getPathname", .cache = "pathname" }),
        b.getter("query", query_record, .{ .implementation = "getQuery", .cache = "query" }),
        b.getter("scriptSrc", b.dom_string, .{
            .implementation = "getScriptSrc",
            .cache = "scriptSrc",
        }),
        b.getter("src", b.dom_string, .{
            .implementation = "getSrc",
            .cache = "scriptSrc",
        }),
    },
    .{
        b.cachedSlot("filePath", b.dom_string, .{}),
        b.cachedSlot("kind", b.dom_string, .{}),
        b.cachedSlot("name", b.dom_string, .{}),
        b.cachedSlot("params", query_record, .{}),
        b.cachedSlot("pathname", b.dom_string, .{}),
        b.cachedSlot("query", query_record, .{}),
        b.cachedSlot("scriptSrc", b.dom_string, .{}),
    },
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .last_release = b.sweep("Matched routes own byte buffers and shared immutable byte metadata; teardown only releases an atomic reference and frees native allocations"),
        .identity = .fresh,
    },
);

pub const schema = b.moduleWithClasses("MatchedRoute", .{}, .{matched_route_class});
pub const matched_route = schema.class("MatchedRoute");
