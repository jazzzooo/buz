const ServerConfig = @This();

pub fn PendingCallback(comptime callback_name: []const u8) type {
    const CallbackType = bun.bindgen.CallbackSchema(callback_name);
    return struct {
        configured: bool = false,
        pending: ?bun.bindgen.Callback(CallbackType) = null,

        pub fn setView(this: *@This(), callback: bun.bindgen.CallbackView(CallbackType)) bun.JSError!void {
            const retained = try callback.toOwned();
            if (this.pending) |*previous| previous.deinit();
            this.pending = retained;
            this.configured = true;
        }

        pub fn takePending(this: *@This()) ?bun.bindgen.Callback(CallbackType) {
            const callback = if (this.pending) |*value| value.take() else return null;
            this.pending = null;
            return callback;
        }

        pub fn moveFrom(this: *@This(), source: *@This()) void {
            this.deinit();
            this.configured = source.configured;
            this.pending = if (source.pending) |*callback| callback.take() else null;
            source.pending = null;
            source.configured = false;
        }

        pub fn deinit(this: *@This()) void {
            if (this.pending) |*callback| callback.deinit();
            this.pending = null;
        }
    };
}

address: union(enum) {
    tcp: struct {
        port: u16 = 0,
        hostname: ?[*:0]const u8 = null,
    },
    unix: [:0]const u8,

    pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
        switch (this.*) {
            .tcp => |tcp| {
                if (tcp.hostname) |host| {
                    allocator.free(std.mem.sliceTo(host, 0));
                }
            },
            .unix => |addr| {
                allocator.free(addr);
            },
        }
        this.* = .{ .tcp = .{} };
    }
} = .{
    .tcp = .{},
},
idleTimeout: u8 = 10, //TODO: should we match websocket default idleTimeout of 120?
has_idleTimeout: bool = false,
// TODO: use webkit URL parser instead of bun's
base_url: URL = URL{},
base_uri: string = "",

ssl_config: ?SSLConfig = null,
sni: ?bun.BabyList(SSLConfig) = null,
max_request_body_size: usize = 1024 * 1024 * 128,
development: DevelopmentOption = .development,
broadcast_console_log_from_browser_to_server_for_bake: bool = false,

/// Enable automatic workspace folders for Chrome DevTools
/// https://chromium.googlesource.com/devtools/devtools-frontend/+/main/docs/ecosystem/automatic_workspace_folders.md
/// https://github.com/ChromeDevTools/vite-plugin-devtools-json/blob/76080b04422b36230d4b7a674b90d6df296cbff5/src/index.ts#L60-L77
///
/// If HMR is not enabled, then this field is ignored.
enable_chrome_devtools_automatic_workspace_folders: bool = true,

onError: PendingCallback("ServeErrorCallback") = .{},
onRequest: PendingCallback("ServeFetchCallback") = .{},
onNodeHTTPRequest: PendingCallback("NodeHTTPServerRequestCallback") = .{},

websocket: ?WebSocketServerContext = null,

reuse_port: bool = false,
id: []const u8 = "",
allow_hot: bool = true,
ipv6_only: bool = false,
http3: bool = false,
http1: bool = true,

is_node_http: bool = false,
had_routes_object: bool = false,

static_routes: std.array_list.Managed(StaticRouteEntry) = std.array_list.Managed(StaticRouteEntry).init(bun.default_allocator),
negative_routes: std.array_list.Managed([:0]const u8) = std.array_list.Managed([:0]const u8).init(bun.default_allocator),
user_routes_to_build: std.array_list.Managed(UserRouteBuilder) = std.array_list.Managed(UserRouteBuilder).init(bun.default_allocator),

bake: ?bun.bake.UserOptions = null,

pub const DevelopmentOption = enum {
    development,
    production,
    development_without_hmr,

    pub fn isHMREnabled(this: DevelopmentOption) bool {
        return this == .development;
    }

    pub fn isDevelopment(this: DevelopmentOption) bool {
        return this == .development or this == .development_without_hmr;
    }
};

pub fn isDevelopment(this: *const ServerConfig) bool {
    return this.development.isDevelopment();
}

