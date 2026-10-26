const httplog = Output.scoped(.Server, .visible);
const ctxLog = Output.scoped(.RequestContext, .visible);

pub const WebSocketServerContext = @import("./WebSocketServerContextEngine.zig");
pub const HTTPStatusText = @import("./HTTPStatusText.zig");
pub const HTMLBundle = @import("./HTMLBundleEngine.zig");
pub const StaticRoute = @import("./StaticRouteEngine.zig");
pub const FileRoute = @import("./FileRouteEngine.zig");
pub const FileResponseStream = @import("./FileResponseStream.zig");
pub const RangeRequest = @import("./RangeRequest.zig");

pub const AnyRoute = union(enum) {
    /// Serve a static file
    /// "/robots.txt": new Response(...),
    static: *StaticRoute,
    /// Serve a file from disk
    file: *FileRoute,
    /// Bundle an HTML import
    /// import html from "./index.html";
    /// "/": html,
    html: bun.ptr.RefPtr(HTMLBundle.Route),
    /// Use file system routing.
    /// "/*": {
    ///   "dir": import.meta.resolve("./pages"),
    ///   "style": "nextjs-pages",
    /// }
    framework_router: bun.bake.FrameworkRouter.Type.Index,

    pub fn memoryCost(this: AnyRoute) usize {
        return switch (this) {
            .static => |static_route| static_route.memoryCost(),
            .file => |file_route| file_route.memoryCost(),
            .html => |html_bundle_route| html_bundle_route.data.memoryCost(),
            .framework_router => @sizeOf(bun.bake.Framework.FileSystemRouterType),
        };
    }

    pub fn setServer(this: AnyRoute, server: ?AnyServer) void {
        switch (this) {
            .static => |static_route| static_route.server = server,
            .file => |file_route| file_route.server = server,
            .html => |html_bundle_route| html_bundle_route.server = server,
            .framework_router => {}, // DevServer contains .server field
        }
    }

    pub fn deref(this: AnyRoute) void {
        switch (this) {
            .static => |static_route| static_route.deref(),
            .file => |file_route| file_route.deref(),
            .html => |html_bundle_route| html_bundle_route.deref(),
            .framework_router => {}, // not reference counted
        }
    }

    pub fn ref(this: AnyRoute) void {
        switch (this) {
            .static => |static_route| static_route.ref(),
            .file => |file_route| file_route.ref(),
            .html => |html_bundle_route| html_bundle_route.data.ref(),
            .framework_router => {}, // not reference counted
        }
    }

    fn manifestItemRoute(
        context: anytype,
        path_input: anytype,
        headers: ?*jsc.WebCore.FetchHeaders,
        index_path: []const u8,
        init_ctx: *ServerInitContext,
    ) bun.bindgen.CallError(@TypeOf(context))!?AnyRoute {
        var owned_path = path_input.toOwned();
        var path_string = owned_path.takeBunString();
        defer path_string.deref();
        const path_like: bun.api.node.PathLike = switch (try bun.api.node.PathLike.fromNativeString(&path_string, bun.default_allocator)) {
            .path => |result| value: {
                var sliced = result.slice;
                if (result.report_extra_memory) bun.api.StringEngine.reportStringSliceExtraMemory(&sliced, init_ctx.global.vm());
                break :value .{ .slice_with_underlying_string = sliced };
            },
            .too_long => |invalid| {
                defer invalid.deinit();
                var system_error = bun.sys.Error.fromCode(.NAMETOOLONG, .open).toSystemError();
                system_error.syscall = bun.String.dead;
                return bun.api.SystemErrorBindings.throwSystemError(system_error, init_ctx.global);
            },
            .contains_null => |invalid| {
                defer invalid.deinit();
                return init_ctx.global.throwNodeError(.ERR_INVALID_ARG_VALUE, "The argument 'path' must not contain null bytes. Received {f}", .{bun.fmt.quote(invalid.slice())});
            },
        };
        var path = bun.api.node.PathOrFileDescriptor{ .path = path_like };
        defer path.deinit();

        // Construct the route by stripping paths above the root.
        //
        //    "./index-abc.js" -> "/index-abc.js"
        //    "../index-abc.js" -> "/index-abc.js"
        //    "/index-abc.js" -> "/index-abc.js"
        //    "index-abc.js" -> "/index-abc.js"
        //
        const cwd = if (bun.StandaloneModuleGraph.isBunStandaloneFilePath(path.path.slice()))
            bun.StandaloneModuleGraph.targetBasePublicPath(bun.Environment.os, "root/")
        else
            bun.fs.FileSystem.instance.top_level_dir;

        const abs_path = bun.fs.FileSystem.instance.abs(&[_][]const u8{path.path.slice()});
        const relative_path_owned = try std.fs.path.relative(bun.default_allocator, cwd, null, cwd, abs_path);
        defer bun.default_allocator.free(relative_path_owned);
        bun.path.platformToPosixInPlace(u8, relative_path_owned);
        var relative_path: []const u8 = relative_path_owned;

        if (strings.hasPrefixComptime(relative_path, "./")) {
            relative_path = relative_path[2..];
        } else if (strings.hasPrefixComptime(relative_path, "../")) {
            while (strings.hasPrefixComptime(relative_path, "../")) {
                relative_path = relative_path[3..];
            }
        }
        const is_index_route = bun.strings.eql(path.path.slice(), index_path);
        var builder = std.array_list.Managed(u8).init(bun.default_allocator);
        defer builder.deinit();
        if (!strings.hasPrefixComptime(relative_path, "/")) {
            try builder.append('/');
        }

        try builder.appendSlice(relative_path);

        const route = try fromOptions(context, init_ctx.global, headers, &path);
        errdefer route.deref();

        if (is_index_route) {
            return route;
        }

        var methods = HTTP.Method.Optional{ .method = .init(.{}) };
        methods.insert(.GET);
        methods.insert(.HEAD);

        try init_ctx.user_routes.ensureUnusedCapacity(1);
        init_ctx.user_routes.appendAssumeCapacity(.{
            .path = try builder.toOwnedSlice(),
            .route = route,
            .method = methods,
        });
        return null;
    }

    fn manifestRoute(
        context: anytype,
        extras: anytype,
        init_ctx: *ServerInitContext,
    ) bun.bindgen.CallError(@TypeOf(context))!?AnyRoute {
        const index_field = if (extras.index) |*field| field else return null;
        const index_value = if (index_field.*) |*value| value else return null;
        const files_field = if (extras.files) |*field| field else return null;
        const files = switch (files_field.*) {
            .files => |*value| value,
            .invalid => return null,
        };

        var index_slice = try index_value.toUTF8(bun.default_allocator);
        defer index_slice.deinit();

        var html_route: ?AnyRoute = null;
        errdefer if (html_route) |route| route.deref();
        var iterator = files.iterator();
        while (iterator.next()) |converted| {
            const item = converted;
            switch (item.value) {
                .file => |*file| {
                    const path = if (file.path) |*value| value else continue;
                    const headers_field = if (file.headers) |*value| value else continue;
                    const headers: ?*jsc.WebCore.FetchHeaders = if (headers_field.*) |*value| value.get() else null;
                    if (try manifestItemRoute(context, path, headers, index_slice.slice(), init_ctx)) |route| {
                        if (html_route) |previous| previous.deref();
                        html_route = route;
                    }
                },
                .invalid => continue,
            }
        }

        return html_route;
    }

    pub fn fromOptions(context: anytype, global: *jsc.JSGlobalObject, headers: ?*jsc.WebCore.FetchHeaders, path: *bun.api.node.PathOrFileDescriptor) bun.bindgen.CallError(@TypeOf(context))!AnyRoute {
        // The file/static route doesn't ref it.
        var blob = try Blob.findOrCreateFileFromPath(path, global, false);
        defer blob.deinit();

        if (blob.needsToReadFile()) {
            // Throw a more helpful error upfront if the file does not exist.
            //
            // In production, you do NOT want to find out that all the assets
            // are 404'ing when the user goes to the route. You want to find
            // that out immediately so that the health check on startup fails
            // and the process exits with a non-zero status code.
            if (blob.storePtr()) |store| {
                if (store.getPath()) |store_path| {
                    switch (bun.sys.existsAtType(bun.FD.cwd(), store_path)) {
                        .result => |file_type| {
                            if (file_type == .directory) {
                                return failBundledFile(context, "Bundled file {f} cannot be a directory. You may want to configure --asset-naming or `naming` when bundling.", store_path);
                            }
                        },
                        .err => {
                            return failBundledFile(context, "Bundled file {f} not found. You may want to configure --asset-naming or `naming` when bundling.", store_path);
                        },
                    }
                }
            }

            return AnyRoute{ .file = try FileRoute.fromBlobWithHeaders(&blob, .{ .server = null, .headers = headers }) };
        }

        var static_blob: jsc.WebCore.Blob.Any = .{ .Blob = blob.take() };
        defer static_blob.detach();
        return AnyRoute{ .static = try StaticRoute.fromBlobWithHeaders(&static_blob, .{ .server = null, .headers = headers }) };
    }

    fn failBundledFile(context: anytype, comptime fmt: []const u8, store_path: []const u8) bun.bindgen.CallError(@TypeOf(context)) {
        const message = try std.fmt.allocPrint(bun.default_allocator, fmt, .{bun.fmt.quote(store_path)});
        defer bun.default_allocator.free(message);
        return context.fail(.bundled_file_invalid, try bun.bindgen.DOMString.fromUTF8(message));
    }

    pub fn fromHTMLBundle(html_bundle: *HTMLBundle, init_ctx: *ServerInitContext) bun.OOM!AnyRoute {
        if (init_ctx.dedupe_html_bundle_map.get(html_bundle)) |route| return .{ .html = route.dupeRef() };
        try init_ctx.dedupe_html_bundle_map.ensureUnusedCapacity(1);
        const route = try HTMLBundle.Route.init(html_bundle);
        init_ctx.dedupe_html_bundle_map.putAssumeCapacityNoClobber(html_bundle, route);
        return .{ .html = route.dupeRef() };
    }

    pub fn fromResponse(context: anytype, response: *jsc.WebCore.Response) bun.bindgen.CallError(@TypeOf(context))!AnyRoute {
        if (try FileRoute.fromResponse(context, response)) |file_route| {
            return .{ .file = file_route };
        }
        return .{ .static = try StaticRoute.fromResponse(context, response) };
    }

    /// Returns null when the blob is not file-backed; memory-backed blobs
    /// are not valid route values.
    pub fn fromBlob(blob: *jsc.WebCore.Blob) bun.OOM!?AnyRoute {
        const file_route = (try FileRoute.fromBlob(blob)) orelse return null;
        return .{ .file = file_route };
    }

    pub fn fromGeneratedExtras(
        context: anytype,
        path: []const u8,
        extras: anytype,
        init_ctx: *ServerInitContext,
    ) bun.bindgen.CallError(@TypeOf(context))!?AnyRoute {
        if (try manifestRoute(context, extras, init_ctx)) |html_route| {
            return html_route;
        }

        const FrameworkRouter = bun.bake.FrameworkRouter;
        const FrameworkRouterEngine = bun.bake.FrameworkRouterEngine;
        if (extras.dir) |dir_field| if (dir_field) |*dir_view| {
            const dir = try dir_view.toUTF8(bun.default_allocator);
            defer dir.deinit();
            const relative_root = try init_ctx.js_string_allocations.copy(dir.slice());

            var style: FrameworkRouterEngine.Style = if (extras.style) |*style_field| style: {
                if (style_field.*) |*style_union| {
                    break :style try FrameworkRouterEngine.Style.fromArgument(style_union.*);
                }
                break :style .nextjs_pages;
            } else .nextjs_pages;
            errdefer style.deinit();

            if (!bun.strings.endsWith(path, "/*")) {
                return context.fail(.mount_dir_requires_wildcard, {});
            }

            const router_index = init_ctx.framework_router_list.items.len;
            const limit = @as(usize, std.math.maxInt(@typeInfo(FrameworkRouter.Type.Index).@"enum".tag_type)) + 1;
            if (router_index >= limit) {
                const message = try std.fmt.allocPrint(bun.default_allocator, "Too many framework routers. Maximum is {d}.", .{limit});
                defer bun.default_allocator.free(message);
                return context.fail(.too_many_framework_routers, try bun.bindgen.DOMString.fromUTF8(message));
            }

            try init_ctx.framework_router_list.append(.{
                .root = relative_root,
                .style = style.toRouterStyle(@intCast(router_index)),

                // trim the /*
                .prefix = if (path.len == 2) "/" else path[0 .. path.len - 2],

                // TODO: customizable framework option.
                .entry_client = "bun-framework-react/client.tsx",
                .entry_server = "bun-framework-react/server.tsx",
                .ignore_underscores = true,
                .ignore_dirs = &.{ "node_modules", ".git" },
                .extensions = &.{ ".tsx", ".jsx" },
                .allow_layouts = true,
            });
            errdefer _ = init_ctx.framework_router_list.pop();
            try init_ctx.framework_router_styles.append(style);
            return .{ .framework_router = .init(@intCast(router_index)) };
        };

        return null;
    }

    pub const ServerInitContext = struct {
        arena: std.heap.ArenaAllocator,
        dedupe_html_bundle_map: std.AutoHashMap(*HTMLBundle, bun.ptr.RefPtr(HTMLBundle.Route)),
        js_string_allocations: bun.bake.StringRefList,
        global: *jsc.JSGlobalObject,
        framework_router_list: std.array_list.Managed(bun.bake.Framework.FileSystemRouterType),
        framework_router_styles: std.array_list.Managed(bun.bake.FrameworkRouterEngine.Style),
        user_routes: *std.array_list.Managed(ServerConfig.StaticRouteEntry),
    };
};

pub const ServerConfig = @import("./ServerConfig.zig");
pub const ServerWebSocket = @import("./ServerWebSocketEngine.zig");
pub const NodeHTTPResponse = @import("./NodeHTTPResponseEngine.zig");

pub fn serveFromBinding(
    context: anytype,
    args: anytype,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    const globalObject = context.viewToken().globalObject();
    var config: ServerConfig = .{};
    defer config.deinit();
    try ServerConfig.fromSchema(
        globalObject,
        context,
        &config,
        args.options,
        .{
            .allow_bake_config = bun.FeatureFlags.bake(),
            .has_user_routes = false,
        },
    );
    return serveConfiguredFromBinding(context, &config);
}

fn serveConfiguredFromBinding(
    context: anytype,
    config: *ServerConfig,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    const globalObject = context.viewToken().globalObject();
    if (globalObject.hasException()) return error.JSError;
    const vm = globalObject.bunVM();

    if (config.allow_hot) {
        if (vm.hotMap()) |hot| {
            if (config.id.len == 0) config.id = try config.computeID();
            if (hot.getEntry(config.id)) |entry| {
                switch (entry.tag()) {
                    inline @field(@TypeOf(entry.tag()), @typeName(HTTPServer)),
                    @field(@TypeOf(entry.tag()), @typeName(HTTPSServer)),
                    => |tag| {
                        const ServerType = if (tag == @field(@TypeOf(entry.tag()), @typeName(HTTPServer))) HTTPServer else HTTPSServer;
                        const server = entry.as(ServerType);
                        var result = try server.serverClassRefAs(bun.bindgen.Return(@TypeOf(context)));
                        errdefer bun.bindgen.deinitReturn(@TypeOf(context), &result);
                        try server.onReloadFromZig(config);
                        return result;
                    },
                    else => {},
                }
            }
        }
    }

    switch (config.ssl_config != null) {
        inline else => |has_ssl_config| {
            const ServerType = if (has_ssl_config) HTTPSServer else HTTPServer;
            const server = try ServerType.init(config, globalObject);
            var wrapper_attached = false;
            errdefer if (!wrapper_attached) {
                server.stop(true);
                server.finalize();
            };
            if (globalObject.hasException()) return error.JSError;

            var route_list_object = try server.listen(context);
            defer if (route_list_object) |*route_list| route_list.deinit();
            if (globalObject.hasException()) return error.JSError;

            var server_ref = try server.adoptClassRefAs(bun.bindgen.Return(@TypeOf(context)), globalObject);
            wrapper_attached = true;
            errdefer {
                server.stop(true);
                bun.bindgen.deinitReturn(@TypeOf(context), &server_ref);
            }
            try server.writeHandlerSlots();
            if (route_list_object) |*route_list| try server.routeListSetCached(route_list);

            if (server.config.allow_hot) {
                if (vm.hotMap()) |hot| try hot.insert(server.config.id, server);
            }

            if (vm.debugger) |*debugger| {
                try debugger.http_server_agent.notifyServerStarted(AnyServer.from(server));
                try debugger.http_server_agent.notifyServerRoutesUpdated(AnyServer.from(server));
            }

            return server_ref;
        },
    }
}

