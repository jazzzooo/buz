const default_extensions = &[_][]const u8{
    "tsx",
    "jsx",
    "ts",
    "mjs",
    "cjs",
    "js",
};

const OwnedArena = struct {
    state: *bun.ArenaAllocator,

    fn init(backing_allocator: std.mem.Allocator) !OwnedArena {
        const state = try backing_allocator.create(bun.ArenaAllocator);
        state.* = bun.ArenaAllocator.init(backing_allocator);
        return .{ .state = state };
    }

    fn allocator(this: *const OwnedArena) std.mem.Allocator {
        return this.state.allocator();
    }

    fn deinit(this: *OwnedArena) void {
        const backing_allocator = this.state.child_allocator;
        this.state.deinit();
        backing_allocator.destroy(this.state);
        this.* = undefined;
    }
};

const OwnedRouteConfig = struct {
    arena: OwnedArena,
    value: Options.RouteConfig = .{},

    fn init(backing_allocator: std.mem.Allocator) !OwnedRouteConfig {
        return .{ .arena = try .init(backing_allocator) };
    }

    fn allocator(this: *const OwnedRouteConfig) std.mem.Allocator {
        return this.arena.allocator();
    }

    fn deinit(this: *OwnedRouteConfig) void {
        this.arena.deinit();
        this.* = undefined;
    }
};

const RouteSnapshot = struct {
    arena: OwnedArena,
    router: ?Router = null,

    fn init(backing_allocator: std.mem.Allocator) !RouteSnapshot {
        return .{ .arena = try .init(backing_allocator) };
    }

    fn allocator(this: *const RouteSnapshot) std.mem.Allocator {
        return this.arena.allocator();
    }

    fn load(
        this: *RouteSnapshot,
        fs: *Fs.FileSystem,
        config: Options.RouteConfig,
        log: *Log.Log,
        resolver: *Resolver,
        root_dir_info: *const DirInfo,
    ) !void {
        bun.assert(this.router == null);
        var router = try Router.init(fs, this.allocator(), config);
        errdefer router.deinit();
        try router.loadRoutes(log, root_dir_info, Resolver, resolver, config.dir);
        this.router = router;
    }

    fn get(this: *RouteSnapshot) *Router {
        return if (this.router) |*router| router else unreachable;
    }

    fn deinit(this: *RouteSnapshot) void {
        if (this.router) |*router| router.deinit();
        this.arena.deinit();
        this.* = undefined;
    }
};