pub fn memoryCost(this: *const ServerConfig) usize {
    // ignore @sizeOf(ServerConfig), assume already included.
    var cost: usize = 0;
    for (this.static_routes.items) |*entry| {
        cost += entry.memoryCost();
    }
    cost += this.id.len;
    cost += this.base_uri.len;
    for (this.negative_routes.items) |route| {
        cost += route.len;
    }

    return cost;
}

pub fn take(this: *ServerConfig) ServerConfig {
    const config = this.*;
    this.* = .{};
    return config;
}

// We need to be able to apply the route to multiple Apps even when there is only one RouteList.
pub const RouteDeclaration = struct {
    path: [:0]const u8 = "",
    method: union(enum) {
        any: void,
        specific: HTTP.Method,
    } = .any,

    pub fn deinit(this: *RouteDeclaration) void {
        if (this.path.len > 0) {
            bun.default_allocator.free(this.path);
        }
    }
};

// TODO: rename to StaticRoute.Entry
pub const StaticRouteEntry = struct {
    path: []const u8,
    route: AnyRoute,
    method: HTTP.Method.Optional = .any,

    pub fn memoryCost(this: *const StaticRouteEntry) usize {
        return this.path.len + this.route.memoryCost();
    }

    /// Clone the path buffer and increment the ref count
    /// This doesn't actually clone the route, it just increments the ref count
    pub fn clone(this: StaticRouteEntry) !StaticRouteEntry {
        const path = try bun.default_allocator.dupe(u8, this.path);
        this.route.ref();

        return .{
            .path = path,
            .route = this.route,
            .method = this.method,
        };
    }

    pub fn deinit(this: *StaticRouteEntry) void {
        bun.default_allocator.free(this.path);
        this.path = "";
        this.route.deref();
        this.* = undefined;
    }

    pub fn isLessThan(_: void, this: StaticRouteEntry, other: StaticRouteEntry) bool {
        return strings.cmpStringsDesc({}, this.path, other.path);
    }
};

pub fn normalizeStaticRoutes(this: *ServerConfig) bun.OOM!void {
    const Key = struct {
        path: []const u8,
        method: HTTP.Method.Optional,
    };
    const Context = struct {
        pub fn hash(_: @This(), key: Key) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, key.method);
            hasher.update(key.path);
            return hasher.final();
        }

        pub fn eql(_: @This(), a: Key, b: Key) bool {
            if (!std.mem.eql(u8, a.path, b.path)) {
                return false;
            }
            return switch (a.method) {
                .any => b.method == .any,
                .method => |a_set| switch (b.method) {
                    .any => false,
                    .method => |b_set| a_set.eql(b_set),
                },
            };
        }
    };

    var seen: std.HashMapUnmanaged(Key, void, Context, std.hash_map.default_max_load_percentage) = .empty;
    defer seen.deinit(bun.default_allocator);
    try seen.ensureTotalCapacity(bun.default_allocator, @intCast(this.static_routes.items.len));

    // Iterate through the list of static routes backwards
    // Later ones added override earlier ones
    var list = &this.static_routes;
    if (list.items.len > 0) {
        var index = list.items.len - 1;
        while (true) {
            const route = &list.items[index];
            const result = seen.getOrPutAssumeCapacity(.{
                .path = route.path,
                .method = route.method,
            });
            if (result.found_existing) {
                var item = list.orderedRemove(index);
                item.deinit();
            }

            if (index == 0) break;
            index -= 1;
        }
    }

    // Sort static routes by name for determinism.
    std.mem.sort(StaticRouteEntry, list.items, {}, StaticRouteEntry.isLessThan);
}

pub fn appendStaticRoute(this: *ServerConfig, path: []const u8, route: AnyRoute, method: HTTP.Method.Optional) !void {
    errdefer route.deref();
    try this.static_routes.ensureUnusedCapacity(1);
    this.static_routes.appendAssumeCapacity(StaticRouteEntry{
        .path = try bun.default_allocator.dupe(u8, path),
        .route = route,
        .method = method,
    });
}