/// State machine to handle loading plugins asynchronously. This structure is not thread-safe.
const ServePlugins = struct {
    const PromiseReaction = bun.bindgen.PromiseReaction(ServePluginsOnResolveSchema.args[1].ArgumentType, ServePlugins);

    state: State,
    ref_count: RefCount,

    /// Reference count is incremented while there are other objects that are waiting on plugin loads.
    const RefCount = bun.ptr.RefCount(@This(), "ref_count", @This().deinit, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;

    pub fn releasePromiseReactionRef(this: *ServePlugins) void {
        this.deref();
    }

    pub const State = union(enum) {
        unqueued: []const []const u8,
        pending: struct {
            /// Promise may be empty if the plugin load finishes synchronously.
            plugin: *bun.jsc.API.JSBundler.Plugin,
            promise: bun.jsc.API.JSBundler.Plugin.LoadAndResolvePluginsForServePromise,
            html_bundle_routes: std.ArrayListUnmanaged(*HTMLBundle.Route),
            dev_server: ?*bun.bake.DevServer,
        },
        loaded: *bun.jsc.API.JSBundler.Plugin,
        /// Error information is not stored as it is already reported.
        err,
    };

    pub const GetOrStartLoadResult = union(enum) {
        /// null = no plugins, used by server implementation
        ready: ?*bun.jsc.API.JSBundler.Plugin,
        pending,
        err,
    };

    pub const Callback = union(enum) {
        html_bundle_route: *HTMLBundle.Route,
        dev_server: *bun.bake.DevServer,
    };

    pub fn init(plugins: []const []const u8) bun.OOM!*ServePlugins {
        return bun.tryNew(ServePlugins, .{ .ref_count = .init(), .state = .{ .unqueued = plugins } });
    }

    fn deinit(this: *ServePlugins) void {
        switch (this.state) {
            .unqueued => {},
            .pending => assert(false), // should have one ref while pending!
            .loaded => |loaded| loaded.deinit(),
            .err => {},
        }
        bun.destroy(this);
    }

    pub fn getOrStartLoad(this: *ServePlugins, global: *jsc.JSGlobalObject, cb: Callback) bun.JSError!GetOrStartLoadResult {
        sw: switch (this.state) {
            .unqueued => {
                try this.loadAndResolvePlugins(global);
                continue :sw this.state; // could jump to any branch if synchronously resolved
            },
            .pending => |*pending| {
                switch (cb) {
                    .html_bundle_route => |route| {
                        try pending.html_bundle_routes.append(bun.default_allocator, route);
                        route.ref();
                    },
                    .dev_server => |server| {
                        assert(pending.dev_server == null or pending.dev_server == server); // one dev server per server
                        pending.dev_server = server;
                    },
                }
                return .pending;
            },
            .loaded => |plugins| return .{ .ready = plugins },
            .err => return .err,
        }
    }

    fn loadAndResolvePlugins(this: *ServePlugins, global: *jsc.JSGlobalObject) bun.JSError!void {
        bun.assert(this.state == .unqueued);
        const plugin_list = this.state.unqueued;
        const bunfig_folder = std.fs.path.dirname(global.bunVM().transpiler.options.bunfig_path) orelse "";

        this.ref();
        defer this.deref();

        var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
        engine_scope.init(global);
        defer engine_scope.deinit();
        const plugin = try bun.jsc.API.JSBundler.Plugin.createInRealm(global, .browser);
        errdefer switch (this.state) {
            .unqueued => plugin.deinit(),
            else => {},
        };
        var sfb_buffer: [4]bun.bindgen.DOMString = undefined;
        var sfb: std.heap.BufferFirstAllocator = .init(@ptrCast(&sfb_buffer), bun.default_allocator);
        const alloc = sfb.allocator();
        const plugin_strings = try alloc.alloc(bun.bindgen.DOMString, plugin_list.len);
        defer alloc.free(plugin_strings);
        var initialized_plugin_strings: usize = 0;
        defer for (plugin_strings[0..initialized_plugin_strings]) |*plugin_string| plugin_string.deinit();
        for (plugin_list, plugin_strings) |raw_plugin, *out| {
            out.* = try bun.bindgen.DOMString.fromUTF8(raw_plugin);
            initialized_plugin_strings += 1;
        }
        var bunfig_folder_string = try bun.bindgen.DOMString.fromUTF8(bunfig_folder);
        defer bunfig_folder_string.deinit();

        this.state = .{ .pending = .{
            .promise = .empty,
            .plugin = plugin,
            .html_bundle_routes = .empty,
            .dev_server = null,
        } };

        var result = result: {
            global.bunVM().eventLoop().enter();
            defer global.bunVM().eventLoop().exit();
            break :result plugin.loadAndResolvePluginsForServe(
                plugin_strings,
                bunfig_folder_string,
            ) catch |err| {
                this.transitionToRejected();
                Output.errGeneric("Failed to load plugins for Bun.serve:", .{});
                if (err == error.OutOfMemory) return error.OutOfMemory;
                _ = engine_scope.runPendingErrorHandler();
                return;
            };
        };
        defer result.deinit();

        switch (engine_scope.engine(PromiseStatusShim).call(.{ .promise = result.operand(&engine_scope).asPromise() })) {
            .pending => {
                this.ref();
                this.state.pending.promise = .initFromOwned(&result);
                PromiseReaction.attach(
                    &engine_scope,
                    result.operand(&engine_scope).asPromise(),
                    this,
                    ServePluginsOnResolveBinding,
                    ServePluginsOnRejectBinding,
                ) catch |err| {
                    this.transitionToRejected();
                    Output.errGeneric("Failed to load plugins for Bun.serve:", .{});
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    _ = engine_scope.runPendingErrorHandler();
                };
            },
            .fulfilled => handleOnResolve(this),
            .rejected => {
                const reason = (try engine_scope.engine(PromiseResultShim).call(.{
                    .promise = result.operand(&engine_scope).asPromise(),
                })) orelse @panic("rejected plugin promise has no result");
                this.transitionToRejected();
                Output.errGeneric("Failed to load plugins for Bun.serve:", .{});
                engine_scope.runErrorHandler(reason.operand(&engine_scope).asAny());
            },
        }
    }

    fn bindOnResolve(
        _: bun.bindgen.CallContext(ServePluginsOnResolveSchema),
        args: bun.bindgen.Args(ServePluginsOnResolveSchema),
    ) bun.JSError!bun.bindgen.Return(ServePluginsOnResolveSchema) {
        ctxLog("onResolve", .{});

        const plugins = PromiseReaction.take(args.plugins) orelse return;
        defer plugins.deref();

        handleOnResolve(plugins);
    }

    pub fn handleOnResolve(this: *ServePlugins) void {
        bun.assert(this.state == .pending);
        const pending = &this.state.pending;
        const plugin = pending.plugin;
        const dev_server = pending.dev_server;
        var html_bundle_routes = pending.html_bundle_routes;
        pending.html_bundle_routes = .empty;
        defer html_bundle_routes.deinit(bun.default_allocator);

        pending.promise.deinit();

        this.state = .{ .loaded = plugin };

        for (html_bundle_routes.items) |route| {
            bun.handleOom(route.onPluginsResolved(plugin));
            route.deref();
        }
        if (dev_server) |server| {
            bun.handleOom(server.onPluginsResolved(plugin));
        }
    }

    fn bindOnReject(
        context: bun.bindgen.CallContext(ServePluginsOnRejectSchema),
        args: bun.bindgen.Args(ServePluginsOnRejectSchema),
    ) bun.JSError!bun.bindgen.Return(ServePluginsOnRejectSchema) {
        ctxLog("onReject", .{});

        const plugins = PromiseReaction.take(args.plugins) orelse return;
        defer plugins.deref();
        plugins.transitionToRejected();
        Output.errGeneric("Failed to load plugins for Bun.serve:", .{});
        context.runErrorHandler(args.errorValue.operand(context).asAny());
    }

    fn transitionToRejected(this: *ServePlugins) void {
        bun.assert(this.state == .pending);
        const pending = &this.state.pending;
        const dev_server = pending.dev_server;
        var html_bundle_routes = pending.html_bundle_routes;
        pending.html_bundle_routes = .empty;
        defer html_bundle_routes.deinit(bun.default_allocator);
        pending.plugin.deinit();
        pending.promise.deinit();

        this.state = .err;

        for (html_bundle_routes.items) |route| {
            bun.handleOom(route.onPluginsRejected());
            route.deref();
        }
        if (dev_server) |server| {
            bun.handleOom(server.onPluginsRejected());
        }
    }
};

fn ServerJSBinding(comptime Server: type, comptime ClassSchema: type) type {
    return struct {
        const Self = @This();
        const Binding = bun.bindgen.Class(ClassSchema, Self);
        const DisposeSchema = ClassSchema.member("dispose");
        const AddressSchema = ClassSchema.member("address");
        const AddressResult = bun.bindgen.Return(AddressSchema);
        const CloseIdleConnectionsSchema = ClassSchema.member("closeIdleConnections");
        const DevelopmentSchema = ClassSchema.member("development");
        const FetchNativeSchema = ClassSchema.member("__fetch");
        const HostnameSchema = ClassSchema.member("hostname");
        const IdSchema = ClassSchema.member("id");
        const PendingRequestsSchema = ClassSchema.member("pendingRequests");
        const PendingWebSocketsSchema = ClassSchema.member("pendingWebSockets");
        const PortSchema = ClassSchema.member("port");
        const ProtocolSchema = ClassSchema.member("protocol");
        const PublishSchema = ClassSchema.member("publish");
        const RefSchema = ClassSchema.member("ref");
        const ReloadSchema = ClassSchema.member("reload");
        const RequestIPSchema = ClassSchema.member("requestIP");
        const RequestIPResult = bun.bindgen.Return(RequestIPSchema);
        const RequestIPDTO = @typeInfo(RequestIPResult).optional.child;
        const StopNativeSchema = ClassSchema.member("__stop");
        const SubscriberCountSchema = ClassSchema.member("subscriberCount");
        const TimeoutSchema = ClassSchema.member("timeout");
        const UnrefSchema = ClassSchema.member("unref");
        const UpgradeSchema = ClassSchema.member("upgrade");
        const URLSchema = ClassSchema.member("url");

        bindgen_state: bun.bindgen.ClassState = .{},
        server: ?bun.bindgen.BorrowedNative(Server, .vm) = null,

        fn native(this: *const Self) *Server {
            return this.server.?.get();
        }

        pub const destroy = finalize;

        fn finalize(this: *Self) void {
            if (this.server) |server| server.get().finalize();
            bun.destroy(this);
        }

        pub fn memoryUsage(this: *const Self, _: bun.bindgen.MemoryUsageContext(.vm)) usize {
            return @sizeOf(Self) + if (this.server) |server| server.get().memoryCost() else @as(usize, 0);
        }

        pub fn bindDispose(
            this: *Self,
            _: bun.bindgen.CallContext(DisposeSchema),
            _: bun.bindgen.Args(DisposeSchema),
        ) bun.JSError!void {
            this.native().disposeFromJS();
        }

        pub fn bindGetAddress(
            this: *Self,
            _: bun.bindgen.CallContext(AddressSchema),
            _: bun.bindgen.Args(AddressSchema),
        ) bun.JSError!AddressResult {
            return try this.native().getAddress(AddressResult);
        }

        pub fn bindCloseIdleConnections(
            this: *Self,
            _: bun.bindgen.CallContext(CloseIdleConnectionsSchema),
            _: bun.bindgen.Args(CloseIdleConnectionsSchema),
        ) bun.JSError!void {
            this.native().closeIdleConnections();
        }

        pub fn bindGetDevelopment(
            this: *Self,
            _: bun.bindgen.CallContext(DevelopmentSchema),
            _: bun.bindgen.Args(DevelopmentSchema),
        ) bun.JSError!bool {
            return this.native().getDevelopment();
        }

        pub fn bindFetchNative(
            this: *Self,
            context: bun.bindgen.CallContext(FetchNativeSchema),
            args: bun.bindgen.Args(FetchNativeSchema),
        ) bun.bindgen.CallError(FetchNativeSchema)!bun.bindgen.Return(FetchNativeSchema) {
            return try AnyServer.from(this.native()).fetchFromBinding(context, args);
        }

        pub fn bindGetHostname(
            this: *Self,
            _: bun.bindgen.CallContext(HostnameSchema),
            _: bun.bindgen.Args(HostnameSchema),
        ) bun.JSError!?bun.bindgen.DOMString {
            return this.native().getHostname();
        }

        pub fn bindGetId(
            this: *Self,
            _: bun.bindgen.CallContext(IdSchema),
            _: bun.bindgen.Args(IdSchema),
        ) bun.JSError!bun.bindgen.DOMString {
            return this.native().getId();
        }

        pub fn bindGetPendingRequests(
            this: *Self,
            _: bun.bindgen.CallContext(PendingRequestsSchema),
            _: bun.bindgen.Args(PendingRequestsSchema),
        ) bun.JSError!i32 {
            return this.native().getPendingRequests();
        }

        pub fn bindGetPendingWebSockets(
            this: *Self,
            _: bun.bindgen.CallContext(PendingWebSocketsSchema),
            _: bun.bindgen.Args(PendingWebSocketsSchema),
        ) bun.JSError!i32 {
            return this.native().getPendingWebSockets();
        }

        pub fn bindGetPort(
            this: *Self,
            _: bun.bindgen.CallContext(PortSchema),
            _: bun.bindgen.Args(PortSchema),
        ) bun.JSError!?u16 {
            return this.native().getPort();
        }

        pub fn bindGetProtocol(
            this: *Self,
            _: bun.bindgen.CallContext(ProtocolSchema),
            _: bun.bindgen.Args(ProtocolSchema),
        ) bun.JSError!bun.bindgen.DOMString {
            return this.native().getProtocol();
        }

        pub fn bindPublish(
            this: *Self,
            context: bun.bindgen.CallContext(PublishSchema),
            args: bun.bindgen.Args(PublishSchema),
        ) bun.bindgen.CallError(PublishSchema)!i64 {
            const topic = args.topic orelse return context.fail(.missing_topic, {});
            if (topic.length() == 0) return context.fail(.empty_topic, {});
            const message = args.message orelse return context.fail(.missing_message, {});
            return this.native().publish(topic, message, args.compress orelse true);
        }

        pub fn bindRef(
            this: *Self,
            _: bun.bindgen.CallContext(RefSchema),
            args: bun.bindgen.Args(RefSchema),
        ) bun.JSError!bun.bindgen.Return(RefSchema) {
            this.native().ref();
            return args.bindingThis.toOwned();
        }

        pub fn bindReload(
            this: *Self,
            context: bun.bindgen.CallContext(ReloadSchema),
            args: bun.bindgen.Args(ReloadSchema),
        ) bun.bindgen.CallError(ReloadSchema)!bun.bindgen.Return(ReloadSchema) {
            var result = try args.bindingThis.toOwned();
            errdefer result.deinit();
            try AnyServer.from(this.native()).reloadFromBinding(context, args);
            return result;
        }

        pub fn bindRequestIP(
            this: *Self,
            context: bun.bindgen.CallContext(RequestIPSchema),
            args: bun.bindgen.Args(RequestIPSchema),
        ) bun.bindgen.CallError(RequestIPSchema)!RequestIPResult {
            const request_value = args.request orelse return context.fail(.missing_request, {});
            return try this.native().requestIP(RequestIPDTO, request_value.get(Request));
        }

        pub fn bindStopNative(
            this: *Self,
            context: bun.bindgen.CallContext(StopNativeSchema),
            args: bun.bindgen.Args(StopNativeSchema),
        ) bun.JSError!bun.bindgen.Return(StopNativeSchema) {
            const abrupt = if (args.abrupt) |value| value orelse false else false;
            return this.native().stopFromJS(context, abrupt);
        }

        pub fn bindSubscriberCount(
            this: *Self,
            context: bun.bindgen.CallContext(SubscriberCountSchema),
            args: bun.bindgen.Args(SubscriberCountSchema),
        ) bun.bindgen.CallError(SubscriberCountSchema)!u32 {
            const topic = args.topic orelse return context.fail(.missing_topic, {});
            return this.native().subscriberCount(topic);
        }

        pub fn bindTimeout(
            this: *Self,
            context: bun.bindgen.CallContext(TimeoutSchema),
            args: bun.bindgen.Args(TimeoutSchema),
        ) bun.bindgen.CallError(TimeoutSchema)!void {
            const request_value = args.request orelse return context.fail(.missing_request, {});
            const seconds = args.seconds orelse return context.fail(.missing_seconds, {});
            this.native().timeout(request_value, seconds);
        }

        pub fn bindUnref(
            this: *Self,
            _: bun.bindgen.CallContext(UnrefSchema),
            args: bun.bindgen.Args(UnrefSchema),
        ) bun.JSError!bun.bindgen.Return(UnrefSchema) {
            this.native().unref();
            return args.bindingThis.toOwned();
        }

        pub fn bindUpgrade(
            this: *Self,
            context: bun.bindgen.CallContext(UpgradeSchema),
            args: bun.bindgen.Args(UpgradeSchema),
        ) bun.bindgen.CallError(UpgradeSchema)!bool {
            return try AnyServer.from(this.native()).upgradeFromBinding(context, args);
        }

        pub fn bindGetURL(
            this: *Self,
            context: bun.bindgen.CallContext(URLSchema),
            _: bun.bindgen.Args(URLSchema),
        ) bun.JSError!bun.bindgen.Return(URLSchema) {
            const url_string = try this.native().getURLAsString();
            var url = try bun.bindgen.DOMString.fromBunString(url_string);
            defer url.deinit();
            return (try context.engineIn("urls", "bunStringToJSDOMURL").call(.{ .value = url.operand() })).toOwned();
        }
    };
}

pub fn NewServer(protocol_enum: enum { http, https }) type {
    return struct {
        const ProductionClassSchema = switch (protocol_enum) {
            .http => HTTPServerBindingModule.class("HTTPServer"),
            .https => HTTPServerBindingModule.class("HTTPSServer"),
        };
        const DebugClassSchema = switch (protocol_enum) {
            .http => HTTPServerBindingModule.class("DebugHTTPServer"),
            .https => HTTPServerBindingModule.class("DebugHTTPSServer"),
        };

        const ThisServer = @This();
        const ProductionJSBinding = ServerJSBinding(ThisServer, ProductionClassSchema);
        const DebugJSBinding = ServerJSBinding(ThisServer, DebugClassSchema);
        const ProductionJS = bun.bindgen.Class(ProductionClassSchema, ProductionJSBinding);
        const DebugJS = bun.bindgen.Class(DebugClassSchema, DebugJSBinding);
        const ServerRouteListValue = ProductionJS.CachedSlot("routeList").OwnedValue;
        const AllClosedPromiseResult = bun.bindgen.Return(ProductionClassSchema.member("__stop"));
        const AllClosedPromise = bun.bindgen.StrongPromise(AllClosedPromiseResult);
        const StopCompletion = bun.bindgen.StandaloneCompletion(HTTPServerBindingModule.function("stopCompletion"));

        pub fn fromProductionClassRef(class_ref: anytype) *ThisServer {
            return class_ref.get(ProductionJSBinding).native();
        }

        pub fn fromDebugClassRef(class_ref: anytype) *ThisServer {
            return class_ref.get(DebugJSBinding).native();
        }

        pub const Handle = union(enum) {
            production: ProductionJS.Handle,
            debug: DebugJS.Handle,

            pub fn get(this: *const Handle) *ThisServer {
                return switch (this.*) {
                    .production => |*handle| handle.get().native(),
                    .debug => |*handle| handle.get().native(),
                };
            }

            pub fn deinit(this: *Handle) void {
                switch (this.*) {
                    .production => |*handle| handle.deinit(),
                    .debug => |*handle| handle.deinit(),
                }
            }
        };

        pub fn adoptClassRef(this: *ThisServer, global: *jsc.JSGlobalObject) bun.JSError!HTTPServerReference {
            return this.adoptClassRefAs(HTTPServerReference, global);
        }

        pub fn adoptClassRefAs(this: *ThisServer, comptime Reference: type, global: *jsc.JSGlobalObject) bun.JSError!Reference {
            if (this.config.isDevelopment()) {
                const binding = try bun.default_allocator.create(DebugJSBinding);
                binding.* = .{};
                var class_ref = try DebugJS.adoptNativeRef(binding, global);
                errdefer class_ref.deinit();
                try this.js_value.setStrongRef(&class_ref);
                binding.server = .init(this);
                return switch (protocol_enum) {
                    .http => .{ .debug_http = class_ref },
                    .https => .{ .debug_https = class_ref },
                };
            }

            const binding = try bun.default_allocator.create(ProductionJSBinding);
            binding.* = .{};
            var class_ref = try ProductionJS.adoptNativeRef(binding, global);
            errdefer class_ref.deinit();
            try this.js_value.setStrongRef(&class_ref);
            binding.server = .init(this);
            return switch (protocol_enum) {
                .http => .{ .http = class_ref },
                .https => .{ .https = class_ref },
            };
        }

        pub fn routeListSetCached(this: *ThisServer, route_list: *const ServerRouteListValue) bun.JSError!void {
            if (this.config.isDevelopment()) {
                try DebugJS.CachedSlot("routeList").setOwnedBrandedOnReference(&this.js_value, route_list);
            } else {
                try ProductionJS.CachedSlot("routeList").setOwnedBrandedOnReference(&this.js_value, route_list);
            }
        }

        fn routeListClearCached(this: *ThisServer) bun.JSError!void {
            if (this.config.isDevelopment()) {
                try DebugJS.CachedSlot("routeList").clearOnReference(&this.js_value);
            } else {
                try ProductionJS.CachedSlot("routeList").clearOnReference(&this.js_value);
            }
        }

        fn routeListGetCached(this: *ThisServer) bun.JSError!?ServerRouteListValue {
            return if (this.config.isDevelopment())
                DebugJS.CachedSlot("routeList").ownedBrandedFromReference(&this.js_value)
            else
                ProductionJS.CachedSlot("routeList").ownedBrandedFromReference(&this.js_value);
        }

        pub fn handlerCallback(this: *ThisServer, comptime slot_name: []const u8) bun.JSError!?bun.bindgen.Callback(bun.bindgen.CallbackSchema(callbackNameForSlot(slot_name))) {
            if (this.config.isDevelopment()) {
                return DebugJS.CachedSlot(slot_name).ownedCallbackFromReference(&this.js_value);
            }
            return ProductionJS.CachedSlot(slot_name).ownedCallbackFromReference(&this.js_value);
        }

        pub fn serverClassRef(this: *ThisServer) bun.JSError!HTTPServerReference {
            return this.serverClassRefAs(HTTPServerReference);
        }

        pub fn serverClassRefAs(this: *ThisServer, comptime Reference: type) bun.JSError!Reference {
            if (this.config.isDevelopment()) {
                const class_ref = (try this.js_value.toOwnedClassRef(DebugClassSchema)) orelse
                    @panic("HTTP server wrapper is unavailable");
                return switch (protocol_enum) {
                    .http => .{ .debug_http = class_ref },
                    .https => .{ .debug_https = class_ref },
                };
            }
            const class_ref = (try this.js_value.toOwnedClassRef(ProductionClassSchema)) orelse
                @panic("HTTP server wrapper is unavailable");
            return switch (protocol_enum) {
                .http => .{ .http = class_ref },
                .https => .{ .https = class_ref },
            };
        }

        pub const FetchCallbackCall = struct {
            invocation: ServeFetchCallback.Invocation,

            pub fn init(call: *@This(), server: *ThisServer) bun.JSError!void {
                var callback = (try server.handlerCallback("onRequest")) orelse
                    @panic("configured fetch callback slot is empty");
                callback.moveIntoInvocation(&call.invocation);
            }

            pub fn initWithCallback(call: *@This(), callback: bun.bindgen.CallbackView(ServeFetchCallbackType)) bun.JSError!void {
                var owned = try callback.toOwned();
                owned.moveIntoInvocation(&call.invocation);
            }

            pub fn deinit(call: *@This()) void {
                call.invocation.deinit();
            }

            pub fn invokeWithRequestRef(
                call: *@This(),
                server: *ThisServer,
                request_ref: *const RequestReference,
            ) bun.JSError!ServeCallbackResult {
                var server_ref = try server.serverClassRef();
                defer deinitHTTPServerReference(&server_ref);
                return call.invocation.call(.{
                    .bindingThis = server_ref.operand(&call.invocation),
                    .request = request_ref.operand(&call.invocation),
                    .server = server_ref.operand(&call.invocation),
                });
            }
        };

        pub const ErrorCallbackCall = struct {
            invocation: ServeErrorCallback.Invocation,

            pub fn init(call: *@This(), server: *ThisServer) bun.JSError!void {
                var callback = (try server.handlerCallback("onError")) orelse
                    @panic("configured server error callback slot is empty");
                callback.moveIntoInvocation(&call.invocation);
            }

            pub fn deinit(call: *@This()) void {
                call.invocation.deinit();
            }

            pub fn invoke(call: *@This(), error_value: *const bun.bindgen.Root) bun.JSError!ServeCallbackResult {
                return call.invocation.call(.{
                    .error_value = error_value.operand(&call.invocation),
                });
            }

            pub fn deinitResult(_: *@This(), result: *ServeCallbackResult) void {
                deinitServeCallbackResult(result);
            }
        };

        pub fn writeHandlerSlots(this: *ThisServer) bun.JSError!void {
            if (this.config.isDevelopment()) {
                var wrapper = (try this.js_value.toOwnedClassRef(DebugClassSchema)) orelse @panic("live HTTP server has no wrapper");
                defer wrapper.deinit();
                this.writeHandlerSlotsOnOwned(DebugJS, &wrapper);
            } else {
                var wrapper = (try this.js_value.toOwnedClassRef(ProductionClassSchema)) orelse @panic("live HTTP server has no wrapper");
                defer wrapper.deinit();
                this.writeHandlerSlotsOnOwned(ProductionJS, &wrapper);
            }
        }

        pub const ssl_enabled = protocol_enum == .https;

        pub const RequestContext = NewRequestContext(ssl_enabled, @This(), false);
        const has_h3 = ssl_enabled;
        pub const H3RequestContext = if (has_h3) NewRequestContext(ssl_enabled, @This(), true) else void;

        pub const App = uws.NewApp(ssl_enabled);
        app: ?*App = null,
        listener: ?*App.ListenSocket = null,
        h3_app: if (has_h3) ?*uws.H3.App else void = if (has_h3) null else {},
        h3_listener: if (has_h3) ?*uws.H3.ListenSocket else void = if (has_h3) null else {},
        /// Cached `h3=":<port>"; ma=86400` value for Alt-Svc on H1 responses;
        /// formatted once in onH3Listen so renderMetadata doesn't reformat.
        h3_alt_svc: if (has_h3) [:0]const u8 else void = if (has_h3) "" else {},
        js_value: bun.bindgen.WrapperReference(.{ ProductionClassSchema, DebugClassSchema }) = .empty(),
        finalizer_queue: *jsc.NativeFinalizerQueue,
        deinit_node: jsc.NativeFinalizerQueue.Node = .{},
        vm: *jsc.VirtualMachine,
        globalThis: *JSGlobalObject,
        base_url_string_for_joining: string = "",
        config: ServerConfig = ServerConfig{},
        pending_requests: usize = 0,
        request_pool_allocator: *RequestContext.RequestContextStackAllocator = undefined,
        h3_request_pool_allocator: if (has_h3) *H3RequestContext.RequestContextStackAllocator else void = if (has_h3) undefined else {},
        all_closed_promise: AllClosedPromise = .empty,
        all_closed_completion: ?StopCompletion.Owned = null,

        listen_callback: jsc.AnyTask = undefined,
        allocator: std.mem.Allocator,
        poll_ref: Async.KeepAlive = .{},

        flags: packed struct(u3) {
            deinit_scheduled: bool = false,
            terminated: bool = false,
            processing_idle: bool = false,
        } = .{},

        plugins: ?*ServePlugins = null,

        dev_server: ?*bun.bake.DevServer,

        routes: ?*RouteGeneration = null,
        dispatch_routes: ?*RouteGeneration = null,
        dispatch_route_list: ?*const ServerRouteListValue = null,
        routing_dispatch_depth: usize = 0,

        on_clienterror: ?ServerClientErrorCallback = null,

        inspector_server_id: jsc.Debugger.DebuggerId = .init(0),

        pub const UserRoute = struct {
            id: u32,
            server: *ThisServer,
            route: ServerConfig.RouteDeclaration,

            pub fn deinit(this: *UserRoute) void {
                this.route.deinit();
            }
        };

        const UserRoutes = struct {
            const RefCount = bun.ptr.RefCount(@This(), "ref_count", @This().deinit, .{});
            pub const ref = RefCount.ref;
            pub const deref = RefCount.deref;

            ref_count: RefCount = .init(),
            items: std.ArrayList(UserRoute) = .empty,

            fn create(server: *ThisServer, builders: []const ServerConfig.UserRouteBuilder) bun.OOM!*UserRoutes {
                const result = try bun.default_allocator.create(UserRoutes);
                result.* = .{};
                errdefer result.deref();
                try result.items.ensureTotalCapacity(bun.default_allocator, builders.len);
                for (builders, 0..) |builder, i| {
                    const id = std.math.cast(u32, i) orelse return error.OutOfMemory;
                    result.items.appendAssumeCapacity(.{
                        .id = id,
                        .server = server,
                        .route = .{
                            .path = try bun.default_allocator.dupeSentinel(u8, builder.route.path, 0),
                            .method = builder.route.method,
                        },
                    });
                }
                return result;
            }

            fn deinit(this: *UserRoutes) void {
                for (this.items.items) |*route| route.deinit();
                this.items.deinit(bun.default_allocator);
                bun.destroy(this);
            }
        };

        pub const RouteGeneration = struct {
            const RefCount = bun.ptr.RefCount(@This(), "ref_count", @This().deinit, .{});
            pub const ref = RefCount.ref;
            pub const deref = RefCount.deref;
            const HTTPRoutes = @import("./Routes.zig").Routes(ssl_enabled, false);
            const H3Routes = @import("./Routes.zig").Routes(ssl_enabled, true);

            ref_count: RefCount = .init(),
            http: HTTPRoutes,
            h3: if (has_h3) H3Routes else void,
            users: *UserRoutes,
            static_routes: std.ArrayList(ServerConfig.StaticRouteEntry) = .empty,

            fn memoryCost(this: *const RouteGeneration) usize {
                var size = @sizeOf(RouteGeneration) + this.http.memoryCost() +
                    @sizeOf(UserRoutes) + this.users.items.capacity * @sizeOf(UserRoute) +
                    this.static_routes.capacity * @sizeOf(ServerConfig.StaticRouteEntry);
                if (comptime has_h3) size += this.h3.memoryCost();
                for (this.users.items.items) |entry| size += entry.route.path.len;
                for (this.static_routes.items) |entry| size += entry.path.len;
                return size;
            }

            fn deinit(this: *RouteGeneration) void {
                this.http.deinit();
                if (comptime has_h3) this.h3.deinit();
                this.users.deref();
                for (this.static_routes.items) |*entry| entry.deinit();
                this.static_routes.deinit(bun.default_allocator);
                bun.destroy(this);
            }
        };

        const RouteOptions = struct {
            config: *const ServerConfig,
            preserve_users: bool,
            fetch: bool,
            node_http: bool,
            websocket: ?*const WebSocketServerContext,
        };

        const PreparedRoutes = struct {
            generation: ?*RouteGeneration,
            route_list: ?ServerRouteListValue = null,
            html_router: bun.bake.DevServer.HTMLRouter = .empty,
            html_allocator: std.mem.Allocator,
            plugins: ?*ServePlugins = null,

            fn deinit(this: *PreparedRoutes) void {
                if (this.route_list) |*value| value.deinit();
                this.html_router.deinit(this.html_allocator);
                if (this.plugins) |plugins| plugins.deref();
                if (this.generation) |generation| generation.deref();
            }
        };

        pub fn userRouteSlice(this: *const ThisServer) []const UserRoute {
            return if (this.routes) |routes| routes.users.items.items else &.{};
        }

        pub fn retainRoutes(this: *ThisServer) ?*RouteGeneration {
            const routes = this.dispatch_routes orelse this.routes orelse return null;
            routes.ref();
            return routes;
        }

        fn dispatchRequest(this: *ThisServer, request: *uws.Request, response: *App.Response) void {
            this.dispatchRequestFor(false, request, response);
        }

        fn dispatchH3Request(this: *ThisServer, request: *uws.H3.Request, response: *uws.H3.Response) void {
            this.dispatchRequestFor(true, request, response);
        }

        fn dispatchRequestFor(this: *ThisServer, comptime http3: bool, request: anytype, response: anytype) void {
            const native_response: uws.AnyResponse = if (http3) .{ .H3 = response } else if (ssl_enabled) .{ .SSL = response } else .{ .TCP = response };
            const generation = this.routes orelse {
                native_response.forceClose();
                return;
            };
            generation.ref();
            defer generation.deref();
            this.routing_dispatch_depth += 1;
            defer {
                this.routing_dispatch_depth -= 1;
                this.deinitIfWeCan();
            }

            // The generated cell owns the persistent root; a dispatch pins its own snapshot across reentrant reloads.
            var route_list = if (generation.users.items.items.len > 0)
                this.routeListGetCached() catch |err| {
                    native_response.forceClose();
                    this.globalThis.reportActiveExceptionAsUnhandled(err);
                    return;
                }
            else
                null;
            defer if (route_list) |*value| value.deinit();
            const previous_routes = this.dispatch_routes;
            const previous_list = this.dispatch_route_list;
            this.dispatch_routes = generation;
            this.dispatch_route_list = if (route_list) |*value| value else null;
            defer {
                this.dispatch_routes = previous_routes;
                this.dispatch_route_list = previous_list;
            }

            const matched = (if (http3) generation.h3.dispatch(request, response) else generation.http.dispatch(request, response)) catch |err| {
                native_response.forceClose();
                this.globalThis.reportActiveExceptionAsUnhandled(err);
                return;
            };
            if (!matched) native_response.forceClose();
        }

        fn publishRoutes(this: *ThisServer, prepared: *PreparedRoutes) void {
            const old = this.routes;
            this.routes = prepared.generation.?;
            prepared.generation = null;
            this.app.?.setRequestHandler(*ThisServer, this, dispatchRequest);
            if (comptime has_h3) if (this.h3_app) |app| app.setRequestHandler(*ThisServer, this, dispatchH3Request);
            if (this.dev_server) |dev| {
                dev.server = AnyServer.from(this);
                std.mem.swap(bun.bake.DevServer.HTMLRouter, &dev.html_router, &prepared.html_router);
            }
            if (prepared.plugins) |plugins| {
                this.plugins = plugins;
                prepared.plugins = null;
            }
            if (this.config.websocket) |*websocket| {
                websocket.handler.state.app = if (ssl_enabled) .{ .https = this.app.? } else .{ .http = this.app.? };
                websocket.handler.flags.ssl = ssl_enabled;
            }
            if (this.config.onNodeHTTPRequest.configured) {
                bun.bindgen.Engine(NodeHTTPAssignOnNodeJSCompatSchema).call(.{
                    .kind = node_http_response_kind,
                    .app = @ptrCast(this.app.?),
                });
            }
            if (old) |routes| routes.deref();
        }

        fn consumeRouteBuilders(config: *ServerConfig) void {
            for (config.user_routes_to_build.items) |*builder| builder.deinit();
            config.user_routes_to_build.clearAndFree();
        }

        /// Returns:
        /// - .ready if no plugin has to be loaded
        /// - .err if there is a cached failure. Currently, this requires restarting the entire server.
        /// - .pending if `callback` was stored. It will call `onPluginsResolved` or `onPluginsRejected` later.
        pub fn getOrLoadPlugins(server: *ThisServer, callback: ServePlugins.Callback) ServePlugins.GetOrStartLoadResult {
            if (server.plugins) |p| {
                return p.getOrStartLoad(server.globalThis, callback) catch |err| switch (err) {
                    error.JSError => std.debug.panic("unhandled exception from ServePlugins.getStartOrLoad", .{}),
                    error.OutOfMemory => bun.outOfMemory(),
                    error.JSTerminated => std.debug.panic("unhandled exception from ServePlugins.getStartOrLoad", .{}),
                };
            }
            // no plugins
            return .{ .ready = null };
        }

        pub fn subscriberCount(this: *ThisServer, topic_value: bun.bindgen.DOMStringView) bun.OOM!u32 {
            const topic = try topic_value.toUTF8(bun.default_allocator);
            defer topic.deinit();

            if (topic.length() == 0) {
                return 0;
            }

            return this.app.?.numSubscribers(topic.slice());
        }

        pub fn requestIP(this: *ThisServer, comptime DTO: type, request: *jsc.WebCore.Request) bun.OOM!?DTO {
            if (this.config.address == .unix) return null;
            const info = request.request_context.getRemoteSocketInfo() orelse return null;
            return try SocketAddress.createDTO(DTO, info.ip, @intCast(info.port), info.is_ipv6);
        }

        pub fn memoryCost(this: *ThisServer) usize {
            return @sizeOf(ThisServer) +
                this.base_url_string_for_joining.len +
                this.config.memoryCost() +
                (if (this.routes) |routes| routes.memoryCost() else 0) +
                (if (this.dev_server) |dev| dev.memoryCost() else 0);
        }

        pub fn timeout(
            this: *ThisServer,
            request_or_response: anytype,
            seconds: u32,
        ) void {
            if (this.config.address == .unix) {
                return;
            }

            switch (request_or_response) {
                .request => |request_value| {
                    _ = request_value.get(Request).request_context.setTimeout(seconds);
                },
                .response => |response_value| {
                    _ = response_value.get(NodeHTTPResponse.JSBinding).response.get().setTimeout(seconds);
                },
            }
        }

        pub fn setIdleTimeout(this: *ThisServer, seconds: c_uint) void {
            this.config.idleTimeout = @truncate(@min(seconds, 255));
        }

        pub fn setFlags(this: *ThisServer, require_host_header: bool, use_strict_method_validation: bool) void {
            if (this.app) |app| {
                app.setFlags(require_host_header, use_strict_method_validation);
            }
        }

        pub fn setMaxHTTPHeaderSize(this: *ThisServer, max_header_size: u64) void {
            if (this.app) |app| {
                app.setMaxHTTPHeaderSize(max_header_size);
            }
        }

        pub fn appendStaticRoute(this: *ThisServer, path: []const u8, route: AnyRoute, method: HTTP.Method.Optional) !void {
            try this.config.appendStaticRoute(path, route, method);
        }

        pub fn publish(this: *ThisServer, topic_value: bun.bindgen.DOMStringView, message_value: anytype, compress: bool) bun.OOM!i64 {
            if (this.config.websocket == null)
                return 0;

            const app = this.app.?;
            const topic_slice = try topic_value.toUTF8(bun.default_allocator);
            defer topic_slice.deinit();
            return switch (message_value) {
                .buffer => |buffer| publishBytes(app, topic_slice.slice(), buffer.unsafePtr("the generated entry frame owns the message lease until synchronous publication consumes or copies its bytes"), .binary, compress),
                .string => |string_value| string: {
                    const message = try string_value.toUTF8(bun.default_allocator);
                    defer message.deinit();
                    break :string publishBytes(app, topic_slice.slice(), message.slice(), .text, compress);
                },
            };
        }

        fn publishBytes(app: anytype, topic: []const u8, message: []const u8, opcode: uws.Opcode, compress: bool) i64 {
            const published = uws.AnyWebSocket.publishWithOptions(ssl_enabled, app, topic, message, opcode, compress);
            return if (published) @intCast(@as(u31, @truncate(message.len))) else 0;
        }

        const ResolvedUpgradeOptions = struct {
            data: ?bun.bindgen.AnyView = null,
            headers: ?*WebCore.FetchHeaders = null,
        };

        fn resolveUpgradeOptions(context: anytype, upgrade_options: anytype) bun.JSError!ResolvedUpgradeOptions {
            const converted = try upgrade_options.convert(context);
            const resolved = converted.value orelse return .{};
            return .{
                .data = resolved.data,
                .headers = if (resolved.headers) |headers| headers.get() else null,
            };
        }

        fn snapshotUpgradeHeader(
            request: *Request,
            upgrader: *RequestContext,
            comptime header: WebCore.FetchHeaders.HTTPHeaderName,
            comptime name: []const u8,
        ) bun.OOM!bun.String.Slice {
            if (request.getFetchHeaders()) |headers| {
                if (try headers.fastGet(header)) |value| {
                    var owned = value;
                    defer owned.deinit();
                    var bytes = try owned.toUTF8(bun.default_allocator);
                    if (bytes.length() != 0) return bytes;
                    bytes.deinit();
                }
            }
            if (upgrader.req) |raw| {
                if (raw.header(name)) |bytes| return bun.String.Slice.initDupe(bun.default_allocator, bytes);
            }
            return .empty;
        }

        pub fn onUpgradeFromBinding(
            this: *ThisServer,
            context: anytype,
            object: anytype,
            optional: anytype,
        ) bun.bindgen.CallError(@TypeOf(context))!bool {
            const globalThis = context.viewToken().globalObject();
            if (this.config.websocket == null) {
                return context.fail(.websocket_not_enabled, {});
            }

            if (this.flags.terminated or !this.hasListener()) {
                return false;
            }

            return switch (object) {
                .response => |response_value| response: {
                    const nodeHttpResponse = response_value.get(NodeHTTPResponse.JSBinding).response.get();
                    if (nodeHttpResponse.core.flags.ended or nodeHttpResponse.core.flags.socket_closed) {
                        return false;
                    }

                    const resolved_options = try resolveUpgradeOptions(context, optional);
                    const fetch_headers_to_use = resolved_options.headers;

                    var sec_websocket_protocol: bun.TextView = .empty;
                    var sec_websocket_extensions: bun.TextView = .empty;

                    // Retain UTF-8 storage while removing handshake fields from response headers.
                    var sec_websocket_protocol_owned = bun.String.Slice.empty;
                    defer sec_websocket_protocol_owned.deinit();
                    var sec_websocket_extensions_owned = bun.String.Slice.empty;
                    defer sec_websocket_extensions_owned.deinit();

                    if (fetch_headers_to_use) |headers| {
                        if (try headers.fastGet(.SecWebSocketProtocol)) |owned_protocol| {
                            var protocol = owned_protocol;
                            defer protocol.deinit();
                            sec_websocket_protocol_owned = try protocol.toUTF8(bun.default_allocator);
                            sec_websocket_protocol = .{ .utf8 = sec_websocket_protocol_owned.slice() };
                            headers.fastRemove(.SecWebSocketProtocol);
                        }

                        if (try headers.fastGet(.SecWebSocketExtensions)) |owned_extensions| {
                            var extensions = owned_extensions;
                            defer extensions.deinit();
                            sec_websocket_extensions_owned = try extensions.toUTF8(bun.default_allocator);
                            sec_websocket_extensions = .{ .utf8 = sec_websocket_extensions_owned.slice() };
                            headers.fastRemove(.SecWebSocketExtensions);
                        }
                    }

                    const ws = try nodeHttpResponse.prepareWebSocket(resolved_options.data) orelse return false;
                    var upgrade_started = false;
                    defer if (!upgrade_started) ws.cancelBeforeUpgrade();

                    const upgraded = try nodeHttpResponse.upgrade(context, ws, sec_websocket_protocol, sec_websocket_extensions, fetch_headers_to_use);
                    upgrade_started = upgraded;
                    break :response upgraded;
                },
                .request => |request_value| request_branch: {
                    const request = request_value.get(Request);

                    var upgrader = request.request_context.get(RequestContext) orelse return false;

                    if (upgrader.isAbortedOrEnded()) {
                        return false;
                    }

                    const resp = upgrader.resp.?;
                    const ctx = switch (upgrader.upgrade_context) {
                        .available => |value| value,
                        .none, .consumed => return false,
                    };

                    // Keep the request context alive until ownership transfers to the WebSocket.
                    upgrader.ref();
                    defer upgrader.deref();

                    var sec_websocket_key = try snapshotUpgradeHeader(request, upgrader, .SecWebSocketKey, "sec-websocket-key");
                    defer sec_websocket_key.deinit();
                    var sec_websocket_protocol = try snapshotUpgradeHeader(request, upgrader, .SecWebSocketProtocol, "sec-websocket-protocol");
                    defer sec_websocket_protocol.deinit();
                    var sec_websocket_extensions = try snapshotUpgradeHeader(request, upgrader, .SecWebSocketExtensions, "sec-websocket-extensions");
                    defer sec_websocket_extensions.deinit();

                    if (sec_websocket_key.length() == 0) return false;

                    const resolved_options = try resolveUpgradeOptions(context, optional);
                    if (upgrader.isAbortedOrEnded() or upgrader.didUpgradeWebSocket()) return false;
                    const fetch_headers_to_use = resolved_options.headers;

                    if (fetch_headers_to_use) |headers| {
                        if (try headers.fastGet(.SecWebSocketProtocol)) |owned_protocol| {
                            var protocol = owned_protocol;
                            defer protocol.deinit();
                            const replacement = try protocol.toUTF8(bun.default_allocator);
                            sec_websocket_protocol.deinit();
                            sec_websocket_protocol = replacement;
                            headers.fastRemove(.SecWebSocketProtocol);
                        }

                        if (try headers.fastGet(.SecWebSocketExtensions)) |owned_extensions| {
                            var extensions = owned_extensions;
                            defer extensions.deinit();
                            const replacement = try extensions.toUTF8(bun.default_allocator);
                            sec_websocket_extensions.deinit();
                            sec_websocket_extensions = replacement;
                            headers.fastRemove(.SecWebSocketExtensions);
                        }
                    }

                    const ws = try ServerWebSocket.init(&this.config.websocket.?.handler, resolved_options.data);
                    var upgrade_started = false;
                    defer if (!upgrade_started) ws.cancelBeforeUpgrade();

                    if (upgrader.isAbortedOrEnded() or upgrader.didUpgradeWebSocket()) {
                        return false;
                    }

                    var cookie_headers: ?WebCore.CookieMapEngine.PreparedHeaders = if (upgrader.cookies) |*cookies|
                        try WebCore.CookieMapEngine.prepare(cookies.get(), globalThis)
                    else
                        null;
                    defer if (cookie_headers) |*prepared| prepared.deinit();
                    if (upgrader.isAbortedOrEnded() or upgrader.didUpgradeWebSocket()) {
                        return false;
                    }
                    var preparation = resp.prepareUpgrade(sec_websocket_key.slice(), sec_websocket_protocol.slice(), sec_websocket_extensions.slice(), ctx) catch |err| return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        error.InvalidWebSocketExtensions => context.fail(.invalid_websocket_extensions, {}),
                        error.WebSocketCompressionInitializationFailed => context.fail(.websocket_compression_initialization_failed, {}),
                        error.InvalidWebSocketKey => context.fail(.invalid_websocket_key, {}),
                        error.InvalidWebSocketProtocol => context.fail(.invalid_websocket_protocol, {}),
                        error.ResponseAlreadyStarted => false,
                    };
                    defer preparation.deinit();
                    if (fetch_headers_to_use) |headers| try headers.appendToUpgrade(&preparation);
                    if (cookie_headers) |*headers| try WebCore.CookieMapEngine.appendToUpgrade(headers, &preparation);
                    var prepared_upgrade = try preparation.finish();
                    defer prepared_upgrade.deinit();
                    var cookies_to_write: ?WebCore.CookieMap.Owner = if (upgrader.cookies) |*cookies| cookies.take() else null;
                    upgrader.cookies = null;
                    defer {
                        if (cookies_to_write) |*cookies| cookies.deinit();
                    }

                    upgrader.upgrade_context = .consumed;
                    const signal = upgrader.signal;
                    upgrader.signal = null;
                    ws.attachSignal(signal);
                    upgrader.resp = null;
                    request.request_context = AnyRequestContext.Null;
                    upgrader.request_weakref.deref();

                    resp.clearAborted();
                    resp.clearOnData();
                    resp.clearOnWritable();
                    resp.clearTimeout();

                    upgrader.deref();

                    upgrade_started = true;
                    _ = prepared_upgrade.upgrade(*ServerWebSocket, ws);

                    break :request_branch true;
                },
            };
        }

        pub fn onReloadFromZig(this: *ThisServer, new_config: *ServerConfig) bun.JSError!void {
            if (this.config.isDevelopment()) {
                var wrapper = (try this.js_value.toOwnedClassRef(DebugClassSchema)) orelse @panic("live HTTP server has no wrapper");
                defer wrapper.deinit();
                try this.reloadWithWrapper(DebugJS, &wrapper, new_config);
            } else {
                var wrapper = (try this.js_value.toOwnedClassRef(ProductionClassSchema)) orelse @panic("live HTTP server has no wrapper");
                defer wrapper.deinit();
                try this.reloadWithWrapper(ProductionJS, &wrapper, new_config);
            }
        }

        fn writeCallbackSlotOnOwned(comptime JS: type, wrapper: anytype, comptime name: []const u8, pending: anytype) void {
            if (pending.takePending()) |owned| {
                var callback = owned;
                defer callback.deinit();
                JS.CachedSlot(name).setOwnedCallbackOnOwned(wrapper, &callback);
            } else if (!pending.configured) {
                JS.CachedSlot(name).clearOwned(wrapper);
            }
        }

        fn writeHandlerSlotsOnOwned(this: *ThisServer, comptime JS: type, wrapper: anytype) void {
            writeCallbackSlotOnOwned(JS, wrapper, "onRequest", &this.config.onRequest);
            writeCallbackSlotOnOwned(JS, wrapper, "onError", &this.config.onError);
            writeCallbackSlotOnOwned(JS, wrapper, "onNodeHTTPRequest", &this.config.onNodeHTTPRequest);
            if (this.config.websocket) |*websocket| {
                websocket.handler.state.server = AnyServer.from(this);
                inline for (.{
                    .{ "wsOnOpen", "onOpen" },
                    .{ "wsOnMessage", "onMessage" },
                    .{ "wsOnClose", "onClose" },
                    .{ "wsOnDrain", "onDrain" },
                    .{ "wsOnError", "onError" },
                    .{ "wsOnPing", "onPing" },
                    .{ "wsOnPong", "onPong" },
                }) |fields| writeCallbackSlotOnOwned(JS, wrapper, fields[0], &@field(websocket.handler, fields[1]));
            } else {
                inline for (.{ "wsOnOpen", "wsOnMessage", "wsOnClose", "wsOnDrain", "wsOnError", "wsOnPing", "wsOnPong" }) |name| JS.CachedSlot(name).clearOwned(wrapper);
            }
        }

        fn reloadWithWrapper(this: *ThisServer, comptime JS: type, wrapper: anytype, new_config: *ServerConfig) bun.JSError!void {
            var prepared = try this.prepareRoutes(.{
                .config = new_config,
                .preserve_users = !new_config.had_routes_object,
                .fetch = new_config.onRequest.configured or this.config.onRequest.configured,
                .node_http = new_config.onNodeHTTPRequest.configured,
                .websocket = if (new_config.websocket) |*value| value else if (this.config.websocket) |*value| value else null,
            });
            defer prepared.deinit();

            if (new_config.onRequest.configured) this.config.onRequest.moveFrom(&new_config.onRequest);
            this.config.onNodeHTTPRequest.moveFrom(&new_config.onNodeHTTPRequest);
            if (new_config.onError.configured) this.config.onError.moveFrom(&new_config.onError);
            if (new_config.websocket) |websocket| {
                const state = if (this.config.websocket) |old| old.handler.state else websocket.handler.state;
                if (this.config.websocket) |*old| old.handler.deinitPendingCallbacks();
                this.config.websocket = websocket;
                new_config.websocket = null;
                this.config.websocket.?.handler.state = state;
            }
            std.mem.swap(@TypeOf(this.config.static_routes), &this.config.static_routes, &new_config.static_routes);
            std.mem.swap(@TypeOf(this.config.negative_routes), &this.config.negative_routes, &new_config.negative_routes);
            this.writeHandlerSlotsOnOwned(JS, wrapper);
            if (prepared.route_list) |*value| {
                JS.CachedSlot("routeList").setOwnedBrandedOnOwned(wrapper, value);
            } else {
                JS.CachedSlot("routeList").clearOwned(wrapper);
            }
            this.publishRoutes(&prepared);
            consumeRouteBuilders(new_config);

            if (this.inspector_server_id.toOptional().unwrap() != null) {
                if (this.vm.debugger) |*debugger| {
                    debugger.http_server_agent.notifyServerRoutesUpdated(AnyServer.from(this)) catch |err|
                        this.globalThis.reportActiveExceptionAsUnhandled(err);
                }
            }
        }

        pub fn reloadStaticRoutes(this: *ThisServer) bun.JSError!bool {
            if (this.app == null) return false;
            try this.config.normalizeStaticRoutes();
            var prepared = try this.prepareRoutes(.{
                .config = &this.config,
                .preserve_users = true,
                .fetch = this.config.onRequest.configured,
                .node_http = this.config.onNodeHTTPRequest.configured,
                .websocket = if (this.config.websocket) |*value| value else null,
            });
            defer prepared.deinit();
            this.publishRoutes(&prepared);
            return true;
        }

        pub fn onReloadFromBinding(
            this: *ThisServer,
            context: anytype,
            reload_options: anytype,
        ) !void {
            const globalThis = context.viewToken().globalObject();
            const options_argument = reload_options orelse {
                return globalThis.throwNotEnoughArguments("reload", 1, 0);
            };

            var new_config: ServerConfig = .{};
            defer new_config.deinit();
            try ServerConfig.fromSchema(globalThis, context, &new_config, @as(?@TypeOf(options_argument), options_argument), .{
                .allow_bake_config = false,
                .has_user_routes = this.userRouteSlice().len > 0,
            });
            if (globalThis.hasException()) {
                return error.JSError;
            }

            try this.onReloadFromZig(&new_config);
        }

        fn rejectedFetchPromise(context: anytype, message: []const u8) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
            var bound_message = try bun.bindgen.DOMString.fromUTF8(message);
            defer bound_message.deinit();
            const error_value = try context.engineIn("errors", "createError").call(.{ .message = bound_message.operand() });
            return context.promiseRejectedWithoutNotifying(error_value.operand(context).asEngine());
        }

        pub fn onFetchFromBinding(
            this: *ThisServer,
            context: anytype,
            input: anytype,
            fetch_options: anytype,
        ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
            const ctx = context.viewToken().globalObject();
            if (!this.config.onRequest.configured) {
                return rejectedFetchPromise(context, "fetch() requires the server to have a fetch handler");
            }

            const deferred_input = input orelse {
                return rejectedFetchPromise(context, WebCore.Fetch.fetch_error_no_args);
            };
            const converted_input = try deferred_input.convert(context);
            const first_arg = converted_input.value;

            var headers: ?WebCore.FetchHeaders.Owner = null;
            defer if (headers) |*value| value.deinit();
            var method = HTTP.Method.GET;
            var body: jsc.WebCore.Body.Value = .{ .Null = {} };
            defer body.deinit();
            var existing_request: WebCore.Request = undefined;
            // TODO: set Host header
            // TODO: set User-Agent header
            // TODO: unify with fetch() implementation.
            switch (first_arg) {
                .url => |url_value| {
                    const url_zig_str = try url_value.toUTF8(bun.default_allocator);
                    defer url_zig_str.deinit();
                    const temp_url_str = url_zig_str.slice();

                    if (temp_url_str.len == 0) {
                        return rejectedFetchPromise(context, jsc.WebCore.Fetch.fetch_error_blank_url);
                    }

                    var url = URL.parse(temp_url_str);

                    // URL.parse borrows this buffer until request_url copies it.
                    const owned_url_buf: []const u8 = if (url.hostname.len == 0)
                        try strings.append(this.allocator, this.base_url_string_for_joining, url.pathname)
                    else
                        try this.allocator.dupe(u8, temp_url_str);
                    defer this.allocator.free(owned_url_buf);
                    url = URL.parse(owned_url_buf);

                    if (fetch_options) |lazy_options| {
                        const converted = try lazy_options.convert(context);
                        switch (converted.value) {
                            .ignored => {},
                            .options => |*resolved_options| {
                                if (resolved_options.method) |*method_input| switch (method_input.*) {
                                    .string => |*method_value| {
                                        var method_slice = try method_value.toUTF8(bun.default_allocator);
                                        defer method_slice.deinit();
                                        method = HTTP.Method.which(method_slice.slice()) orelse method;
                                    },
                                    .ignored => {},
                                };
                                if (resolved_options.headers) |*headers_ref| {
                                    headers = try headers_ref.get().cloneThis();
                                }
                                if (resolved_options.body) |*body_input| switch (body_input.*) {
                                    .blob => |*blob_ref| body = .{ .Blob = try blob_ref.get().dupe() },
                                    .ignored => return rejectedFetchPromise(context, "fetch() received invalid body"),
                                };
                            },
                        }
                    }

                    var request_url = try bun.bindgen.DOMString.fromUTF8(url.href);
                    errdefer request_url.deinit();
                    const request_body = try this.vm.initRequestBodyValue(body);
                    body = .Used;
                    existing_request = Request.init2(request_url, headers, request_body, method);
                    headers = null;
                },
                .request => |request_ref| existing_request = try request_ref.get(Request).cloneValue(ctx),
                .undefined_value => return context.fail(.invalid_undefined, {}),
                .null_value => return context.fail(.invalid_null, {}),
                .boolean => return context.fail(.invalid_boolean, {}),
                .number => return context.fail(.invalid_number, {}),
                .bigint => return context.fail(.invalid_bigint, {}),
                .symbol => return context.fail(.invalid_symbol, {}),
                .invalid => return context.fail(.invalid_object, {}),
            }

            const request = bun.default_allocator.create(Request) catch |err| {
                existing_request.finalizeWithoutDeinit();
                existing_request.body.deinit();
                return err;
            };
            request.* = existing_request;
            var request_ref = try request.toClassRef(this.globalThis);
            defer request_ref.deinit();
            var callback_call: FetchCallbackCall = undefined;
            try callback_call.init(this);
            defer callback_call.deinit();
            var response_value = callback_call.invokeWithRequestRef(this, &request_ref) catch |err| {
                return switch (err) {
                    error.JSError => context.promiseFromPendingException(),
                    error.OutOfMemory, error.JSTerminated => err,
                };
            };
            defer deinitServeCallbackResult(&response_value);

            const fetch_result: bun.bindgen.Return(@TypeOf(context)) = switch (response_value) {
                .response => |*response_ref| response: {
                    response_ref.get(jsc.WebCore.Response).setUrl(request.url.clone());
                    var retained = try response_ref.toOwned();
                    defer retained.deinit();
                    break :response try context.promiseResolved(retained);
                },
                .promise => |promise| promise: {
                    var owned_promise = try promise.toOwned();
                    defer owned_promise.deinit();
                    break :promise owned_promise.toResult(context);
                },
                .error_value => |error_value| rejected: {
                    var owned_error = try error_value.toOwned();
                    defer owned_error.deinit();
                    break :rejected try context.promiseRejectedWithoutNotifying(owned_error.operand(context).asEngine());
                },
                .nulled, .undefined, .invalid => try rejectedFetchPromise(context, "fetch() returned an empty value"),
            };
            return fetch_result;
        }

        pub fn closeIdleConnections(this: *ThisServer) void {
            if (this.app) |app| app.closeIdleConnections();
        }

        pub fn stopFromJS(this: *ThisServer, context: anytype, abrupt: bool) bun.JSError!AllClosedPromiseResult {
            const rc = try this.getAllClosedPromise(context);

            if (this.hasListener()) {
                this.stop(abrupt);
            }

            return rc;
        }

        pub fn disposeFromJS(this: *ThisServer) void {
            if (this.hasListener()) {
                this.stop(true);
            }
        }

        pub fn getPort(this: *ThisServer) ?u16 {
            switch (this.config.address) {
                .unix => return null,
                else => {},
            }

            if (this.listener) |listener| return std.math.cast(u16, listener.getLocalPort());
            if (comptime has_h3) {
                if (this.h3_listener) |h3l| return std.math.cast(u16, h3l.getLocalPort());
            }
            return this.config.address.tcp.port;
        }

        pub fn getId(this: *ThisServer) bun.OOM!bun.bindgen.DOMString {
            return bun.bindgen.DOMString.fromUTF8(this.config.id);
        }

        pub fn getPendingRequests(this: *ThisServer) i32 {
            return @intCast(@as(u31, @truncate(this.pending_requests)));
        }

        pub fn getPendingWebSockets(this: *ThisServer) i32 {
            return @intCast(@as(u31, @truncate(this.activeSocketsCount())));
        }

        pub fn getAddress(this: *ThisServer, comptime Result: type) bun.OOM!Result {
            const Address = @typeInfo(Result).optional.child;
            const DTO = @FieldType(Address, "tcp");
            switch (this.config.address) {
                .unix => |unix| {
                    return .{ .unix_path = try bun.bindgen.DOMString.fromUTF8(unix) };
                },
                .tcp => {
                    var port: u16 = this.config.address.tcp.port;

                    if (this.listener) |listener| {
                        port = @intCast(listener.getLocalPort());

                        var buf: [64]u8 = @splat(0);
                        const address_bytes = listener.socket().localAddress(&buf) orelse return null;
                        var addr = SocketAddress.init(address_bytes, port) catch {
                            @branchHint(.unlikely);
                            return null;
                        };
                        return .{ .tcp = try addr.intoDTO(DTO) };
                    }
                    if (comptime has_h3) if (this.h3_listener) |h3l| {
                        port = @intCast(h3l.getLocalPort());
                        var buf: [64]u8 = @splat(0);
                        const address_bytes = h3l.getLocalAddress(&buf) orelse return null;
                        var addr = SocketAddress.init(address_bytes, port) catch {
                            @branchHint(.unlikely);
                            return null;
                        };
                        return .{ .tcp = try addr.intoDTO(DTO) };
                    };
                    return null;
                },
            }
        }

        pub fn getURLAsString(this: *const ThisServer) bun.OOM!bun.String {
            const fmt = switch (this.config.address) {
                .unix => |unix| brk: {
                    if (unix.len > 1 and unix[0] == 0) {
                        // abstract domain socket, let's give it an "abstract" URL
                        break :brk bun.fmt.URLFormatter{
                            .proto = .abstract,
                            .hostname = unix[1..],
                        };
                    }

                    break :brk bun.fmt.URLFormatter{
                        .proto = .unix,
                        .hostname = unix,
                    };
                },
                .tcp => |tcp| blk: {
                    var port: u16 = tcp.port;
                    if (this.listener) |listener| {
                        port = @intCast(listener.getLocalPort());
                    } else if (comptime has_h3) if (this.h3_listener) |h3l| {
                        port = @intCast(h3l.getLocalPort());
                    };
                    break :blk bun.fmt.URLFormatter{
                        .proto = if (comptime ssl_enabled) .https else .http,
                        .hostname = if (tcp.hostname) |hostname| std.mem.sliceTo(@constCast(hostname), 0) else null,
                        .port = port,
                    };
                },
            };

            const buf = try std.fmt.allocPrint(default_allocator, "{f}", .{fmt});
            defer default_allocator.free(buf);

            return bun.String.cloneUTF8(buf);
        }

        pub fn getHostname(this: *ThisServer) bun.OOM!?bun.bindgen.DOMString {
            switch (this.config.address) {
                .unix => return null,
                .tcp => {},
            }
            {
                if (this.listener) |listener| {
                    var buf: [1024]u8 = @splat(0);

                    if (listener.socket().remoteAddress(buf[0..1024])) |addr| {
                        if (addr.len > 0) {
                            return try bun.bindgen.DOMString.fromUTF8(addr);
                        }
                    }
                }
                {
                    switch (this.config.address) {
                        .tcp => |tcp| {
                            if (tcp.hostname) |hostname| {
                                return try bun.bindgen.DOMString.fromUTF8(std.mem.sliceTo(hostname, 0));
                            } else {
                                return try bun.bindgen.DOMString.fromUTF8("localhost");
                            }
                        },
                        .unix => unreachable,
                    }
                }
            }
            @panic("unreachable");
        }

        pub fn getProtocol(this: *ThisServer) bun.OOM!bun.bindgen.DOMString {
            _ = this;
            return bun.bindgen.DOMString.fromUTF8(if (ssl_enabled) "https" else "http");
        }

        pub fn getDevelopment(this: *ThisServer) bool {
            return this.config.isDevelopment();
        }

        pub fn onStaticRequestComplete(this: *ThisServer) void {
            this.pending_requests -= 1;
            this.deinitIfWeCan();
        }

        pub fn onRequestComplete(this: *ThisServer) void {
            this.vm.eventLoop().processGCTimer();

            this.pending_requests -= 1;
            this.deinitIfWeCan();
        }

        pub fn onRequestCancelled(this: *ThisServer) void {
            bun.assert(this.pending_requests > 0);
            this.pending_requests -= 1;
            this.cancelAllClosed();
            this.deinitIfWeCan();
        }

        pub fn finalize(this: *ThisServer) void {
            httplog("finalize", .{});
            this.js_value.finalize();
            this.deinitIfWeCan();
        }

        pub fn activeSocketsCount(this: *const ThisServer) usize {
            const websocket = &(this.config.websocket orelse return 0);
            return websocket.handler.state.active_connections;
        }

        pub fn hasActiveWebSockets(this: *const ThisServer) bool {
            return this.activeSocketsCount() > 0;
        }

        fn hasActiveWebSocketActivity(this: *const ThisServer) bool {
            const websocket = &(this.config.websocket orelse return false);
            return websocket.handler.state.active_connections > 0 or
                websocket.handler.state.active_dispatches > 0;
        }

        fn onWebSocketsIdle(this: *ThisServer) void {
            this.deinitIfWeCan();
        }

        /// True while either the TCP listen socket or (http1: false) the QUIC
        /// listen socket is bound. The lifecycle code uses this rather than
        /// `this.listener != null` so an HTTP/3-only server is still treated as
        /// running.
        pub fn hasListener(this: *const ThisServer) bool {
            if (this.listener != null) return true;
            if (comptime has_h3) if (this.h3_listener != null) return true;
            return false;
        }

        pub fn getAllClosedPromise(this: *ThisServer, context: anytype) bun.JSError!AllClosedPromiseResult {
            if (!this.hasListener() and
                this.pending_requests == 0 and
                !this.hasActiveWebSocketActivity())
            {
                return context.engineIn("promises", "promiseCreateResolvedUndefined").call(.{});
            }
            const prom = &this.all_closed_promise;
            if (prom.has()) {
                return prom.toResult(context);
            }
            const created = try StopCompletion.create(AllClosedPromiseResult, context);
            prom.* = created.promise;
            this.all_closed_completion = created.completion;
            return prom.toResult(context);
        }

        fn cancelAllClosed(this: *ThisServer) void {
            if (this.all_closed_completion) |completion| {
                this.all_closed_completion = null;
                var owned = completion;
                owned.release();
            }
            this.all_closed_promise.deinit();
        }

        pub fn deinitIfWeCan(this: *ThisServer) void {
            if (this.flags.deinit_scheduled or this.flags.processing_idle or this.routing_dispatch_depth != 0) return;
            this.flags.processing_idle = true;
            defer this.flags.processing_idle = false;

            if (Environment.enable_logs)
                httplog("deinitIfWeCan. requests={d}, listener={s}, websockets={s}, all_closed_promise={s}, has_js_deinited={}", .{
                    this.pending_requests,
                    if (this.listener == null) "null" else "some",
                    if (this.hasActiveWebSockets()) "active" else "no",
                    if (this.all_closed_promise.has()) "has" else "no",
                    this.js_value.isFinalized(),
                });

            if (this.pending_requests > 0 or this.hasListener()) {
                return;
            }

            if (this.hasActiveWebSocketActivity()) {
                this.config.websocket.?.handler.notifyWhenIdle(this, onWebSocketsIdle);
                return;
            }

            if (this.all_closed_completion) |completion| {
                this.all_closed_completion = null;
                this.all_closed_promise.deinit();
                var owned = completion;
                owned.resolve({});
            }

            if (this.config.websocket) |*ws| {
                ws.handler.state.app = null;
            }
            this.js_value.downgrade();
            this.unref();

            // Routes borrow DevServer state and must be removed before its destruction.
            if (this.dev_server) |dev| {
                this.dev_server = null;
                if (this.routes) |routes| routes.deref();
                this.routes = null;
                dev.deinit();
            }

            // Only free the memory if the JS reference has been freed too
            if (this.js_value.isFinalized()) {
                this.scheduleDeinit();
            }
        }

        pub fn stopListening(this: *ThisServer, abrupt: bool) void {
            httplog("stopListening", .{});
            if (comptime has_h3) {
                if (this.h3_listener) |h3l| {
                    this.h3_listener = null;
                    // Graceful: GOAWAY + drain via the still-open UDP socket;
                    // the engine rejects new conns and the timer keeps in-flight
                    // streams progressing until deinit. Abrupt: close the fd now.
                    if (!abrupt) {
                        if (this.h3_app) |h3a| h3a.close();
                    } else {
                        h3l.close();
                    }
                }
            }
            var listener = this.listener orelse {
                if (comptime has_h3) {
                    if (this.h3_app != null) {
                        this.unref();
                        this.notifyInspectorServerStopped();
                        if (abrupt) this.flags.terminated = true;
                    }
                }
                return;
            };
            this.listener = null;
            this.unref();

            this.notifyInspectorServerStopped();

            if (this.config.address == .unix) {
                const path = this.config.address.unix;
                if (path.len > 0 and path[0] != 0) {
                    _ = bun.sys.unlink(path);
                }
            }

            if (!abrupt) {
                listener.close();
            } else if (!this.flags.terminated) {
                if (this.config.websocket) |*ws| {
                    ws.handler.state.app = null;
                }
                this.flags.terminated = true;
                this.app.?.close();
            }
        }

        pub fn stop(this: *ThisServer, abrupt: bool) void {
            if (this.config.allow_hot and this.config.id.len > 0) {
                if (this.globalThis.bunVM().hotMap()) |hot| {
                    hot.remove(this.config.id);
                }
            }

            this.stopListening(abrupt);
            this.deinitIfWeCan();
        }

        fn scheduleDeinit(this: *ThisServer) void {
            if (this.flags.deinit_scheduled) {
                httplog("scheduleDeinit (again)", .{});
                return;
            }
            this.flags.deinit_scheduled = true;
            httplog("scheduleDeinit", .{});
            this.finalizer_queue.enqueue(&this.deinit_node, this, closeForDeinit);
        }

        fn closeForDeinit(this: *ThisServer) void {
            if (!this.flags.terminated) {
                this.flags.terminated = true;
                if (this.app) |app| app.close();
            }
            // Close callbacks may drain finalizers re-entrantly; publish destruction only after they return.
            this.finalizer_queue.enqueue(&this.deinit_node, this, destroyDeferred);
        }

        fn destroyDeferred(this: *ThisServer) void {
            this.deinit();
        }

        fn notifyInspectorServerStopped(this: *ThisServer) void {
            if (this.inspector_server_id.toOptional().unwrap() != null) {
                @branchHint(.unlikely);
                if (this.vm.debugger) |*debugger| {
                    @branchHint(.unlikely);
                    debugger.http_server_agent.notifyServerStopped(
                        AnyServer.from(this),
                    );
                    this.inspector_server_id = .init(0);
                }
            }
        }

        fn deinit(this: *ThisServer) void {
            httplog("deinit", .{});

            // This should've already been handled in stopListening
            // However, when the JS VM terminates, it hypothetically might not call stopListening
            this.notifyInspectorServerStopped();

            this.cancelAllClosed();
            if (this.on_clienterror) |*callback| callback.deinit();
            this.on_clienterror = null;
            if (this.routes) |routes| routes.deref();
            this.routes = null;

            this.config.deinit();

            if (comptime has_h3) {
                if (this.h3_app) |h3a| {
                    this.h3_app = null;
                    h3a.destroy();
                }
            }
            if (comptime has_h3) if (this.h3_alt_svc.len > 0)
                bun.default_allocator.free(this.h3_alt_svc);
            if (this.app) |app| {
                this.app = null;
                app.destroy();
            }

            if (bun.take(&this.dev_server)) |dev_server| {
                dev_server.deinit();
            }

            if (bun.take(&this.plugins)) |plugins| {
                plugins.deref();
            }

            this.allocator.free(this.base_url_string_for_joining);
            bun.destroy(this);
        }

        pub fn init(config: *ServerConfig, global: *JSGlobalObject) bun.JSOOM!*ThisServer {
            const finalizer_queue = (try global.bunVM().tryRareData()).nativeFinalizerQueue();
            const base_url = try bun.default_allocator.dupe(u8, strings.trim(config.base_url.href, "/"));
            errdefer bun.default_allocator.free(base_url);

            const dev_server = if (config.bake) |*bake_options|
                try bun.bake.DevServer.init(.{
                    .arena = bake_options.arena.allocator(),
                    .root = bake_options.root,
                    .framework = bake_options.framework,
                    .route_styles = bake_options.route_styles,
                    .bundler_options = bake_options.bundler_options,
                    .vm = global.bunVM(),
                    .broadcast_console_log_from_browser_to_server = config.broadcast_console_log_from_browser_to_server_for_bake,
                })
            else
                null;
            errdefer if (dev_server) |d| d.deinit();

            const request_pool = RequestContext.pool orelse pool: {
                const pool = try bun.default_allocator.create(RequestContext.RequestContextStackAllocator);
                pool.* = RequestContext.RequestContextStackAllocator.init(bun.typedAllocator(RequestContext));
                RequestContext.pool = pool;
                break :pool pool;
            };
            const h3_request_pool = if (comptime has_h3) pool: {
                if (H3RequestContext.pool) |pool| break :pool pool;
                const pool = try bun.default_allocator.create(H3RequestContext.RequestContextStackAllocator);
                pool.* = H3RequestContext.RequestContextStackAllocator.init(bun.typedAllocator(H3RequestContext));
                H3RequestContext.pool = pool;
                break :pool pool;
            } else {};

            const server = try bun.default_allocator.create(ThisServer);
            server.* = .{
                .globalThis = global,
                .finalizer_queue = finalizer_queue,
                .config = config.take(),
                .base_url_string_for_joining = base_url,
                .vm = jsc.VirtualMachine.get(),
                .allocator = bun.default_allocator,
                .dev_server = dev_server,
                .request_pool_allocator = request_pool,
                .h3_request_pool_allocator = h3_request_pool,
            };

            if (comptime ssl_enabled) {
                analytics.Features.https_server += 1;
            } else {
                analytics.Features.http_server += 1;
            }

            return server;
        }

        fn failListen(this: *ThisServer, context: anytype, failure: uws.ListenFailure) bindgen.CallError(@TypeOf(context)) {
            if (failure.socket_bound != 0 and this.config.address == .unix) {
                const path = this.config.address.unix;
                if (path.len > 0 and path[0] != 0) _ = bun.sys.unlink(path);
            }
            if (failure.server_name_error != .ok) {
                if (failure.server_name_error == .out_of_memory) return error.OutOfMemory;
                return context.fail(.server_sni_replay_failed, {});
            }
            const system_errno = failure.systemErrno() orelse return context.fail(.server_listen_failed, {});
            const errno: bun.sys.E = if (comptime Environment.isWindows)
                system_errno.toE()
            else
                @fromBackingInt(@backingInt(system_errno));
            if (errno == .NOMEM) return error.OutOfMemory;
            var native_error = bun.sys.Error.fromCode(errno, .listen);
            if (this.config.address == .unix) native_error.path = this.config.address.unix;
            const payload = payload: {
                var result = try bindgen.SystemError.fromSysError(native_error);
                errdefer result.deinit();
                const message = if (this.config.address == .tcp and errno == .ACCES)
                    try std.fmt.allocPrint(bun.default_allocator, "permission denied {s}:{d}", .{ this.config.address.tcp.hostname orelse "0.0.0.0", this.config.address.tcp.port })
                else if (this.config.address == .tcp and errno == .ADDRINUSE)
                    try std.fmt.allocPrint(bun.default_allocator, "Failed to start server. Is port {d} in use?", .{this.config.address.tcp.port})
                else
                    try std.fmt.allocPrint(bun.default_allocator, "Failed to start server: {s}", .{result.message.slice()});
                result.message.deinit();
                result.message = bindgen.OwnedBytes.fromDefaultAllocatedSlice(message);
                break :payload result;
            };
            return context.fail(.server_listen_system, payload);
        }

        pub fn h3AltSvc(this: *ThisServer) ?[]const u8 {
            if (comptime !has_h3) return null;
            return if (this.h3_alt_svc.len > 0) this.h3_alt_svc else null;
        }

        pub fn onH3Listen(this: *ThisServer, socket: ?*uws.H3.ListenSocket) void {
            if (comptime !has_h3) unreachable;
            this.h3_listener = socket;
            if (socket) |s| {
                this.h3_alt_svc = std.fmt.allocPrintSentinel(
                    bun.default_allocator,
                    "h3=\":{d}\"; ma=86400",
                    .{s.getLocalPort()},
                    0,
                ) catch "";
            }
        }

        pub fn onH3Request(this: *ThisServer, req: *uws.H3.Request, resp: *uws.H3.Response) void {
            if (comptime !has_h3) unreachable;
            if (!this.config.onRequest.configured) return onH3404(this, req, resp);
            this.onRequestFor(H3RequestContext, req, resp);
        }

        pub fn onH3UserRouteRequest(user_route: *UserRoute, req: *uws.H3.Request, resp: *uws.H3.Response) void {
            if (comptime !has_h3) unreachable;
            onUserRouteRequestFor(H3RequestContext, user_route, req, resp);
        }

        pub fn onH3404(_: *ThisServer, _: *uws.H3.Request, resp: *uws.H3.Response) void {
            if (comptime !has_h3) unreachable;
            resp.writeStatus("404 Not Found") catch |err| return closeResponseAfterWriteFailure(resp, err);
            resp.end("", false) catch |err| closeResponseAfterWriteFailure(resp, err);
        }

        fn closeResponseAfterWriteFailure(resp: anytype, failure: uws.ResponseWriteError) void {
            if (failure != error.ConnectionClosed) uws.AnyResponse.init(resp).forceClose();
        }

        pub fn ref(this: *ThisServer) void {
            if (this.poll_ref.isActive()) return;

            this.poll_ref.ref(this.vm);
        }

        pub fn unref(this: *ThisServer) void {
            if (!this.poll_ref.isActive()) return;

            this.poll_ref.unref(this.vm);
        }

        pub fn onBunInfoRequest(this: *ThisServer, req: *uws.Request, resp: *App.Response) void {
            this.pending_requests += 1;
            defer this.pending_requests -= 1;
            req.setYield(false);
            var stack_fallback_buffer: [8192]u8 = undefined;
            var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buffer, this.allocator);
            const allocator = stack_fallback.allocator();

            const buffer_writer = js_printer.BufferWriter.init(allocator);
            var writer = js_printer.BufferPrinter.init(buffer_writer);
            defer writer.ctx.buffer.deinit();
            const source = &logger.Source.initEmptyFile("info.json");
            _ = js_printer.printJSON(
                *js_printer.BufferPrinter,
                &writer,
                bun.Global.BunInfo.generate(*Transpiler, &jsc.VirtualMachine.get().transpiler, allocator) catch unreachable,
                source,
                .{ .mangled_props = null },
            ) catch unreachable;

            resp.writeStatus("200 OK") catch |err| return closeResponseAfterWriteFailure(resp, err);
            resp.writeHeader("Content-Type", MimeType.json.value) catch |err| return closeResponseAfterWriteFailure(resp, err);
            resp.writeHeader("Cache-Control", "public, max-age=3600") catch |err| return closeResponseAfterWriteFailure(resp, err);
            resp.writeHeaderInt("Age", 0) catch |err| return closeResponseAfterWriteFailure(resp, err);
            const buffer = writer.ctx.written;
            resp.end(buffer, false) catch |err| closeResponseAfterWriteFailure(resp, err);
        }

        pub fn onPendingRequest(this: *ThisServer) void {
            this.pending_requests += 1;
        }

        pub fn onNodeHTTPRequestWithUpgradeCtx(this: *ThisServer, req: *uws.Request, resp: *App.Response, upgrade_ctx: ?*uws.WebSocketUpgradeContext) void {
            const vm = this.vm;
            if (comptime Environment.isDebug) {
                vm.eventLoop().debug.enter();
            }
            defer {
                if (comptime Environment.isDebug) {
                    vm.eventLoop().debug.exit();
                }
            }
            req.setYield(false);
            resp.timeout(this.config.idleTimeout);

            const globalThis = this.globalThis;

            var callback = (this.handlerCallback("onNodeHTTPRequest") catch |err| {
                resp.downcastSocket().close(.failure);
                return globalThis.reportActiveExceptionAsUnhandled(err);
            }) orelse
                @panic("configured Node HTTP callback slot is empty");
            defer callback.deinit();

            var server_ref = this.serverClassRef() catch |err| {
                resp.downcastSocket().close(.failure);
                return globalThis.reportActiveExceptionAsUnhandled(err);
            };
            defer deinitHTTPServerReference(&server_ref);
            const NodeHTTPServerHandle = bun.bindgen.EngineArgumentType(NodeHTTPServerCreateResponseSchema, "anyServer");
            const NodeHTTPRequestHandle = bun.bindgen.EngineArgumentType(NodeHTTPServerPrepareRequestSchema, "request");
            const NodeHTTPResponseHandle = bun.bindgen.EngineArgumentType(NodeHTTPServerPrepareRequestSchema, "response");
            const NodeHTTPUpgradeContextHandle = bun.bindgen.EngineArgumentType(NodeHTTPServerCreateResponseSchema, "upgradeContext");
            var invocation: NodeHTTPRequestCallback.Invocation = undefined;
            callback.beginInvocation(&invocation);
            defer invocation.deinit();
            var method_string = if (bun.http.Method.find(req.method())) |method|
                invocation.engine(HTTPMethodToJSShim).call(.{ .value = method.toBinding() }) catch |failure| {
                    resp.downcastSocket().close(.failure);
                    return globalThis.reportActiveExceptionAsUnhandled(failure);
                }
            else
                null;
            defer if (method_string) |*value| value.deinit();
            const has_body = NodeHTTPResponse.requestHasBody(req);
            const node_response_ref = invocation.engine(NodeHTTPServerCreateResponseSchema).call(.{
                .kind = node_http_response_kind,
                .anyServer = @as(NodeHTTPServerHandle, @ptrCast(AnyServer.from(this).ptr.ptr())),
                .hasBody = has_body,
                .request = @as(NodeHTTPRequestHandle, @ptrCast(req)),
                .response = @as(NodeHTTPResponseHandle, @ptrCast(resp)),
                .upgradeContext = @as(NodeHTTPUpgradeContextHandle, if (upgrade_ctx) |context| @ptrCast(context) else null),
            }) catch |err| {
                resp.downcastSocket().close(.failure);
                return globalThis.reportActiveExceptionAsUnhandled(err);
            };
            const node_http_response = node_response_ref.get(NodeHTTPResponse.JSBinding).response.get();
            node_http_response.activateRequest(invocation.vmIdentity());
            const HTTPResult = enum { success, pending, failed };
            var needs_to_drain = true;

            defer {
                if (needs_to_drain) {
                    vm.drainMicrotasks() catch |err|
                        globalThis.reportActiveExceptionAsUnhandled(err);
                }
            }
            const http_result: HTTPResult = brk: {
                var prepared = invocation.engine(NodeHTTPServerPrepareRequestSchema).call(.{
                    .kind = node_http_response_kind,
                    .methodString = if (method_string) |optional_value| optional_value.operand(&invocation) else null,
                    .request = @as(NodeHTTPRequestHandle, @ptrCast(req)),
                    .response = @as(NodeHTTPResponseHandle, @ptrCast(resp)),
                    .nodeResponse = node_response_ref.operand(&invocation),
                }) catch |failure| {
                    globalThis.reportActiveExceptionAsUnhandled(failure);
                    break :brk .failed;
                };
                defer bun.bindgen.deinitReturn(NodeHTTPServerPrepareRequestSchema, &prepared);
                const result = callPreparedNodeHTTPRequest(&invocation, &server_ref, &node_response_ref, &prepared, has_body) catch |failure| {
                    globalThis.reportActiveExceptionAsUnhandled(failure);
                    break :brk .failed;
                };
                switch (result) {
                    .ignored => break :brk .success,
                    .error_value => |value| {
                        _ = invocation.reportUncaughtException(value.operand(&invocation).asAny(), false);
                        break :brk .failed;
                    },
                    .promise => |promise| {
                        var status = invocation.engine(PromiseStatusShim).call(.{ .promise = promise.operand(&invocation) });
                        if (status == .pending) {
                            needs_to_drain = false;
                            vm.drainMicrotasks() catch |failure| {
                                globalThis.reportActiveExceptionAsUnhandled(failure);
                                break :brk .failed;
                            };
                            status = invocation.engine(PromiseStatusShim).call(.{ .promise = promise.operand(&invocation) });
                        }

                        switch (status) {
                            .fulfilled => {
                                globalThis.handleRejectedPromises();
                                break :brk .success;
                            },
                            .rejected => {
                                invocation.engine(PromiseSetHandledShim).call(.{ .promise = promise.operand(&invocation) });
                                const reason = (invocation.engine(PromiseResultShim).call(.{ .promise = promise.operand(&invocation) }) catch |failure| {
                                    globalThis.reportActiveExceptionAsUnhandled(failure);
                                    break :brk .failed;
                                }) orelse @panic("rejected HTTP request promise has no result");
                                _ = invocation.reportUncaughtException(reason.operand(&invocation).asAny(), true);
                                break :brk .failed;
                            },
                            .pending => {
                                globalThis.handleRejectedPromises();
                                if (node_http_response.core.flags.request_has_completed or node_http_response.core.flags.socket_closed or node_http_response.core.flags.upgraded)
                                    break :brk .success;
                                node_http_response.attachRequestPromiseHandlers(&invocation, promise) catch |failure| {
                                    globalThis.reportActiveExceptionAsUnhandled(failure);
                                    break :brk .failed;
                                };
                                break :brk .pending;
                            },
                        }
                    },
                }
            };

            if (http_result == .failed) node_http_response.finishRequestWithError(true);

            if (!node_http_response.core.flags.upgraded and node_http_response.core.raw_response != null) {
                const raw_response = node_http_response.core.raw_response.?;
                if (!node_http_response.core.flags.request_has_completed and raw_response.state().isResponsePending()) {
                    node_http_response.prepareForAsync() catch |failure| {
                        globalThis.reportActiveExceptionAsUnhandled(failure);
                        node_http_response.finishRequestWithError(true);
                    };
                }
                // If we ended the response without attaching an ondata handler, we discard the body read stream
                else if (http_result != .pending) node_http_response.maybeStopReadingBody();
            }
        }

        pub fn onNodeHTTPRequest(this: *ThisServer, req: *uws.Request, resp: *App.Response) void {
            onNodeHTTPRequestWithUpgradeCtx(this, req, resp, null);
        }

        const node_http_response_kind: bun.bindgen.EngineArgumentType(NodeHTTPServerPrepareRequestSchema, "kind") = if (ssl_enabled) .ssl else .tcp;

        pub fn setUsingCustomExpectHandler(this: *ThisServer, value: bool) void {
            bun.bindgen.Engine(NodeHTTPSetUsingCustomExpectHandlerSchema).call(.{
                .kind = node_http_response_kind,
                .app = @ptrCast(this.app.?),
                .enabled = value,
            });
        }

        var did_send_idletimeout_warning_once = false;
        fn onTimeoutForIdleWarn(_: *anyopaque, _: ?*anyopaque) void {
            if (!did_send_idletimeout_warning_once) {
                if (!bun.cli.Command.get().debug.silent) {
                    did_send_idletimeout_warning_once = true;
                    Output.prettyErrorln("<r><yellow>[Bun.serve]<r><d>:<r> request timed out after 10 seconds. Pass <d><cyan>`idleTimeout`<r> to configure.", .{});
                    Output.flush();
                }
            }
        }

        fn shouldAddTimeoutHandlerForWarning(server: *ThisServer) bool {
            if (server.config.isDevelopment()) {
                if (!did_send_idletimeout_warning_once and !bun.cli.Command.get().debug.silent) {
                    return !server.config.has_idleTimeout;
                }
            }

            return false;
        }

        pub fn onUserRouteRequest(user_route: *UserRoute, req: *uws.Request, resp: *App.Response) void {
            onUserRouteRequestFor(RequestContext, user_route, req, resp);
        }

        fn runUserRouteFor(
            comptime Ctx: type,
            server: *ThisServer,
            index: u32,
            should_deinit_context: *bool,
            prepared: PreparedRequestFor(Ctx),
            req: *Ctx.Req,
        ) void {
            const route_list = server.dispatch_route_list orelse @panic("configured route list slot is empty");

            const RequestNativeHandle = bun.bindgen.EngineArgumentType(ServerRouteListPrepareRouteSchema, "requestNative");
            const RequestHandle = bun.bindgen.EngineArgumentType(ServerRouteListPrepareRouteSchema, "request");
            var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
            engine_scope.init(server.globalThis);
            defer engine_scope.deinit();
            const prepared_route = engine_scope.engine(ServerRouteListPrepareRouteSchema).call(.{
                .index = index,
                .requestNative = @as(RequestNativeHandle, @ptrCast(prepared.request_object)),
                .routeList = route_list.operand(&engine_scope).asEngine(),
                .kind = if (Ctx.is_h3) .h3 else .http,
                .request = @as(RequestHandle, @ptrCast(req)),
            }) catch |err| {
                return server.handleRequestFailureFor(
                    Ctx,
                    should_deinit_context,
                    prepared,
                    req,
                    err,
                );
            };
            var request_ref = prepared_route.request.toOwned() catch |err|
                return server.handleRequestFailureFor(Ctx, should_deinit_context, prepared, req, err);
            defer request_ref.deinit();
            var callback_call: FetchCallbackCall = undefined;
            callback_call.initWithCallback(prepared_route.callback) catch |err|
                return server.handleRequestFailureFor(Ctx, should_deinit_context, prepared, req, err);
            defer callback_call.deinit();
            var response_value = callback_call.invokeWithRequestRef(server, &request_ref) catch |err| {
                return server.handleRequestFailureFor(
                    Ctx,
                    should_deinit_context,
                    prepared,
                    req,
                    err,
                );
            };
            defer deinitServeCallbackResult(&response_value);

            server.handleCallbackRequestFor(
                Ctx,
                should_deinit_context,
                prepared,
                req,
                &callback_call,
                &response_value,
            );
        }

        fn onUserRouteRequestFor(comptime Ctx: type, user_route: *UserRoute, req: *Ctx.Req, resp: *Ctx.Resp) void {
            const server = user_route.server;
            const index = user_route.id;

            var should_deinit_context = false;
            const prepared = server.prepareJsRequestContextFor(Ctx, req, resp, &should_deinit_context, .no, switch (user_route.route.method) {
                .any => null,
                .specific => |m| m,
            }) orelse return;

            runUserRouteFor(Ctx, server, index, &should_deinit_context, prepared, req);
        }

        fn handleRequestFailureFor(
            this: *ThisServer,
            comptime Ctx: type,
            should_deinit_context: *bool,
            prepared: PreparedRequestFor(Ctx),
            req: *Ctx.Req,
            failure: bun.JSError,
        ) void {
            defer prepared.request_object.request_context.detachRequest();
            prepared.ctx.failCallback(failure);
            this.finishRequestCallbackFor(Ctx, should_deinit_context, prepared, req);
        }

        fn handleCallbackRequestFor(
            this: *ThisServer,
            comptime Ctx: type,
            should_deinit_context: *bool,
            prepared: PreparedRequestFor(Ctx),
            req: *Ctx.Req,
            callback_call: *FetchCallbackCall,
            response_value: *ServeCallbackResult,
        ) void {
            const ctx = prepared.ctx;

            defer prepared.request_object.request_context.detachRequest();

            ctx.onResponseFromCallback(
                this,
                &callback_call.invocation,
                response_value,
            );

            this.finishRequestCallbackFor(Ctx, should_deinit_context, prepared, req);
        }

        fn finishRequestCallbackFor(
            this: *ThisServer,
            comptime Ctx: type,
            should_deinit_context: *bool,
            prepared: PreparedRequestFor(Ctx),
            req: *Ctx.Req,
        ) void {
            const ctx = prepared.ctx;
            if (!should_deinit_context.* and this.globalThis.pendingExceptionKind() == .termination) {
                ctx.forceClose();
            }

            ctx.defer_deinit_until_callback_completes = null;

            if (should_deinit_context.*) {
                ctx.deinit();
                return;
            }

            if (ctx.shouldRenderMissing()) {
                ctx.renderMissing();
                return;
            }

            // uWS reuses the stack-allocated request after this callback returns.
            ctx.toAsync(req, prepared.request_object) catch |err| return ctx.fail(err);
        }

        pub fn onRequest(this: *ThisServer, req: *uws.Request, resp: *App.Response) void {
            this.onRequestFor(RequestContext, req, resp);
        }

        fn onRequestFor(this: *ThisServer, comptime Ctx: type, req: *Ctx.Req, resp: *Ctx.Resp) void {
            var should_deinit_context = false;
            var prepared = this.prepareJsRequestContextFor(Ctx, req, resp, &should_deinit_context, .yes, null) orelse return;
            defer prepared.deinit();

            var callback_call: FetchCallbackCall = undefined;
            callback_call.init(this) catch |err|
                return this.handleRequestFailureFor(Ctx, &should_deinit_context, prepared, req, err);
            defer callback_call.deinit();
            var response_value = callback_call.invokeWithRequestRef(this, &prepared.request_ref.?) catch |err| {
                return this.handleRequestFailureFor(
                    Ctx,
                    &should_deinit_context,
                    prepared,
                    req,
                    err,
                );
            };
            defer deinitServeCallbackResult(&response_value);

            this.handleCallbackRequestFor(
                Ctx,
                &should_deinit_context,
                prepared,
                req,
                &callback_call,
                &response_value,
            );
        }

        pub fn onSavedRequest(
            this: *ThisServer,
            req: SavedRequest.Union,
            resp: *App.Response,
            callback: *const DevServerFrameworkRequestCallback,
            metadata: *const DevServerFrameworkRequestMetadata,
            ensure_async_local_storage: *const DevServerEnsureAsyncLocalStorageCallback,
            bundle_new_route: *const DevServerBundleNewRouteCallback,
            new_route_params: *const DevServerNewRouteParamsCallback,
        ) void {
            var prepared: PreparedRequest = switch (req) {
                .stack => |r| this.prepareJsRequestContext(r, resp, null, .bake, null) orelse return,
                .saved => |data| .{
                    .request_ref = data.request_ref.clone(),
                    .request_object = data.request,
                    .ctx = data.ctx.get(RequestContext).?,
                },
            };
            defer prepared.deinit();
            const ctx = prepared.ctx;

            defer if (req == .stack) {
                // uWS request will not live longer than this function
                prepared.request_object.request_context.detachRequest();
            };
            const original_state = ctx.defer_deinit_until_callback_completes;
            var should_deinit_context = false;
            ctx.defer_deinit_until_callback_completes = &should_deinit_context;

            var invocation: DevServerFrameworkRequestCallback.Invocation = undefined;
            callback.beginInvocation(&invocation);
            defer invocation.deinit();
            var request_arg = prepared.request_ref.?.clone();
            defer request_arg.deinit();
            var ensure_async_local_storage_arg = ensure_async_local_storage.clone();
            defer ensure_async_local_storage_arg.deinit();
            var bundle_new_route_arg = bundle_new_route.clone();
            defer bundle_new_route_arg.deinit();
            var new_route_params_arg = new_route_params.clone();
            defer new_route_params_arg.deinit();
            if (invocation.call(.{
                .request = request_arg.operand(&invocation),
                .metadata = metadata.*,
                .setAsyncLocalStorage = ensure_async_local_storage_arg.operand(&invocation),
                .bundleNewRoute = bundle_new_route_arg.operand(&invocation),
                .newRouteParams = new_route_params_arg.operand(&invocation),
            })) |response| {
                var response_value = response;
                defer deinitServeCallbackResult(&response_value);
                ctx.onResponseFromCallback(this, &invocation, &response_value);
            } else |err| {
                ctx.failCallback(err);
            }
            ctx.defer_deinit_until_callback_completes = original_state;

            if (should_deinit_context) {
                ctx.deinit();
                return;
            }

            if (ctx.shouldRenderMissing()) {
                ctx.renderMissing();
                return;
            }

            // The request is asynchronous, and all information from `req` must be copied
            // since the provided uws.Request will be re-used for future requests (stack allocated).
            switch (req) {
                .stack => |r| ctx.toAsync(r, prepared.request_object) catch |err| return ctx.fail(err),
                .saved => {}, // info already copied
            }
        }

        pub const PreparedRequest = PreparedRequestFor(RequestContext);

        fn PreparedRequestFor(comptime Ctx: type) type {
            return struct {
                request_ref: ?RequestReference,
                request_object: *Request,
                ctx: *Ctx,

                pub fn deinit(prepared: *@This()) void {
                    if (prepared.request_ref) |*request_ref| request_ref.deinit();
                    prepared.request_ref = null;
                }

                /// This is used by DevServer for deferring calling the JS handler
                /// to until the bundle is actually ready.
                pub fn save(
                    prepared: *@This(),
                    req: *Ctx.Req,
                    resp: *Ctx.Resp,
                ) bun.OOM!SavedRequest {
                    if (comptime Ctx.is_h3) @compileError("PreparedRequest.save is HTTP/1-only");
                    // By saving a request, all information from `req` must be
                    // copied since the provided uws.Request will be re-used for
                    // future requests (stack allocated).
                    try prepared.ctx.toAsync(req, prepared.request_object);

                    const request_ref = prepared.request_ref orelse @panic("saved request has no JavaScript wrapper");
                    prepared.request_ref = null;
                    return .{
                        .request_ref = request_ref,
                        .request = prepared.request_object,
                        .ctx = AnyRequestContext.init(prepared.ctx),
                        .response = uws.AnyResponse.init(resp),
                    };
                }
            };
        }

        const CreateJsRequest = enum { yes, no, bake };

        pub fn prepareJsRequestContext(
            this: *ThisServer,
            req: *uws.Request,
            resp: *App.Response,
            should_deinit_context: ?*bool,
            create_js_request: CreateJsRequest,
            method: ?bun.http.Method,
        ) ?PreparedRequest {
            return this.prepareJsRequestContextFor(RequestContext, req, resp, should_deinit_context, create_js_request, method);
        }

        fn prepareJsRequestContextFor(
            this: *ThisServer,
            comptime Ctx: type,
            req: *Ctx.Req,
            resp: *Ctx.Resp,
            should_deinit_context: ?*bool,
            create_js_request: CreateJsRequest,
            method: ?bun.http.Method,
        ) ?PreparedRequestFor(Ctx) {

            // We need to register the handler immediately since uSockets will not buffer.
            //
            // We first validate the self-reported request body length so that
            // we avoid needing to worry as much about what memory to free.
            // RFC 9114 §4.2: an HTTP/3 message containing a transfer-encoding
            // header field is malformed.
            if (comptime Ctx.is_h3) if (req.header("transfer-encoding") != null) {
                resp.writeStatus("400 Bad Request") catch |err| {
                    closeResponseAfterWriteFailure(resp, err);
                    return null;
                };
                resp.endWithoutBody(false) catch |err| closeResponseAfterWriteFailure(resp, err);
                return null;
            };

            const request_body_length: ?usize = request_body_length: {
                if ((HTTP.Method.which(req.method()) orelse HTTP.Method.OPTIONS).hasRequestBody()) {
                    const len: usize = brk: {
                        if (req.header("content-length")) |content_length| {
                            break :brk std.fmt.parseInt(usize, content_length, 10) catch 0;
                        }

                        break :brk 0;
                    };

                    // Abort the request very early. For H3 a per-request error
                    // is a stream error (RFC 9114 §4.1.2); close_connection
                    // would CONNECTION_CLOSE every sibling stream on the conn.
                    if (len > this.config.max_request_body_size) {
                        resp.writeStatus("413 Request Entity Too Large") catch |err| {
                            closeResponseAfterWriteFailure(resp, err);
                            return null;
                        };
                        resp.endWithoutBody(comptime !Ctx.is_h3) catch |err| closeResponseAfterWriteFailure(resp, err);
                        return null;
                    }

                    break :request_body_length len;
                }

                break :request_body_length null;
            };

            var h3_headers: ?WebCore.FetchHeaders.Owner = if (comptime Ctx.is_h3)
                WebCore.FetchHeaders.createFromH3(req) catch |err| {
                    const sent = resp.writeStatus("500 Internal Server Error");
                    if (sent) |_| {
                        resp.endWithoutBody(false) catch |failure| closeResponseAfterWriteFailure(resp, failure);
                    } else |failure| closeResponseAfterWriteFailure(resp, failure);
                    this.globalThis.reportActiveExceptionAsUnhandled(err);
                    return null;
                }
            else
                null;
            defer if (h3_headers) |*headers| headers.deinit();

            this.onPendingRequest();

            if (comptime Environment.isDebug) {
                this.vm.eventLoop().debug.enter();
            }
            defer {
                if (comptime Environment.isDebug) {
                    this.vm.eventLoop().debug.exit();
                }
            }
            req.setYield(false);
            resp.timeout(this.config.idleTimeout);

            // Since we do timeouts by default, we should tell the user when
            // this happens - but limit it to only warn once.
            if (shouldAddTimeoutHandlerForWarning(this)) {
                // We need to pass it a pointer, any pointer should do.
                resp.onTimeout(*anyopaque, struct {
                    fn warn(p: *anyopaque, _: *Ctx.Resp) void {
                        onTimeoutForIdleWarn(p, null);
                    }
                }.warn, &did_send_idletimeout_warning_once);
            }

            const pool_allocator = if (comptime Ctx.is_h3) this.h3_request_pool_allocator else this.request_pool_allocator;
            const ctx = bun.handleOom(pool_allocator.tryGet());
            ctx.create(this, req, resp, should_deinit_context, method);
            this.vm.jsc_vm.reportExtraMemory(@sizeOf(Ctx));
            const body = this.vm.initRequestBodyValue(.{ .Null = {} }) catch unreachable;

            ctx.request_body = body;
            var signal = jsc.WebCore.AbortSignal.new(this.globalThis);
            ctx.signal = signal;
            signal.pendingActivityRef();

            const request_object = Request.new(Request.init(
                ctx.method,
                AnyRequestContext.init(ctx),
                ssl_enabled,
                signal.ref(),
                body.ref(),
            ));
            ctx.request_weakref = .initRef(request_object);

            // The lazy `getRequest()` path that backs Request.url / .headers
            // is `*uws.Request`-typed; for HTTP/3 we populate both eagerly so
            // the rest of the pipeline never needs to know which transport
            // delivered the bytes.
            if (comptime Ctx.is_h3) {
                request_object.setFetchHeaders(h3_headers.?.take());
                const path = req.url();
                if (path.len > 0 and path[0] == '/') {
                    if (req.header("host")) |host| {
                        const fmt = bun.fmt.HostFormatter{ .is_https = true, .host = host };
                        request_object.url = bun.handleOom(bun.bindgen.DOMString.fromBunString(
                            bun.handleOom(bun.String.createFormat("https://{f}{s}", .{ fmt, path })),
                        ));
                    } else {
                        request_object.url = bun.handleOom(bun.bindgen.DOMString.fromUTF8(path));
                    }
                } else {
                    request_object.url = bun.handleOom(bun.bindgen.DOMString.fromUTF8(path));
                }
                ctx.req = null;
            }

            if (this.config.isDevelopment()) {
                ctx.flags.is_web_browser_navigation = brk: {
                    if (req.header("sec-fetch-dest")) |fetch_dest| {
                        if (strings.eqlComptime(fetch_dest, "document")) {
                            break :brk true;
                        }
                    }

                    break :brk false;
                };
            }

            if (request_body_length) |req_len| {
                ctx.request_body_content_len = req_len;
                ctx.flags.is_transfer_encoding = req.header("transfer-encoding") != null;
                // HTTP/3 (RFC 9114 §4.2.2): Content-Length is optional and
                // Transfer-Encoding is forbidden; the body is terminated by
                // the QUIC stream FIN, so always arm onData for body methods.
                if (req_len > 0 or ctx.flags.is_transfer_encoding or comptime Ctx.is_h3) {
                    // we defer pre-allocating the body until we receive the first chunk
                    // that way if the client is lying about how big the body is or the client aborts
                    // we don't waste memory
                    ctx.request_body.?.value = .{
                        .Locked = .{
                            .global = .init(this.globalThis),
                        },
                    };
                    ctx.request_body.?.value.Locked.setSource(&ctx.request_body_source);
                    ctx.flags.is_waiting_for_request_body = true;

                    resp.onData(*Ctx, Ctx.onBufferedBodyChunk, ctx);
                }
            }

            return .{
                .request_ref = switch (create_js_request) {
                    .yes => request_object.toClassRef(this.globalThis) catch |err| switch (err) {
                        error.OutOfMemory => bun.outOfMemory(),
                        else => return null,
                    },
                    .bake => request_object.toClassRefForBake(this.globalThis) catch |err| switch (err) {
                        error.OutOfMemory => bun.outOfMemory(),
                        else => return null,
                    },
                    .no => null,
                },
                .request_object = request_object,
                .ctx = ctx,
            };
        }

        fn upgradeWebSocketUserRoute(this: *UserRoute, resp: *App.Response, req: *uws.Request, upgrade_ctx: *uws.WebSocketUpgradeContext, method: ?bun.http.Method) void {
            const server = this.server;
            const index = this.id;

            var should_deinit_context = false;
            var prepared = server.prepareJsRequestContext(req, resp, &should_deinit_context, .no, method) orelse return;
            prepared.ctx.upgrade_context = .{ .available = upgrade_ctx };
            runUserRouteFor(RequestContext, server, index, &should_deinit_context, prepared, req);
        }

        pub fn onWebSocketUpgrade(this: *ThisServer, resp: *App.Response, req: *uws.Request, upgrade_ctx: *uws.WebSocketUpgradeContext, id: usize) void {
            if (id == 1) {
                // This is actually a UserRoute if id is 1 so it's safe to cast
                upgradeWebSocketUserRoute(@ptrCast(this), resp, req, upgrade_ctx, null);
                return;
            }
            // Access `this` as *ThisServer only if id is 0
            bun.assert(id == 0);
            if (this.config.onNodeHTTPRequest.configured) {
                onNodeHTTPRequestWithUpgradeCtx(this, req, resp, upgrade_ctx);
                return;
            }
            if (!this.config.onRequest.configured) {
                // require fetch method to be set otherwise we dont know what route to call
                // this should be the fallback in case no route is provided to upgrade
                resp.writeStatus("403 Forbidden") catch |err| return closeResponseAfterWriteFailure(resp, err);
                resp.endWithoutBody(true) catch |err| closeResponseAfterWriteFailure(resp, err);
                return;
            }
            this.pending_requests += 1;
            req.setYield(false);
            var ctx = bun.handleOom(this.request_pool_allocator.tryGet());
            var should_deinit_context = false;
            ctx.create(this, req, resp, &should_deinit_context, null);
            var body = this.vm.initRequestBodyValue(.{ .Null = {} }) catch unreachable;

            ctx.request_body = body;
            var signal = jsc.WebCore.AbortSignal.new(this.globalThis);
            ctx.signal = signal;
            signal.pendingActivityRef();

            var request_object = Request.new(Request.init(
                ctx.method,
                AnyRequestContext.init(ctx),
                ssl_enabled,
                signal.ref(),
                body.ref(),
            ));
            ctx.upgrade_context = .{ .available = upgrade_ctx };
            ctx.request_weakref = .initRef(request_object);
            // We keep the Request object alive for the duration of the request so that we can remove the pointer to the UWS request object.
            var request_ref = request_object.toClassRef(this.globalThis) catch |err| switch (err) {
                error.OutOfMemory => bun.outOfMemory(),
                else => {
                    this.globalThis.reportActiveExceptionAsUnhandled(error.JSError);
                    return;
                },
            };
            defer request_ref.deinit();

            const prepared: PreparedRequest = .{
                .request_ref = null,
                .request_object = request_object,
                .ctx = ctx,
            };
            var callback_call: FetchCallbackCall = undefined;
            callback_call.init(this) catch |err|
                return this.handleRequestFailureFor(RequestContext, &should_deinit_context, prepared, req, err);
            defer callback_call.deinit();
            var response_value = callback_call.invokeWithRequestRef(this, &request_ref) catch |err| {
                return this.handleRequestFailureFor(
                    RequestContext,
                    &should_deinit_context,
                    prepared,
                    req,
                    err,
                );
            };
            defer deinitServeCallbackResult(&response_value);
            this.handleCallbackRequestFor(
                RequestContext,
                &should_deinit_context,
                prepared,
                req,
                &callback_call,
                &response_value,
            );
        }

        // https://chromium.googlesource.com/devtools/devtools-frontend/+/main/docs/ecosystem/automatic_workspace_folders.md
        fn onChromeDevToolsJSONRequest(this: *ThisServer, req: *uws.Request, resp: *App.Response) void {
            if (comptime Environment.enable_logs)
                httplog("{s} - {s}", .{ req.method(), req.url() });

            const authorized = brk: {
                if (this.dev_server == null)
                    break :brk false;

                if (resp.getRemoteSocketInfo()) |*address| {
                    // IPv4 loopback addresses
                    if (strings.startsWith(address.ip, "127.")) {
                        break :brk true;
                    }

                    // IPv6 loopback addresses
                    if (strings.startsWith(address.ip, "::ffff:127.") or
                        strings.startsWith(address.ip, "::1") or
                        strings.eqlComptime(address.ip, "0:0:0:0:0:0:0:1"))
                    {
                        break :brk true;
                    }
                }

                break :brk false;
            };

            if (!authorized) {
                req.setYield(true);
                return;
            }

            // They need a 16 byte uuid. It needs to be somewhat consistent. We don't want to store this field anywhere.

            // So we first use a hash of the main field:
            const first_hash_segment: [8]u8 = brk: {
                const buffer = bun.path_buffer_pool.get();
                defer bun.path_buffer_pool.put(buffer);
                const main = jsc.VirtualMachine.get().main;
                const len = @min(main.len, buffer.len);
                break :brk @bitCast(bun.hash(bun.strings.copyLowercase(main[0..len], buffer[0..len])));
            };

            // And then we use a hash of their project root directory:
            const second_hash_segment: [8]u8 = brk: {
                const buffer = bun.path_buffer_pool.get();
                defer bun.path_buffer_pool.put(buffer);
                const root = this.dev_server.?.root;
                const len = @min(root.len, buffer.len);
                break :brk @bitCast(bun.hash(bun.strings.copyLowercase(root[0..len], buffer[0..len])));
            };

            // We combine it together to get a 16 byte uuid.
            const hash_bytes: [16]u8 = first_hash_segment ++ second_hash_segment;
            const uuid = bun.UUID.initWith(&hash_bytes);

            // interface DevToolsJSON {
            //   workspace?: {
            //     root: string,
            //     uuid: string,
            //   }
            // }
            const json_string = std.fmt.allocPrint(bun.default_allocator, "{{ \"workspace\": {{ \"root\": {f}, \"uuid\": \"{f}\" }} }}", .{
                bun.fmt.formatJSONStringUTF8(this.dev_server.?.root, .{}),
                uuid,
            }) catch |err| bun.handleOom(err);
            defer bun.default_allocator.free(json_string);

            resp.writeStatus("200 OK") catch |err| return closeResponseAfterWriteFailure(resp, err);
            resp.writeHeader("Content-Type", "application/json") catch |err| return closeResponseAfterWriteFailure(resp, err);
            resp.end(json_string, resp.shouldCloseConnection()) catch |err| closeResponseAfterWriteFailure(resp, err);
        }

        fn prepareRoutes(this: *ThisServer, route_options: RouteOptions) bun.JSError!PreparedRoutes {
            const generation = generation: {
                const users = if (route_options.preserve_users and this.routes != null) users: {
                    const users = this.routes.?.users;
                    users.ref();
                    break :users users;
                } else try UserRoutes.create(this, route_options.config.user_routes_to_build.items);
                errdefer users.deref();
                const result = try bun.default_allocator.create(RouteGeneration);
                result.* = .{
                    .users = users,
                    .http = .init(bun.default_allocator, this.app.?, this.config.is_node_http),
                    .h3 = if (has_h3) .init(bun.default_allocator, this.app.?, this.config.is_node_http) else {},
                };
                break :generation result;
            };
            var prepared: PreparedRoutes = .{
                .generation = generation,
                .html_allocator = if (this.dev_server) |dev| dev.allocator() else bun.default_allocator,
            };
            errdefer prepared.deinit();
            if (route_options.preserve_users and this.routes != null) {
                prepared.route_list = try this.routeListGetCached();
            } else if (generation.users.items.items.len > 0) {
                const builders = route_options.config.user_routes_to_build.items;
                var paths = try bun.bindgen.OwnedNativeSlice(bun.bindgen.DOMString, .vm).Builder.init(builders.len);
                defer paths.deinit();
                var scope: bun.bindgen.FocusedEngineScope = undefined;
                scope.init(this.globalThis);
                defer scope.deinit();
                const operation = scope.engine(ServerRouteListCreateSchema);
                const Callback = std.meta.Elem(@FieldType(@TypeOf(operation).Args, "callbacks"));
                const Path = std.meta.Elem(@FieldType(@TypeOf(operation).Args, "paths"));
                const callbacks = try bun.default_allocator.alloc(Callback, builders.len);
                defer bun.default_allocator.free(callbacks);
                const path_operands = try bun.default_allocator.alloc(Path, builders.len);
                defer bun.default_allocator.free(path_operands);
                for (builders, callbacks, path_operands, 0..) |*builder, *callback, *path_operand, index| {
                    paths.appendOwned(try bun.bindgen.DOMString.fromUTF8(builder.route.path));
                    callback.* = builder.callback.operand(&scope);
                    path_operand.* = paths.slice()[index].operand();
                }
                const result = try operation.call(.{ .callbacks = callbacks, .paths = path_operands });
                prepared.route_list = try result.toOwned();
            }
            try generation.static_routes.ensureTotalCapacity(bun.default_allocator, route_options.config.static_routes.items.len);
            for (route_options.config.static_routes.items) |entry| generation.static_routes.appendAssumeCapacity(try entry.clone());

            const app = &generation.http;
            const h3_routes = if (has_h3) if (this.h3_app != null) &generation.h3 else null else @as(?*void, null);
            _ = &h3_routes;
            const any_server = AnyServer.from(this);
            const dev_server = this.dev_server;
            var should_add_chrome_devtools_json_route = this.config.isDevelopment() and this.config.allow_hot and dev_server != null and this.config.enable_chrome_devtools_automatic_workspace_folders;
            const chrome_devtools_route = "/.well-known/appspecific/com.chrome.devtools.json";

            var star_methods_covered_by_user = bun.http.Method.Set.empty;
            var has_any_user_route_for_star_path = false; // True if "/*" path appears in user_routes at all
            var has_any_ws_route_for_star_path = false;

            for (generation.users.items.items) |*user_route| {
                const is_star_path = strings.eqlComptime(user_route.route.path, "/*");
                if (is_star_path) {
                    has_any_user_route_for_star_path = true;
                }

                if (should_add_chrome_devtools_json_route) {
                    if (strings.eqlComptime(user_route.route.path, chrome_devtools_route) or strings.hasPrefix(user_route.route.path, "/.well-known/")) {
                        should_add_chrome_devtools_json_route = false;
                    }
                }

                // Register HTTP routes
                switch (user_route.route.method) {
                    .any => {
                        try app.any(user_route.route.path, *UserRoute, user_route, onUserRouteRequest);
                        if (comptime has_h3) {
                            if (h3_routes) |h3_app| try h3_app.any(user_route.route.path, *UserRoute, user_route, onH3UserRouteRequest);
                        }
                        if (is_star_path) {
                            star_methods_covered_by_user = .full;
                        }

                        if (route_options.websocket) |websocket| {
                            if (is_star_path) {
                                has_any_ws_route_for_star_path = true;
                            }
                            try app.ws(
                                user_route.route.path,
                                user_route,
                                1, // id 1 means is a user route
                                ServerWebSocket.behavior(ThisServer, ssl_enabled, websocket.toBehavior()),
                            );
                        }
                    },
                    .specific => |method_val| { // method_val is HTTP.Method here
                        try app.method(method_val, user_route.route.path, *UserRoute, user_route, onUserRouteRequest);
                        if (comptime has_h3) {
                            if (h3_routes) |h3_app| try h3_app.method(method_val, user_route.route.path, *UserRoute, user_route, onH3UserRouteRequest);
                        }
                        if (is_star_path) {
                            star_methods_covered_by_user.insert(method_val);
                        }

                        // Setup user websocket in the route if needed.
                        if (route_options.websocket) |websocket| {
                            // Websocket upgrade is a GET request
                            if (method_val == .GET) {
                                try app.ws(
                                    user_route.route.path,
                                    user_route,
                                    1, // id 1 means is a user route
                                    ServerWebSocket.behavior(ThisServer, ssl_enabled, websocket.toBehavior()),
                                );
                            }
                        }
                    },
                }
            }

            for (route_options.config.negative_routes.items) |route_path| {
                try app.head(route_path, *ThisServer, this, onRequest);
                try app.any(route_path, *ThisServer, this, onRequest);
                if (comptime has_h3) {
                    if (h3_routes) |h3_app| {
                        try h3_app.head(route_path, *ThisServer, this, onH3Request);
                        try h3_app.any(route_path, *ThisServer, this, onH3Request);
                    }
                }
            }

            var needs_plugins = dev_server != null;
            var has_static_route_for_star_path = false;

            if (generation.static_routes.items.len > 0) {
                for (generation.static_routes.items) |*entry| {
                    if (strings.eqlComptime(entry.path, "/*")) {
                        has_static_route_for_star_path = true;
                        switch (entry.method) {
                            .any => {
                                star_methods_covered_by_user = .full;
                            },
                            .method => |method| {
                                star_methods_covered_by_user.setUnion(method);
                            },
                        }
                    }

                    if (should_add_chrome_devtools_json_route) {
                        if (strings.eqlComptime(entry.path, chrome_devtools_route) or strings.hasPrefix(entry.path, "/.well-known/")) {
                            should_add_chrome_devtools_json_route = false;
                        }
                    }

                    switch (entry.route) {
                        .static => |static_route| {
                            try ServerConfig.applyStaticRoute(any_server, ssl_enabled, app, *StaticRoute, static_route, entry.path, entry.method);
                            if (comptime has_h3) if (h3_routes) |h3_app|
                                try ServerConfig.applyStaticRouteH3(any_server, h3_app, *StaticRoute, static_route, entry.path, entry.method);
                        },
                        .file => |file_route| {
                            try ServerConfig.applyStaticRoute(any_server, ssl_enabled, app, *FileRoute, file_route, entry.path, entry.method);
                            if (comptime has_h3) if (h3_routes) |h3_app|
                                try ServerConfig.applyStaticRouteH3(any_server, h3_app, *FileRoute, file_route, entry.path, entry.method);
                        },
                        .html => |html_bundle_route| {
                            try ServerConfig.applyStaticRoute(any_server, ssl_enabled, app, *HTMLBundle.Route, html_bundle_route.data, entry.path, entry.method);
                            if (comptime has_h3) if (h3_routes) |h3_app|
                                try ServerConfig.applyStaticRouteH3(any_server, h3_app, *HTMLBundle.Route, html_bundle_route.data, entry.path, entry.method);
                            if (dev_server != null) {
                                try prepared.html_router.put(prepared.html_allocator, entry.path, html_bundle_route.data);
                            }
                            needs_plugins = true;
                        },
                        .framework_router => {},
                    }
                }
            }

            if (needs_plugins and this.plugins == null) {
                if (this.vm.transpiler.options.serve_plugins) |serve_plugins_config| {
                    if (serve_plugins_config.len > 0) {
                        prepared.plugins = try ServePlugins.init(serve_plugins_config);
                    }
                }
            }

            if (this.config.isDevelopment()) {
                try app.get("/bun:info", *ThisServer, this, onBunInfoRequest);
            }

            // Snapshot "/*" coverage from user/static routes before DevServer
            // (which is H1-only and not mirrored to the H3 router) marks it
            // as full.
            const h3_star_covered = star_methods_covered_by_user;
            _ = &h3_star_covered;

            var has_dev_server_for_star_path = false;
            if (dev_server) |dev| {
                // dev.setRoutes might register its own "/*" HTTP handler
                has_dev_server_for_star_path = try dev.setRoutes(app);
                if (has_dev_server_for_star_path) {
                    // Assume dev server "/*" covers all methods if it exists
                    star_methods_covered_by_user = .full;
                }
            }

            // Setup user websocket fallback route aka fetch function if fetch is not provided will respond with 403.
            if (!has_any_ws_route_for_star_path) {
                if (route_options.websocket) |websocket| {
                    try app.ws(
                        "/*",
                        this,
                        0, // id 0 means is a fallback route and ctx is the server
                        ServerWebSocket.behavior(ThisServer, ssl_enabled, websocket.toBehavior()),
                    );
                }
            }

            if (star_methods_covered_by_user.eql(bun.http.Method.Set.full)) {
                // User/Static/Dev has already provided a "/*" handler for ALL methods.
                // No further global "/*" HTTP fallback needed.
            } else if (has_any_user_route_for_star_path or has_static_route_for_star_path or has_dev_server_for_star_path) {
                // A "/*" route exists, but doesn't cover all methods.
                // Apply the global handler to the *remaining* methods for "/*".
                // So we flip the bits for the methods that are not covered by the user/static/dev routes
                star_methods_covered_by_user.toggleAll();
                var iter = star_methods_covered_by_user.iterator();
                while (iter.next()) |method_to_cover| {
                    if (route_options.node_http)
                        try app.method(method_to_cover, "/*", *ThisServer, this, onNodeHTTPRequest)
                    else if (route_options.fetch)
                        try app.method(method_to_cover, "/*", *ThisServer, this, onRequest)
                    else
                        try app.method(method_to_cover, "/*", *ThisServer, this, on404);
                }
            } else {
                if (route_options.node_http)
                    try app.any("/*", *ThisServer, this, onNodeHTTPRequest)
                else if (route_options.fetch)
                    try app.any("/*", *ThisServer, this, onRequest)
                else
                    try app.any("/*", *ThisServer, this, on404);
            }

            // H3 fallback — same three-way as H1 above, but driven by
            // user/static "/*" coverage only (DevServer routes are not mirrored
            // to H3). try h3_app.any("/*") would overwrite a user .any "/*"
            // mirrored at line 2714, so skip when coverage is already full;
            // for method-specific "/*" routes fill the complement per method.
            if (comptime has_h3) {
                if (h3_routes) |h3_app| {
                    if (h3_star_covered.eql(bun.http.Method.Set.full)) {
                        // user/static "/*" already covers every method
                    } else if (has_any_user_route_for_star_path or has_static_route_for_star_path) {
                        var uncovered = h3_star_covered;
                        uncovered.toggleAll();
                        var iter = uncovered.iterator();
                        while (iter.next()) |m| {
                            if (route_options.fetch) {
                                try h3_app.method(m, "/*", *ThisServer, this, onH3Request);
                            } else {
                                try h3_app.method(m, "/*", *ThisServer, this, onH3404);
                            }
                        }
                    } else if (route_options.fetch) {
                        try h3_app.any("/*", *ThisServer, this, onH3Request);
                    } else {
                        try h3_app.any("/*", *ThisServer, this, onH3404);
                    }
                }
            }

            if (should_add_chrome_devtools_json_route) {
                try app.get(chrome_devtools_route, *ThisServer, this, onChromeDevToolsJSONRequest);
            }

            return prepared;
        }

        pub fn on404(_: *ThisServer, req: *uws.Request, resp: *App.Response) void {
            if (comptime Environment.enable_logs)
                httplog("{s} - {s} 404", .{ req.method(), req.url() });

            resp.writeStatus("404 Not Found") catch |err| return closeResponseAfterWriteFailure(resp, err);

            // Rely on browser default page for now.
            resp.end("", false) catch |err| closeResponseAfterWriteFailure(resp, err);
        }

        pub fn listen(this: *ThisServer, context: anytype) bun.bindgen.CallError(@TypeOf(context))!?ServerRouteListValue {
            httplog("listen", .{});
            var app: *App = undefined;
            const globalThis = this.globalThis;
            var route_list_value: ?ServerRouteListValue = null;
            errdefer if (route_list_value) |*route_list| route_list.deinit();
            if (ssl_enabled) {
                bun.BoringSSL.load();
                const ssl_config = this.config.ssl_config orelse @panic("Assertion failure: ssl_config");
                const ssl_options = ssl_config.asUSockets();

                var tls_failure: uws.TLSContextFailure = .{};
                const tls_context = ssl_options.createSSLContext(&tls_failure) orelse {
                    return @import("../socket/TLSFailure.zig").fromContextCreation(context, tls_failure);
                };
                defer bun.BoringSSL.c.SSL_CTX_free(tls_context);
                app = try App.create(tls_context, ssl_options.request_cert != 0, ssl_options.reject_unauthorized != 0);

                this.app = app;

                if (comptime has_h3) {
                    if (this.config.http3) {
                        this.h3_app = uws.H3.App.create(ssl_options, this.config.idleTimeout) orelse {
                            if (!globalThis.hasException()) {
                                globalThis.throw("Failed to create HTTP/3 server", .{}) catch {};
                            }
                            return error.JSError;
                        };
                    }
                }

                // add serverName to the SSL context using default ssl options
                if (ssl_config.server_name) |server_name| {
                    if (server_name.len > 0) {
                        const domain_context = ssl_options.createSSLContext(&tls_failure) orelse {
                            return @import("../socket/TLSFailure.zig").fromContextCreation(context, tls_failure);
                        };
                        defer bun.BoringSSL.c.SSL_CTX_free(domain_context);
                        app.addServerName(server_name, domain_context) catch |err| {
                            if (err == error.OutOfMemory) return error.OutOfMemory;
                            return failServerNameRegistration(context, server_name);
                        };
                    }
                }

                // apply SNI routes if any
                if (this.config.sni) |*sni| {
                    for (sni.slice()) |*sni_ssl_config| {
                        const sni_servername = sni_ssl_config.server_name.?;
                        if (sni_servername.len > 0) {
                            if (comptime has_h3) if (this.h3_app) |h3a|
                                h3a.addServerNameWithOptions(sni_servername, sni_ssl_config.asUSockets()) catch {
                                    if (!globalThis.hasException()) {
                                        globalThis.throw("Failed to add serverName \"{s}\" for HTTP/3", .{sni_servername}) catch {};
                                    }
                                    return error.JSError;
                                };
                            const sni_context = sni_ssl_config.asUSockets().createSSLContext(&tls_failure) orelse {
                                return @import("../socket/TLSFailure.zig").fromContextCreation(context, tls_failure);
                            };
                            defer bun.BoringSSL.c.SSL_CTX_free(sni_context);
                            app.addServerName(sni_servername, sni_context) catch |err| {
                                if (err == error.OutOfMemory) return error.OutOfMemory;
                                return failServerNameRegistration(context, sni_servername);
                            };
                        }
                    }
                }
            } else {
                app = try App.create(null, false, false);
                this.app = app;
            }

            var prepared_routes = try this.prepareRoutes(.{
                .config = &this.config,
                .preserve_users = false,
                .fetch = this.config.onRequest.configured,
                .node_http = this.config.onNodeHTTPRequest.configured,
                .websocket = if (this.config.websocket) |*value| value else null,
            });
            defer prepared_routes.deinit();
            this.publishRoutes(&prepared_routes);
            consumeRouteBuilders(&this.config);
            route_list_value = prepared_routes.route_list;
            prepared_routes.route_list = null;

            if (this.config.onNodeHTTPRequest.configured) {
                this.setUsingCustomExpectHandler(true);
            }

            switch (this.config.address) {
                .tcp => |tcp| {
                    var host: ?[*:0]const u8 = null;
                    var host_buff: [1024:0]u8 = undefined;

                    if (tcp.hostname) |existing| {
                        const hostname = bun.span(existing);

                        if (hostname.len > 2 and hostname[0] == '[') {
                            // remove "[" and "]" from hostname
                            host = std.mem.printSentinel(&host_buff, "{s}", .{hostname[1 .. hostname.len - 1]}, 0) catch unreachable;
                        } else {
                            host = tcp.hostname;
                        }
                    }

                    if (this.config.http1) {
                        var failure: uws.ListenFailure = .{};
                        this.listener = app.listenWithConfig(.{
                            .port = tcp.port,
                            .host = host,
                            .options = this.config.getUsocketsOptions(),
                        }, &failure) orelse return this.failListen(context, failure);
                        this.vm.event_loop_handle = Async.Loop.get();
                    }

                    if (comptime has_h3) {
                        if (this.h3_app) |h3_app| {
                            // Same UDP port as the TCP listener so Alt-Svc works.
                            const h3_port: u16 = if (this.listener) |ls| @intCast(ls.getLocalPort()) else tcp.port;
                            h3_app.listenWithConfig(*ThisServer, this, onH3Listen, .{
                                .port = h3_port,
                                .host = host,
                                .options = this.config.getUsocketsOptions(),
                            });
                            if (this.h3_listener == null) {
                                if (!globalThis.hasException()) {
                                    globalThis.throw("Failed to listen on UDP port {d} for HTTP/3", .{h3_port}) catch {};
                                }
                                return error.JSError;
                            }
                            if (!this.config.http1) this.vm.event_loop_handle = Async.Loop.get();
                        }
                    }
                },

                .unix => |unix| {
                    if (comptime has_h3) if (this.h3_app) |h3a| {
                        // QUIC over AF_UNIX is non-standard and Alt-Svc can't
                        // advertise it. Drop the H3 listener rather than wire
                        // an exotic transport nobody can reach.
                        bun.Output.warn("http3: true with a unix socket — HTTP/3 listener skipped", .{});
                        h3a.destroy();
                        this.h3_app = null;
                    };
                    var failure: uws.ListenFailure = .{};
                    this.listener = app.listenOnUnixSocket(
                        unix,
                        this.config.getUsocketsOptions(),
                        &failure,
                    ) orelse return this.failListen(context, failure);
                    this.vm.event_loop_handle = Async.Loop.get();
                },
            }

            if (globalThis.hasException()) {
                return error.JSError;
            }

            this.ref();

            // Starting up an HTTP server is a good time to GC
            if (this.vm.aggressive_garbage_collection == .aggressive) {
                this.vm.autoGarbageCollect();
            } else {
                this.vm.eventLoop().performGC();
            }

            return route_list_value;
        }

        pub fn onClientErrorCallback(this: *ThisServer, socket: *uws.Socket, error_code: u8, raw_packet: []const u8) void {
            var callback = if (this.on_clienterror) |*value| value.clone() else return;
            defer callback.deinit();
            var server_ref = this.serverClassRef() catch |err| return this.globalThis.reportActiveExceptionAsUnhandled(err);
            defer deinitHTTPServerReference(&server_ref);
            const is_ssl = protocol_enum == .https;
            const SocketHandle = bun.bindgen.EngineArgumentType(NodeHTTPServerSocketCreateForClientErrorSchema, "socket");
            var scope: bun.bindgen.FocusedEngineScope = undefined;
            scope.init(this.globalThis);
            defer scope.deinit();
            const socket_result = scope.engine(NodeHTTPServerSocketCreateForClientErrorSchema).call(.{
                .isSSL = is_ssl,
                .socket = @as(SocketHandle, @ptrCast(socket)),
            }) catch |err| return this.globalThis.reportActiveExceptionAsUnhandled(err);
            var node_socket = socket_result.toOwned() catch |err| return this.globalThis.reportActiveExceptionAsUnhandled(err);
            defer node_socket.deinit();

            var packet = bun.bindgen.OwnedBytes.fromSlice(raw_packet) catch |err| return this.globalThis.reportActiveExceptionAsUnhandled(err);
            defer packet.deinit();
            var invocation: ServerClientErrorCallback.Invocation = undefined;
            callback.beginInvocation(&invocation);
            defer invocation.deinit();
            const socket_view = node_socket.view(&invocation) catch |err| return invocation.reportActiveException(err);
            const event_loop = this.vm.eventLoop();
            event_loop.enter();
            defer event_loop.exit();
            invocation.call(.{
                .isSSL = is_ssl,
                .socket = socket_view.operand(&invocation),
                .errorCode = error_code,
                .rawPacket = packet.operand(),
            }) catch |err| invocation.reportActiveException(err);
        }
    };
}

