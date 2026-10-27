//! Implements building a Bake application to production
const log = bun.Output.scoped(.production, .visible);

pub fn buildCommand(ctx: bun.cli.Command.Context) !void {
    bun.bake.printWarning();

    if (ctx.args.entry_points.len > 1) {
        Output.errGeneric("bun build --app only accepts one entrypoint", .{});
        bun.Global.crash();
    }

    if (ctx.debug.hot_reload != .none) {
        Output.errGeneric("Instead of using --watch, use 'bun run'", .{});
        bun.Global.crash();
    }

    var cwd_buf: bun.PathBuffer = undefined;
    const cwd = bun.getcwd(&cwd_buf) catch |err| {
        Output.err(err, "Could not query current working directory", .{});
        bun.Global.crash();
    };

    // Create a VM + global for loading the config file, plugins, and
    // performing build time prerendering.
    bun.jsc.initialize(false);
    bun.ast.Expr.Data.Store.create();
    bun.ast.Stmt.Data.Store.create();

    var arena = bun.MimallocArena.init();
    defer arena.deinit();

    const vm = try VirtualMachine.initBake(.{
        .allocator = arena.allocator(),
        .io = ctx.io,
        .pinned_threads = bun.cli.Cli.pinnedThreads(),
        .log = ctx.log,
        .args = ctx.args,
        .smol = ctx.runtime_options.smol,
    });
    vm.arena = &arena;
    const build_result = configureAndBuild(ctx, cwd, vm);
    {
        const api_lock = vm.jsc_vm.getAPILock();
        defer api_lock.release();
        if (build_result) |_| {} else |_| {
            if (vm.exit_handler.exit_code == 0) vm.exit_handler.exit_code = 1;
        }
        vm.onExit();
    }
    const exit_code = vm.exit_handler.exit_code;
    if (!vm.destructOnExit()) bun.Global.exitWithoutCleanup(exit_code);
    try build_result;
    if (exit_code != 0) bun.Global.exit(exit_code);
}

fn configureAndBuild(ctx: bun.cli.Command.Context, cwd: []const u8, vm: *VirtualMachine) !void {
    // A special global object is used to allow registering virtual modules
    // that bypass Bun's normal module resolver and plugin system.
    vm.regular_event_loop.global = vm.global;
    vm.event_loop.ensureWaker();
    const b = &vm.transpiler;
    vm.preload = ctx.preloads;
    vm.argv = ctx.passthrough;
    b.options.install = ctx.install;
    b.resolver.opts.install = ctx.install;
    b.resolver.opts.global_cache = ctx.debug.global_cache;
    b.resolver.opts.prefer_offline_install = (ctx.debug.offline_mode_setting orelse .online) == .offline;
    b.resolver.opts.prefer_latest_install = (ctx.debug.offline_mode_setting orelse .online) == .latest;
    b.options.global_cache = b.resolver.opts.global_cache;
    b.options.prefer_offline_install = b.resolver.opts.prefer_offline_install;
    b.options.prefer_latest_install = b.resolver.opts.prefer_latest_install;
    b.resolver.env_loader = b.env;
    b.options.minify_identifiers = ctx.bundler_options.minify_identifiers;
    b.options.minify_whitespace = ctx.bundler_options.minify_whitespace;
    b.options.ignore_dce_annotations = ctx.bundler_options.ignore_dce_annotations;
    b.resolver.opts.minify_identifiers = ctx.bundler_options.minify_identifiers;
    b.resolver.opts.minify_whitespace = ctx.bundler_options.minify_whitespace;
    b.options.env.behavior = .load_all_without_inlining;
    vm.event_loop.ensureWaker();
    switch (ctx.debug.macros) {
        .disable => {
            b.options.no_macros = true;
        },
        .map => |macros| {
            b.options.macro_remap = macros;
        },
        .unspecified => {},
    }
    b.configureDefines() catch {
        bun.bun_js.failWithBuildError(vm);
    };
    bun.http.AsyncHTTP.loadEnv(vm.allocator, vm.log, b.env);
    vm.loadExtraEnvAndSourceCodePrinter();
    vm.is_main_thread = true;
    jsc.VirtualMachine.is_main_thread_vm = true;

    const api_lock = vm.jsc_vm.getAPILock();
    defer api_lock.release();

    var pt: PerThread = .{
        .input_files = &.{},
        .bundled_outputs = &.{},
        .output_indexes = &.{},
        .module_keys = &.{},
        .module_map = .{},
        .source_maps = .{},

        .vm = vm,
        .loaded_files = .{},
    };
    defer pt.deinit();

    buildWithVm(ctx, cwd, vm, &pt) catch |err| switch (err) {
        error.JSError => {
            bun.handleErrorReturnTrace(err, @errorReturnTrace());
            {
                var scope: bun.bindgen.FocusedEngineScope = undefined;
                scope.init(vm.global);
                defer scope.deinit();
                if (!scope.runPendingErrorHandler()) @panic("build failed without a pending exception");
            }
            if (vm.exit_handler.exit_code == 0) {
                vm.exit_handler.exit_code = 1;
            }
        },
        else => |e| return e,
    };
}

pub fn writeSourcemapToDisk(
    allocator: std.mem.Allocator,
    file: *const OutputFile,
    bundled_outputs: []const OutputFile,
    source_maps: *bun.StringArrayHashMap(OutputFile.Index),
) !void {
    // don't call this if the file does not have sourcemaps!
    bun.assert(file.source_map_index != std.math.maxInt(u32));

    // TODO: should we just write the sourcemaps to disk?
    const source_map_index = file.source_map_index;
    const source_map_file: *const OutputFile = &bundled_outputs[source_map_index];
    bun.assert(source_map_file.output_kind == .sourcemap);

    const without_prefix = if (bun.strings.hasPrefixComptime(file.dest_path, "./") or
        (Environment.isWindows and bun.strings.hasPrefixComptime(file.dest_path, ".\\")))
        file.dest_path[2..]
    else
        file.dest_path;

    try source_maps.put(
        allocator,
        try std.fmt.allocPrint(allocator, "bake:/{s}", .{without_prefix}),
        OutputFile.Index.init(@intCast(source_map_index)),
    );
}

