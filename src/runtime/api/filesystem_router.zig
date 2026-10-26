pub const default_extensions = &[_][]const u8{
    "tsx",
    "jsx",
    "ts",
    "mjs",
    "cjs",
    "js",
};

pub const OwnedRouteConfig = struct {
    dir: bindgen.OwnedBytes,
    asset_prefix_path: bindgen.OwnedBytes,
    extensions: bindgen.OwnedNativeSlice(bindgen.OwnedBytes, .any),

    pub fn deinit(this: *OwnedRouteConfig) void {
        this.dir.deinit();
        this.asset_prefix_path.deinit();
        this.extensions.deinit();
    }

    fn copyToArena(this: *const OwnedRouteConfig, allocator: std.mem.Allocator) bun.OOM!Options.RouteConfig {
        const source = this.extensions.slice();
        const extensions = try allocator.alloc([]const u8, source.len);
        for (source, extensions) |*extension, *target| target.* = try allocator.dupe(u8, extension.slice());
        return .{
            .dir = try allocator.dupe(u8, this.dir.slice()),
            .asset_prefix_path = try allocator.dupe(u8, this.asset_prefix_path.slice()),
            .extensions = if (extensions.len > 0) extensions else default_extensions,
        };
    }
};

pub const RouteSnapshot = struct {
    entries: bindgen.OwnedNativeSlice(Entry, .any),
    static_keys: bindgen.OwnedNativeSlice(StaticKey, .any),
    index: ?usize,
    dynamic_start: usize,

    const Entry = struct {
        name: bindgen.OwnedBytes,
        match_name: bindgen.OwnedBytes,
        file_path: bindgen.OwnedBytes,
        basename: bindgen.OwnedBytes,

        fn copy(route: *const Router.Route) bun.OOM!Entry {
            var name = try bindgen.OwnedBytes.fromSlice(route.name);
            errdefer name.deinit();
            var match_name = try bindgen.OwnedBytes.fromSlice(route.match_name.slice());
            errdefer match_name.deinit();
            var file_path = try bindgen.OwnedBytes.fromSlice(route.abs_path.slice());
            errdefer file_path.deinit();
            return .{ .name = name, .match_name = match_name, .file_path = file_path, .basename = try bindgen.OwnedBytes.fromSlice(route.basename) };
        }

        pub fn deinit(this: *Entry) void {
            this.name.deinit();
            this.match_name.deinit();
            this.file_path.deinit();
            this.basename.deinit();
        }

        fn result(this: *const Entry, url: URLPath, params: *Router.Param.List) Router.Match {
            return .{ .name = this.name.slice(), .path = this.file_path.slice(), .file_path = this.file_path.slice(), .basename = this.basename.slice(), .pathname = url.pathname, .query_string = url.query_string, .params = params };
        }
    };

    const StaticKey = struct {
        name: bindgen.OwnedBytes,
        entry_index: usize,

        pub fn deinit(this: *StaticKey) void {
            this.name.deinit();
        }

        fn lessThan(_: void, a: StaticKey, b: StaticKey) bool {
            return std.mem.lessThan(u8, a.name.slice(), b.name.slice());
        }
    };

    pub fn load(
        scratch: std.mem.Allocator,
        fs: *Fs.FileSystem,
        owned_config: *const OwnedRouteConfig,
        log: *Log.Log,
        resolver: *Resolver,
        root_dir_info: *const DirInfo,
    ) !*RouteSnapshot {
        const config = try owned_config.copyToArena(scratch);
        var router = try Router.init(fs, scratch, config);
        defer router.deinit();
        try router.loadRoutes(log, root_dir_info, Resolver, resolver, config.dir);
        const routes = router.routes.list.items(.route);
        var entries = try bindgen.OwnedNativeSlice(Entry, .any).Builder.init(routes.len);
        errdefer entries.deinit();
        var route_indices = std.AutoHashMap(*Router.Route, usize).init(scratch);
        defer route_indices.deinit();
        var index: ?usize = null;
        for (routes, 0..) |route, i| {
            entries.appendOwned(try Entry.copy(route));
            try route_indices.put(route, i);
            if (router.routes.index == route) index = i;
        }
        var keys = try bindgen.OwnedNativeSlice(StaticKey, .any).Builder.init(router.routes.static.count());
        errdefer keys.deinit();
        var iter = router.routes.static.iterator();
        while (iter.next()) |item| {
            keys.appendOwned(.{ .name = try bindgen.OwnedBytes.fromSlice(item.key_ptr.*), .entry_index = route_indices.get(item.value_ptr.*).? });
        }
        std.sort.pdq(StaticKey, keys.slice(), {}, StaticKey.lessThan);
        const snapshot = try bun.default_allocator.create(RouteSnapshot);
        snapshot.* = .{ .entries = entries.finish(), .static_keys = keys.finish(), .index = index, .dynamic_start = routes.len - router.routes.dynamic.len };
        return snapshot;
    }

    pub fn match(this: *const RouteSnapshot, url: URLPath, params: *Router.Param.List, allocator: std.mem.Allocator) bun.OOM!?Router.Match {
        const path = std.mem.trimStart(u8, Router.Routes.normalizeMatchPath(url.path), "/");
        const entries = this.entries.slice();
        if (path.len == 0) return if (this.index) |i| entries[i].result(url, params) else null;
        const keys = this.static_keys.slice();
        var lo: usize = 0;
        var hi = keys.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, path, keys[mid].name.slice())) {
                .lt => hi = mid,
                .gt => lo = mid + 1,
                .eq => return entries[keys[mid].entry_index].result(url, params),
            }
        }
        for (entries[this.dynamic_start..]) |*entry| {
            if (try Router.Pattern.match(path, entry.name.slice()[1..], entry.match_name.slice(), allocator, *Router.Param.List, params, true))
                return entry.result(url, params);
        }
        return null;
    }

    pub fn destroy(this: *RouteSnapshot) void {
        this.entries.deinit();
        this.static_keys.deinit();
        bun.default_allocator.destroy(this);
    }
};