pub const AnyRequestContext = @import("./AnyRequestContext.zig").WithTypes(HTTPServer, HTTPSServer, bun.bake.DevServer);
pub const RequestContextModule = @import("./RequestContext.zig");
pub const NewRequestContext = RequestContextModule.NewRequestContext;

pub const SavedRequest = struct {
    request_ref: RequestReference,
    request: *Request,
    ctx: AnyRequestContext,
    response: uws.AnyResponse,

    pub fn deinit(sr: *SavedRequest) void {
        sr.request_ref.deinit();
        sr.ctx.deref();
    }

    pub const Union = union(enum) {
        /// Direct pointer to a µWebSockets request that is still on the stack.
        /// Used for synchronous request handling where the request can be processed
        /// immediately within the current call frame. This avoids heap allocation
        /// and is more efficient for simple, fast operations.
        stack: *uws.Request,

        /// A heap-allocated copy of the request data that persists beyond the
        /// initial request handler. Used when request processing needs to be
        /// deferred (e.g., async operations, waiting for framework initialization).
        /// Contains strong references to JavaScript objects and all context needed
        /// to complete the request later.
        saved: bun.jsc.API.SavedRequest,
    };
};

pub const HTTPServer = NewServer(.http);
pub const HTTPSServer = NewServer(.https);
pub const AnyServer = struct {
    ptr: Ptr,

    pub const RouteLease = union(enum) {
        none,
        http: *HTTPServer.RouteGeneration,
        https: *HTTPSServer.RouteGeneration,

        pub fn deinit(this: *RouteLease) void {
            const lease = this.*;
            this.* = .none;
            switch (lease) {
                .none => {},
                inline else => |routes| routes.deref(),
            }
        }
    };

    pub fn retainRoutes(this: AnyServer) RouteLease {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => if (this.ptr.as(HTTPServer).retainRoutes()) |routes| .{ .http = routes } else .none,
            Ptr.case(HTTPSServer) => if (this.ptr.as(HTTPSServer).retainRoutes()) |routes| .{ .https = routes } else .none,
            else => unreachable,
        };
    }

    pub const Ptr = bun.TaggedPointerUnion(.{
        HTTPServer,
        HTTPSServer,
    });

    pub const AnyUserRouteList = union(enum) {
        HTTPServer: []const HTTPServer.UserRoute,
        HTTPSServer: []const HTTPSServer.UserRoute,
    };

    pub fn userRoutes(this: AnyServer) AnyUserRouteList {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => .{ .HTTPServer = this.ptr.as(HTTPServer).userRouteSlice() },
            Ptr.case(HTTPSServer) => .{ .HTTPSServer = this.ptr.as(HTTPSServer).userRouteSlice() },
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    pub fn getURLAsString(this: AnyServer) bun.OOM!bun.String {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).getURLAsString(),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).getURLAsString(),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }
    pub fn vm(this: AnyServer) *jsc.VirtualMachine {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).vm,
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).vm,
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }
    /// Cached `h3=":<port>"; ma=86400` for Alt-Svc on H1/H2 responses, or
    /// null when the server has no H3 listener. Static/file/HTML routes
    /// emit it via this so browsers discover the QUIC endpoint regardless
    /// of which response path produced the body.
    pub fn h3AltSvc(this: AnyServer) ?[]const u8 {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).h3AltSvc(),
            else => null,
        };
    }
    pub fn setInspectorServerID(this: AnyServer, id: jsc.Debugger.DebuggerId) void {
        switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => {
                this.ptr.as(HTTPServer).inspector_server_id = id;
                if (this.ptr.as(HTTPServer).dev_server) |dev_server| {
                    dev_server.inspector_server_id = id;
                }
            },
            Ptr.case(HTTPSServer) => {
                this.ptr.as(HTTPSServer).inspector_server_id = id;
                if (this.ptr.as(HTTPSServer).dev_server) |dev_server| {
                    dev_server.inspector_server_id = id;
                }
            },
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        }
    }

    pub fn inspectorServerID(this: AnyServer) jsc.Debugger.DebuggerId {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).inspector_server_id,
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).inspector_server_id,
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    pub fn plugins(this: AnyServer) ?*ServePlugins {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).plugins,
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).plugins,
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    pub fn loadAndResolvePlugins(this: AnyServer, bundle: *HTMLBundle.HTMLBundleRoute, raw_plugins: []const []const u8, bunfig_path: []const u8) void {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).getPluginsAsync(bundle, raw_plugins, bunfig_path),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).getPluginsAsync(bundle, raw_plugins, bunfig_path),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    /// Returns:
    /// - .ready if no plugin has to be loaded
    /// - .err if there is a cached failure. Currently, this requires restarting the entire server.
    /// - .pending if `callback` was stored. It will call `onPluginsResolved` or `onPluginsRejected` later.
    pub fn getOrLoadPlugins(server: AnyServer, callback: ServePlugins.Callback) ServePlugins.GetOrStartLoadResult {
        return switch (server.ptr.tag()) {
            Ptr.case(HTTPServer) => server.ptr.as(HTTPServer).getOrLoadPlugins(callback),
            Ptr.case(HTTPSServer) => server.ptr.as(HTTPSServer).getOrLoadPlugins(callback),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    pub fn reloadStaticRoutes(this: AnyServer) bun.JSError!bool {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).reloadStaticRoutes(),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).reloadStaticRoutes(),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    pub fn appendStaticRoute(this: AnyServer, path: []const u8, route: AnyRoute, method: HTTP.Method.Optional) !void {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).appendStaticRoute(path, route, method),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).appendStaticRoute(path, route, method),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    pub fn globalThis(this: AnyServer) *jsc.JSGlobalObject {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).globalThis,
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).globalThis,
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    pub fn config(this: AnyServer) *const ServerConfig {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => &this.ptr.as(HTTPServer).config,
            Ptr.case(HTTPSServer) => &this.ptr.as(HTTPSServer).config,
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    pub fn handlerCallback(this: AnyServer, comptime slot_name: []const u8) bun.JSError!?bun.bindgen.Callback(bun.bindgen.CallbackSchema(callbackNameForSlot(slot_name))) {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).handlerCallback(slot_name),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).handlerCallback(slot_name),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    pub fn webSocketCallback(this: AnyServer, comptime slot_name: []const u8) bun.JSError!?bun.bindgen.Callback(bun.bindgen.CallbackSchema(callbackNameForSlot(slot_name))) {
        return this.handlerCallback(slot_name);
    }

    pub fn webSocketHandler(this: AnyServer) ?*WebSocketServerContext.Handler {
        const server_config: *ServerConfig = switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => &this.ptr.as(HTTPServer).config,
            Ptr.case(HTTPSServer) => &this.ptr.as(HTTPSServer).config,
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
        if (server_config.websocket == null) return null;
        return &server_config.websocket.?.handler;
    }

    pub fn onRequest(
        this: AnyServer,
        req: *uws.Request,
        resp: bun.uws.AnyResponse,
    ) void {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).onRequest(req, resp.assertNoSSL()),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).onRequest(req, resp.assertSSL()),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    pub fn fetchFromBinding(
        this: AnyServer,
        context: anytype,
        args: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).onFetchFromBinding(context, args.input, args.options),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).onFetchFromBinding(context, args.input, args.options),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    pub fn reloadFromBinding(
        this: AnyServer,
        context: anytype,
        args: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!void {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).onReloadFromBinding(context, args.options),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).onReloadFromBinding(context, args.options),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    pub fn upgradeFromBinding(
        this: AnyServer,
        context: anytype,
        args: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!bool {
        const request = args.request orelse return context.fail(.missing_request, {});
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).onUpgradeFromBinding(context, request, args.options),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).onUpgradeFromBinding(context, request, args.options),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    pub fn from(server: anytype) AnyServer {
        return .{ .ptr = Ptr.init(server) };
    }

    pub fn fromBinding(input: anytype) AnyServer {
        return switch (input) {
            .debug_http => |class_ref| AnyServer.from(HTTPServer.fromDebugClassRef(class_ref)),
            .debug_https => |class_ref| AnyServer.from(HTTPSServer.fromDebugClassRef(class_ref)),
            .http => |class_ref| AnyServer.from(HTTPServer.fromProductionClassRef(class_ref)),
            .https => |class_ref| AnyServer.from(HTTPSServer.fromProductionClassRef(class_ref)),
        };
    }

    pub fn setIdleTimeout(this: AnyServer, seconds: u32) void {
        switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).setIdleTimeout(seconds),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).setIdleTimeout(seconds),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        }
    }

    pub fn setFlags(this: AnyServer, require_host_header: bool, use_strict_method_validation: bool) void {
        switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).setFlags(require_host_header, use_strict_method_validation),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).setFlags(require_host_header, use_strict_method_validation),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        }
    }

    pub fn setOnClientError(this: AnyServer, callback: *ServerClientErrorCallback) void {
        switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => {
                const server = this.ptr.as(HTTPServer);
                if (server.app) |app| {
                    if (server.on_clienterror) |*previous| previous.deinit();
                    server.on_clienterror = callback.take();
                    app.onClientError(*HTTPServer, server, HTTPServer.onClientErrorCallback);
                }
            },
            Ptr.case(HTTPSServer) => {
                const server = this.ptr.as(HTTPSServer);
                if (server.app) |app| {
                    if (server.on_clienterror) |*previous| previous.deinit();
                    server.on_clienterror = callback.take();
                    app.onClientError(*HTTPSServer, server, HTTPSServer.onClientErrorCallback);
                }
            },
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        }
    }

    pub fn setMaxHTTPHeaderSize(this: AnyServer, max_header_size: u64) void {
        switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).setMaxHTTPHeaderSize(max_header_size),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).setMaxHTTPHeaderSize(max_header_size),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        }
    }

    pub fn onPendingRequest(this: AnyServer) void {
        switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).onPendingRequest(),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).onPendingRequest(),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        }
    }

    pub fn onRequestComplete(this: AnyServer) void {
        switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).onRequestComplete(),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).onRequestComplete(),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        }
    }

    pub fn onRequestCancelled(this: AnyServer) void {
        switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).onRequestCancelled(),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).onRequestCancelled(),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        }
    }

    pub fn onStaticRequestComplete(this: AnyServer) void {
        switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).onStaticRequestComplete(),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).onStaticRequestComplete(),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        }
    }

    pub fn publish(this: AnyServer, topic: []const u8, message: []const u8, opcode: uws.Opcode, compress: bool) bool {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).app.?.publish(topic, message, opcode, compress),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).app.?.publish(topic, message, opcode, compress),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    pub fn onSavedRequest(
        this: AnyServer,
        req: SavedRequest.Union,
        resp: uws.AnyResponse,
        callback: *const DevServerFrameworkRequestCallback,
        metadata: *const DevServerFrameworkRequestMetadata,
        ensure_async_local_storage: *const DevServerEnsureAsyncLocalStorageCallback,
        bundle_new_route: *const DevServerBundleNewRouteCallback,
        new_route_params: *const DevServerNewRouteParamsCallback,
    ) void {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).onSavedRequest(req, resp.TCP, callback, metadata, ensure_async_local_storage, bundle_new_route, new_route_params),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).onSavedRequest(req, resp.SSL, callback, metadata, ensure_async_local_storage, bundle_new_route, new_route_params),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    pub fn prepareAndSaveJsRequestContext(
        server: AnyServer,
        req: *uws.Request,
        resp: uws.AnyResponse,
        method: ?bun.http.Method,
    ) bun.JSError!?SavedRequest {
        return switch (server.ptr.tag()) {
            Ptr.case(HTTPServer) => request: {
                var prepared = server.ptr.as(HTTPServer).prepareJsRequestContext(req, resp.TCP, null, .bake, method) orelse return null;
                defer prepared.deinit();
                break :request prepared.save(req, resp.TCP) catch |err| {
                    prepared.ctx.fail(err);
                    return null;
                };
            },
            Ptr.case(HTTPSServer) => request: {
                var prepared = server.ptr.as(HTTPSServer).prepareJsRequestContext(req, resp.SSL, null, .bake, method) orelse return null;
                defer prepared.deinit();
                break :request prepared.save(req, resp.SSL) catch |err| {
                    prepared.ctx.fail(err);
                    return null;
                };
            },
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }
    pub fn numSubscribers(this: AnyServer, topic: []const u8) u32 {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).app.?.numSubscribers(topic),
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).app.?.numSubscribers(topic),
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }

    pub fn devServer(this: AnyServer) ?*bun.bake.DevServer {
        return switch (this.ptr.tag()) {
            Ptr.case(HTTPServer) => this.ptr.as(HTTPServer).dev_server,
            Ptr.case(HTTPSServer) => this.ptr.as(HTTPSServer).dev_server,
            else => bun.unreachablePanic("Invalid pointer tag", .{}),
        };
    }
};