pub fn buildWithVm(ctx: bun.cli.Command.Context, cwd: []const u8, vm: *VirtualMachine, pt: *PerThread) !void {
    // Load and evaluate the configuration module
    const global = vm.global;
    const b = &vm.transpiler;
    const allocator = bun.default_allocator;

    Output.prettyErrorln("Loading configuration", .{});
    Output.flush();
    var unresolved_config_entry_point = if (ctx.args.entry_points.len > 0) ctx.args.entry_points[0] else "./bun.app";
    if (bun.resolver.isPackagePath(unresolved_config_entry_point)) {
        unresolved_config_entry_point = try std.fmt.allocPrint(ctx.allocator, "./{s}", .{unresolved_config_entry_point});
    }

    const config_entry_point = b.resolver.resolve(cwd, unresolved_config_entry_point, .entry_point_build) catch |err| {
        if (err == error.ModuleNotFound) {
            if (ctx.args.entry_points.len == 0) {
                // Onboarding message
                Output.err(err,
                    \\'bun build --app' cannot find your application's config file
                    \\
                    \\The default location for this is `bun.app.ts`
                    \\
                    \\TODO: insert a link to `bun.com/docs`
                , .{});
                bun.Global.crash();
            }
        }

        Output.err(err, "could not resolve application config file '{s}'", .{unresolved_config_entry_point});
        bun.Global.crash();
    };

    var config_entry_point_name = try bun.bindgen.DOMString.fromUTF8(config_entry_point.pathConst().?.text);
    const config_entry_point_string = config_entry_point_name.takeBunString();
    defer config_entry_point_string.deref();

    try loadModule(global, &config_entry_point_string);
    var default = try bakeGetDefaultExportFromModule(vm.global, &config_entry_point_string);
    defer default.deinit();
    var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
    engine_scope.init(global);
    defer engine_scope.deinit();
    const options_ref = try engine_scope.engine(BakeAppOptionsCreateFromModuleDefaultSchema).call(.{
        .moduleDefault = default.operand(&engine_scope).asEngine(),
    });
    const options = options_ref.get(bake.BakeAppOptions).options.get();

    const framework = &options.framework;

    const separate_ssr_graph = if (framework.server_components) |sc| sc.separate_ssr_graph else false;

    // this is probably wrong
    const map = try allocator.create(bun.DotEnv.Map);
    map.* = bun.DotEnv.Map.init(allocator);
    const loader = try allocator.create(bun.DotEnv.Loader);
    loader.* = bun.DotEnv.Loader.init(map, allocator);
    try loader.map.put("NODE_ENV", "production");
    bun.DotEnv.instance = loader;

    var client_transpiler: bun.transpiler.Transpiler = undefined;
    var server_transpiler: bun.transpiler.Transpiler = undefined;
    var ssr_transpiler: bun.transpiler.Transpiler = undefined;
    try bake.FrameworkTranspilerEngine.initWithOptions(framework, allocator, vm.io, vm.log, .production_static, .server, &server_transpiler, &options.bundler_options.server, bun.options.SourceMapOption.fromApi(options.bundler_options.server.source_map), options.bundler_options.server.minify_whitespace, options.bundler_options.server.minify_syntax, options.bundler_options.server.minify_identifiers);
    try bake.FrameworkTranspilerEngine.initWithOptions(framework, allocator, vm.io, vm.log, .production_static, .client, &client_transpiler, &options.bundler_options.client, bun.options.SourceMapOption.fromApi(options.bundler_options.client.source_map), options.bundler_options.client.minify_whitespace, options.bundler_options.client.minify_syntax, options.bundler_options.client.minify_identifiers);
    if (separate_ssr_graph) {
        try bake.FrameworkTranspilerEngine.initWithOptions(framework, allocator, vm.io, vm.log, .production_static, .ssr, &ssr_transpiler, &options.bundler_options.ssr, bun.options.SourceMapOption.fromApi(options.bundler_options.ssr.source_map), options.bundler_options.ssr.minify_whitespace, options.bundler_options.ssr.minify_syntax, options.bundler_options.ssr.minify_identifiers);
    }

    if (ctx.bundler_options.bake_debug_disable_minify) {
        for ([_]*bun.transpiler.Transpiler{ &client_transpiler, &server_transpiler, &ssr_transpiler }) |transpiler| {
            transpiler.options.minify_syntax = false;
            transpiler.options.minify_identifiers = false;
            transpiler.options.minify_whitespace = false;
            transpiler.resolver.opts.entry_naming = "_bun/[dir]/[name].[hash].[ext]";
            transpiler.resolver.opts.chunk_naming = "_bun/[dir]/[name].[hash].chunk.[ext]";
            transpiler.resolver.opts.asset_naming = "_bun/[dir]/[name].[hash].asset.[ext]";
        }
    }

    // these share pointers right now, so setting NODE_ENV == production on one should affect all
    bun.assert(server_transpiler.env == client_transpiler.env);

    framework.* = framework.resolve(&server_transpiler.resolver, &client_transpiler.resolver, allocator) catch {
        if (framework.is_built_in_react)
            try bake.Framework.addReactInstallCommandNote(server_transpiler.log);
        Output.errGeneric("Failed to resolve all imports required by the framework", .{});
        Output.flush();
        server_transpiler.log.print(Output.errorWriter()) catch {};
        bun.Global.crash();
    };

    Output.prettyErrorln("Bundling routes", .{});
    Output.flush();

    // trailing slash
    const public_path = "/";

    var root_dir_buf: bun.PathBuffer = undefined;
    const root_dir_path = bun.path.joinAbsStringBuf(cwd, &root_dir_buf, &.{"dist"}, .auto);

    var router_types = try std.ArrayList(FrameworkRouter.Type).initCapacity(allocator, options.framework.file_system_router_types.len);

    var entry_points: EntryPointMap = .{
        .root = cwd,
        .allocator = allocator,
        .files = .{},
    };

    for (options.framework.file_system_router_types) |fsr| {
        const joined_root = try std.fs.path.resolve(allocator, &.{ cwd, fsr.root });
        defer allocator.free(joined_root);
        const entry = server_transpiler.resolver.readDirInfoIgnoreError(joined_root) orelse
            continue;
        try router_types.append(allocator, .{
            .abs_root = bun.strings.withoutTrailingSlashWindowsPath(entry.abs_path),
            .prefix = fsr.prefix,
            .ignore_underscores = fsr.ignore_underscores,
            .ignore_dirs = fsr.ignore_dirs,
            .extensions = fsr.extensions,
            .style = fsr.style,
            .allow_layouts = fsr.allow_layouts,
            .server_file = try entry_points.getOrPutEntryPoint(fsr.entry_server, .server),
            .client_file = if (fsr.entry_client) |client|
                (try entry_points.getOrPutEntryPoint(client, .client)).toOptional()
            else
                .none,
            .server_file_string = null,
        });
    }

    var router = try FrameworkRouter.initEmpty(cwd, router_types.items, allocator);
    var router_context: ProductionRouterContext = .{
        .entry_points = &entry_points,
        .route_styles = options.route_styles,
    };
    try router.scanAll(
        allocator,
        &server_transpiler.resolver,
        FrameworkRouter.InsertionContext.wrap(ProductionRouterContext, &router_context),
    );

    const bundled_outputs_list = try bun.BundleV2.generateFromBakeProductionCLI(
        entry_points,
        &server_transpiler,
        .{
            .framework = framework.*,
            .client_transpiler = &client_transpiler,
            .ssr_transpiler = if (separate_ssr_graph) &ssr_transpiler else &server_transpiler,
            .plugin_host = if (options.bundler_options.plugin) |plugin| plugin.host() else null,
        },
        allocator,
        BundlerEngine.forEventLoop(vm.event_loop),
        BundlerEngine.bytecode_generator,
    );
    const bundled_outputs = bundled_outputs_list.items;
    if (bundled_outputs.len == 0) {
        Output.prettyln("done", .{});
        Output.flush();
        return;
    }

    Output.prettyErrorln("Rendering routes", .{});
    Output.flush();

    const root_dir = try bun.MakePath.makeOpenPath(vm.io, std.Io.Dir.cwd(), "dist", .{});
    defer root_dir.close(vm.io);

    var maybe_runtime_file_index: ?u32 = null;

    var css_chunks_count: usize = 0;
    var css_chunks_first: usize = 0;

    // Index all bundled outputs.
    // Client files go to disk.
    // Server files get loaded in memory.
    // Populate indexes in `entry_points` to be looked up during prerendering
    const module_keys = try vm.allocator.alloc(bun.String, entry_points.files.count());
    const output_indexes = entry_points.files.values();
    var output_module_map: bun.StringArrayHashMap(OutputFile.Index) = .empty;
    var source_maps: bun.StringArrayHashMap(OutputFile.Index) = .empty;
    @memset(module_keys, bun.String.dead);
    for (bundled_outputs, 0..) |file, i| {
        log("src_index={?f} side={s} src={s} dest={s} - {?d}\n", .{
            file.source_index.unwrap(),
            if (file.side) |s| @tagName(s) else "null",
            file.src_path.text,
            file.dest_path,
            file.entry_point_index,
        });
        if (file.loader.isCSS()) {
            if (css_chunks_count == 0) {
                css_chunks_first = i;
            } else {
                css_chunks_first = @min(css_chunks_first, i);
            }
            css_chunks_count += 1;
        }

        if (file.entry_point_index) |entry_point| {
            if (entry_point < output_indexes.len) {
                output_indexes[entry_point] = OutputFile.Index.init(@intCast(i));
            }
        }

        // The output file which contains the runtime (Index.runtime, contains
        // wrapper functions like `__esm`) is marked as server side, but it is
        // also used by client
        if (file.bake_extra.bake_is_runtime) {
            if (comptime bun.Environment.allow_assert) {
                bun.assertf(maybe_runtime_file_index == null, "Runtime file should only be in one chunk.", .{});
            }
            maybe_runtime_file_index = @intCast(i);
        }

        // TODO: Maybe not do all the disk-writing in 1 thread?
        switch (file.side orelse continue) {
            .client => {
                // Client-side resources will be written to disk for usage in on the client side
                _ = file.writeToDisk(vm.io, root_dir, ".") catch |err| {
                    bun.handleErrorReturnTrace(err, @errorReturnTrace());
                    Output.err(err, "Failed to write {f} to output directory", .{bun.fmt.quote(file.dest_path)});
                };
            },
            .server => {
                if (ctx.bundler_options.bake_debug_dump_server) {
                    _ = file.writeToDisk(vm.io, root_dir, ".") catch |err| {
                        bun.handleErrorReturnTrace(err, @errorReturnTrace());
                        Output.err(err, "Failed to write {f} to output directory", .{bun.fmt.quote(file.dest_path)});
                    };
                }

                // If the file has a sourcemap, store it so we can put it on
                // `PerThread` so we can provide sourcemapped stacktraces for
                // server components.
                if (file.source_map_index != std.math.maxInt(u32)) {
                    try writeSourcemapToDisk(allocator, &file, bundled_outputs, &source_maps);
                }

                switch (file.output_kind) {
                    .@"entry-point", .chunk => {
                        const without_prefix = if (bun.strings.hasPrefixComptime(file.dest_path, "./") or
                            (Environment.isWindows and bun.strings.hasPrefixComptime(file.dest_path, ".\\")))
                            file.dest_path[2..]
                        else
                            file.dest_path;

                        if (file.entry_point_index) |entry_point_index| {
                            if (entry_point_index < module_keys.len) {
                                var str = try bun.String.createFormat("bake:/{s}", .{without_prefix});
                                errdefer str.deref();
                                try str.toThreadSafe();
                                module_keys[entry_point_index] = str;
                            }
                        }

                        log("  adding module map entry: output_module_map(bake:/{s}) = {d}\n", .{ without_prefix, i });

                        try output_module_map.put(
                            allocator,
                            try std.fmt.allocPrint(allocator, "bake:/{s}", .{without_prefix}),
                            OutputFile.Index.init(@intCast(i)),
                        );
                    },
                    .asset => {},
                    .bytecode => {},
                    .sourcemap => {},
                    .module_info => {},
                    .@"metafile-json", .@"metafile-markdown" => {},
                }
            },
        }

        // TODO: should we just write the sourcemaps to disk?
        if (file.source_map_index != std.math.maxInt(u32)) {
            try writeSourcemapToDisk(allocator, &file, bundled_outputs, &source_maps);
        }
    }
    // Write the runtime file to disk if there are any client chunks
    {
        const runtime_file_index = maybe_runtime_file_index orelse {
            bun.Output.panic("Runtime file not found. This is an unexpected bug in Bun. Please file a bug report on GitHub.", .{});
        };
        const any_client_chunks = any_client_chunks: {
            for (bundled_outputs) |file| {
                if (file.side) |s| {
                    if (s == .client and !bun.strings.eqlComptime(file.src_path.text, "bun-framework-react/client.tsx")) {
                        break :any_client_chunks true;
                    }
                }
            }
            break :any_client_chunks false;
        };
        if (any_client_chunks) {
            const runtime_file: *const OutputFile = &bundled_outputs[runtime_file_index];
            _ = runtime_file.writeToDisk(vm.io, root_dir, ".") catch |err| {
                bun.handleErrorReturnTrace(err, @errorReturnTrace());
                Output.err(err, "Failed to write {f} to output directory", .{bun.fmt.quote(runtime_file.dest_path)});
            };
        }
    }

    const per_thread_options: PerThread.Options = .{
        .input_files = entry_points.files.keys(),
        .bundled_outputs = bundled_outputs,
        .output_indexes = output_indexes,
        .module_keys = module_keys,
        .module_map = output_module_map,
        .source_maps = source_maps,
    };

    pt.* = try PerThread.init(vm, per_thread_options);
    pt.attach();

    const router_type_data = try allocator.alloc(BakeProductionRouterTypeData, router.types.len);
    var initialized_router_types: usize = 0;
    defer {
        for (router_type_data[0..initialized_router_types]) |*data| data.deinit();
        allocator.free(router_type_data);
    }
    const needs_get_params = router.dynamic_routes.count() > 0;
    for (router.types, 0..) |router_type, i| {
        var client_entry_url: ?bun.bindgen.DOMString = if (router_type.client_file.unwrap()) |client_file|
            try bun.bindgen.DOMString.fromBunString(try bun.String.createFormat("{s}{s}", .{
                public_path,
                pt.outputFile(client_file).dest_path,
            }))
        else
            null;
        errdefer if (client_entry_url) |*url| url.deinit();

        const server_entry_point = try pt.loadBundledModule(router_type.server_file);
        var prerender = (try bakeGetCallableExport(global, server_entry_point, .prerender)) orelse {
            Output.errGeneric("Framework does not support static site generation", .{});
            const relative_path = bun.handleOom(std.fs.path.relative(
                bun.default_allocator,
                cwd,
                null,
                cwd,
                entry_points.files.keys()[router_type.server_file.get()].absPath(),
            ));
            defer bun.default_allocator.free(relative_path);
            Output.note("The file {f} is missing the \"prerender\" export, which defines how to generate static files.", .{
                bun.fmt.quote(relative_path),
            });
            bun.Global.crash();
        };
        errdefer prerender.deinit();

        var get_params: ?BakeProductionCallable = if (needs_get_params)
            (try bakeGetCallableExport(global, server_entry_point, .get_params)) orelse {
                Output.errGeneric("Framework does not support static site generation", .{});
                const relative_path = bun.handleOom(std.fs.path.relative(
                    bun.default_allocator,
                    cwd,
                    null,
                    cwd,
                    entry_points.files.keys()[router_type.server_file.get()].absPath(),
                ));
                defer bun.default_allocator.free(relative_path);
                Output.note("The file {f} is missing the \"getParams\" export, which defines how to generate static files.", .{
                    bun.fmt.quote(relative_path),
                });
                bun.Global.crash();
            }
        else
            null;
        errdefer if (get_params) |*callback| callback.deinit();

        router_type_data[i] = .{
            .prerender = prerender.take(),
            .get_params = if (get_params) |*callback| callback.take() else null,
            .client_entry_url = if (client_entry_url) |*url| url.take() else null,
        };
        initialized_router_types += 1;
    }

    var navigatable_routes = std.array_list.Managed(FrameworkRouter.Route.Index).init(allocator);
    defer navigatable_routes.deinit();
    for (router.routes.items, 0..) |route, i| {
        _ = route.file_page.unwrap() orelse continue;
        try navigatable_routes.append(FrameworkRouter.Route.Index.init(@intCast(i)));
    }

    const style_urls = try allocator.alloc(bun.bindgen.DOMString, css_chunks_count);
    var initialized_style_urls: usize = 0;
    defer {
        for (style_urls[0..initialized_style_urls]) |*url| url.deinit();
        allocator.free(style_urls);
    }
    for (bundled_outputs[css_chunks_first..][0..css_chunks_count], style_urls) |output_file, *url| {
        bun.assert(output_file.dest_path[0] != '.');
        bun.assert(output_file.loader.isCSS());
        url.* = try bun.bindgen.DOMString.fromBunString(try bun.String.createFormat("{s}{s}", .{ public_path, output_file.dest_path }));
        initialized_style_urls += 1;
    }

    const route_data = try allocator.alloc(BakeProductionRouteData, navigatable_routes.items.len);
    var initialized_routes: usize = 0;
    defer {
        for (route_data[0..initialized_routes]) |*data| data.deinit(allocator);
        allocator.free(route_data);
    }
    var params_buf: std.ArrayList([]const u8) = .empty;
    defer params_buf.deinit(ctx.allocator);
    for (navigatable_routes.items, 0..) |route_index, nav_index| {
        defer params_buf.clearRetainingCapacity();

        var pattern = bake.PatternBuffer.empty;

        const route = router.routePtr(route_index);
        const main_file_route_index = route.file_page.unwrap().?;
        const main_file = pt.outputFile(main_file_route_index);

        // Count how many JS+CSS files associated with this route and prepare `pattern`
        pattern.prependPart(route.part);
        switch (route.part) {
            .param => {
                params_buf.append(ctx.allocator, route.part.param) catch unreachable;
            },
            .catch_all => {
                params_buf.append(ctx.allocator, route.part.catch_all) catch unreachable;
            },
            .catch_all_optional => {
                return global.throw("catch-all routes are not supported in static site generation", .{});
            },
            else => {},
        }
        var file_count: usize = 1;
        var style_count: usize = main_file.referenced_css_chunks.len;
        if (route.file_layout.unwrap()) |file| {
            style_count += pt.outputFile(file).referenced_css_chunks.len;
            file_count += 1;
        }
        var next: ?FrameworkRouter.Route.Index = route.parent.unwrap();
        while (next) |parent_index| {
            const parent = router.routePtr(parent_index);
            pattern.prependPart(parent.part);
            switch (parent.part) {
                .param => {
                    params_buf.append(ctx.allocator, parent.part.param) catch unreachable;
                },
                .catch_all => {
                    params_buf.append(ctx.allocator, parent.part.catch_all) catch unreachable;
                },
                .catch_all_optional => {
                    return global.throw("catch-all routes are not supported in static site generation", .{});
                },
                else => {},
            }
            if (parent.file_layout.unwrap()) |file| {
                style_count += pt.outputFile(file).referenced_css_chunks.len;
                file_count += 1;
            }
            next = parent.parent.unwrap();
        }

        const files = try allocator.alloc(u32, file_count);
        errdefer allocator.free(files);
        const style_indexes = try allocator.alloc(u32, style_count);
        errdefer allocator.free(style_indexes);

        next = route.parent.unwrap();
        file_count = 1;
        style_count = 0;
        files[0] = pt.preloadBundledModule(main_file_route_index);
        for (main_file.referenced_css_chunks) |ref| {
            style_indexes[style_count] = @intCast(ref.get() - css_chunks_first);
            style_count += 1;
        }
        if (route.file_layout.unwrap()) |file| {
            files[file_count] = pt.preloadBundledModule(file);
            for (pt.outputFile(file).referenced_css_chunks) |ref| {
                style_indexes[style_count] = @intCast(ref.get() - css_chunks_first);
                style_count += 1;
            }
            file_count += 1;
        }

        while (next) |parent_index| {
            const parent = router.routePtr(parent_index);
            if (parent.file_layout.unwrap()) |file| {
                files[file_count] = pt.preloadBundledModule(file);
                for (pt.outputFile(file).referenced_css_chunks) |ref| {
                    style_indexes[style_count] = @intCast(ref.get() - css_chunks_first);
                    style_count += 1;
                }
                file_count += 1;
            }
            next = parent.parent.unwrap();
        }

        var pattern_string = try bun.bindgen.DOMString.fromUTF8(pattern.slice());
        errdefer pattern_string.deinit();

        const relative_src_path = bun.handleOom(std.fs.path.relative(
            bun.default_allocator,
            cwd,
            null,
            cwd,
            pt.inputFile(main_file_route_index).absPath(),
        ));
        defer bun.default_allocator.free(relative_src_path);
        var source_file = try bun.bindgen.DOMString.fromUTF8(relative_src_path);
        errdefer source_file.deinit();

        var parameters: ?[]bun.bindgen.DOMString = null;
        if (params_buf.items.len != 0) {
            const values = try allocator.alloc(bun.bindgen.DOMString, params_buf.items.len);
            var initialized_parameters: usize = 0;
            errdefer {
                for (values[0..initialized_parameters]) |*value| value.deinit();
                allocator.free(values);
            }
            for (0..params_buf.items.len) |i| {
                values[i] = try bun.bindgen.DOMString.fromUTF8(params_buf.items[params_buf.items.len - i - 1]);
                initialized_parameters += 1;
            }
            parameters = values;
        }

        route_data[nav_index] = .{
            .pattern = pattern_string.take(),
            .files = files,
            .router_type = route.type.get(),
            .no_client = main_file.bake_extra.fully_static,
            .source_file = source_file.take(),
            .parameters = parameters,
            .style_indexes = style_indexes,
        };
        initialized_routes += 1;
    }

    const server_files = try allocator.alloc(BakeProductionServerFileData, pt.loaded_files.count());
    var initialized_server_files: usize = 0;
    defer {
        for (server_files[0..initialized_server_files]) |*file| file.specifier.deinit();
        allocator.free(server_files);
    }
    var loaded_file_iterator = pt.loaded_files.iterator(.{ .kind = .set });
    while (loaded_file_iterator.next()) |index| {
        server_files[initialized_server_files] = .{
            .index = @intCast(index),
            .specifier = try bun.bindgen.DOMString.fromBunString(pt.module_keys[index].clone()),
        };
        initialized_server_files += 1;
    }

    var bound_out_base = try bun.bindgen.DOMString.fromUTF8(root_dir_path);
    defer bound_out_base.deinit();
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    const operation = scope.engine(BakeRenderRoutesForProdStaticSchema);
    const RenderArgs = @TypeOf(operation).Args;
    var input_arena = std.heap.ArenaAllocator.init(allocator);
    defer input_arena.deinit();
    const inputs = input_arena.allocator();
    const ServerFile = std.meta.Elem(@FieldType(RenderArgs, "serverFiles"));
    const server_file_inputs = try inputs.alloc(ServerFile, server_files.len);
    for (server_files, server_file_inputs) |*file, *input| {
        input.* = .{ .index = file.index, .specifier = file.specifier.operand() };
    }
    const StyleURL = std.meta.Elem(@FieldType(RenderArgs, "styleURLs"));
    const style_url_inputs = try inputs.alloc(StyleURL, style_urls.len);
    for (style_urls, style_url_inputs) |*url, *input| input.* = url.operand();
    const router_type_inputs = try inputs.alloc(BakeProductionRouterTypeInput, router_type_data.len);
    for (router_type_data, router_type_inputs) |*data, *input| {
        input.* = .{
            .prerender = data.prerender.operand(&scope),
            .getParams = if (data.get_params) |*callback| callback.operand(&scope) else null,
            .clientEntryURL = if (data.client_entry_url) |*url| url.operand() else null,
        };
    }
    const route_inputs = try inputs.alloc(BakeProductionRouteInput, route_data.len);
    for (route_data, route_inputs) |*data, *input| {
        input.* = .{
            .pattern = data.pattern.operand(),
            .files = data.files,
            .routerType = data.router_type,
            .noClient = data.no_client,
            .sourceFile = data.source_file.operand(),
            .parameters = if (data.parameters) |parameters| parameters_input: {
                const Parameter = std.meta.Elem(@typeInfo(@FieldType(BakeProductionRouteInput, "parameters")).optional.child);
                const names = try inputs.alloc(Parameter, parameters.len);
                for (parameters, names) |*parameter, *name| name.* = parameter.operand();
                break :parameters_input names;
            } else null,
            .styleIndexes = data.style_indexes,
        };
    }
    const result = try operation.call(.{
        .outBase = bound_out_base.operand(),
        .serverFileCount = @intCast(pt.module_keys.len),
        .serverFiles = server_file_inputs,
        .routerTypes = router_type_inputs,
        .styleURLs = style_url_inputs,
        .routes = route_inputs,
    });
    var render_promise_value = try result.toOwned();
    defer render_promise_value.deinit();
    try awaitBuildPromise(global, &render_promise_value);
    Output.prettyln("done", .{});
    Output.flush();
    vm.waitForTasks();
}

