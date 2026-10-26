pub const jsc = @import("./jsc/jsc.zig");
pub const webcore = @import("./runtime/WebCoreEngine.zig");
pub const api = @import("./runtime/RuntimeApiEngine.zig");

pub fn applyStandaloneRuntimeFlags(b: *bun.Transpiler, graph: *const bun.StandaloneModuleGraph) void {
    b.options.env.disable_default_env_files = graph.flags.disable_default_env_files;
    b.options.env.behavior = if (graph.flags.disable_default_env_files)
        .disable
    else
        .load_all_without_inlining;

    b.resolver.opts.load_tsconfig_json = !graph.flags.disable_autoload_tsconfig;
    b.resolver.opts.load_package_json = !graph.flags.disable_autoload_package_json;
}

pub const Run = struct {
    ctx: Command.Context,
    vm: *VirtualMachine,
    entry_path: string,
    arena: Arena,
    is_html_entrypoint: bool = false,

    var run: Run = undefined;

    pub fn bootStandalone(ctx: Command.Context, entry_path: string, graph_ptr: *bun.StandaloneModuleGraph) !void {
        bun.jsc.initialize(false);
        bun.analytics.Features.standalone_executable += 1;

        js_ast.Expr.Data.Store.create();
        js_ast.Stmt.Data.Store.create();
        const arena = Arena.init();

        // Load bunfig.toml unless disabled by compile flags
        // Note: config loading with execArgv is handled earlier in cli.zig via loadConfig
        if (!ctx.debug.loaded_bunfig and !graph_ptr.flags.disable_autoload_bunfig) {
            try bun.cli.Arguments.loadConfigPath(ctx.allocator, true, "bunfig.toml", ctx, .RunCommand);
        }

        run = .{
            .vm = try VirtualMachine.initWithModuleGraph(.{
                .allocator = arena.allocator(),
                .io = ctx.io,
                .pinned_threads = bun.cli.Cli.pinnedThreads(),
                .log = ctx.log,
                .args = ctx.args,
                .graph = graph_ptr,
                .is_main_thread = true,
                .smol = ctx.runtime_options.smol,
                .debugger = ctx.runtime_options.debugger,
                .dns_result_order = DNSResolver.Order.fromStringOrDie(ctx.runtime_options.dns_result_order),
            }),
            .arena = arena,
            .ctx = ctx,
            .entry_path = entry_path,
        };

        var vm = run.vm;
        var b = &vm.transpiler;
        vm.preload = ctx.preloads;
        vm.argv = ctx.passthrough;
        vm.arena = &run.arena;
        vm.allocator = vm.arena.allocator();

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

        b.options.serve_plugins = ctx.args.serve_plugins;
        b.options.bunfig_path = ctx.args.bunfig_path;

        // b.options.minify_syntax = ctx.bundler_options.minify_syntax;

        switch (ctx.debug.macros) {
            .disable => {
                b.options.no_macros = true;
            },
            .map => |macros| {
                b.options.macro_remap = macros;
            },
            .unspecified => {},
        }

        applyStandaloneRuntimeFlags(b, graph_ptr);

        b.configureDefines() catch {
            failWithBuildError(vm);
        };

        AsyncHTTP.loadEnv(vm.allocator, vm.log, b.env);

        vm.loadExtraEnvAndSourceCodePrinter();
        vm.is_main_thread = true;
        jsc.VirtualMachine.is_main_thread_vm = true;

        bun.http.experimental_http2_client_from_cli = ctx.runtime_options.experimental_http2_fetch;
        bun.http.experimental_http3_client_from_cli = ctx.runtime_options.experimental_http3_fetch;
        doPreconnect(ctx.io, ctx.transpiler_capabilities.javascript_semantics, ctx.runtime_options.preconnect);

        const api_lock = vm.global.vm().getAPILock();
        defer api_lock.release();
        run.start();
    }

    fn doPreconnect(io: std.Io, javascript_semantics: JavaScriptSemantics, preconnect: []const string) void {
        if (preconnect.len == 0) return;
        bun.HTTPThread.init(io, &.{});

        for (preconnect) |url_str| {
            const url = bun.URL.parse(url_str);

            if (!url.isHTTP() and !url.isHTTPS()) {
                Output.errGeneric("preconnect URL must be HTTP or HTTPS: {f}", .{bun.fmt.quote(url_str)});
                Global.exit(1);
            }

            if (url.hostname.len == 0) {
                Output.errGeneric("preconnect URL must have a hostname: {f}", .{bun.fmt.quote(url_str)});
                Global.exit(1);
            }

            if (!url.hasValidPort()) {
                Output.errGeneric("preconnect URL must have a valid port: {f}", .{bun.fmt.quote(url_str)});
                Global.exit(1);
            }

            AsyncHTTP.preconnect(url, false, javascript_semantics);
        }
    }

    fn bootBunShell(ctx: Command.Context, entry_path: []const u8) !bun.shell.ExitCode {
        @branchHint(.cold);

        const env_map = try ctx.allocator.create(bun.DotEnv.Map);
        env_map.* = bun.DotEnv.Map.init(ctx.allocator);
        const env = try ctx.allocator.create(bun.DotEnv.Loader);
        env.* = bun.DotEnv.Loader.init(env_map, ctx.allocator);
        env.quiet = !ctx.log.level.atLeast(.info);
        try env.loadCurrentDirectory(ctx.io, ctx.args.env_files, ctx.args.disable_default_env_files);
        const mini = try jsc.MiniEventLoop.initGlobal(ctx.io, env, null);
        mini.top_level_dir = ctx.args.absolute_working_dir orelse "";
        return bun.shell.Interpreter.initAndRunFromFile(ctx, mini, entry_path);
    }

    pub fn boot(ctx: Command.Context, entry_path: string, loader: ?bun.options.Loader) !void {
        if (!ctx.debug.loaded_bunfig) {
            try bun.cli.Arguments.loadConfigPath(ctx.allocator, true, "bunfig.toml", ctx, .RunCommand);
        }

        // The shell does not need to initialize JSC.
        // JSC initialization costs 1-3ms. We skip this if we know it's a shell script.
        if (strings.endsWithComptime(entry_path, ".sh")) {
            const exit_code = try bootBunShell(ctx, entry_path);
            Global.exit(exit_code);
            return;
        }

        bun.jsc.initialize(ctx.runtime_options.eval.eval_and_print);

        js_ast.Expr.Data.Store.create();
        js_ast.Stmt.Data.Store.create();
        const arena = Arena.init();

        run = .{
            .vm = try VirtualMachine.init(
                .{
                    .allocator = arena.allocator(),
                    .io = ctx.io,
                    .pinned_threads = bun.cli.Cli.pinnedThreads(),
                    .log = ctx.log,
                    .args = ctx.args,
                    .store_fd = ctx.debug.hot_reload != .none,
                    .smol = ctx.runtime_options.smol,
                    .eval = ctx.runtime_options.eval.eval_and_print,
                    .debugger = ctx.runtime_options.debugger,
                    .dns_result_order = DNSResolver.Order.fromStringOrDie(ctx.runtime_options.dns_result_order),
                    .is_main_thread = true,
                },
            ),
            .arena = arena,
            .ctx = ctx,
            .entry_path = entry_path,
        };

        var vm = run.vm;
        var b = &vm.transpiler;
        vm.preload = ctx.preloads;
        vm.argv = ctx.passthrough;
        vm.arena = &run.arena;
        vm.allocator = vm.arena.allocator();

        if (ctx.runtime_options.eval.script.len > 0) {
            const script_source = try bun.default_allocator.create(logger.Source);
            script_source.* = logger.Source.initPathString(entry_path, ctx.runtime_options.eval.script);
            vm.module_loader.eval_source = script_source;

            if (ctx.runtime_options.eval.eval_and_print) {
                b.options.dead_code_elimination = false;
            }
        } else if (ctx.runtime_options.cron_title.len > 0 and ctx.runtime_options.cron_period.len > 0) {
            // Cron execution mode: wrap the entry point in a script that imports the
            // module and calls default.scheduled(controller)
            // Escape path for embedding in JS string literal (handle backslashes on Windows)
            const escaped_path = try escapeForJSString(bun.default_allocator, entry_path);
            defer bun.default_allocator.free(escaped_path);
            const escaped_period = try escapeForJSString(bun.default_allocator, ctx.runtime_options.cron_period);
            defer bun.default_allocator.free(escaped_period);
            const cron_script = try std.fmt.allocPrint(bun.default_allocator,
                \\const mod = await import("{s}");
                \\const scheduled = (mod.default || mod).scheduled;
                \\if (typeof scheduled !== "function") throw new Error("Module does not export default.scheduled()");
                \\const controller = {{ cron: "{s}", type: "scheduled", scheduledTime: Date.now() }};
                \\await scheduled(controller);
            , .{ escaped_path, escaped_period });
            // entry_path must end with /[eval] for the transpiler to use eval_source
            const trigger = bun.pathLiteral("/[eval]");
            var cwd_buf: bun.PathBuffer = undefined;
            const cwd_slice = switch (bun.sys.getcwd(&cwd_buf)) {
                .result => |cwd| cwd,
                .err => return error.SystemResources,
            };
            var eval_path_buf: [bun.MAX_PATH_BYTES + trigger.len]u8 = undefined;
            @memcpy(eval_path_buf[0..cwd_slice.len], cwd_slice);
            @memcpy(eval_path_buf[cwd_slice.len..][0..trigger.len], trigger);
            const eval_entry_path = eval_path_buf[0 .. cwd_slice.len + trigger.len];
            // Heap-allocate the path so it outlives this stack frame
            const heap_entry_path = try bun.default_allocator.dupe(u8, eval_entry_path);
            const script_source = try bun.default_allocator.create(logger.Source);
            script_source.* = logger.Source.initPathString(heap_entry_path, cron_script);
            vm.module_loader.eval_source = script_source;
            run.entry_path = heap_entry_path;
        }

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
        // b.options.minify_syntax = ctx.bundler_options.minify_syntax;

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
            failWithBuildError(vm);
        };

        AsyncHTTP.loadEnv(vm.allocator, vm.log, b.env);

        vm.loadExtraEnvAndSourceCodePrinter();
        vm.is_main_thread = true;
        jsc.VirtualMachine.is_main_thread_vm = true;

        // Allow setting a custom timezone
        if (vm.transpiler.env.get("TZ")) |tz| {
            if (tz.len > 0) {
                _ = try vm.global.setTimeZone(tz);
            }
        }

        bun.http.experimental_http2_client_from_cli = ctx.runtime_options.experimental_http2_fetch;
        bun.http.experimental_http3_client_from_cli = ctx.runtime_options.experimental_http3_fetch;
        doPreconnect(ctx.io, ctx.transpiler_capabilities.javascript_semantics, ctx.runtime_options.preconnect);

        vm.main_is_html_entrypoint = (loader orelse vm.transpiler.options.loader(std.fs.path.extension(entry_path))) == .html;

        const api_lock = vm.global.vm().getAPILock();
        defer api_lock.release();
        run.start();
    }

    pub fn start(this: *Run) void {
        var vm = this.vm;
        vm.hot_reload = this.ctx.debug.hot_reload;
        vm.useDefaultUnhandledRejectionHandler();

        // Start CPU profiler if enabled
        if (this.ctx.runtime_options.cpu_prof.enabled) {
            const cpu_prof_opts = this.ctx.runtime_options.cpu_prof;

            vm.cpu_profiler_config = CPUProfiler.CPUProfilerConfig{
                .name = cpu_prof_opts.name,
                .dir = cpu_prof_opts.dir,
                .md_format = cpu_prof_opts.md_format,
                .json_format = cpu_prof_opts.json_format,
                .interval = cpu_prof_opts.interval,
            };
            CPUProfiler.setSamplingInterval(cpu_prof_opts.interval);
            CPUProfiler.startCPUProfiler(vm.jsc_vm);
            bun.analytics.Features.cpu_profile += 1;
        }

        // Set up heap profiler config if enabled (actual profiling happens on exit)
        if (this.ctx.runtime_options.heap_prof.enabled) {
            const heap_prof_opts = this.ctx.runtime_options.heap_prof;

            vm.heap_profiler_config = HeapProfiler.HeapProfilerConfig{
                .name = heap_prof_opts.name,
                .dir = heap_prof_opts.dir,
                .text_format = heap_prof_opts.text_format,
            };
            bun.analytics.Features.heap_snapshot += 1;
        }

        this.addConditionalGlobals();
        if (this.ctx.runtime_options.redis_preconnect) {
            const global = vm.global;
            var scope: bun.bindgen.FocusedEngineScope = undefined;
            scope.init(global);
            defer scope.deinit();
            if (scope.engine(RedisDefaultClientShim).call(.{})) |client_ref| {
                client_ref.get(bun.valkey.RedisClientBinding).client.get().preconnect();
            } else |err| {
                global.reportActiveExceptionAsUnhandled(err);
            }
        }

        do_postgres_preconnect: {
            if (this.ctx.runtime_options.sql_preconnect) {
                const global = vm.global;
                bun.bindgen.Engine(SQLPreconnectShim).call(global, .{}) catch |err| {
                    global.reportActiveExceptionAsUnhandled(err);
                    break :do_postgres_preconnect;
                };
            }
        }

        switch (this.ctx.debug.hot_reload) {
            .hot => jsc.hot_reloader.HotReloader.enableHotModuleReloading(vm, this.entry_path),
            .watch => jsc.hot_reloader.WatchReloader.enableHotModuleReloading(vm, this.entry_path),
            else => {},
        }

        if (strings.eqlComptime(this.entry_path, ".") and vm.transpiler.fs.top_level_dir.len > 0) {
            this.entry_path = vm.transpiler.fs.top_level_dir;
        }

        var printed_sourcemap_warning_and_version = false;

        if (vm.loadEntryPoint(this.entry_path)) |loaded| {
            var promise = loaded;
            defer promise.deinit();
            if (vm.entryPointPromiseStatus(&promise) == .rejected) {
                const reporting_generation = vm.hot_reload_counter;
                const handled = vm.reportEntryPointRejection(&promise) catch |err| failed: {
                    vm.global.reportUncaughtExceptionFromError(err);
                    break :failed false;
                };
                {
                    var scope: bun.bindgen.FocusedEngineScope = undefined;
                    scope.init(vm.global);
                    defer scope.deinit();
                    scope.engineIn("promises", "promiseSetHandled").call(.{ .promise = promise.operand(&scope) });
                }
                vm.pending_entry_promise_reported_at = reporting_generation;
                promise.deinit();

                if (vm.hot_reload != .none or handled) {
                    vm.addMainToWatcherIfNeeded();
                    vm.eventLoop().tick();
                    vm.eventLoop().tickPossiblyForever();
                } else {
                    vm.exit_handler.exit_code = 1;
                    vm.onExit();

                    if (vm.hasReportedUnhandledRejection()) {
                        printed_sourcemap_warning_and_version = true;
                        bun.jsc.SavedSourceMap.MissingSourceMapNoteInfo.print();

                        Output.prettyErrorln(
                            "<r>\n<d>{s}<r>",
                            .{Global.unhandled_error_bun_version_string},
                        );
                    }
                    vm.globalExit();
                }
            }

            if (vm.log.msgs.items.len > 0) {
                dumpBuildError(vm);
                vm.log.reset();
            }
        } else |err| {
            if (vm.log.msgs.items.len > 0) {
                dumpBuildError(vm);
                vm.log.reset();
            } else {
                Output.prettyErrorln("Error occurred loading entry point: {s}", .{@errorName(err)});
                Output.flush();
            }
            // TODO: Do a event loop tick when we figure out how to watch the file that wasn't found
            //   under hot reload mode
            vm.exit_handler.exit_code = 1;
            vm.onExit();
            if (vm.hasReportedUnhandledRejection()) {
                printed_sourcemap_warning_and_version = true;
                bun.jsc.SavedSourceMap.MissingSourceMapNoteInfo.print();

                Output.prettyErrorln(
                    "<r>\n<d>{s}<r>",
                    .{Global.unhandled_error_bun_version_string},
                );
            }
            vm.globalExit();
        }

        // don't run the GC if we don't actually need to
        if (vm.isEventLoopAlive() or
            vm.eventLoop().tickConcurrentWithCount() > 0)
        {
            vm.global.vm().releaseWeakRefs();
            _ = vm.arena.gc();
            _ = vm.global.vm().runGC(false);
            vm.tick();
        }

        // Initial synchronous evaluation of the entrypoint is done (TLA may
        // still be pending and will resolve in the loop below); the embedded
        // source pages are off the hot path now. No-op unless this is a
        // compiled standalone binary, and skip under --watch/--hot since those
        // re-read source on every reload.
        if (!this.vm.isWatcherEnabled()) {
            bun.StandaloneModuleGraph.hintSourcePagesDontNeed();
        }

        {
            if (this.vm.isWatcherEnabled()) {
                vm.reportExceptionInHotReloadedModuleIfNeeded();

                while (true) {
                    while (vm.isEventLoopAlive()) {
                        vm.tick();

                        // Report exceptions in hot-reloaded modules
                        vm.reportExceptionInHotReloadedModuleIfNeeded();

                        vm.eventLoop().autoTickActive();
                    }

                    vm.onBeforeExit();

                    vm.reportExceptionInHotReloadedModuleIfNeeded();

                    vm.eventLoop().tickPossiblyForever();
                }
            } else {
                while (vm.isEventLoopAlive()) {
                    vm.tick();
                    vm.eventLoop().autoTickActive();
                }

                if (this.ctx.runtime_options.eval.eval_and_print) {
                    this.printEvalResult() catch |err| {
                        vm.global.reportUncaughtExceptionFromError(err);
                    };
                }

                vm.onBeforeExit();
            }

            if (vm.log.msgs.items.len > 0) {
                dumpBuildError(vm);
                Output.flush();
            }
        }

        vm.useDefaultUnhandledRejectionHandler();
        vm.global.handleRejectedPromises();
        vm.onExit();

        if (vm.hasReportedUnhandledRejection() and !printed_sourcemap_warning_and_version) {
            this.vm.exit_handler.exit_code = 1;

            bun.jsc.SavedSourceMap.MissingSourceMapNoteInfo.print();

            Output.prettyErrorln(
                "<r>\n<d>{s}<r>",
                .{Global.unhandled_error_bun_version_string},
            );
        }

        bun.api.napi.fixDeadCodeElimination();
        vm.globalExit();
    }

    fn printEvalResult(this: *Run) bun.JSError!void {
        const vm = this.vm;
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(vm.global);
        defer scope.deinit();
        var to_print = vm.entry_point_result.value.cloneRoot() orelse try bun.bindgen.EngineRoot.initUndefined(&scope);
        defer to_print.deinit();
        if (try scope.engine(JSValueAsPromiseShim).call(.{
            .value = to_print.operand(&scope),
        })) |promise_result| {
            var promise = try promise_result.toOwned();
            defer promise.deinit();
            switch (scope.engine(PromiseStatusShim).call(.{ .promise = promise.operand(&scope) })) {
                .pending => {
                    const reaction = bun.new(EntryPointPromiseReactionOwner, .{});
                    EntryPointPromiseReaction.attach(
                        &scope,
                        promise.operand(&scope).asPromise(),
                        reaction,
                        EntryPointResolveBinding,
                        EntryPointRejectBinding,
                    ) catch {};

                    vm.tick();
                    vm.eventLoop().autoTickActive();

                    while (vm.isEventLoopAlive()) {
                        vm.tick();
                        vm.eventLoop().autoTickActive();
                    }
                },
                else => {
                    const settled = try scope.engine(PromiseResultShim).call(.{
                        .promise = promise.operand(&scope),
                    });
                    const value = settled orelse @panic("settled entry-point promise has no result");
                    const retained = try value.toRoot();
                    to_print.deinit();
                    to_print = retained;
                },
            }
        }
        jsc.ConsoleObject.printOwnedEngineValue(vm.global, &to_print);
    }

    fn addConditionalGlobals(this: *Run) void {
        const vm = this.vm;
        const runtime_options: *const Command.RuntimeOptions = &this.ctx.runtime_options;

        if (runtime_options.eval.script.len > 0) {
            bun.bindgen.Engine(ExposeNodeModuleGlobalsShim).call(vm.global, .{}) catch unreachable;
        }
        if (runtime_options.expose_gc) {
            bun.bindgen.Engine(AddGcShim).call(vm.global, .{}) catch unreachable;
        }
    }
};