comptime {
    _ = ServePluginsOnResolveBinding;
    _ = ServePluginsOnRejectBinding;
}

fn failServerNameRegistration(context: anytype, hostname: []const u8) bindgen.CallError(@TypeOf(context)) {
    const message = try std.fmt.allocPrint(bun.default_allocator, "Failed to add serverName: {s}", .{hostname});
    defer bun.default_allocator.free(message);
    return context.fail(.server_name_registration_failed, try bindgen.DOMString.fromUTF8(message));
}

const string = []const u8;

const options = @import("../../bundler/options.zig");
const std = @import("std");
const URL = @import("../../url/url.zig").URL;
const Allocator = std.mem.Allocator;

const Runtime = @import("../../js_parser/runtime.zig");
const Fallback = Runtime.Fallback;

const bun = @import("bun");
const bindgen = bun.bindgen;
const Async = bun.Async;
const Environment = bun.Environment;
const Global = bun.Global;
const Output = bun.Output;
const Transpiler = bun.Transpiler;
const analytics = bun.analytics;
const assert = bun.assert;
const default_allocator = bun.default_allocator;
const js_printer = bun.js_printer;
const logger = bun.logger;
const strings = bun.strings;
const uws = bun.uws;
const BoringSSL = bun.BoringSSL.c;
const SocketAddress = bun.api.socket.SocketAddress;
const HTTP = bun.http;
const MimeType = HTTP.MimeType;