fn loadModule(global: *jsc.JSGlobalObject, key: *const bun.String) bun.JSError!void {
    var module_name = try bun.bindgen.DOMString.fromBunString(key.dupeRef());
    defer module_name.deinit();
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    const result = try scope.engineIn("ModuleLoader", "loadAndEvaluateModule").call(.{ .moduleName = module_name.operand() });
    var promise = try result.toOwned();
    defer promise.deinit();
    try awaitBuildPromise(global, &promise);
}

fn awaitBuildPromise(global: *jsc.JSGlobalObject, promise: anytype) bun.JSError!void {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    var rejection = try scope.waitForPromiseRejection(promise.operand(&scope).asPromise());
    defer if (rejection) |*value| value.deinit();
    try global.bunVM().drainMicrotasks();
    if (rejection) |*value| return value.throwException(&scope);
}

fn bakeGetDefaultExportFromModule(global: *jsc.JSGlobalObject, module_name: *const bun.String) bun.JSError!bun.bindgen.EngineRoot {
    var bound_module_name = try bun.bindgen.DOMString.fromBunString(module_name.dupeRef());
    defer bound_module_name.deinit();
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    const result = try scope.engine(BakeGetDefaultExportFromModuleSchema).call(.{ .moduleName = bound_module_name.operand() });
    return result.toRoot();
}