pub fn applyStaticRoute(server: AnyServer, comptime ssl: bool, app: anytype, comptime T: type, entry: T, path: []const u8, method: HTTP.Method.Optional) bun.OOM!void {
    entry.server = server;
    const handler_wrap = struct {
        pub fn handler(route: T, req: *uws.Request, resp: *uws.NewApp(ssl).Response) void {
            route.onRequest(.{ .h1 = req }, switch (comptime ssl) {
                true => .{ .SSL = resp },
                false => .{ .TCP = resp },
            });
        }

        pub fn HEAD(route: T, req: *uws.Request, resp: *uws.NewApp(ssl).Response) void {
            route.onHEADRequest(.{ .h1 = req }, switch (comptime ssl) {
                true => .{ .SSL = resp },
                false => .{ .TCP = resp },
            });
        }
    };
    try app.head(path, T, entry, handler_wrap.HEAD);
    switch (method) {
        .any => {
            try app.any(path, T, entry, handler_wrap.handler);
        },
        .method => |*m| {
            var iter = m.iterator();
            while (iter.next()) |method_| {
                try app.method(method_, path, T, entry, handler_wrap.handler);
            }
        },
    }
}

pub fn applyStaticRouteH3(server: AnyServer, app: anytype, comptime T: type, entry: T, path: []const u8, method: HTTP.Method.Optional) bun.OOM!void {
    entry.server = server;
    const handler_wrap = struct {
        pub fn handler(route: T, req: *uws.H3.Request, resp: *uws.H3.Response) void {
            route.onRequest(.{ .h3 = req }, .{ .H3 = resp });
        }
        pub fn HEAD(route: T, req: *uws.H3.Request, resp: *uws.H3.Response) void {
            route.onHEADRequest(.{ .h3 = req }, .{ .H3 = resp });
        }
    };
    try app.head(path, T, entry, handler_wrap.HEAD);
    switch (method) {
        .any => try app.any(path, T, entry, handler_wrap.handler),
        .method => |*m| {
            var iter = m.iterator();
            while (iter.next()) |method_| try app.method(method_, path, T, entry, handler_wrap.handler);
        },
    }
}

pub fn deinit(this: *ServerConfig) void {
    this.onError.deinit();
    this.onRequest.deinit();
    this.onNodeHTTPRequest.deinit();
    if (this.websocket) |*websocket| websocket.handler.deinitPendingCallbacks();

    this.address.deinit(bun.default_allocator);

    for (this.negative_routes.items) |route| {
        bun.default_allocator.free(route);
    }
    this.negative_routes.clearAndFree();

    bun.default_allocator.free(this.base_uri);
    this.base_uri = "";
    this.base_url = .{};
    bun.default_allocator.free(this.id);
    this.id = "";
    if (this.ssl_config) |*ssl_config| {
        ssl_config.deinit();
        this.ssl_config = null;
    }
    if (this.sni) |*sni| {
        for (sni.slice()) |*ssl_config| {
            ssl_config.deinit();
        }
        sni.deinit(bun.default_allocator);
        this.sni = null;
    }

    for (this.static_routes.items) |*entry| {
        entry.deinit();
    }
    this.static_routes.clearAndFree();

    if (this.bake) |*bake| {
        bake.deinit();
    }

    for (this.user_routes_to_build.items) |*builder| {
        builder.deinit();
    }
    this.user_routes_to_build.clearAndFree();
}

pub fn computeID(this: *const ServerConfig) bun.OOM![]const u8 {
    return switch (this.address) {
        .tcp => |tcp| std.fmt.allocPrint(bun.default_allocator, "[http]-tcp:{s}:{d}", .{
            if (tcp.hostname) |host| std.mem.span(host) else "localhost",
            tcp.port,
        }),
        .unix => |path| std.fmt.allocPrint(bun.default_allocator, "[http]-unix:{s}", .{path}),
    };
}

pub fn getUsocketsOptions(this: *const ServerConfig) i32 {
    // Unlike Node.js, we set exclusive port in case reuse port is not set
    var out: i32 = if (this.reuse_port)
        uws.LIBUS_LISTEN_REUSE_PORT | uws.LIBUS_LISTEN_REUSE_ADDR
    else
        uws.LIBUS_LISTEN_EXCLUSIVE_PORT;

    if (this.ipv6_only) {
        out |= uws.LIBUS_SOCKET_IPV6_ONLY;
    }

    return out;
}