const jsc = bun.jsc;
const JSGlobalObject = bun.jsc.JSGlobalObject;
const Node = bun.jsc.Node;
const VM = bun.jsc.VM;
const VirtualMachine = jsc.VirtualMachine;

const PromiseBindings = bun.bindgen.Module("promises");
const BunServeSchema = bun.bindgen.Module("BunObject").function("serve");
const HTTPServerBindingModule = bun.bindgen.Module("HTTPServer");
const ServeFetchCallbackType = bun.bindgen.CallbackSchema("ServeFetchCallback");
const ServeFetchCallback = bun.bindgen.Callback(ServeFetchCallbackType);
const ServeErrorCallbackType = bun.bindgen.CallbackSchema("ServeErrorCallback");
const ServeErrorCallback = bun.bindgen.Callback(ServeErrorCallbackType);
const ServeCallbackResult = bun.bindgen.Return(ServeFetchCallbackType);
const NodeHTTPRequestCallbackType = bun.bindgen.CallbackSchema("NodeHTTPServerRequestCallback");
const NodeHTTPRequestCallback = bun.bindgen.Callback(NodeHTTPRequestCallbackType);
const NodeHTTPRequestResponseReference = bun.bindgen.ClassRefView(bun.bindgen.Module("NodeHTTPResponse").class("NodeHTTPResponse"));
const PreparedNodeHTTPRequest = bun.bindgen.Return(NodeHTTPServerPrepareRequestSchema);
const RequestReference = Request.Ref;
const HTTPServerReference = union(enum) {
    debug_http: bun.bindgen.ClassRef(HTTPServerBindingModule.class("DebugHTTPServer")),
    debug_https: bun.bindgen.ClassRef(HTTPServerBindingModule.class("DebugHTTPSServer")),
    http: bun.bindgen.ClassRef(HTTPServerBindingModule.class("HTTPServer")),
    https: bun.bindgen.ClassRef(HTTPServerBindingModule.class("HTTPSServer")),

    fn operand(reference: *const @This(), context: anytype) @FieldType(bun.bindgen.Args(ServeFetchCallbackType), "server") {
        const Value = @FieldType(bun.bindgen.Args(ServeFetchCallbackType), "server");
        return switch (reference.*) {
            inline else => |*value, tag| @unionInit(Value, @tagName(tag), value.operand(context)),
        };
    }
};
const DevServerFrameworkRequestCallbackType = bun.bindgen.CallbackSchema("DevServerFrameworkRequestCallback");
const DevServerFrameworkRequestCallback = bun.bindgen.Callback(DevServerFrameworkRequestCallbackType);
const DevServerFrameworkRequestMetadata = @FieldType(bun.bindgen.Args(DevServerFrameworkRequestCallbackType), "metadata");
const DevServerEnsureAsyncLocalStorageCallback = bun.bindgen.Callback(bun.bindgen.CallbackSchema("DevServerEnsureAsyncLocalStorageCallback"));
const DevServerBundleNewRouteCallback = bun.bindgen.Callback(bun.bindgen.CallbackSchema("DevServerBundleNewRouteCallback"));
const DevServerNewRouteParamsCallback = bun.bindgen.Callback(bun.bindgen.CallbackSchema("DevServerNewRouteParamsCallback"));

