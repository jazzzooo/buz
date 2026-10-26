const b = @import("bindgen_schema");
const dev_server = @import("binding_schema_DevServer");
const request = @import("binding_schema_Request");

const functions = .{
    b.function("getAsyncLocalStorage", .{}, b.optionalUndefined(b.js_object), .{ .backend = .cpp, .profile = .exact }),
    b.function(
        "jsFunctionBakeEnsureAsyncLocalStorage",
        .{b.argument("storage", b.js_object, .{})},
        b.none,
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
    b.function(
        "jsFunctionBakeGetBundleNewRouteJSFunction",
        .{
            b.argument("request", request.bun_request_value, .{}),
            b.argument("url", b.dom_string, .{}),
        },
        dev_server.bundle_new_route_result,
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
};

pub const schema = b.module("BakeInternal", functions);