fn bakeGetCallableExport(
    global: *jsc.JSGlobalObject,
    module_name: *const bun.String,
    kind: BakeProductionCallableExport,
) bun.JSError!?BakeProductionCallable {
    var bound_module_name = try bun.bindgen.DOMString.fromBunString(module_name.dupeRef());
    defer bound_module_name.deinit();
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    const result = (try scope.engine(BakeGetCallableExportSchema).call(.{
        .moduleName = bound_module_name.operand(),
        .kind = kind,
    })) orelse return null;
    return try result.toOwned();
}

fn bindToWindowsPath(
    args: bun.bindgen.Args(BakeToWindowsPathSchema),
) bun.OOM!bun.bindgen.Return(BakeToWindowsPathSchema) {
    if (comptime bun.Environment.isPosix) {
        @panic("This code should not be called on POSIX systems.");
    }
    var sfa_buffer: [1024]u8 = undefined;
    var sfa: std.heap.BufferFirstAllocator = .init(&sfa_buffer, bun.default_allocator);
    const alloc = sfa.allocator();
    const input_utf8 = try args.input.toUTF8(alloc);
    defer input_utf8.deinit();
    const input_slice = input_utf8.slice();
    const output = bun.w_path_buffer_pool.get();
    defer bun.w_path_buffer_pool.put(output);
    const output_slice = bun.strings.toWPathNormalizeAutoExtend(output.*[0..], input_slice);
    return bun.bindgen.DOMString.fromUTF16(output_slice);
}