pub const RouteMetadata = struct {
    ref_count: RefCount = .init(),
    base_dir: bindgen.OwnedBytes,
    origin: bindgen.OwnedBytes,
    asset_prefix: bindgen.OwnedBytes,

    const RefCount = bun.ptr.ThreadSafeRefCount(RouteMetadata, "ref_count", destroy, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;
    pub const Ref = bindgen.RefNative(RouteMetadata, .any);

    pub fn create(base_dir: []const u8, origin: []const u8, asset_prefix: []const u8) bun.OOM!Ref {
        var owned_base_dir = try bindgen.OwnedBytes.fromSlice(base_dir);
        errdefer owned_base_dir.deinit();
        var owned_origin = try bindgen.OwnedBytes.fromSlice(origin);
        errdefer owned_origin.deinit();
        var owned_asset_prefix = try bindgen.OwnedBytes.fromSlice(asset_prefix);
        errdefer owned_asset_prefix.deinit();
        const metadata = try bun.default_allocator.create(RouteMetadata);
        metadata.* = .{
            .base_dir = owned_base_dir,
            .origin = owned_origin,
            .asset_prefix = owned_asset_prefix,
        };
        return .adopt(metadata);
    }

    fn destroy(this: *RouteMetadata) void {
        this.base_dir.deinit();
        this.origin.deinit();
        this.asset_prefix.deinit();
        bun.default_allocator.destroy(this);
    }
};

pub const FileSystemRouter = struct {
    bindgen_state: bindgen.ClassState = .{},
    metadata: RouteMetadata.Ref,
    config: OwnedRouteConfig,
    snapshot: FileSystemRouterSnapshot,

    pub const getConstructor = FileSystemRouterClass.constructor;

    pub fn construct(
        context: bindgen.CallContext(FileSystemRouterConstructorSchema),
        args: bindgen.Args(FileSystemRouterConstructorSchema),
    ) bindgen.CallError(FileSystemRouterConstructorSchema)!*FileSystemRouter {
        return bun.api.FileSystemRouterEngine.constructFromContext(context, args);
    }

    pub fn reload(
        this: *FileSystemRouter,
        context: bindgen.CallContext(FileSystemRouterReloadSchema),
        args: bindgen.Args(FileSystemRouterReloadSchema),
    ) bun.JSError!bindgen.Return(FileSystemRouterReloadSchema) {
        return bun.api.FileSystemRouterEngine.reloadFromContext(context, FileSystemRouterReloadInput{
            .router = this,
            .args = args,
        });
    }

    pub fn match(
        this: *FileSystemRouter,
        context: bindgen.CallContext(FileSystemRouterMatchSchema),
        args: bindgen.Args(FileSystemRouterMatchSchema),
    ) bindgen.CallError(FileSystemRouterMatchSchema)!bindgen.Return(FileSystemRouterMatchSchema) {
        const allocator = bun.default_allocator;
        const input = args.input orelse return context.fail(.invalid_input, {});
        var extracted_path = bindgen.DOMString.empty();
        defer extracted_path.deinit();

        var path: bun.String.Slice = switch (input) {
            .string => |path_string| try path_string.toUTF8(allocator),
            .request => |request| request_path: {
                extracted_path = try bun.api.FileSystemRouterEngine.requestPath(request);
                break :request_path try extracted_path.toUTF8(allocator);
            },
            .response => |response| response_path: {
                extracted_path = try bun.api.FileSystemRouterEngine.responsePath(response);
                break :response_path try extracted_path.toUTF8(allocator);
            },
            .invalid => return context.fail(.invalid_input, {}),
        };
        defer path.deinit();

        if (strings.hasPrefixComptime(path.slice(), "http://") or strings.hasPrefixComptime(path.slice(), "https://") or strings.hasPrefixComptime(path.slice(), "file://")) {
            const pathname = try bun.String.Slice.initDupe(allocator, URL.parse(path.slice()).pathname);
            path.deinit();
            path = pathname;
        }

        if (path.length() == 0) {
            path.deinit();
            path = bun.String.Slice.fromUTF8NeverFree("/");
        }
        if (path.slice()[0] != '/') return null;

        var parsed = URLPath.parseAlloc(allocator, path.slice()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DecodingError => {
                const message = try std.fmt.allocPrint(allocator, "DecodingError parsing path: {s}", .{path.slice()});
                defer allocator.free(message);
                return context.fail(.invalid_path, try bindgen.DOMString.fromUTF8(message));
            },
        };
        defer parsed.deinit(allocator);
        var params = Router.Param.List{};
        defer params.deinit(allocator);
        const route = (try this.snapshot.get().match(
            parsed.value,
            &params,
            allocator,
        )) orelse {
            return null;
        };

        if (parsed.takeOwned()) |owned| {
            path.deinit();
            path = bun.String.Slice.init(allocator, owned);
        }

        const pathname_backing = path;
        path = .empty;

        const result = try MatchedRoute.init(
            route,
            pathname_backing,
            this.metadata,
        );
        return try MatchedRouteClass.adoptResult(result, context);
    }

    pub fn getOrigin(
        this: *FileSystemRouter,
        _: bindgen.CallContext(FileSystemRouterOriginSchema),
        _: bindgen.Args(FileSystemRouterOriginSchema),
    ) bun.JSError!?bindgen.DOMString {
        const origin = this.metadata.get().origin.slice();
        return if (origin.len > 0) try bindgen.DOMString.fromUTF8(origin) else null;
    }

    pub fn getRoutes(
        this: *FileSystemRouter,
        _: bindgen.CallContext(FileSystemRouterRoutesSchema),
        _: bindgen.Args(FileSystemRouterRoutesSchema),
    ) bun.JSError!bindgen.Return(FileSystemRouterRoutesSchema) {
        const Record = bindgen.Return(FileSystemRouterRoutesSchema);
        const routes = this.snapshot.get().entries.slice();
        var result = try Record.Builder.init(routes.len);
        errdefer result.deinit();
        for (routes) |*route| {
            var key = try bindgen.DOMString.fromUTF8(route.name.slice());
            errdefer key.deinit();
            result.appendOwned(.{ .key = key, .value = try bindgen.DOMString.fromUTF8(route.file_path.slice()) });
        }
        return result.finish();
    }

    pub fn getStyle(
        _: *FileSystemRouter,
        _: bindgen.CallContext(FileSystemRouterStyleSchema),
        _: bindgen.Args(FileSystemRouterStyleSchema),
    ) bun.JSError!bindgen.DOMString {
        return bindgen.DOMString.fromUTF8("nextjs");
    }

    pub fn destroy(this: *FileSystemRouter) void {
        this.metadata.deinit();
        this.snapshot.deinit();
        this.config.deinit();
        bun.default_allocator.destroy(this);
    }
};

pub const FileSystemRouterReloadInput = struct {
    router: *FileSystemRouter,
    args: bindgen.Args(FileSystemRouterReloadSchema),
};

const OwnedRouteParam = struct {
    name: bindgen.OwnedBytes,
    value: bindgen.OwnedBytes,

    pub fn deinit(this: *OwnedRouteParam) void {
        this.name.deinit();
        this.value.deinit();
    }

    fn copyAll(source: *const Router.Param.List) bun.OOM!MatchedRouteParams {
        var values = try MatchedRouteParams.Builder.init(source.len);
        errdefer values.deinit();
        for (source.items(.name), source.items(.value)) |name, value| {
            var owned_name = try bindgen.OwnedBytes.fromSlice(name);
            errdefer owned_name.deinit();
            values.appendOwned(.{
                .name = owned_name,
                .value = try bindgen.OwnedBytes.fromSlice(value),
            });
        }
        return values.finish();
    }
};

pub const MatchedRoute = struct {
    bindgen_state: bindgen.ClassState = .{},
    name: bindgen.OwnedBytes,
    file_path: bindgen.OwnedBytes,
    pathname: bindgen.OwnedBytes,
    query_string: bindgen.OwnedBytes,
    params: MatchedRouteParams,
    metadata: RouteMetadata.Ref,

    pub fn getName(
        this: *MatchedRoute,
        _: bindgen.CallContext(MatchedRouteNameSchema),
        _: bindgen.Args(MatchedRouteNameSchema),
    ) bun.JSError!bindgen.DOMString {
        return bindgen.DOMString.fromUTF8(this.name.slice());
    }

    pub fn init(
        match: Router.Match,
        pathname_backing: bun.String.Slice,
        metadata: RouteMetadata.Ref,
    ) !*MatchedRoute {
        defer pathname_backing.deinit();

        var name = try bindgen.OwnedBytes.fromSlice(match.name);
        errdefer name.deinit();
        var file_path = try bindgen.OwnedBytes.fromSlice(match.file_path);
        errdefer file_path.deinit();
        var pathname = try bindgen.OwnedBytes.fromSlice(match.pathname);
        errdefer pathname.deinit();
        var query_string = try bindgen.OwnedBytes.fromSlice(match.query_string);
        errdefer query_string.deinit();
        var params = try OwnedRouteParam.copyAll(match.params);
        errdefer params.deinit();

        const route = try bun.default_allocator.create(MatchedRoute);
        route.* = .{
            .name = name,
            .file_path = file_path,
            .pathname = pathname,
            .query_string = query_string,
            .params = params,
            .metadata = metadata.clone(),
        };
        return route;
    }

    pub fn deinit(this: *MatchedRoute) void {
        this.params.deinit();
        this.name.deinit();
        this.file_path.deinit();
        this.pathname.deinit();
        this.query_string.deinit();

        this.metadata.deinit();

        bun.default_allocator.destroy(this);
    }

    pub fn getFilePath(
        this: *MatchedRoute,
        _: bindgen.CallContext(MatchedRouteFilePathSchema),
        _: bindgen.Args(MatchedRouteFilePathSchema),
    ) bun.JSError!bindgen.DOMString {
        return bindgen.DOMString.fromUTF8(this.file_path.slice());
    }

    pub fn destroy(this: *MatchedRoute, _: bindgen.SweepContext) void {
        this.deinit();
    }

    pub fn getPathname(
        this: *MatchedRoute,
        _: bindgen.CallContext(MatchedRoutePathnameSchema),
        _: bindgen.Args(MatchedRoutePathnameSchema),
    ) bun.JSError!bindgen.DOMString {
        return bindgen.DOMString.fromUTF8(this.pathname.slice());
    }

    const KindEnum = struct {
        pub const exact = "exact";
        pub const catch_all = "catch-all";
        pub const optional_catch_all = "optional-catch-all";
        pub const dynamic = "dynamic";

        // this is kinda stupid it should maybe just store it
        pub fn init(name: string) []const u8 {
            if (strings.contains(name, "[[...")) {
                return optional_catch_all;
            } else if (strings.contains(name, "[...")) {
                return catch_all;
            } else if (strings.contains(name, "[")) {
                return dynamic;
            } else {
                return exact;
            }
        }
    };

    pub fn getKind(
        this: *MatchedRoute,
        _: bindgen.CallContext(MatchedRouteKindSchema),
        _: bindgen.Args(MatchedRouteKindSchema),
    ) bun.JSError!bindgen.DOMString {
        return bindgen.DOMString.fromLatin1(KindEnum.init(this.name.slice()));
    }

    fn queryEntry(comptime Schema: type, name: []const u8, values: anytype, value_count: usize) bun.OOM!bindgen.Return(Schema).Entry {
        const Entry = bindgen.Return(Schema).Entry;
        const QueryValue = @FieldType(Entry, "value");
        var value_iter = values;

        var key = try bindgen.DOMString.fromUTF8(name);
        errdefer key.deinit();

        if (value_count == 1) {
            return .{
                .key = key,
                .value = .{ .text = try bindgen.DOMString.fromUTF8(value_iter.next().?) },
            };
        }

        const Strings = @FieldType(QueryValue, "values");
        const allocator = bun.default_allocator;
        const slices = try allocator.alloc([]const u8, value_count);
        defer allocator.free(slices);
        for (slices) |*slice| slice.* = value_iter.next().?;
        return .{
            .key = key,
            .value = .{ .values = try Strings.fromUTF8Slices(slices) },
        };
    }

    fn queryRecord(comptime Schema: type, map: ?*QueryStringMap) bun.OOM!bindgen.Return(Schema) {
        const Record = bindgen.Return(Schema);
        const query = map orelse return Record.fromOwnedSlice(&[_]Record.Entry{});
        var result = try Record.Builder.init(query.getNameCount());
        errdefer result.deinit();
        var iter = query.iter();
        while (iter.next()) |entry| {
            result.appendOwned(try queryEntry(Schema, entry.name, entry.values, entry.value_count));
        }
        return result.finish();
    }

    pub fn getScriptSrc(
        this: *MatchedRoute,
        context: bindgen.CallContext(MatchedRouteScriptSrcSchema),
        _: bindgen.Args(MatchedRouteScriptSrcSchema),
    ) bun.JSError!bindgen.DOMString {
        _ = context;
        return bun.api.FileSystemRouterEngine.scriptSrc(this);
    }

    pub fn getSrc(
        this: *MatchedRoute,
        context: bindgen.CallContext(MatchedRouteSrcSchema),
        _: bindgen.Args(MatchedRouteSrcSchema),
    ) bun.JSError!bindgen.DOMString {
        _ = context;
        return bun.api.FileSystemRouterEngine.scriptSrc(this);
    }

    pub fn getParams(
        this: *MatchedRoute,
        _: bindgen.CallContext(MatchedRouteParamsSchema),
        _: bindgen.Args(MatchedRouteParamsSchema),
    ) bun.JSError!bindgen.Return(MatchedRouteParamsSchema) {
        var map = (try this.queryMap("")) orelse return queryRecord(MatchedRouteParamsSchema, null);
        defer map.deinit();
        return queryRecord(MatchedRouteParamsSchema, &map);
    }

    pub fn getQuery(
        this: *MatchedRoute,
        _: bindgen.CallContext(MatchedRouteQuerySchema),
        _: bindgen.Args(MatchedRouteQuerySchema),
    ) bun.JSError!bindgen.Return(MatchedRouteQuerySchema) {
        var map = (try this.queryMap(this.query_string.slice())) orelse
            return queryRecord(MatchedRouteQuerySchema, null);
        defer map.deinit();
        return queryRecord(MatchedRouteQuerySchema, &map);
    }

    fn queryMap(this: *const MatchedRoute, query: []const u8) bun.OOM!?QueryStringMap {
        const allocator = bun.default_allocator;
        const entries = this.params.slice();
        if (entries.len == 0) return QueryStringMap.init(allocator, query);
        var params: Router.Param.List = .{};
        defer params.deinit(allocator);
        try params.ensureTotalCapacity(allocator, entries.len);
        for (entries) |*entry| {
            params.appendAssumeCapacity(.{ .name = entry.name.slice(), .value = entry.value.slice() });
        }
        return QueryStringMap.initWithParams(allocator, query, &params);
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

const QueryStringMap = @import("../../url/url.zig").QueryStringMap;
const URL = @import("../../url/url.zig").URL;

const bun = @import("bun");
const Log = bun.logger;
const strings = bun.strings;

const bindgen = bun.bindgen;

const FileSystemRouterSnapshot = bindgen.OwnedNative(RouteSnapshot, .any);

const FileSystemRouterBindingModule = bindgen.Module("FileSystemRouter");
const FileSystemRouterSchema = FileSystemRouterBindingModule.class("FileSystemRouter");
const FileSystemRouterConstructorSchema = FileSystemRouterSchema.constructor();
const FileSystemRouterMatchSchema = FileSystemRouterSchema.member("match");
const FileSystemRouterOriginSchema = FileSystemRouterSchema.member("origin");
const FileSystemRouterReloadSchema = FileSystemRouterSchema.member("reload");
const FileSystemRouterRoutesSchema = FileSystemRouterSchema.member("routes");
const FileSystemRouterStyleSchema = FileSystemRouterSchema.member("style");
const FileSystemRouterClass = bindgen.Class(FileSystemRouterSchema, FileSystemRouter);
pub const FileSystemRouterRoutesSlot = FileSystemRouterClass.CachedSlotInvalidator("routes");

const MatchedRouteParams = bindgen.OwnedNativeSlice(OwnedRouteParam, .any);

const MatchedRouteBindingModule = bindgen.Module("MatchedRoute");
const MatchedRouteSchema = MatchedRouteBindingModule.class("MatchedRoute");
const MatchedRouteFilePathSchema = MatchedRouteSchema.member("filePath");
const MatchedRouteKindSchema = MatchedRouteSchema.member("kind");
const MatchedRouteNameSchema = MatchedRouteSchema.member("name");
const MatchedRouteParamsSchema = MatchedRouteSchema.member("params");
const MatchedRoutePathnameSchema = MatchedRouteSchema.member("pathname");
const MatchedRouteQuerySchema = MatchedRouteSchema.member("query");
const MatchedRouteScriptSrcSchema = MatchedRouteSchema.member("scriptSrc");
const MatchedRouteSrcSchema = MatchedRouteSchema.member("src");
const MatchedRouteClass = bindgen.Class(MatchedRouteSchema, MatchedRoute);

comptime {
    _ = FileSystemRouterClass;
    _ = MatchedRouteClass;
}