/// Matches `JSValue.getStringish`: null and `false` mean absent, everything
/// else coerces to a string, and an empty result is also absent.
fn stringishOwnedZ(field: anytype) bun.OOM!?[:0]u8 {
    switch (field.*) {
        .nulled => return null,
        .flag => |flag| {
            if (!flag) return null;
            return try bun.default_allocator.dupeSentinel(u8, "true", 0);
        },
        .text => |*view| {
            if (view.length() == 0) return null;
            return try view.toOwnedSliceZ(bun.default_allocator);
        },
    }
}

fn validateRouteName(context: anytype, path: []const u8) bun.bindgen.CallError(@TypeOf(context))!void {
    // Already validated by the caller
    bun.debugAssert(path.len > 0 and path[0] == '/');

    // For now, we don't support params that start with a number.
    // Mostly because it makes the params object more complicated to implement and it's easier to cut scope this way for now.
    var remaining = path;
    var duped_route_names = bun.StringHashMap(void).init(bun.default_allocator);
    defer duped_route_names.deinit();
    while (strings.indexOfChar(remaining, ':')) |index| {
        remaining = remaining[index + 1 ..];
        const end = strings.indexOfChar(remaining, '/') orelse remaining.len;
        const route_name = remaining[0..end];
        if (route_name.len > 0 and std.ascii.isDigit(route_name[0])) {
            return context.fail(.route_parameter_starts_with_number, {});
        }

        const entry = try duped_route_names.getOrPut(route_name);
        if (entry.found_existing) {
            return context.fail(.route_parameter_duplicate, {});
        }

        remaining = remaining[end..];
    }
}

pub const SSLConfig = @import("../socket/SSLConfig.zig");
pub const SSLConfigEngine = @import("../socket/SSLConfigEngine.zig");

pub const FromJSOptions = struct {
    allow_bake_config: bool = true,
    has_user_routes: bool = false,
};

