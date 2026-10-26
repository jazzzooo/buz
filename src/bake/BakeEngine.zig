pub const production = @import("./production.zig");
pub const DevServer = @import("./DevServer.zig");
pub const FrameworkRouter = @import("./FrameworkRouter.zig");
pub const FrameworkRouterEngine = @import("./FrameworkRouterEngine.zig");
pub const FrameworkTranspilerEngine = @import("./FrameworkTranspilerEngine.zig");
pub const Framework = @import("./Framework.zig");
pub const BuildConfigSubset = @import("./BuildConfig.zig").Subset;

pub const api_name = "app";

pub const UserOptions = struct {
    arena: std.heap.ArenaAllocator,
    allocations: StringRefList,

    root: [:0]const u8,
    framework: Framework,
    route_styles: []FrameworkRouterEngine.Style,
    bundler_options: SplitBundlerOptions,

    pub fn deinit(options: *UserOptions) void {
        for (options.route_styles) |*style| style.deinit();
        options.arena.deinit();
        options.allocations.free();
        if (options.bundler_options.plugin) |plugin| plugin.deinit();
    }

    pub fn destroy(options: *UserOptions) void {
        options.deinit();
        bun.destroy(options);
    }

    pub fn fromSchema(globalThis: *jsc.JSGlobalObject, context: anytype, config: anytype) bun.bindgen.CallError(@TypeOf(context))!UserOptions {
        var arena = std.heap.ArenaAllocator.init(bun.default_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        var bundler_options = SplitBundlerOptions.empty;
        errdefer if (bundler_options.plugin) |plugin| plugin.deinit();

        switch (config.*) {
            .preset => {
                const root = try allocator.dupeSentinel(u8, globalThis.bunVM().transpiler.fs.top_level_dir, 0);
                return .{
                    .arena = arena,
                    .allocations = .empty,
                    .root = root,
                    .framework = try Framework.react(globalThis.bunVM().io, allocator),
                    .route_styles = &.{},
                    .bundler_options = bundler_options,
                };
            },
            .invalid => return invalidOptions(context, "'" ++ api_name ++ "' is not an object"),
            .options => |*options| {
                const parsed_framework = try parseFramework(
                    globalThis.bunVM().io,
                    context,
                    &options.framework,
                    &bundler_options,
                    allocator,
                );
                errdefer for (parsed_framework.route_styles) |*style| style.deinit();

                if (options.bundlerOptions) |*generated| {
                    try bundler_options.applySchema(context, generated);
                }
                if (options.plugins) |*plugins| {
                    try bundler_options.parsePluginSequence(context, plugins);
                }

                const root = if (options.root) |root|
                    try root.toOwnedSliceZ(allocator)
                else
                    try allocator.dupeSentinel(u8, globalThis.bunVM().transpiler.fs.top_level_dir, 0);

                return .{
                    .arena = arena,
                    .allocations = .empty,
                    .root = root,
                    .framework = parsed_framework.framework,
                    .route_styles = parsed_framework.route_styles,
                    .bundler_options = bundler_options,
                };
            },
        }
    }
};

pub const BakeAppOptions = struct {
    bindgen_state: bindgen.ClassState = .{},
    options: bindgen.OwnedNative(UserOptions, .vm),

    fn createNative(
        context: bindgen.CallContext(BakeAppOptionsCreateSchema),
        args: bindgen.Args(BakeAppOptionsCreateSchema),
    ) bindgen.CallError(BakeAppOptionsCreateSchema)!bindgen.ClassRef(BakeAppOptionsClassSchema) {
        const user_options = bun.new(UserOptions, try UserOptions.fromSchema(context.viewToken().globalObject(), context, &args.options));
        var user_options_unowned = true;
        errdefer if (user_options_unowned) UserOptions.destroy(user_options);
        const native = bun.new(BakeAppOptions, .{
            .options = .init(user_options),
        });
        user_options_unowned = false;
        return BakeAppOptionsClass.adoptResult(native, context);
    }

    pub fn destroy(options: *BakeAppOptions) void {
        options.options.deinit();
        bun.destroy(options);
    }
};

pub const StringRefList = struct {
    strings: std.ArrayListUnmanaged([]const u8),

    pub const empty: StringRefList = .{ .strings = .empty };

    pub fn copy(list: *StringRefList, string: []const u8) bun.OOM![]const u8 {
        const owned = try bun.default_allocator.dupe(u8, string);
        errdefer bun.default_allocator.free(owned);
        try list.strings.append(bun.default_allocator, owned);
        return owned;
    }

    pub fn free(list: *StringRefList) void {
        for (list.strings.items) |item| bun.default_allocator.free(item);
        list.strings.clearAndFree(bun.default_allocator);
    }
};

pub const SplitBundlerOptions = struct {
    plugin: ?*Plugin = null,
    client: BuildConfigSubset = .{},
    server: BuildConfigSubset = .{},
    ssr: BuildConfigSubset = .{},

    pub const empty: SplitBundlerOptions = .{
        .plugin = null,
        .client = .{},
        .server = .{},
        .ssr = .{},
    };

    fn applySchema(options: *SplitBundlerOptions, context: anytype, generated: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
        if (generated.client) |*client| try applyBuildConfig(&options.client, context, client);
        if (generated.server) |*server| try applyBuildConfig(&options.server, context, server);
        if (generated.ssr) |*ssr| try applyBuildConfig(&options.ssr, context, ssr);
    }

    fn parsePluginSequence(options: *SplitBundlerOptions, context: anytype, generated: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
        if (generated.len() == 0) return;
        const plugin = options.plugin orelse try Plugin.create(context, .bun);
        options.plugin = plugin;

        var iterator = generated.iterator();
        var plugin_index: usize = 0;
        while (iterator.next()) |plugin_config_| : (plugin_index += 1) {
            const plugin_config_item = plugin_config_;
            const plugin_config = &plugin_config_item.value;
            if (plugin_config.name.length() == 0) {
                return invalidOptions(context, "Expected plugin to have a non-empty name");
            }

            try plugin.runSetup(
                context,
                &plugin_config.setup,
                null,
                plugin_index == 0,
                plugin_index + 1 == generated.len(),
                true,
            );
        }
    }
};

const ParsedFramework = struct {
    framework: Framework,
    route_styles: []FrameworkRouterEngine.Style,
};

fn parseFramework(
    io: std.Io,
    context: anytype,
    input: anytype,
    bundler_options: *SplitBundlerOptions,
    arena: Allocator,
) bun.bindgen.CallError(@TypeOf(context))!ParsedFramework {
    switch (input.*) {
        .preset => |preset| {
            if (preset == .react_server_components) {
                bun.Output.warn("deprecation notice: 'react-server-components' will be renamed to 'react'", .{});
            }
            return .{
                .framework = try Framework.react(io, arena),
                .route_styles = &.{},
            };
        },
        .invalid => return invalidOptions(context, "Framework must be an object"),
        .options => |*options| {
            if (options.bundlerOptions) |*generated| {
                try bundler_options.applySchema(context, generated);
            }

            const react_fast_refresh: ?Framework.ReactFastRefresh = if (options.reactFastRefresh) |*refresh|
                switch (refresh.*) {
                    .flag => |enabled| if (enabled) .{} else null,
                    .nulled => null,
                    .options => |settings| .{
                        .import_source = try settings.importSource.toOwnedSlice(arena),
                    },
                }
            else
                null;

            const server_components: ?Framework.ServerComponents = if (options.serverComponents) |*components|
                switch (components.*) {
                    .nulled => null,
                    .flag => |enabled| if (!enabled)
                        null
                    else
                        return invalidOptions(context, "'framework.serverComponents' must be an object or 'undefined'"),
                    .options => |settings| .{
                        .separate_ssr_graph = settings.separateSSRGraph,
                        .server_runtime_import = try settings.serverRuntimeImportSource.toOwnedSlice(arena),
                        .server_register_client_reference = if (settings.serverRegisterClientReferenceExport) |value|
                            try value.toOwnedSlice(arena)
                        else
                            "registerClientReference",
                    },
                }
            else
                null;

            const built_in_modules: bun.StringArrayHashMap(Framework.BuiltInModule) = modules: {
                const generated = if (options.builtInModules) |*modules| modules else break :modules .empty;
                var modules: bun.StringArrayHashMap(Framework.BuiltInModule) = .empty;
                try modules.ensureTotalCapacity(arena, generated.len());
                var iterator = generated.iterator();
                var index: usize = 0;
                while (iterator.next()) |module_| : (index += 1) {
                    const module_item = module_;
                    const module = module_item.value;
                    const path = try module.import.toOwnedSlice(arena);
                    const value: Framework.BuiltInModule = if (module.path) |module_path|
                        .{ .import = try module_path.toOwnedSlice(arena) }
                    else if (module.code) |code|
                        .{ .code = try code.toOwnedSlice(arena) }
                    else {
                        const message = try std.fmt.allocPrint(arena, "'builtInModules[{d}]' needs either 'path' or 'code'", .{index});
                        return invalidOptions(context, message);
                    };
                    modules.putAssumeCapacity(path, value);
                }
                break :modules modules;
            };

            const generated_routers = &options.fileSystemRouterTypes;
            const router_limit = @as(usize, std.math.maxInt(@typeInfo(FrameworkRouter.Type.Index).@"enum".tag_type)) + 1;
            if (generated_routers.len() > router_limit) {
                return invalidOptions(context, "Framework can only define up to 256 file-system router types");
            }
            const routers = try arena.alloc(Framework.FileSystemRouterType, generated_routers.len());
            const route_styles = try arena.alloc(FrameworkRouterEngine.Style, generated_routers.len());
            var initialized: usize = 0;
            errdefer for (route_styles[0..initialized]) |*style| style.deinit();

            var router_iterator = generated_routers.iterator();
            var index: usize = 0;
            while (router_iterator.next()) |generated_| : (index += 1) {
                const generated_item = generated_;
                const generated = &generated_item.value;
                var route_style = try FrameworkRouterEngine.Style.fromArgument(generated.style);
                errdefer route_style.deinit();

                const extensions: []const []const u8 = if (generated.extensions) |*extension_input|
                    switch (extension_input.*) {
                        .all => &.{},
                        .invalid => return invalidOptions(context, "'extensions' must be an array of strings or \"*\" for all extensions"),
                        .values => |*values| extensions: {
                            const copied = try arena.alloc([]const u8, values.len());
                            var extension_iterator = values.iterator();
                            var extension_index: usize = 0;
                            while (extension_iterator.next()) |extension_| : (extension_index += 1) {
                                const extension_item = extension_;
                                const extension = try extension_item.value.toOwnedSlice(arena);
                                if (bun.strings.eqlComptime(extension, "*")) {
                                    return invalidOptions(context, "'extensions' cannot include \"*\" as an extension. Pass \"*\" instead of the array.");
                                }
                                if (extension.len == 0) {
                                    return invalidOptions(context, "'extensions' cannot include \"\" as an extension.");
                                }
                                copied[extension_index] = if (extension[0] == '.')
                                    extension
                                else
                                    try std.mem.concat(arena, u8, &.{ ".", extension });
                            }
                            break :extensions copied;
                        },
                    }
                else
                    &.{ ".jsx", ".tsx", ".js", ".ts", ".cjs", ".cts", ".mjs", ".mts" };

                routers[index] = .{
                    .root = try generated.root.toOwnedSlice(arena),
                    .prefix = if (generated.prefix) |prefix| try prefix.toOwnedSlice(arena) else "/",
                    .entry_server = try generated.serverEntryPoint.toOwnedSlice(arena),
                    .entry_client = if (generated.clientEntryPoint) |entry| try entry.toOwnedSlice(arena) else null,
                    .ignore_underscores = generated.ignoreUnderscores orelse false,
                    .ignore_dirs = if (generated.ignoreDirs) |*dirs|
                        try copyDOMStringSequence(arena, dirs)
                    else
                        &.{ ".git", "node_modules" },
                    .extensions = extensions,
                    .style = route_style.toRouterStyle(@intCast(index)),
                    .allow_layouts = generated.layouts orelse false,
                };
                route_styles[index] = route_style;
                initialized += 1;
            }

            if (options.plugins) |*generated| {
                try bundler_options.parsePluginSequence(context, generated);
            }
            return .{
                .framework = .{
                    .is_built_in_react = false,
                    .file_system_router_types = routers,
                    .react_fast_refresh = react_fast_refresh,
                    .server_components = server_components,
                    .built_in_modules = built_in_modules,
                },
                .route_styles = route_styles,
            };
        },
    }
}

fn applyBuildConfig(options: *BuildConfigSubset, context: anytype, generated: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
    if (generated.sourcemap) |source_map| {
        options.source_map = switch (source_map) {
            .inlined => .@"inline",
            .external => .external,
            .linked => .linked,
        };
    }

    if (generated.minify) |*minify| switch (minify.*) {
        .flag => |value| {
            options.minify_syntax = value;
            options.minify_identifiers = value;
            options.minify_whitespace = value;
        },
        .options => |settings| {
            if (settings.whitespace) |value| options.minify_whitespace = value;
            if (settings.syntax) |value| options.minify_syntax = value;
            if (settings.identifiers) |value| options.minify_identifiers = value;
        },
        .invalid => return invalidOptions(context, "'minify' must be a boolean or an object"),
    };
}

fn invalidOptions(context: anytype, message: []const u8) bun.bindgen.CallError(@TypeOf(context)) {
    const payload = bindgen.DOMString.fromUTF8(message) catch return error.OutOfMemory;
    return context.fail(.invalid_options, payload);
}

fn copyDOMStringSequence(
    allocator: Allocator,
    values: anytype,
) bun.OOM![]const []const u8 {
    const result = try allocator.alloc([]const u8, values.len());
    var iterator = values.iterator();
    var index: usize = 0;
    while (iterator.next()) |item_| : (index += 1) {
        const item = item_;
        result[index] = try item.value.toOwnedSlice(allocator);
    }
    return result;
}

const BakeCore = @import("./BakeCore.zig");
pub const HmrRuntime = BakeCore.HmrRuntime;
pub const getHmrRuntime = BakeCore.getHmrRuntime;
pub const Mode = BakeCore.Mode;
pub const Side = BakeCore.Side;
pub const Graph = BakeCore.Graph;
pub const addImportMetaDefines = BakeCore.addImportMetaDefines;
pub const server_virtual_source = BakeCore.server_virtual_source;
pub const client_virtual_source = BakeCore.client_virtual_source;
pub const PatternBuffer = BakeCore.PatternBuffer;
pub const printWarning = BakeCore.printWarning;

const std = @import("std");
const Allocator = std.mem.Allocator;

const bun = @import("bun");
const jsc = bun.jsc;
const bindgen = bun.bindgen;
const Plugin = jsc.API.JSBundler.Plugin;

const BakeAppOptionsBindingModule = bindgen.Module("BakeAppOptions");
const BakeAppOptionsClassSchema = BakeAppOptionsBindingModule.class("BakeAppOptions");
const BakeAppOptionsCreateSchema = BakeAppOptionsBindingModule.function("createNative");
const BakeAppOptionsClass = bindgen.Class(BakeAppOptionsClassSchema, BakeAppOptions);
const BakeAppOptionsCreateBinding = bindgen.Fn(BakeAppOptionsCreateSchema, BakeAppOptions.createNative);

comptime {
    _ = BakeAppOptionsClass;
    _ = BakeAppOptionsCreateBinding;
}