pub const FileSystemRouter = struct {
    origin: ?*jsc.RefString = null,
    base_dir: ?*jsc.RefString = null,
    asset_prefix: ?*jsc.RefString = null,
    config: OwnedRouteConfig,
    snapshot: RouteSnapshot,

    pub const js = jsc.Codegen.JSFileSystemRouter;
    pub const toJS = js.toJS;
    pub const fromJS = js.fromJS;
    pub const fromJSDirect = js.fromJSDirect;

    pub fn constructor(globalThis: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!*FileSystemRouter {
        const argument_ = callframe.arguments_old(1);
        if (argument_.len == 0) {
            return globalThis.throwInvalidArguments("Expected object", .{});
        }

        const argument = argument_.ptr[0];
        if (argument.isEmptyOrUndefinedOrNull() or !argument.isObject()) {
            return globalThis.throwInvalidArguments("Expected object", .{});
        }
        var vm = globalThis.bunVM();

        var root_dir_path: ZigString.Slice = ZigString.Slice.fromUTF8NeverFree(vm.transpiler.fs.top_level_dir);
        defer root_dir_path.deinit();
        var origin_str: ZigString.Slice = .{};
        defer origin_str.deinit();

        var out_buf: [bun.MAX_PATH_BYTES * 2]u8 = undefined;
        if (try argument.get(globalThis, "style")) |style_val| {
            if (!(try style_val.getZigString(globalThis)).eqlComptime("nextjs")) {
                return globalThis.throwInvalidArguments("Only 'nextjs' style is currently implemented", .{});
            }
        } else {
            return globalThis.throwInvalidArguments("Expected 'style' option (ex: \"style\": \"nextjs\")", .{});
        }

        if (try argument.get(globalThis, "dir")) |dir| {
            if (!dir.isString()) {
                return globalThis.throwInvalidArguments("Expected dir to be a string", .{});
            }
            var root_dir_path_ = try dir.toSlice(globalThis, globalThis.allocator());
            defer root_dir_path_.deinit();
            if (!(root_dir_path_.len == 0 or strings.eqlComptime(root_dir_path_.slice(), "."))) {
                // resolve relative path if needed
                const path = root_dir_path_.slice();
                if (bun.path.Platform.isAbsolute(.auto, path)) {
                    root_dir_path = root_dir_path_;
                    root_dir_path_ = .empty;
                } else {
                    var parts = [_][]const u8{path};
                    root_dir_path = jsc.ZigString.Slice.fromUTF8NeverFree(bun.path.joinAbsStringBuf(Fs.FileSystem.instance.top_level_dir, &out_buf, &parts, .auto));
                }
            }
        } else {
            // dir is not optional
            return globalThis.throwInvalidArguments("Expected dir to be a string", .{});
        }
        var config = OwnedRouteConfig.init(globalThis.allocator()) catch unreachable;
        errdefer config.deinit();
        const config_allocator = config.allocator();

        var extensions = std.array_list.Managed(string).init(config_allocator);
        if (try argument.get(globalThis, "fileExtensions")) |file_extensions| {
            if (!file_extensions.jsType().isArray()) {
                return globalThis.throwInvalidArguments("Expected fileExtensions to be an Array", .{});
            }

            var iter = try file_extensions.arrayIterator(globalThis);
            extensions.ensureTotalCapacityPrecise(iter.len) catch unreachable;
            while (try iter.next()) |val| {
                if (!val.isString()) {
                    return globalThis.throwInvalidArguments("Expected fileExtensions to be an Array of strings", .{});
                }
                if (try val.getLength(globalThis) == 0) continue;
                extensions.appendAssumeCapacity((try val.toUTF8Bytes(globalThis, config_allocator))[1..]);
            }
        }

        var asset_prefix_path: string = "";
        if (try argument.getTruthy(globalThis, "assetPrefix")) |asset_prefix| {
            if (!asset_prefix.isString()) {
                return globalThis.throwInvalidArguments("Expected assetPrefix to be a string", .{});
            }

            asset_prefix_path = try asset_prefix.toUTF8Bytes(globalThis, config_allocator);
        }

        if (try argument.get(globalThis, "origin")) |origin| {
            if (!origin.isString()) {
                return globalThis.throwInvalidArguments("Expected origin to be a string", .{});
            }
            origin_str = try origin.toSlice(globalThis, globalThis.allocator());
        }

        const path_to_use = (root_dir_path.cloneWithTrailingSlash(config_allocator) catch unreachable).slice();
        config.value = .{
            .dir = path_to_use,
            .extensions = if (extensions.items.len > 0) extensions.items else default_extensions,
            .asset_prefix_path = asset_prefix_path,
        };

        var snapshot = RouteSnapshot.init(globalThis.allocator()) catch unreachable;
        errdefer snapshot.deinit();

        const orig_log = vm.transpiler.resolver.log;
        var log = Log.Log.init(snapshot.allocator());
        vm.transpiler.resolver.log = &log;
        defer vm.transpiler.resolver.log = orig_log;

        const root_dir_info = vm.transpiler.resolver.readDirInfo(config.value.dir) catch {
            // Build the JS error before freeing the arena: `log` is backed by the arena allocator.
            // Capture the error union so cleanup runs even if toJS itself fails.
            const err_value = log.toJS(globalThis, globalThis.allocator(), "reading root directory");
            return globalThis.throwValue(try err_value);
        } orelse {
            return globalThis.throw("Unable to find directory: {s}", .{root_dir_path.slice()});
        };

        snapshot.load(vm.transpiler.fs, config.value, &log, &vm.transpiler.resolver, root_dir_info) catch {
            // Build the JS error before freeing the arena: `log` is backed by the arena allocator.
            // Capture the error union so cleanup runs even if toJS itself fails.
            const err_value = log.toJS(globalThis, globalThis.allocator(), "loading routes");
            return globalThis.throwValue(try err_value);
        };

        if (log.errors + log.warnings > 0) {
            // Build the JS error before freeing the arena: `log` is backed by the arena allocator.
            // Capture the error union so cleanup runs even if toJS itself fails.
            const err_value = log.toJS(globalThis, globalThis.allocator(), "loading routes");
            return globalThis.throwValue(try err_value);
        }

        const fs_router = globalThis.allocator().create(FileSystemRouter) catch unreachable;
        fs_router.* = .{
            .origin = if (origin_str.len > 0) vm.refCountedString(origin_str.slice(), null, true) else null,
            .base_dir = vm.refCountedString(if (root_dir_info.abs_real_path.len > 0)
                root_dir_info.abs_real_path
            else
                root_dir_info.abs_path, null, true),
            .asset_prefix = if (config.value.asset_prefix_path.len > 0) vm.refCountedString(config.value.asset_prefix_path, null, true) else null,
            .config = config,
            .snapshot = snapshot,
        };

        return fs_router;
    }

    const win32_normalize_bufs = bun.ThreadlocalBuffers(struct {
        buf: if (Environment.isWindows) [bun.MAX_PATH_BYTES * 2]u8 else void = undefined,
    });
    pub fn bustDirCacheRecursive(this: *FileSystemRouter, globalThis: *jsc.JSGlobalObject, inputPath: []const u8) void {
        var vm = globalThis.bunVM();
        var path = inputPath;
        if (comptime Environment.isWindows) {
            path = vm.transpiler.resolver.fs.normalizeBuf(&win32_normalize_bufs.get().buf, path);
        }

        const root_dir_info = vm.transpiler.resolver.readDirInfo(path) catch {
            return;
        };

        if (root_dir_info) |dir| {
            if (dir.getEntriesConst()) |entries| {
                var iter = entries.data.iterator();
                outer: while (iter.next()) |entry_ptr| {
                    const entry = entry_ptr.value_ptr.*;
                    if (entry.base()[0] == '.') {
                        continue :outer;
                    }
                    if (entry.kind(&vm.transpiler.fs.fs, false) == .dir) {
                        inline for (Router.banned_dirs) |banned_dir| {
                            if (strings.eqlComptime(entry.base(), comptime banned_dir)) {
                                continue :outer;
                            }
                        }

                        var abs_parts_con = [_]string{ entry.dir, entry.base() };
                        const full_path = vm.transpiler.fs.abs(&abs_parts_con);

                        _ = vm.transpiler.resolver.bustDirCache(strings.withoutTrailingSlashWindowsPath(full_path));
                        bustDirCacheRecursive(this, globalThis, full_path);
                    }
                }
            }
        }

        _ = vm.transpiler.resolver.bustDirCache(path);
    }

    pub fn bustDirCache(this: *FileSystemRouter, globalThis: *jsc.JSGlobalObject) void {
        bustDirCacheRecursive(this, globalThis, strings.withoutTrailingSlashWindowsPath(this.config.value.dir));
    }

    pub fn reload(this: *FileSystemRouter, globalThis: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!JSValue {
        const this_value = callframe.this();
        var vm = globalThis.bunVM();

        var snapshot = RouteSnapshot.init(globalThis.allocator()) catch unreachable;
        errdefer snapshot.deinit();

        const orig_log = vm.transpiler.resolver.log;
        var log = Log.Log.init(snapshot.allocator());
        vm.transpiler.resolver.log = &log;
        defer vm.transpiler.resolver.log = orig_log;

        bustDirCache(this, globalThis);

        const root_dir_info = vm.transpiler.resolver.readDirInfo(this.config.value.dir) catch {
            // Build the JS error before freeing the arena: `log` is backed by the arena allocator.
            // Capture the error union so cleanup runs even if toJS itself fails.
            const err_value = log.toJS(globalThis, globalThis.allocator(), "reading root directory");
            return globalThis.throwValue(try err_value);
        } orelse {
            return globalThis.throw("Unable to find directory: {s}", .{this.config.value.dir});
        };

        snapshot.load(vm.transpiler.fs, this.config.value, &log, &vm.transpiler.resolver, root_dir_info) catch {
            // Build the JS error before freeing the arena: `log` is backed by the arena allocator.
            // Capture the error union so cleanup runs even if toJS itself fails.
            const err_value = log.toJS(globalThis, globalThis.allocator(), "loading routes");
            return globalThis.throwValue(try err_value);
        };

        var old_snapshot = this.snapshot;
        this.snapshot = snapshot;
        js.routesSetCached(this_value, globalThis, jsc.JSValue.zero);
        old_snapshot.deinit();
        return this_value;
    }

    pub fn match(this: *FileSystemRouter, globalThis: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!JSValue {
        const argument_ = callframe.arguments_old(2);
        if (argument_.len == 0) {
            return globalThis.throwInvalidArguments("Expected string, Request or Response", .{});
        }

        const argument = argument_.ptr[0];
        if (argument.isEmptyOrUndefinedOrNull() or !argument.isCell()) {
            return globalThis.throwInvalidArguments("Expected string, Request or Response", .{});
        }

        var path: ZigString.Slice = brk: {
            if (argument.isString()) {
                break :brk try (try argument.toSlice(globalThis, globalThis.allocator())).cloneIfBorrowed(globalThis.allocator());
            }

            if (argument.isCell()) {
                if (argument.as(jsc.WebCore.Request)) |req| {
                    req.ensureURL() catch unreachable;
                    break :brk req.url.toUTF8(globalThis.allocator());
                }

                if (argument.as(jsc.WebCore.Response)) |resp| {
                    break :brk resp.getUTF8Url(globalThis.allocator());
                }
            }

            return globalThis.throwInvalidArguments("Expected string, Request or Response", .{});
        };
        defer path.deinit();

        if (path.len == 0 or (path.len == 1 and path.ptr[0] == '/')) {
            path.deinit();
            path = ZigString.Slice.fromUTF8NeverFree("/");
        }

        if (strings.hasPrefixComptime(path.slice(), "http://") or strings.hasPrefixComptime(path.slice(), "https://") or strings.hasPrefixComptime(path.slice(), "file://")) {
            const prev_path = path;
            defer prev_path.deinit();
            path = try .initDupe(globalThis.allocator(), URL.parse(path.slice()).pathname);
        }

        var parsed = URLPath.parseAlloc(globalThis.allocator(), path.slice()) catch |err| {
            return globalThis.throw("{s} parsing path: {s}", .{ @errorName(err), path.slice() });
        };
        defer parsed.deinit(globalThis.allocator());
        var params = Router.Param.List{};
        defer params.deinit(globalThis.allocator());
        const route = this.snapshot.get().routes.matchPageWithAllocator(
            "",
            parsed.value,
            &params,
            globalThis.allocator(),
        ) orelse {
            return JSValue.jsNull();
        };

        if (parsed.takeDecoded()) |decoded| {
            path.deinit();
            path = ZigString.Slice.init(globalThis.allocator(), decoded);
        }

        const pathname_backing = path;
        path = .empty;

        var result = MatchedRoute.init(
            globalThis.allocator(),
            route,
            pathname_backing,
            this.origin,
            this.asset_prefix,
            this.base_dir.?,
        ) catch unreachable;
        return result.toJS(globalThis);
    }

    pub fn getOrigin(this: *FileSystemRouter, globalThis: *jsc.JSGlobalObject) JSValue {
        if (this.origin) |origin| {
            return jsc.ZigString.init(origin.slice()).withEncoding().toJS(globalThis);
        }

        return JSValue.jsNull();
    }

    pub fn getRoutes(this: *FileSystemRouter, globalThis: *jsc.JSGlobalObject) bun.JSError!JSValue {
        const paths = this.snapshot.get().getEntryPoints();
        const names = this.snapshot.get().getNames();
        var name_strings = try bun.default_allocator.alloc(ZigString, names.len * 2);
        defer bun.default_allocator.free(name_strings);
        var paths_strings = name_strings[names.len..];
        for (names, 0..) |name, i| {
            name_strings[i] = ZigString.init(name).withEncoding();
            paths_strings[i] = ZigString.init(paths[i]).withEncoding();
        }
        return jsc.JSValue.fromEntries(
            globalThis,
            name_strings.ptr,
            paths_strings.ptr,
            names.len,
            true,
        );
    }

    pub fn getStyle(_: *FileSystemRouter, globalThis: *jsc.JSGlobalObject) bun.JSError!JSValue {
        return bun.String.static("nextjs").toJS(globalThis);
    }

    pub fn getAssetPrefix(this: *FileSystemRouter, globalThis: *jsc.JSGlobalObject) JSValue {
        if (this.asset_prefix) |asset_prefix| {
            return jsc.ZigString.init(asset_prefix.slice()).withEncoding().toJS(globalThis);
        }

        return JSValue.jsNull();
    }

    pub fn finalize(
        this: *FileSystemRouter,
    ) callconv(.c) void {
        if (this.asset_prefix) |prefix| {
            prefix.deref();
        }

        if (this.origin) |prefix| {
            prefix.deref();
        }

        if (this.base_dir) |dir| {
            dir.deref();
        }

        this.snapshot.deinit();
        this.config.deinit();
    }
};

pub const MatchedRoute = struct {
    route: *const Router.Match,
    route_holder: Router.Match = undefined,
    query_string_map: ?QueryStringMap = null,
    param_map: ?QueryStringMap = null,
    params_list_holder: Router.Param.List = .{},
    pathname_backing: ZigString.Slice = .empty,
    allocator: std.mem.Allocator,
    origin: ?*jsc.RefString = null,
    asset_prefix: ?*jsc.RefString = null,
    base_dir: ?*jsc.RefString = null,

    pub const js = jsc.Codegen.JSMatchedRoute;
    pub const toJS = js.toJS;
    pub const fromJS = js.fromJS;
    pub const fromJSDirect = js.fromJSDirect;

    pub fn getName(this: *MatchedRoute, globalThis: *jsc.JSGlobalObject) JSValue {
        return ZigString.init(this.route.name).withEncoding().toJS(globalThis);
    }

    pub fn init(
        allocator: std.mem.Allocator,
        match: Router.Match,
        pathname_backing: ZigString.Slice,
        origin: ?*jsc.RefString,
        asset_prefix: ?*jsc.RefString,
        base_dir: *jsc.RefString,
    ) !*MatchedRoute {
        errdefer pathname_backing.deinit();
        var params_list = try match.params.clone(allocator);
        errdefer params_list.deinit(allocator);

        var route = try allocator.create(MatchedRoute);

        route.* = MatchedRoute{
            .route_holder = match,
            .route = undefined,
            .pathname_backing = pathname_backing,
            .allocator = allocator,
            .asset_prefix = asset_prefix,
            .origin = origin,
            .base_dir = base_dir,
        };
        base_dir.ref();
        route.params_list_holder = params_list;
        route.route = &route.route_holder;
        route.route_holder.params = &route.params_list_holder;
        if (origin) |o| {
            o.ref();
        }

        if (asset_prefix) |prefix| {
            prefix.ref();
        }

        return route;
    }

    pub fn deinit(this: *MatchedRoute) void {
        if (this.query_string_map) |*map| {
            map.deinit();
        }
        if (this.param_map) |*map| {
            map.deinit();
        }
        this.params_list_holder.deinit(this.allocator);
        this.params_list_holder = .{};
        this.pathname_backing.deinit();
        this.pathname_backing = .empty;

        if (this.origin) |o| {
            o.deref();
        }

        if (this.asset_prefix) |prefix| {
            prefix.deref();
        }

        if (this.base_dir) |base|
            base.deref();

        this.allocator.destroy(this);
    }

    pub fn getFilePath(
        this: *MatchedRoute,
        globalThis: *jsc.JSGlobalObject,
    ) JSValue {
        return ZigString.init(this.route.file_path)
            .withEncoding()
            .toJS(globalThis);
    }

    pub fn finalize(
        this: *MatchedRoute,
    ) callconv(.c) void {
        this.deinit();
    }

    pub fn getPathname(this: *MatchedRoute, globalThis: *jsc.JSGlobalObject) JSValue {
        return ZigString.init(this.route.pathname)
            .withEncoding()
            .toJS(globalThis);
    }

    pub fn getRoute(this: *MatchedRoute, globalThis: *jsc.JSGlobalObject) JSValue {
        return ZigString.init(this.route.name)
            .withEncoding()
            .toJS(globalThis);
    }

    const KindEnum = struct {
        pub const exact = "exact";
        pub const catch_all = "catch-all";
        pub const optional_catch_all = "optional-catch-all";
        pub const dynamic = "dynamic";

        // this is kinda stupid it should maybe just store it
        pub fn init(name: string) ZigString {
            if (strings.contains(name, "[[...")) {
                return ZigString.init(optional_catch_all);
            } else if (strings.contains(name, "[...")) {
                return ZigString.init(catch_all);
            } else if (strings.contains(name, "[")) {
                return ZigString.init(dynamic);
            } else {
                return ZigString.init(exact);
            }
        }
    };

    pub fn getKind(this: *MatchedRoute, globalThis: *jsc.JSGlobalObject) JSValue {
        return KindEnum.init(this.route.name).toJS(globalThis);
    }

    pub fn createQueryObject(ctx: *jsc.JSGlobalObject, map: *QueryStringMap) JSValue {
        const QueryObjectCreator = struct {
            query: *QueryStringMap,
            pub fn create(this: *@This(), obj: *JSObject, global: *JSGlobalObject) bun.JSError!void {
                var value_refs_buffer: [256 * @sizeOf(ZigString)]u8 align(@alignOf(ZigString)) = undefined;
                var value_refs_allocator: std.heap.BufferFirstAllocator = .init(&value_refs_buffer, global.allocator());
                const allocator = value_refs_allocator.allocator();
                var value_refs: std.ArrayListUnmanaged(ZigString) = .empty;
                defer value_refs.deinit(allocator);

                var iter = this.query.iter();
                while (iter.next()) |entry| {
                    const entry_name = entry.name;
                    var str = ZigString.init(entry_name).withEncoding();

                    try value_refs.resize(allocator, entry.value_count);
                    var values = entry.values;
                    for (value_refs.items) |*value_ref| {
                        value_ref.* = ZigString.init(values.next().?).withEncoding();
                    }
                    try obj.putRecord(global, &str, value_refs.items);
                }
            }
        };

        var creator = QueryObjectCreator{ .query = map };

        const value = JSObject.createWithInitializer(QueryObjectCreator, &creator, ctx, map.getNameCount());

        return value;
    }

    pub fn getScriptSrcString(
        origin: []const u8,
        writer: *std.Io.Writer,
        file_path: string,
        client_framework_enabled: bool,
    ) void {
        var entry_point_tempbuf: bun.PathBuffer = undefined;
        // We don't store the framework config including the client parts in the server
        // instead, we just store a boolean saying whether we should generate this whenever the script is requested
        // this is kind of bad. we should consider instead a way to inline the contents of the script.
        if (client_framework_enabled) {
            jsc.API.Bun.getPublicPath(
                Transpiler.ClientEntryPoint.generateEntryPointPath(
                    &entry_point_tempbuf,
                    Fs.PathName.init(file_path),
                ),
                origin,
                writer,
            );
        } else {
            jsc.API.Bun.getPublicPath(file_path, origin, writer);
        }
    }

    pub fn getScriptSrc(
        this: *MatchedRoute,
        globalThis: *jsc.JSGlobalObject,
    ) jsc.JSValue {
        var buf: bun.PathBuffer = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        jsc.API.Bun.getPublicPathWithAssetPrefix(
            this.route.file_path,
            if (this.base_dir) |base_dir| base_dir.slice() else jsc.VirtualMachine.get().transpiler.fs.top_level_dir,
            if (this.origin) |origin| URL.parse(origin.slice()) else URL{},
            if (this.asset_prefix) |prefix| prefix.slice() else "",
            &writer,
            .posix,
        );
        return ZigString.init(buf[0..writer.end])
            .withEncoding()
            .toJS(globalThis);
    }

    pub fn getParams(
        this: *MatchedRoute,
        globalThis: *jsc.JSGlobalObject,
    ) bun.JSError!jsc.JSValue {
        if (this.route.params.len == 0)
            return JSValue.createEmptyObject(globalThis, 0);

        if (this.param_map == null) {
            this.param_map = try QueryStringMap.initWithScanner(
                globalThis.allocator(),
                CombinedScanner.init(
                    "",
                    this.route.pathnameWithoutLeadingSlash(),
                    this.route.name,
                    this.route.params,
                ),
            );
        }

        return createQueryObject(globalThis, &this.param_map.?);
    }

    pub fn getQuery(
        this: *MatchedRoute,
        globalThis: *jsc.JSGlobalObject,
    ) bun.JSError!jsc.JSValue {
        if (this.route.query_string.len == 0 and this.route.params.len == 0) {
            return JSValue.createEmptyObject(globalThis, 0);
        } else if (this.route.query_string.len == 0) {
            return this.getParams(globalThis);
        }

        if (this.query_string_map == null) {
            if (this.route.params.len > 0) {
                this.query_string_map = try QueryStringMap.initWithScanner(globalThis.allocator(), CombinedScanner.init(
                    this.route.query_string,
                    this.route.pathnameWithoutLeadingSlash(),
                    this.route.name,

                    this.route.params,
                ));
            } else {
                this.query_string_map = try QueryStringMap.init(globalThis.allocator(), this.route.query_string);
            }
        }

        // If it's still null, the query string has no names.
        if (this.query_string_map) |*map| {
            return createQueryObject(globalThis, map);
        }

        return JSValue.createEmptyObject(globalThis, 0);
    }
};

const string = []const u8;

const DirInfo = @import("../../resolver/dir_info.zig");
const Fs = @import("../../resolver/fs.zig");
const Options = @import("../../bundler/options.zig");
const Router = @import("../../router/router.zig");
const URLPath = @import("../../http_types/URLPath.zig");
const std = @import("std");
const Resolver = @import("../../resolver/resolver.zig").Resolver;

const CombinedScanner = @import("../../url/url.zig").CombinedScanner;
const QueryStringMap = @import("../../url/url.zig").QueryStringMap;
const URL = @import("../../url/url.zig").URL;

const bun = @import("bun");
const Environment = bun.Environment;
const Log = bun.logger;
const Transpiler = bun.transpiler;
const strings = bun.strings;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSObject = jsc.JSObject;
const JSValue = jsc.JSValue;
const ZigString = jsc.ZigString;

const WebCore = jsc.WebCore;
const Request = WebCore.Request;