fn parseRoutes(
    global: *jsc.JSGlobalObject,
    context: anytype,
    args: *ServerConfig,
    routes: anytype,
) bun.bindgen.CallError(@TypeOf(context))!void {
    const record = switch (routes.*) {
        // https://github.com/oven-sh/bun/issues/17568
        .list => return,
        .invalid => return context.fail(.invalid_routes_object, {}),
        .routes => |*value| value,
    };
    const vm = global.bunVM();
    args.had_routes_object = true;

    var init_ctx_: AnyRoute.ServerInitContext = .{
        .arena = .init(bun.default_allocator),
        .dedupe_html_bundle_map = .init(bun.default_allocator),
        .framework_router_list = .init(bun.default_allocator),
        .framework_router_styles = .init(bun.default_allocator),
        .js_string_allocations = .empty,
        .user_routes = &args.static_routes,
        .global = global,
    };
    const init_ctx: *AnyRoute.ServerInitContext = &init_ctx_;
    var route_styles_transferred = false;
    defer {
        if (!route_styles_transferred) {
            for (init_ctx.framework_router_styles.items) |*style| style.deinit();
        }
        init_ctx.framework_router_styles.deinit();
        init_ctx.framework_router_list.deinit();
    }
    errdefer {
        init_ctx.arena.deinit();
    }
    defer {
        var routes_iterator = init_ctx.dedupe_html_bundle_map.valueIterator();
        while (routes_iterator.next()) |route| route.deref();
        init_ctx.dedupe_html_bundle_map.deinit();
    }

    errdefer {
        for (args.static_routes.items) |*static_route| {
            static_route.deinit();
        }
        args.static_routes.clearAndFree();
    }

    for (0..record.len()) |index| {
        const entry = record.at(index).?;
        if (entry.key.length() == 0) continue;
        const path_string = try entry.key.toUTF8(bun.default_allocator);
        defer path_string.deinit();
        const path = path_string.slice();

        if (path.len == 0 or (path[0] != '/')) {
            return failRoutePath(context, "Invalid route {f}. Path must start with '/'", path);
        }

        if (!strings.isAllASCII(path)) {
            return failRoutePath(context, "Invalid route {f}. Please encode all non-ASCII characters in the path.", path);
        }

        switch (entry.value) {
            .disabled => |flag| {
                if (flag) return context.fail(.invalid_route_value, {});
                try args.negative_routes.ensureUnusedCapacity(1);
                args.negative_routes.appendAssumeCapacity(try bun.default_allocator.dupeSentinel(u8, path, 0));
                continue;
            },
            .handler => |*handler| {
                try validateRouteName(context, path);
                try args.user_routes_to_build.ensureUnusedCapacity(1);
                var callback = try handler.toOwned();
                defer callback.deinit();
                args.user_routes_to_build.appendAssumeCapacity(.{
                    .route = .{
                        .path = try bun.default_allocator.dupeSentinel(u8, path, 0),
                        .method = .any,
                    },
                    .callback = callback.take(),
                });
                continue;
            },
            .object => |*object| {
                const methods = .{ "CONNECT", "DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT", "TRACE" };
                var found = false;
                inline for (methods) |method_name| {
                    const method = @field(HTTP.Method, method_name);
                    if (@field(object, method_name)) |*target_field| if (target_field.*) |*target| {
                        if (!found) {
                            try validateRouteName(context, path);
                        }
                        found = true;

                        switch (target.*) {
                            .handler => |*handler| {
                                try args.user_routes_to_build.ensureUnusedCapacity(1);
                                var callback = try handler.toOwned();
                                defer callback.deinit();
                                args.user_routes_to_build.appendAssumeCapacity(.{
                                    .route = .{
                                        .path = try bun.default_allocator.dupeSentinel(u8, path, 0),
                                        .method = .{ .specific = method },
                                    },
                                    .callback = callback.take(),
                                });
                            },
                            else => if (try routeFromTarget(context, path, target, init_ctx)) |target_route| {
                                var method_set = bun.http.Method.Set.empty;
                                method_set.insert(method);

                                try args.appendStaticRoute(path, target_route, .{ .method = method_set });
                            },
                        }
                    };
                }

                if (found) continue;

                const route = (try AnyRoute.fromGeneratedExtras(context, path, object, init_ctx)) orelse
                    return context.fail(.invalid_route_value, {});
                try args.appendStaticRoute(path, route, .any);
            },
            .html, .response, .blob, .invalid => {
                const route = (try routeFromTarget(context, path, &entry.value, init_ctx)) orelse
                    return context.fail(.invalid_route_value, {});
                try args.appendStaticRoute(path, route, .any);
            },
        }
    }

    // When HTML bundles are provided, ensure DevServer options are ready
    // The presence of these options causes Bun.serve to initialize things.
    if ((init_ctx.dedupe_html_bundle_map.count() > 0 or
        init_ctx.framework_router_list.items.len > 0))
    {
        if (args.development.isHMREnabled()) {
            const root = bun.fs.FileSystem.instance.top_level_dir;
            const framework = try bun.bake.Framework.auto(
                init_ctx.arena.allocator(),
                &global.bunVM().transpiler.resolver,
                init_ctx.framework_router_list.items,
            );
            const route_styles = try init_ctx.arena.allocator().alloc(
                bun.bake.FrameworkRouterEngine.Style,
                init_ctx.framework_router_styles.items.len,
            );
            for (route_styles, init_ctx.framework_router_styles.items) |*destination, *source| {
                destination.* = source.take();
            }
            args.bake = .{
                .arena = init_ctx.arena,
                .allocations = init_ctx.js_string_allocations,
                .root = root,
                .framework = framework,
                .route_styles = route_styles,
                .bundler_options = bun.bake.SplitBundlerOptions.empty,
            };
            route_styles_transferred = true;
            const bake = &args.bake.?;

            const o = vm.transpiler.options.transform_options;

            switch (o.serve_env_behavior) {
                .prefix => {
                    bake.bundler_options.client.env_prefix = vm.transpiler.options.transform_options.serve_env_prefix;
                    bake.bundler_options.client.env = .prefix;
                },
                .load_all => {
                    bake.bundler_options.client.env = .load_all;
                },
                .disable => {
                    bake.bundler_options.client.env = .disable;
                },
                else => {},
            }

            if (o.serve_define) |define| {
                bake.bundler_options.client.define = define;
                bake.bundler_options.server.define = define;
                bake.bundler_options.ssr.define = define;
            }
        } else {
            if (init_ctx.framework_router_list.items.len > 0) {
                return context.fail(.framework_router_requires_development, {});
            }
            init_ctx.arena.deinit();
        }
    } else {
        bun.debugAssert(init_ctx.arena.state.used_list == null and
            init_ctx.arena.state.free_list == null);
        init_ctx.arena.deinit();
    }
}