fn bindProdResolve(
    context: bun.bindgen.CallContext(BakeProdResolveSchema),
    args: bun.bindgen.Args(BakeProdResolveSchema),
) bun.bindgen.CallError(BakeProdResolveSchema)!bun.bindgen.Return(BakeProdResolveSchema) {
    var sfa_buffer: [2]bun.PathBuffer = undefined;
    var sfa: std.heap.BufferFirstAllocator = .init(@ptrCast(&sfa_buffer), bun.default_allocator);
    const alloc = sfa.allocator();

    const specifier = try args.specifier.toUTF8(alloc);
    defer specifier.deinit();

    if (jsc.ModuleLoader.HardcodedModule.Alias.get(specifier.slice(), .bun, .{})) |alias| {
        return try bun.bindgen.DOMString.fromBunString(bun.String.cloneLatin1(alias.path));
    }

    const referrer = try args.referrer.toUTF8(alloc);
    defer referrer.deinit();

    if (bun.resolver.isPackagePath(specifier.slice())) {
        const message = try bun.String.createFormat("Non-relative import {f} from {f} are not allowed in production assets. This is a bug in Bun's bundler", .{
            bun.fmt.quote(specifier.slice()),
            bun.fmt.quote(referrer.slice()),
        });
        return context.fail(.package_import_not_allowed, try bun.bindgen.DOMString.fromBunString(message));
    }

    if (Environment.allow_assert)
        bun.assert(bun.strings.hasPrefix(referrer.slice(), "bake:"));

    const resolved = std.fs.path.resolvePosix(alloc, &.{
        std.fs.path.dirnamePosix(referrer.slice()[5..]) orelse "/",
        specifier.slice(),
    }) catch return error.OutOfMemory;
    defer alloc.free(resolved);
    return try bun.bindgen.DOMString.fromBunString(try bun.String.createFormat("bake:{s}", .{resolved}));
}