fn onResolveEntryPointResult(
    context: bun.bindgen.CallContext(EntryPointResolveSchema),
    args: bun.bindgen.Args(EntryPointResolveSchema),
) bun.JSError!void {
    const reaction = EntryPointPromiseReaction.take(args.context) orelse return;
    defer reaction.releasePromiseReactionRef();
    jsc.ConsoleObject.printLogForBinding(context, args.result);
    bun.Global.exit(jsc.VirtualMachine.get().exit_handler.exit_code);
}

fn onRejectEntryPointResult(
    context: bun.bindgen.CallContext(EntryPointRejectSchema),
    args: bun.bindgen.Args(EntryPointRejectSchema),
) bun.JSError!void {
    const reaction = EntryPointPromiseReaction.take(args.context) orelse return;
    defer reaction.releasePromiseReactionRef();
    jsc.ConsoleObject.printLogForBinding(context, args.result);
    bun.Global.exit(jsc.VirtualMachine.get().exit_handler.exit_code);
}

const EntryPointPromiseReactionOwner = struct {
    pub fn releasePromiseReactionRef(this: *@This()) void {
        bun.destroy(this);
    }
};

noinline fn dumpBuildError(vm: *jsc.VirtualMachine) void {
    @branchHint(.cold);

    Output.flush();

    const writer = Output.errorWriterBuffered();
    defer Output.flush();

    vm.log.print(writer) catch {};
}

