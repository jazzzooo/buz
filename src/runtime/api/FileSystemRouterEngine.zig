pub fn constructFromContext(
    context: bindgen.CallContext(FileSystemRouterConstructorSchema),
    args: bindgen.Args(FileSystemRouterConstructorSchema),
) bindgen.CallError(FileSystemRouterConstructorSchema)!*FileSystemRouter {
    return construct(context.viewToken().globalObject(), context, args);
}

pub fn reloadFromContext(
    context: bindgen.CallContext(FileSystemRouterReloadSchema),
    input: FileSystemRouterReloadInput,
) bun.JSError!bindgen.Return(FileSystemRouterReloadSchema) {
    return reload(context.viewToken().globalObject(), context, input);
}

pub fn requestPath(request: RequestInput) bun.JSError!bindgen.DOMString {
    const value = request.get(jsc.WebCore.Request);
    try value.ensureURL();
    return value.url.clone();
}

pub fn responsePath(response: ResponseInput) bun.OOM!bindgen.DOMString {
    return response.get(jsc.WebCore.Response).getUrl().clone();
}

pub fn scriptSrc(route: *MatchedRoute) bun.OOM!bindgen.DOMString {
    const allocator = bun.default_allocator;
    const metadata = route.metadata.get();
    const source = try jsc.API.Bun.getPublicPathWithAssetPrefix(
        allocator,
        route.file_path.slice(),
        metadata.base_dir.slice(),
        if (metadata.origin.slice().len > 0) URL.parse(metadata.origin.slice()) else URL{},
        metadata.asset_prefix.slice(),
        .posix,
    );
    defer allocator.free(source);
    return bindgen.DOMString.fromUTF8(source);
}

fn construct(
    globalThis: *jsc.JSGlobalObject,
    context: bindgen.CallContext(FileSystemRouterConstructorSchema),
    args: bindgen.Args(FileSystemRouterConstructorSchema),
) bindgen.CallError(FileSystemRouterConstructorSchema)!*FileSystemRouter {
    const options = args.options orelse return context.fail(.missing_options, {});
    var vm = globalThis.bunVM();

    var root_dir_path: bun.String.Slice = bun.String.Slice.fromUTF8NeverFree(vm.transpiler.fs.top_level_dir);
    defer root_dir_path.deinit();
    var origin_str: bun.String.Slice = .{};
    defer origin_str.deinit();

    var out_buf: [bun.MAX_PATH_BYTES * 2]u8 = undefined;
    var requested_root = try options.dir.toUTF8(globalThis.allocator());
    defer requested_root.deinit();
    if (!(requested_root.length() == 0 or strings.eqlComptime(requested_root.slice(), "."))) {
        const path = requested_root.slice();
        if (bun.path.Platform.isAbsolute(.auto, path)) {
            root_dir_path = requested_root;
            requested_root = .empty;
        } else {
            var parts = [_][]const u8{path};
            root_dir_path = bun.String.Slice.fromUTF8NeverFree(bun.path.joinAbsStringBuf(
                Fs.FileSystem.instance.top_level_dir,
                &out_buf,
                &parts,
                .auto,
            ));
        }
    }

    var extensions = std.array_list.Managed(bindgen.OwnedBytes).init(bun.default_allocator);
    defer {
        for (extensions.items) |*extension| extension.deinit();
        extensions.deinit();
    }
    if (options.file_extensions) |*file_extensions| {
        try extensions.ensureTotalCapacityPrecise(file_extensions.len());
        for (0..file_extensions.len()) |index| {
            const encoded = try file_extensions.at(index).?.toUTF8(bun.default_allocator);
            defer encoded.deinit();
            const value = encoded.slice();
            if (value.len == 0) continue;
            const extension = if (value[0] == '.') value[1..] else value;
            if (extension.len > 0) extensions.appendAssumeCapacity(try bindgen.OwnedBytes.fromSlice(extension));
        }
    }

    var config: OwnedRouteConfig = .{
        .dir = .empty(),
        .extensions = .empty,
        .asset_prefix_path = .empty(),
    };
    errdefer config.deinit();
    if (options.asset_prefix) |asset_prefix| {
        config.asset_prefix_path = .fromDefaultAllocatedSlice(try asset_prefix.toOwnedSlice(bun.default_allocator));
    }
    if (options.origin) |origin| origin_str = try origin.toUTF8(globalThis.allocator());

    config.dir = .fromDefaultAllocatedSlice(try strings.cloneNormalizingSeparators(bun.default_allocator, root_dir_path.slice()));
    config.extensions = .fromOwnedSlice(try extensions.toOwnedSlice());

    var scratch = bun.ArenaAllocator.init(bun.default_allocator);
    defer scratch.deinit();
    const original_log = vm.transpiler.resolver.log;
    var log = Log.Log.init(scratch.allocator());
    defer log.deinit();
    vm.transpiler.resolver.log = &log;
    defer vm.transpiler.resolver.log = original_log;

    const root_dir_info = vm.transpiler.resolver.readDirInfo(config.dir.slice()) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return LoggerEngine.throwLog(&log, globalThis, "reading root directory");
    } orelse return globalThis.throw("Unable to find directory: {s}", .{root_dir_path.slice()});

    const snapshot = RouteSnapshot.load(scratch.allocator(), vm.transpiler.fs, &config, &log, &vm.transpiler.resolver, root_dir_info) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return LoggerEngine.throwLog(&log, globalThis, "loading routes");
    };
    errdefer snapshot.destroy();
    if (log.errors + log.warnings > 0) {
        return LoggerEngine.throwLog(&log, globalThis, "loading routes");
    }

    var metadata = try core.RouteMetadata.create(
        if (root_dir_info.abs_real_path.len > 0) root_dir_info.abs_real_path else root_dir_info.abs_path,
        origin_str.slice(),
        config.asset_prefix_path.slice(),
    );
    errdefer metadata.deinit();

    const router = try bun.default_allocator.create(FileSystemRouter);
    router.* = .{
        .metadata = metadata,
        .config = config,
        .snapshot = .init(snapshot),
    };
    return router;
}