const ProductionRouterContext = struct {
    entry_points: *EntryPointMap,
    route_styles: []const bake.FrameworkRouterEngine.Style,

    pub fn getFileIdForRouter(context: *ProductionRouterContext, absolute_path: []const u8, route: FrameworkRouter.Route.Index, kind: FrameworkRouter.Route.FileKind) !OpaqueFileId {
        return context.entry_points.getFileIdForRouter(absolute_path, route, kind);
    }

    pub fn onRouterCollisionError(context: *ProductionRouterContext, relative_path: []const u8, other_id: OpaqueFileId, kind: FrameworkRouter.Route.FileKind) bun.OOM!void {
        return context.entry_points.onRouterCollisionError(relative_path, other_id, kind);
    }

    pub fn onRouterSyntaxError(context: *ProductionRouterContext, relative_path: []const u8, route_log: FrameworkRouter.TinyLog) bun.OOM!void {
        return context.entry_points.onRouterSyntaxError(relative_path, route_log);
    }

    pub fn parseCustomRoute(
        context: *ProductionRouterContext,
        style_index: u8,
        file_path: []const u8,
        route_log: *FrameworkRouter.TinyLog,
        allocator: std.mem.Allocator,
    ) bake.FrameworkRouterEngine.ParseError!?FrameworkRouter.ParsedPattern {
        return context.route_styles[style_index].parseCustom(file_path, route_log, allocator);
    }
};

