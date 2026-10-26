const HTTPServerAgent = @This();

/// Underlying C++ agent. Set to null when not enabled.
agent: ?*InspectorHTTPServerAgent = null,

/// This becomes the "server ID" field.
next_server_id: ServerId = .init(0),

pub fn isEnabled(this: *const HTTPServerAgent) bool {
    return this.agent != null;
}

//#region Events
pub fn notifyServerStarted(this: *HTTPServerAgent, instance: jsc.API.AnyServer) bun.OOM!void {
    if (this.agent) |agent| {
        var address = try bun.bindgen.DOMString.fromBunString(try instance.getURLAsString());
        defer address.deinit();
        this.next_server_id = .init(this.next_server_id.get() + 1);
        instance.setInspectorServerID(this.next_server_id);
        bun.bindgen.Engine(InspectorHTTPServerAgentNotifyServerStartedShim).call(.{
            .agent = @ptrCast(agent),
            .serverId = this.next_server_id.get(),
            .address = address.operand(),
            .startTime = @floatFromInt(bun.timespec.now(.allow_mocked_time).ms()),
            .serverInstance = @ptrCast(instance.ptr.ptr()),
        });
    }
}

pub fn notifyServerStopped(this: *const HTTPServerAgent, server: jsc.API.AnyServer) void {
    if (this.agent) |agent| {
        agent.notifyServerStopped(server.inspectorServerID(), @floatFromInt(bun.timespec.now(.allow_mocked_time).ms()));
    }
}

pub fn notifyServerRoutesUpdated(this: *const HTTPServerAgent, server: jsc.API.AnyServer) bun.OOM!void {
    if (this.agent) |agent| {
        const config = server.config();
        var routes = std.array_list.Managed(OwnedRoute).init(bun.default_allocator);
        defer {
            for (routes.items) |*route| {
                route.path.deinit();
                route.filePath.deinit();
                route.scriptUrl.deinit();
            }
            routes.deinit();
        }

        var max_id: u32 = 0;

        switch (server.userRoutes()) {
            inline else => |user_routes| {
                for (user_routes) |*user_route| {
                    const decl: *const jsc.API.ServerConfig.RouteDeclaration = &user_route.route;
                    max_id = @max(max_id, user_route.id);
                    var path = try bun.bindgen.DOMString.fromUTF8(decl.path);
                    errdefer path.deinit();
                    try routes.append(.{
                        .routeId = @intCast(user_route.id),
                        .path = path,
                        .type = .api,
                        .scriptLine = -1,
                        .filePath = bun.bindgen.DOMString.empty(),
                        .scriptUrl = bun.bindgen.DOMString.empty(),
                    });
                }
            },
        }

        for (config.static_routes.items) |*route| {
            var path = try bun.bindgen.DOMString.fromUTF8(route.path);
            errdefer path.deinit();
            var file_path = switch (route.route) {
                .html => |html| try bun.bindgen.DOMString.fromUTF8(html.data.bundle.data.path.slice()),
                else => bun.bindgen.DOMString.empty(),
            };
            errdefer file_path.deinit();
            try routes.append(.{
                .routeId = @intCast(max_id + 1),
                .path = path,
                .type = switch (route.route) {
                    .html => .html,
                    .static => .static_route,
                    else => .other,
                },
                .scriptLine = -1,
                .filePath = file_path,
                .scriptUrl = bun.bindgen.DOMString.empty(),
            });
            max_id += 1;
        }

        const route_operands = try bun.default_allocator.alloc(Route, routes.items.len);
        defer bun.default_allocator.free(route_operands);
        for (routes.items, route_operands) |*route, *operand| operand.* = route.borrow();
        try bun.bindgen.Engine(InspectorHTTPServerAgentNotifyServerRoutesUpdatedShim).call(.{
            .agent = @ptrCast(agent),
            .serverId = server.inspectorServerID().get(),
            .hotReloadId = @intCast(jsc.VirtualMachine.get().hot_reload_counter),
            .routes = route_operands,
        });
    }
}

//#endregion

const Route = std.meta.Elem(@FieldType(bun.bindgen.Args(InspectorHTTPServerAgentNotifyServerRoutesUpdatedShim), "routes"));

const OwnedRoute = struct {
    routeId: @FieldType(Route, "routeId"),
    path: bun.bindgen.DOMString,
    type: @FieldType(Route, "type"),
    scriptLine: @FieldType(Route, "scriptLine"),
    filePath: bun.bindgen.DOMString,
    scriptUrl: bun.bindgen.DOMString,

    fn borrow(route: *const OwnedRoute) Route {
        return .{
            .routeId = route.routeId,
            .path = route.path.operand(),
            .type = route.type,
            .scriptLine = route.scriptLine,
            .filePath = route.filePath.operand(),
            .scriptUrl = route.scriptUrl.operand(),
        };
    }
};

//#region C++ agent reference type for Zig
pub const InspectorHTTPServerAgent = opaque {
    pub fn notifyServerStopped(agent: *InspectorHTTPServerAgent, serverId: ServerId, timestamp: f64) void {
        bun.bindgen.Engine(InspectorHTTPServerAgentNotifyServerStoppedShim).call(.{
            .agent = @ptrCast(agent),
            .serverId = serverId.get(),
            .timestamp = timestamp,
        });
    }
};

//#endregion

//#region Zig -> C++

fn bindSetAgent(
    args: bun.bindgen.Args(SetInspectorHTTPServerAgentSchema),
) bun.bindgen.Return(SetInspectorHTTPServerAgentSchema) {
    const agent: *InspectorHTTPServerAgent = @ptrCast(args.agent);
    if (jsc.VirtualMachine.get().debugger) |*debugger| {
        if (args.enabled) {
            debugger.http_server_agent.agent = agent;
        } else if (debugger.http_server_agent.agent == agent) {
            debugger.http_server_agent.agent = null;
        }
    }
}

//#endregion

// Typedefs from HTTPServer.json
pub const ServerId = jsc.Debugger.DebuggerId;
pub const RequestId = i32;
pub const RouteId = i32;
pub const HotReloadId = i32;
pub const HTTPMethod = bun.http.Method;

const std = @import("std");

const bun = @import("bun");
const jsc = bun.jsc;
const InspectorAgentBindings = bun.bindgen.Module("inspector_agents");
const InspectorHTTPServerAgentNotifyServerStartedShim = InspectorAgentBindings.engineShim("inspectorHTTPServerAgentNotifyServerStarted");
const InspectorHTTPServerAgentNotifyServerStoppedShim = InspectorAgentBindings.engineShim("inspectorHTTPServerAgentNotifyServerStopped");
const InspectorHTTPServerAgentNotifyServerRoutesUpdatedShim = InspectorAgentBindings.engineShim("inspectorHTTPServerAgentNotifyServerRoutesUpdated");
const SetInspectorHTTPServerAgentSchema = InspectorAgentBindings.nativeExport("setInspectorHTTPServerAgent");
const SetInspectorHTTPServerAgentBinding = bun.bindgen.Fn(SetInspectorHTTPServerAgentSchema, bindSetAgent);

comptime {
    _ = SetInspectorHTTPServerAgentBinding;
}