fn routeFromTarget(
    context: anytype,
    path: []const u8,
    target: anytype,
    init_ctx: *AnyRoute.ServerInitContext,
) bun.bindgen.CallError(@TypeOf(context))!?AnyRoute {
    return switch (target.*) {
        .html => |*handle| try AnyRoute.fromHTMLBundle(handle.get(bun.api.server.HTMLBundle), init_ctx),
        .response => |*handle| try AnyRoute.fromResponse(context, handle.get(jsc.WebCore.Response)),
        .blob => |*view| try AnyRoute.fromBlob(view.get()),
        .object => |*object| try AnyRoute.fromGeneratedExtras(context, path, object, init_ctx),
        .invalid => null,
        else => unreachable,
    };
}

fn failRoutePath(context: anytype, comptime fmt: []const u8, path: []const u8) bun.bindgen.CallError(@TypeOf(context)) {
    const message = try std.fmt.allocPrint(bun.default_allocator, fmt, .{bun.fmt.quote(path)});
    defer bun.default_allocator.free(message);
    return context.fail(.route_path_invalid, try bun.bindgen.DOMString.fromUTF8(message));
}

pub fn fromSchema(
    global: *jsc.JSGlobalObject,
    context: anytype,
    args: *ServerConfig,
    options_argument: anytype,
    opts: FromJSOptions,
) !void {
    const vm = global.bunVM();
    const env = vm.transpiler.env;

    args.* = .{
        .address = .{
            .tcp = .{
                .port = 3000,
                .hostname = null,
            },
        },
        .development = if (vm.transpiler.options.transform_options.serve_hmr) |hmr|
            if (!hmr) .development_without_hmr else .development
        else
            .development,

        // If this is a node:cluster child, let's default to SO_REUSEPORT.
        // That way you don't have to remember to set reusePort: true in Bun.serve() when using node:cluster.
        .reuse_port = env.get("NODE_UNIQUE_ID") != null,
    };
    var has_hostname = false;

    defer {
        if (!args.development.isHMREnabled()) {
            bun.assert(args.bake == null);
        }
    }

    if (strings.eqlComptime(env.get("NODE_ENV") orelse "", "production")) {
        args.development = .production;
    }

    if (vm.transpiler.options.production) {
        args.development = .production;
    }

    args.address.tcp.port = brk: {
        const PORT_ENV = .{ "BUN_PORT", "PORT", "NODE_PORT" };

        inline for (PORT_ENV) |PORT| {
            if (env.get(PORT)) |port| {
                if (std.fmt.parseInt(u16, port, 10)) |_port| {
                    break :brk _port;
                } else |_| {}
            }
        }

        if (vm.transpiler.options.transform_options.port) |port| {
            break :brk port;
        }

        break :brk args.address.tcp.port;
    };
    var port = args.address.tcp.port;

    if (vm.transpiler.options.transform_options.origin) |origin| {
        args.base_uri = try bun.default_allocator.dupe(u8, origin);
    }

    const lazy_options = options_argument orelse return context.fail(.object_required, {});
    const converted_options = try lazy_options.convert(context);

    {
        const arg = &converted_options.value;

        // "development" impacts other settings like bake.
        if (arg.development) |*development_field| {
            switch (development_field.*) {
                .options => |*dev| {
                    args.development = .development;
                    if (dev.hmr) |hmr| args.development = if (!hmr) .development_without_hmr else .development;
                    if (dev.console) |console| args.broadcast_console_log_from_browser_to_server_for_bake = console;
                    if (dev.chromeDevToolsAutomaticWorkspaceFolders) |flag| args.enable_chrome_devtools_automatic_workspace_folders = flag;
                },
                .truthy => |flag| args.development = if (flag) .development else .production,
            }
            args.reuse_port = args.development == .production;
        }

        if (arg.routes) |*routes_field| {
            if (routes_field.*) |*routes_input| {
                try parseRoutes(global, context, args, routes_input);
            }
        }

        if (global.hasException()) return error.JSError;

        if (arg.idleTimeout) |field| {
            if (field) |seconds| {
                args.has_idleTimeout = true;
                args.idleTimeout = seconds;
            }
        }

        if (arg.webSocket) |*field| {
            if (field.*) |*websocket_options| {
                args.websocket = try WebSocketServerContext.fromSchema(global, context, websocket_options);
            }
        }
        if (global.hasException()) return error.JSError;

        if (arg.port) |port_field| if (port_field) |configured_port| {
            args.address.tcp.port = configured_port;
            port = configured_port;
        };
        if (global.hasException()) return error.JSError;

        if (arg.baseURI) |*field| {
            if (field.*) |*base_uri| {
                if (base_uri.length() > 0) {
                    const replacement = try base_uri.toOwnedSlice(bun.default_allocator);
                    bun.default_allocator.free(args.base_uri);
                    args.base_uri = replacement;
                }
            }
        }

        if (arg.hostname) |*field| if (try stringishOwnedZ(field)) |host_str| {
            args.address.tcp.hostname = host_str;
            has_hostname = true;
        };

        if (arg.unix_path) |*field| if (try stringishOwnedZ(field)) |unix_str| {
            errdefer bun.default_allocator.free(unix_str);
            if (has_hostname) {
                return context.fail(.hostname_and_unix, {});
            }

            args.address = .{ .unix = unix_str };
        };

        if (arg.id) |*field| switch (field.*) {
            .nulled => args.allow_hot = false,
            .text => |*id| {
                if (id.length() > 0) {
                    args.id = try id.toOwnedSlice(bun.default_allocator);
                } else {
                    args.allow_hot = false;
                }
            },
        };

        if (opts.allow_bake_config) {
            if (arg.app) |*field| {
                if (field.*) |*bake_value| brk: {
                    if (!bun.FeatureFlags.bake()) {
                        break :brk;
                    }
                    if (args.bake != null) {
                        // "app" is likely to be removed in favor of the HTML loader.
                        return context.fail(.app_with_html_loader, {});
                    }

                    if (args.development == .production) {
                        return context.fail(.app_requires_development, {});
                    }

                    args.bake = try bun.bake.UserOptions.fromSchema(global, context, bake_value);
                }
            }
        }

        if (arg.reusePort) |flag| args.reuse_port = flag;
        if (arg.ipv6Only) |flag| args.ipv6_only = flag;
        if (arg.http3) |flag| args.http3 = flag;
        if (arg.http1) |flag| args.http1 = flag;

        if (arg.maxRequestBodySize) |*field| switch (field.*) {
            .number => |count| args.max_request_body_size = count,
            .ignored => {},
        };

        if (arg.error_callback) |*field| switch (field.*) {
            .callback => |*callback| {
                try args.onError.setView(callback.*);
            },
            .nulled => {},
        };

        if (arg.onNodeHTTPRequest) |*field| switch (field.*) {
            .callback => |*callback| {
                try args.onNodeHTTPRequest.setView(callback.*);
            },
            .nulled => {},
        };

        fetch: {
            if (arg.fetch) |*field| switch (field.*) {
                .callback => |*callback| {
                    try args.onRequest.setView(callback.*);
                    break :fetch;
                },
                .nulled => {},
            };
            if (args.bake == null and !args.onNodeHTTPRequest.configured and
                ((args.static_routes.items.len + args.user_routes_to_build.items.len) == 0 and !opts.has_user_routes))
            {
                return context.fail(.missing_fetch_handler, {});
            }
        }

        if (arg.tls) |*field| {
            if (field.*) |*tls_value| switch (tls_value.*) {
                .list => |*list| {
                    for (0..list.len()) |index| {
                        const converted = list.at(index).?;
                        var ssl_config = try SSLConfigEngine.parse(context, &converted) orelse {
                            // Backwards-compatibility; we ignored empty tls objects.
                            continue;
                        };
                        errdefer ssl_config.deinit();

                        if (args.ssl_config == null) {
                            args.ssl_config = ssl_config;
                        } else {
                            if (ssl_config.server_name == null or ssl_config.server_name.?.len == 0) {
                                return context.fail(.sni_requires_server_name, {});
                            }
                            if (args.sni == null) {
                                args.sni = try bun.BabyList(SSLConfig).initCapacity(bun.default_allocator, list.len() - 1);
                            }

                            try args.sni.?.append(bun.default_allocator, ssl_config);
                        }
                    }
                },
                .config => |*tls_config| {
                    if (try SSLConfigEngine.parse(context, tls_config)) |ssl_config| {
                        args.ssl_config = ssl_config;
                    }
                },
            };
        }
        if (global.hasException()) return error.JSError;

        // @compatibility Bun v0.x - v0.2.1
        // this used to be top-level, now it's "tls" object
        if (args.ssl_config == null) {
            if (try SSLConfigEngine.parse(context, arg)) |ssl_config| {
                args.ssl_config = ssl_config;
            }
            if (global.hasException()) {
                return error.JSError;
            }
        }

        if (args.http3) {
            if (args.ssl_config == null) {
                return context.fail(.http3_requires_tls, {});
            }
        } else if (!args.http1) {
            return context.fail(.http1_requires_http3, {});
        }
        if (!args.http1 and args.address == .unix) {
            return context.fail(.http1_unix_unsupported, {});
        }
    }

    if (args.base_uri.len > 0) {
        const parsed = URL.parse(args.base_uri);
        if (parsed.hostname.len == 0) return context.fail(.base_uri_missing_hostname, {});
        if (!strings.isAllASCII(args.base_uri)) return context.fail(.base_uri_not_encoded, {});
        if (parsed.username.len > 0 or parsed.password.len > 0) return context.fail(.base_uri_has_credentials, {});

        if (parsed.protocol.len == 0) {
            const replacement = try formatBaseURI(parsed.hostname, strings.trimLeadingChar(parsed.pathname, '/'), port, args.ssl_config != null);
            bun.default_allocator.free(args.base_uri);
            args.base_uri = replacement;
        }
    } else {
        const hostname: string = if (has_hostname) std.mem.span(args.address.tcp.hostname.?) else "0.0.0.0";
        if (!strings.isAllASCII(hostname)) return context.fail(.hostname_not_encoded, {});
        args.base_uri = try formatBaseURI(hostname, "", port, args.ssl_config != null);
    }

    const parsed = URL.parse(args.base_uri);
    if (parsed.hostname.len == 0) return context.fail(.base_uri_missing_hostname, {});
    if (parsed.username.len > 0 or parsed.password.len > 0) return context.fail(.base_uri_has_credentials, {});
    args.base_url = parsed;
}