const BakeProductionRouterTypeData = struct {
    prerender: BakeProductionCallable,
    get_params: ?BakeProductionCallable,
    client_entry_url: ?bun.bindgen.DOMString,

    fn deinit(data: *@This()) void {
        data.prerender.deinit();
        if (data.get_params) |*callback| callback.deinit();
        if (data.client_entry_url) |*url| url.deinit();
    }
};

const BakeProductionRouteData = struct {
    pattern: bun.bindgen.DOMString,
    files: []u32,
    router_type: u8,
    no_client: bool,
    source_file: bun.bindgen.DOMString,
    parameters: ?[]bun.bindgen.DOMString,
    style_indexes: []u32,

    fn deinit(data: *@This(), allocator: std.mem.Allocator) void {
        data.pattern.deinit();
        allocator.free(data.files);
        data.source_file.deinit();
        if (data.parameters) |parameters| {
            for (parameters) |*parameter| parameter.deinit();
            allocator.free(parameters);
        }
        allocator.free(data.style_indexes);
    }
};

const BakeProductionServerFileData = struct {
    index: u32,
    specifier: bun.bindgen.DOMString,
};

const BakeProductionRenderArgs = bun.bindgen.Args(BakeRenderRoutesForProdStaticSchema);
const BakeProductionRouterTypeInput = std.meta.Elem(@FieldType(BakeProductionRenderArgs, "routerTypes"));
const BakeProductionRouteInput = std.meta.Elem(@FieldType(BakeProductionRenderArgs, "routes"));

