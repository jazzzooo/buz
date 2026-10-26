const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const http_server = @import("binding_schema_HTTPServer");

const request_kind = b.enumeration("ServerRouteRequestKind", .{
    b.enumerationValue("http", "http"),
    b.enumerationValue("h3", "h3"),
});

const request_native_handle = b.nominalHandle("ServerRouteRequestNative", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::ServerRouteRequestNative" } },
    .cpp_declarations = &.{.{ .structure = "Bun::ServerRouteRequestNative" }},
    .access_thread = .vm,
});

const uws_request_handle = b.nominalHandle("ServerRouteUWSRequest", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::ServerRouteUWSRequest" } },
    .cpp_declarations = &.{.{ .structure = "Bun::ServerRouteUWSRequest" }},
    .access_thread = .vm,
});

const stored_route_list = b.brandCast(http_server.server_route_list_value, .{ .name = "routeList", .failure = .assert, .input = .engine_value });

const prepared_route = b.dictionary("PreparedServerRoute", .{
    b.dictionaryField("callback", http_server.serve_fetch_callback, .{ .required = true }),
    b.dictionaryField("request", b.classRefByName("Request", "Request"), .{ .required = true }),
});

const engine_shims = .{
    b.engineShim(
        "prepareRoute",
        .{
            b.argument("index", b.uint32, .{}),
            b.argument("requestNative", request_native_handle, .{}),
            b.argument("routeList", stored_route_list, .{}),
            b.argument("kind", request_kind, .{}),
            b.argument("request", uws_request_handle, .{}),
        },
        prepared_route,
        .current_realm_throwing,
    ),
    b.engineShim(
        "create",
        .{
            b.argument("callbacks", b.sequence(http_server.serve_fetch_callback), .{}),
            b.argument("paths", archetypes.dom_strings, .{}),
        },
        http_server.server_route_list_value,
        .current_realm_throwing,
    ),
};

pub const schema = b.moduleWithDeclarations("ServerRouteList", .{}, .{}, engine_shims, .{});