fn callPreparedNodeHTTPRequest(
    invocation: *NodeHTTPRequestCallback.Invocation,
    server: *HTTPServerReference,
    response: *const NodeHTTPRequestResponseReference,
    prepared: *const PreparedNodeHTTPRequest,
    has_body: bool,
) bun.JSError!bun.bindgen.Return(NodeHTTPRequestCallbackType) {
    return invocation.call(.{
        .server = server.operand(invocation),
        .url = prepared.url.operand(invocation),
        .method = prepared.method.operand(invocation),
        .headers = prepared.headers.operand(invocation),
        .raw_headers = prepared.raw_headers.operand(invocation),
        .response = response.operand(invocation),
        .has_body = has_body,
        .socket = prepared.socket.operand(invocation),
        .new_socket = prepared.new_socket,
        .duplex = if (prepared.duplex) |*duplex| duplex.operand(invocation) else null,
        .ancient = prepared.ancient,
        .head = if (prepared.head) |*head| head.operand() else null,
    });
}

fn deinitServeCallbackResult(result: *ServeCallbackResult) void {
    bun.bindgen.deinitReturn(ServeFetchCallbackType, result);
}

fn callbackNameForSlot(comptime slot_name: []const u8) []const u8 {
    inline for (.{
        .{ "onRequest", "ServeFetchCallback" },
        .{ "onError", "ServeErrorCallback" },
        .{ "onNodeHTTPRequest", "NodeHTTPServerRequestCallback" },
        .{ "wsOnOpen", "ServeWebSocketOpenCallback" },
        .{ "wsOnMessage", "ServeWebSocketMessageCallback" },
        .{ "wsOnClose", "ServeWebSocketCloseCallback" },
        .{ "wsOnDrain", "ServeWebSocketDrainCallback" },
        .{ "wsOnError", "ServeWebSocketErrorCallback" },
        .{ "wsOnPing", "ServeWebSocketPingCallback" },
        .{ "wsOnPong", "ServeWebSocketPongCallback" },
    }) |entry| {
        if (std.mem.eql(u8, slot_name, entry[0])) return entry[1];
    }
    @compileError("unknown HTTP server callback slot: " ++ slot_name);
}