pub const PerThread = struct {
    // Shared Data
    input_files: []const EntryPointMap.InputFile,
    bundled_outputs: []const OutputFile,
    /// Indexed by entry point index (OpaqueFileId)
    output_indexes: []const OutputFile.Index,
    /// Indexed by entry point index (OpaqueFileId)
    module_keys: []const bun.String,
    /// Unordered
    module_map: bun.StringArrayHashMap(OutputFile.Index),
    source_maps: bun.StringArrayHashMap(OutputFile.Index),

    // Thread-local
    vm: *jsc.VirtualMachine,
    /// Indexed by entry point index (OpaqueFileId)
    loaded_files: std.bit_set.Dynamic,

    /// Sent to other threads for rendering
    pub const Options = struct {
        input_files: []const EntryPointMap.InputFile,
        bundled_outputs: []const OutputFile,
        /// Indexed by entry point index (OpaqueFileId)
        output_indexes: []const OutputFile.Index,
        /// Indexed by entry point index (OpaqueFileId)
        module_keys: []const bun.String,
        /// Unordered
        module_map: bun.StringArrayHashMap(OutputFile.Index),
        source_maps: bun.StringArrayHashMap(OutputFile.Index),
    };

    /// After initializing, call `attach`
    pub fn init(vm: *VirtualMachine, opts: Options) !PerThread {
        var loaded_files = try std.bit_set.Dynamic.initEmpty(vm.allocator, opts.output_indexes.len);
        errdefer loaded_files.deinit(vm.allocator);

        return .{
            .input_files = opts.input_files,
            .bundled_outputs = opts.bundled_outputs,
            .output_indexes = opts.output_indexes,
            .module_keys = opts.module_keys,
            .module_map = opts.module_map,
            .vm = vm,
            .loaded_files = loaded_files,
            .source_maps = opts.source_maps,
        };
    }

    pub fn attach(pt: *PerThread) void {
        bun.bindgen.Engine(BakeGlobalObjectSetPerThreadDataShim).call(pt.vm.global, .{ .perThreadData = pt });
    }

    pub fn deinit(pt: *PerThread) void {
        bun.bindgen.Engine(BakeGlobalObjectSetPerThreadDataShim).call(pt.vm.global, .{ .perThreadData = null });
        pt.loaded_files.deinit(pt.vm.allocator);
    }

    pub fn outputIndex(s: PerThread, id: OpaqueFileId) OutputFile.Index {
        return s.output_indexes[id.get()];
    }

    pub fn inputFile(s: PerThread, id: OpaqueFileId) EntryPointMap.InputFile {
        return s.input_files[id.get()];
    }

    pub fn outputFile(s: PerThread, id: OpaqueFileId) *const OutputFile {
        return &s.bundled_outputs[s.outputIndex(id).get()];
    }

    // Must be run at the top of the event loop
    pub fn loadBundledModule(pt: *PerThread, id: OpaqueFileId) !*const bun.String {
        const module_key = &pt.module_keys[id.get()];
        try loadModule(pt.vm.global, module_key);
        return module_key;
    }

    pub fn preloadBundledModule(pt: *PerThread, id: OpaqueFileId) u32 {
        pt.loaded_files.set(id.get());
        return @intCast(id.get());
    }
};

/// Given a key, returns the source code to load.
fn bindProdLoad(
    args: bun.bindgen.Args(BakeProdLoadSchema),
) bun.OOM!bun.bindgen.Return(BakeProdLoadSchema) {
    const pt = args.perThreadData;
    var sfa_buffer: [4096]u8 = undefined;
    var sfa: std.heap.BufferFirstAllocator = .init(&sfa_buffer, bun.default_allocator);
    const allocator = sfa.allocator();
    const utf8 = try args.key.toUTF8(allocator);
    defer utf8.deinit();
    log("BakeProdLoad: {s}\n", .{utf8.slice()});
    if (pt.module_map.get(utf8.slice())) |value| {
        log("  found in module_map: {s}\n", .{utf8.slice()});
        return try bun.bindgen.DOMString.fromBunString(pt.bundled_outputs[value.get()].value.toBunString());
    }
    return null;
}

const std = @import("std");

const bun = @import("bun");
const BakeAppOptionsBindings = bun.bindgen.Module("BakeAppOptions");
const BakeProductionBindings = bun.bindgen.Module("BakeProduction");
const BakeAppOptionsCreateFromModuleDefaultSchema = BakeAppOptionsBindings.engineShim("createFromModuleDefault");
const BakeToWindowsPathSchema = BakeProductionBindings.nativeExport("bakeToWindowsPath");
const BakeProdResolveSchema = BakeProductionBindings.nativeExport("bakeProdResolve");
const BakeProdLoadSchema = BakeProductionBindings.nativeExport("bakeProdLoad");
const BakeGetDefaultExportFromModuleSchema = BakeProductionBindings.engineShim("bakeGetDefaultExportFromModule");
const BakeGetCallableExportSchema = BakeProductionBindings.engineShim("getCallableExport");
const BakeRenderRoutesForProdStaticSchema = BakeProductionBindings.engineShim("renderRoutesForProdStatic");
const BakeProductionCallableExport = @FieldType(bun.bindgen.Args(BakeGetCallableExportSchema), "kind");
const BakeProductionCallable = bun.bindgen.OwnedBrandedValue(BakeGetCallableExportSchema.ReturnType.child);
const BakeToWindowsPathBinding = bun.bindgen.Fn(BakeToWindowsPathSchema, bindToWindowsPath);
const BakeProdResolveBinding = bun.bindgen.Fn(BakeProdResolveSchema, bindProdResolve);
const BakeProdLoadBinding = bun.bindgen.Fn(BakeProdLoadSchema, bindProdLoad);

comptime {
    _ = BakeToWindowsPathBinding;
    _ = BakeProdResolveBinding;
    _ = BakeProdLoadBinding;
}

const Environment = bun.Environment;
const Output = bun.Output;
const bake = bun.bake;
const OutputFile = bun.options.OutputFile;
const BundlerEngine = @import("../bundler/BundlerEngine.zig");

const EntryPointMap = @import("./ProductionEntryPoints.zig");
const FrameworkRouter = @import("./FrameworkRouter.zig");
const OpaqueFileId = FrameworkRouter.OpaqueFileId;

const jsc = bun.jsc;
const VirtualMachine = jsc.VirtualMachine;
const BakeGlobalObjectSetPerThreadDataShim = BakeProductionBindings.engineShim("bakeGlobalObjectSetPerThreadData");