fn formatBaseURI(hostname: []const u8, pathname: []const u8, port: u16, tls: bool) bun.OOM![]u8 {
    const protocol: []const u8 = if (tls) "https" else "http";
    const needs_brackets = hostname.len > 0 and hostname[0] != '[' and strings.isIPV6Address(hostname);
    const open: []const u8 = if (needs_brackets) "[" else "";
    const close: []const u8 = if (needs_brackets) "]" else "";
    if (port == @as(u16, if (tls) 443 else 80)) {
        return std.fmt.allocPrint(bun.default_allocator, "{s}://{s}{s}{s}/{s}", .{ protocol, open, hostname, close, pathname });
    }
    return std.fmt.allocPrint(bun.default_allocator, "{s}://{s}{s}{s}:{d}/{s}", .{ protocol, open, hostname, close, port, pathname });
}

pub const UserRouteBuilder = struct {
    route: ServerConfig.RouteDeclaration,
    callback: bun.bindgen.Callback(bun.bindgen.CallbackSchema("ServeFetchCallback")),

    pub fn deinit(this: *UserRouteBuilder) void {
        this.callback.deinit();
        this.route.deinit();
    }
};

const string = []const u8;

const WebSocketServerContext = @import("./WebSocketServerContextEngine.zig");
const std = @import("std");

const bun = @import("bun");
const HTTP = bun.http;
const JSError = bun.JSError;
const URL = bun.URL;
const assert = bun.assert;
const jsc = bun.jsc;
const strings = bun.strings;
const uws = bun.uws;
const AnyRoute = bun.api.server.AnyRoute;
const AnyServer = jsc.API.AnyServer;