pub noinline fn failWithBuildError(vm: *jsc.VirtualMachine) noreturn {
    @branchHint(.cold);
    dumpBuildError(vm);
    Global.exit(1);
}

const VirtualMachine = jsc.VirtualMachine;

const string = []const u8;

/// Escape a string for safe embedding in a JS double-quoted string literal.
/// Escapes backslashes, double quotes, newlines, etc.
fn escapeForJSString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var needs_escape = false;
    for (input) |c| {
        if (c == '\\' or c == '"' or c == '\n' or c == '\r' or c == '\t') {
            needs_escape = true;
            break;
        }
    }
    if (!needs_escape) return allocator.dupe(u8, input);

    var result = try std.array_list.Managed(u8).initCapacity(allocator, input.len + 16);
    for (input) |c| {
        switch (c) {
            '\\' => try result.appendSlice("\\\\"),
            '"' => try result.appendSlice("\\\""),
            '\n' => try result.appendSlice("\\n"),
            '\r' => try result.appendSlice("\\r"),
            '\t' => try result.appendSlice("\\t"),
            else => try result.append(c),
        }
    }
    return result.toOwnedSlice();
}

const CPUProfiler = @import("./jsc/BunCPUProfiler.zig");
const HeapProfiler = @import("./jsc/BunHeapProfiler.zig");
const options = @import("./bundler/options.zig");
const std = @import("std");
const JavaScriptSemantics = @import("./bun_core/JavaScriptSemantics.zig");
const Command = @import("./cli/cli.zig").Command;
const which = @import("./which/which.zig").which;