fn reload(
    globalThis: *jsc.JSGlobalObject,
    _: bindgen.CallContext(FileSystemRouterReloadSchema),
    input: FileSystemRouterReloadInput,
) bun.JSError!bindgen.Return(FileSystemRouterReloadSchema) {
    var vm = globalThis.bunVM();
    const config = &input.router.config;
    var scratch = bun.ArenaAllocator.init(bun.default_allocator);
    defer scratch.deinit();

    const original_log = vm.transpiler.resolver.log;
    var log = Log.Log.init(scratch.allocator());
    defer log.deinit();
    vm.transpiler.resolver.log = &log;
    defer vm.transpiler.resolver.log = original_log;

    bustDirCache(input.router, globalThis);
    const root_dir_info = vm.transpiler.resolver.readDirInfo(config.dir.slice()) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return LoggerEngine.throwLog(&log, globalThis, "reading root directory");
    } orelse return globalThis.throw("Unable to find directory: {s}", .{config.dir.slice()});

    const snapshot = RouteSnapshot.load(scratch.allocator(), vm.transpiler.fs, config, &log, &vm.transpiler.resolver, root_dir_info) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return LoggerEngine.throwLog(&log, globalThis, "loading routes");
    };
    errdefer snapshot.destroy();
    if (log.errors + log.warnings > 0) {
        return LoggerEngine.throwLog(&log, globalThis, "loading routes");
    }

    const result = try input.args.bindingThis.toOwned();
    const old_snapshot = input.router.snapshot.take();
    input.router.snapshot = .init(snapshot);
    core.FileSystemRouterRoutesSlot.clearView(input.args.bindingThis);
    old_snapshot.destroy();
    return result;
}

const win32_normalize_bufs = bun.ThreadlocalBuffers(struct {
    buf: if (bun.Environment.isWindows) [bun.MAX_PATH_BYTES * 2]u8 else void = undefined,
});

fn bustDirCache(router: *FileSystemRouter, globalThis: *jsc.JSGlobalObject) void {
    bustDirCacheRecursive(globalThis, strings.withoutTrailingSlashWindowsPath(router.config.dir.slice()));
}

fn bustDirCacheRecursive(globalThis: *jsc.JSGlobalObject, input_path: []const u8) void {
    var vm = globalThis.bunVM();
    var path = input_path;
    if (comptime bun.Environment.isWindows) {
        var fba = std.heap.FixedBufferAllocator.init(&win32_normalize_bufs.get().buf);
        path = std.fs.path.resolveWindows(fba.allocator(), &.{path}) catch return;
    }

    const root_dir_info = vm.transpiler.resolver.readDirInfo(path) catch return;
    if (root_dir_info) |dir| {
        if (dir.getEntriesConst()) |entries| {
            var iter = entries.data.iterator();
            outer: while (iter.next()) |entry_ptr| {
                const entry = entry_ptr.value_ptr.*;
                if (entry.base()[0] == '.') continue;
                if (entry.kind(&vm.transpiler.fs.fs, false) != .dir) continue;
                inline for (Router.banned_dirs) |banned_dir| {
                    if (strings.eqlComptime(entry.base(), comptime banned_dir)) continue :outer;
                }

                var parts = [_][]const u8{ entry.dir, entry.base() };
                const full_path = vm.transpiler.fs.abs(&parts);
                _ = vm.transpiler.resolver.bustDirCache(strings.withoutTrailingSlashWindowsPath(full_path));
                bustDirCacheRecursive(globalThis, full_path);
            }
        }
    }
    _ = vm.transpiler.resolver.bustDirCache(path);
}

const std = @import("std");
const core = @import("./filesystem_router.zig");
const FileSystemRouter = core.FileSystemRouter;
const FileSystemRouterReloadInput = core.FileSystemRouterReloadInput;
const MatchedRoute = core.MatchedRoute;
const OwnedRouteConfig = core.OwnedRouteConfig;
const RouteSnapshot = core.RouteSnapshot;
const Fs = @import("../../resolver/fs.zig");
const Router = @import("../../router/router.zig");
const URL = @import("../../url/url.zig").URL;

const bun = @import("bun");
const bindgen = bun.bindgen;
const jsc = bun.jsc;
const Log = bun.logger;
const strings = bun.strings;
const LoggerEngine = @import("../../logger_jsc/LoggerEngine.zig");

const FileSystemRouterBindingModule = bindgen.Module("FileSystemRouter");
const FileSystemRouterSchema = FileSystemRouterBindingModule.class("FileSystemRouter");
const FileSystemRouterConstructorSchema = FileSystemRouterSchema.constructor();
const FileSystemRouterMatchSchema = FileSystemRouterSchema.member("match");
const FileSystemRouterReloadSchema = FileSystemRouterSchema.member("reload");

const RouteMatchInput = @typeInfo(@FieldType(bindgen.Args(FileSystemRouterMatchSchema), "input")).optional.child;
const RequestInput = @FieldType(RouteMatchInput, "request");
const ResponseInput = @FieldType(RouteMatchInput, "response");

const MatchedRouteBindingModule = bindgen.Module("MatchedRoute");
const MatchedRouteSchema = MatchedRouteBindingModule.class("MatchedRoute");
const MatchedRouteScriptSrcSchema = MatchedRouteSchema.member("scriptSrc");
const MatchedRouteSrcSchema = MatchedRouteSchema.member("src");