fn deinitHTTPServerReference(reference: *HTTPServerReference) void {
    switch (reference.*) {
        inline else => |*class_ref| class_ref.deinit(),
    }
}
const ServerRouteListBindings = bun.bindgen.Module("ServerRouteList");
const ServePluginsBindings = bun.bindgen.Module("ServePlugins");
const NodeHTTPBindings = bun.bindgen.Module("NodeHTTP");
const NodeHTTPSetCustomOptionsSchema = NodeHTTPBindings.function("setCustomOptions");
const ServerClientErrorCallback = bun.bindgen.Callback(NodeHTTPSetCustomOptionsSchema.args[4].ArgumentType);
const NodeHTTPAssignOnNodeJSCompatSchema = NodeHTTPBindings.engineShim("nodeHTTPAssignOnNodeJSCompat");
const NodeHTTPSetUsingCustomExpectHandlerSchema = NodeHTTPBindings.engineShim("nodeHTTPSetUsingCustomExpectHandler");
const NodeHTTPServerCreateResponseSchema = NodeHTTPBindings.engineShim("nodeHTTPServerCreateResponse");
const NodeHTTPServerPrepareRequestSchema = NodeHTTPBindings.engineShim("nodeHTTPServerPrepareRequest");
const NodeHTTPServerSocketCreateForClientErrorSchema = NodeHTTPBindings.engineShim("nodeHTTPServerSocketCreateForClientError");
const ServerRouteListPrepareRouteSchema = ServerRouteListBindings.engineShim("prepareRoute");
const ServerRouteListCreateSchema = ServerRouteListBindings.engineShim("create");
const ServePluginsOnResolveSchema = ServePluginsBindings.function("onResolve");
const ServePluginsOnRejectSchema = ServePluginsBindings.function("onReject");
const ServePluginsOnResolveBinding = bun.bindgen.Fn(ServePluginsOnResolveSchema, ServePlugins.bindOnResolve);
const ServePluginsOnRejectBinding = bun.bindgen.Fn(ServePluginsOnRejectSchema, ServePlugins.bindOnReject);
const PromiseStatusShim = PromiseBindings.engineShim("promiseStatus");
const PromiseResultShim = PromiseBindings.engineShim("promiseResult");
const PromiseSetHandledShim = PromiseBindings.engineShim("promiseSetHandled");
const HTTPMethodToJSShim = bun.bindgen.Module("HTTPMethod").engineShim("httpMethodToJS");

const WebCore = bun.jsc.WebCore;
const Blob = jsc.WebCore.Blob;
const Fetch = WebCore.Fetch;
const Headers = WebCore.Headers;
const Request = WebCore.Request;
const Response = WebCore.Response;