const bun = @import("bun");
const ExposeNodeModuleGlobalsBindings = bun.bindgen.Module("ExposeNodeModuleGlobalsHost");
const GarbageCollectionBindings = bun.bindgen.Module("garbage_collection");
const PromiseBindings = bun.bindgen.Module("promises");
const BunJSBindings = bun.bindgen.Module("BunJS");
const BunObjectBindings = bun.bindgen.Module("BunObject");
const AddGcShim = GarbageCollectionBindings.engineShim("addGc");
const ExposeNodeModuleGlobalsShim = ExposeNodeModuleGlobalsBindings.engineShim("exposeNodeModuleGlobals");
const JSValueAsPromiseShim = PromiseBindings.engineShim("jsValueAsPromise");
const PromiseResultShim = PromiseBindings.engineShim("promiseResult");
const PromiseStatusShim = PromiseBindings.engineShim("promiseStatus");
const SQLPreconnectShim = BunObjectBindings.engineShim("preconnectDefaultSQL");
const RedisDefaultClientShim = BunObjectBindings.engineShim("defaultRedisClient");
const EntryPointResolveSchema = BunJSBindings.function("onResolveEntryPointResult");
const EntryPointRejectSchema = BunJSBindings.function("onRejectEntryPointResult");
const EntryPointPromiseReaction = bun.bindgen.PromiseReaction(EntryPointResolveSchema.args[1].ArgumentType, EntryPointPromiseReactionOwner);
pub const EntryPointResolveBinding = bun.bindgen.Fn(EntryPointResolveSchema, onResolveEntryPointResult);
pub const EntryPointRejectBinding = bun.bindgen.Fn(EntryPointRejectSchema, onRejectEntryPointResult);

comptime {
    _ = EntryPointResolveBinding;
    _ = EntryPointRejectBinding;
}

const Global = bun.Global;
const Output = bun.Output;
const default_allocator = bun.default_allocator;
const js_ast = bun.ast;
const logger = bun.logger;
const strings = bun.strings;
const transpiler = bun.transpiler;
const Arena = bun.allocators.MimallocArena;
const AsyncHTTP = bun.http.AsyncHTTP;
const DNSResolver = bun.api.dns.Resolver;
