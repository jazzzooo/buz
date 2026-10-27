const debug = Output.scoped(.RuntimeTranspilerStore, .hidden);

const string = []const u8;

pub fn dumpSource(vm: *VirtualMachine, specifier: string, printer: anytype) void {
    dumpSourceString(vm, specifier, printer.ctx.getWritten());
}

pub fn dumpSourceString(vm: *VirtualMachine, specifier: string, written: []const u8) void {
    dumpSourceStringFailiable(vm, specifier, written) catch |e| {
        Output.debugWarn("Failed to dump source string: {}", .{e});
    };
}

pub fn dumpSourceStringFailiable(vm: *VirtualMachine, specifier: string, written: []const u8) !void {
    if (!Environment.isDebug) return;
    if (bun.feature_flag.BUN_DEBUG_NO_DUMP.get()) return;

    const BunDebugHolder = struct {
        pub var dir: ?std.Io.Dir = null;
        pub var lock: std.Io.Mutex = .init;
    };

    BunDebugHolder.lock.lockUncancelable(vm.io);
    defer BunDebugHolder.lock.unlock(vm.io);

    const dir = BunDebugHolder.dir orelse dir: {
        const base_name = switch (Environment.os) {
            else => if (comptime Environment.isAndroid) "/data/local/tmp/bun-debug-src/" else "/tmp/bun-debug-src/",
            .windows => brk: {
                const temp = bun.fs.FileSystem.RealFS.platformTempDir(vm.io);
                var win_temp_buffer: bun.PathBuffer = undefined;
                @memcpy(win_temp_buffer[0..temp.len], temp);
                const suffix = "\\bun-debug-src";
                @memcpy(win_temp_buffer[temp.len .. temp.len + suffix.len], suffix);
                win_temp_buffer[temp.len + suffix.len] = 0;
                break :brk win_temp_buffer[0 .. temp.len + suffix.len :0];
            },
        };
        const dir = try bun.MakePath.makeOpenPath(vm.io, std.Io.Dir.cwd(), base_name, .{});
        BunDebugHolder.dir = dir;
        break :dir dir;
    };

    if (std.fs.path.dirname(specifier)) |dir_path| {
        const root_len = switch (Environment.os) {
            else => "/".len,
            .windows => std.fs.path.parsePathWindows(u8, dir_path).root.len,
        };
        var parent = try bun.MakePath.makeOpenPath(vm.io, dir, dir_path[root_len..], .{});
        defer parent.close(vm.io);
        parent.writeFile(vm.io, .{
            .sub_path = std.fs.path.basename(specifier),
            .data = written,
        }) catch |e| {
            Output.debugWarn("Failed to dump source string: writeFile {}", .{e});
            return;
        };
        if (try vm.source_mappings.get(specifier)) |mappings| {
            defer mappings.deref();
            const map_path = try std.mem.concat(bun.default_allocator, u8, &.{ std.fs.path.basename(specifier), ".map" });
            defer bun.default_allocator.free(map_path);
            const file = try parent.createFile(vm.io, map_path, .{});
            defer file.close(vm.io);

            const source_file = parent.readFileAlloc(
                vm.io,
                specifier,
                bun.default_allocator,
                .unlimited,
            ) catch "";
            defer bun.default_allocator.free(source_file);

            var bufw_buffer: [4096]u8 = undefined;
            var bufw = file.writerStreaming(vm.io, &bufw_buffer);
            const w = &bufw.interface;
            try w.print(
                \\{{
                \\  "version": 3,
                \\  "file": {f},
                \\  "sourceRoot": "",
                \\  "sources": [{f}],
                \\  "sourcesContent": [{f}],
                \\  "names": [],
                \\  "mappings": "
            , .{
                bun.fmt.formatJSONStringUTF8(std.fs.path.basename(specifier), .{}),
                bun.fmt.formatJSONStringUTF8(specifier, .{}),
                bun.fmt.formatJSONStringUTF8(source_file, .{}),
            });
            try mappings.writeVLQs(w);
            try w.writeAll("\"\n}");
            try w.flush();
        }
    } else {
        dir.writeFile(vm.io, .{
            .sub_path = std.fs.path.basename(specifier),
            .data = written,
        }) catch return;
    }
}

pub fn setBreakPointOnFirstLine() bool {
    const s = struct {
        var set_break_point: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
    };
    return s.set_break_point.swap(false, .seq_cst);
}

pub const RuntimeTranspilerStore = struct {
    generation_number: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    store: TranspilerJob.Store,
    enabled: bool = true,

    pub fn init() RuntimeTranspilerStore {
        return RuntimeTranspilerStore{
            .store = TranspilerJob.Store.init(bun.typedAllocator(TranspilerJob)),
        };
    }

    pub fn transpile(
        this: *RuntimeTranspilerStore,
        vm: *VirtualMachine,
        globalObject: *JSGlobalObject,
        input_specifier: bun.String,
        path: Fs.Path,
        referrer: bun.String,
        loader: bun.options.Loader,
        package_json: ?*const PackageJSON,
    ) bun.JSError!jsc.ModuleLoader.OwnedModulePromise {
        errdefer input_specifier.deref();
        errdefer referrer.deref();
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(globalObject);
        defer scope.deinit();
        const created = try scope.engineIn("promises", "promiseCreate").call(.{});
        var promise = try created.toOwned();
        errdefer promise.deinit();
        var retained: bun.bindgen.PromiseRoot.Optional = .empty;
        errdefer retained.deinit();
        try retained.set(created.operand(&scope).asPromise());
        const owned_path = Fs.Path.init(try bun.default_allocator.dupe(u8, path.text));
        errdefer bun.default_allocator.free(owned_path.text);
        const job = try this.store.tryGet();

        // NOTE: DirInfo should already be cached since module loading happens
        // after module resolution, so this should be cheap
        var resolved_source = ResolvedSource{};
        if (package_json) |pkg| {
            switch (pkg.module_type) {
                .cjs => {
                    resolved_source.tag = .{ .source = .package_json_type_commonjs };
                    resolved_source.is_commonjs_module = true;
                },
                .esm => resolved_source.tag = .{ .source = .package_json_type_module },
                .unknown => {},
            }
        }

        job.* = TranspilerJob{
            .non_threadsafe_input_specifier = input_specifier,
            .path = owned_path,
            .globalThis = globalObject,
            .non_threadsafe_referrer = referrer,
            .vm = vm,
            .event_loop = vm.eventLoop(),
            .log = logger.Log.init(bun.default_allocator),
            .loader = loader,
            .promise = retained,
            .poll_ref = .{},
            .fetcher = TranspilerJob.Fetcher{
                .file = {},
            },
            .resolved_source = resolved_source,
            .generation_number = this.generation_number.load(.seq_cst),
        };
        if (comptime Environment.allow_assert)
            debug("transpile({s}, {s}, async)", .{ path.text, @tagName(job.loader) });
        job.delivery_task = jsc.AnyTaskWithExtraContext.New(TranspilerJob, void, TranspilerJob.deliver).init(job);
        job.delivery_task.on_cancel = TranspilerJob.cancelDelivery;
        job.schedule();
        return promise;
    }

    pub const TranspilerJob = struct {
        path: Fs.Path,
        non_threadsafe_input_specifier: String,
        non_threadsafe_referrer: String,
        loader: options.Loader,
        promise: bun.bindgen.PromiseRoot.Optional = .empty,
        vm: *VirtualMachine,
        event_loop: *jsc.EventLoop,
        globalThis: *JSGlobalObject,
        fetcher: Fetcher,
        poll_ref: Async.KeepAlive = .{},
        generation_number: u32 = 0,
        log: logger.Log,
        parse_error: ?anyerror = null,
        resolved_source: ResolvedSource = ResolvedSource{},
        work_task: bun.BackgroundTaskGroup.Task = .{ .callback = runFromWorkerThread, .on_cancel = cancelWork },
        delivery_task: jsc.AnyTaskWithExtraContext = .{},

        pub const Store = bun.HiveArray(TranspilerJob, if (bun.heap_breakdown.enabled) 0 else 64).Fallback;

        pub const Fetcher = union(enum) {
            virtual_module: bun.String,
            file: void,

            pub fn deinit(this: *@This()) void {
                if (this.* == .virtual_module) {
                    this.virtual_module.deref();
                }
            }
        };

        pub fn deinit(this: *TranspilerJob) void {
            bun.default_allocator.free(this.path.text);

            this.poll_ref.disable();
            this.fetcher.deinit();
            this.loader = options.Loader.file;
            this.non_threadsafe_input_specifier.deref();
            this.non_threadsafe_referrer.deref();
            this.path = Fs.Path.empty;
            this.log.deinit();
            this.promise.deinit();
            this.resolved_source.deinit();
            this.globalThis = undefined;
        }

        threadlocal var ast_memory_store: ?*js_ast.ASTMemoryAllocator = null;
        threadlocal var source_code_printer: ?*js_printer.BufferPrinter = null;

        pub fn dispatchToMainThread(this: *TranspilerJob) void {
            this.event_loop.enqueueNativeTaskConcurrent(&this.delivery_task);
        }

        fn deliver(this: *TranspilerJob, _: *void) void {
            const global = this.globalThis;
            this.runFromJSThread() catch |err| global.reportUncaughtExceptionFromError(err);
        }

        fn cancelDelivery(context: jsc.AnyTaskWithExtraContext.Context) void {
            const this = context.get(*TranspilerJob);
            const vm = this.vm;
            this.poll_ref.unref(vm);
            this.deinit();
            vm.transpiler_store.store.put(this);
        }

        fn cancelWork(task: *bun.BackgroundTaskGroup.Task) void {
            const this: *TranspilerJob = @fieldParentPtr("work_task", task);
            this.parse_error = error.Canceled;
            this.dispatchToMainThread();
        }

        pub fn runFromJSThread(this: *TranspilerJob) bun.JSError!void {
            const vm = this.vm;
            const globalThis = this.globalThis;
            var promise = this.promise.take();
            defer promise.deinit();
            this.poll_ref.unref(vm);
            defer {
                this.deinit();
                vm.transpiler_store.store.put(this);
            }

            var parse_error = this.parse_error;
            const specifier = this.prepareSpecifier() catch |err| blk: {
                parse_error = err;
                const fallback = this.non_threadsafe_input_specifier;
                this.non_threadsafe_input_specifier = .empty;
                break :blk fallback;
            };

            const referrer = this.non_threadsafe_referrer;
            this.non_threadsafe_referrer = String.empty;
            var log = this.log.take();
            defer log.deinit();
            var resolved_source = this.resolved_source;
            this.resolved_source = .{};
            try AsyncModule.fulfill(globalThis, &promise, &resolved_source, parse_error, specifier, referrer, &log);
        }

        fn prepareSpecifier(this: *TranspilerJob) bun.OOM!bun.String {
            var source_url = try bun.bindgen.DOMString.fromBunString(this.non_threadsafe_input_specifier.createIfDifferent(this.path.text));
            if (this.parse_error != null) return source_url.takeBunString();
            bun.debugAssert(this.resolved_source.source_url.isEmpty());
            this.resolved_source.source_url = source_url.takeBunString();
            const specifier = this.non_threadsafe_input_specifier;
            this.non_threadsafe_input_specifier = .empty;
            return specifier;
        }

        pub fn schedule(this: *TranspilerJob) void {
            this.poll_ref.ref(this.vm);
            bun.BackgroundWork.schedule(&this.vm.background_tasks, &this.work_task) catch |err| {
                this.parse_error = err;
                this.dispatchToMainThread();
            };
        }

        pub fn runFromWorkerThread(work_task: *bun.BackgroundTaskGroup.Task) void {
            @as(*TranspilerJob, @fieldParentPtr("work_task", work_task)).run();
        }

        pub fn run(this: *TranspilerJob) void {
            this.transpile() catch |err| {
                this.parse_error = err;
            };
            this.dispatchToMainThread();
        }

        fn transpile(this: *TranspilerJob) !void {
            var arena = bun.ArenaAllocator.init(bun.default_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            if (this.generation_number != this.vm.transpiler_store.generation_number.load(.monotonic)) {
                return error.TranspilerJobGenerationMismatch;
            }

            if (ast_memory_store == null) {
                ast_memory_store = try bun.default_allocator.create(js_ast.ASTMemoryAllocator);
                ast_memory_store.?.* = js_ast.ASTMemoryAllocator{
                    .allocator = allocator,
                    .previous = null,
                };
            }

            var ast_scope = ast_memory_store.?.enter(allocator);
            defer ast_scope.exit();

            const path = this.path;
            const specifier = this.path.text;
            const loader = this.loader;

            var cache = bun.js_parser.RuntimeTranspilerCache{
                .io = this.vm.io,
                .output_code_allocator = allocator,
                .sourcemap_allocator = bun.default_allocator,
                .esm_record_allocator = bun.default_allocator,
            };
            defer {
                if (cache.entry) |*entry| entry.deinit(cache.sourcemap_allocator, cache.output_code_allocator, cache.esm_record_allocator);
                if (cache.output_code) |output| output.deref();
            }
            var vm = this.vm;
            var transpiler: bun.Transpiler = undefined;
            transpiler = vm.transpiler;
            transpiler.feature_flags = .empty;
            transpiler.setAllocator(allocator);
            transpiler.setLog(&this.log);
            transpiler.resolver.opts = transpiler.options;
            transpiler.clearMacroContext();
            defer transpiler.destroyMacroContext();
            transpiler.linker.resolver = &transpiler.resolver;

            const hash = bun.Watcher.getHash(path.text);
            const package_json = vm.bun_watcher.packageJsonForFile(hash);

            // this should be a cheap lookup because 24 bytes == 8 * 3 so it's read 3 machine words
            const is_node_override = strings.hasPrefixComptime(specifier, node_fallbacks.import_path);

            const macro_remappings = if (vm.macro_mode or !vm.has_any_macro_remappings or is_node_override)
                MacroRemap{}
            else
                transpiler.options.macro_remap;

            var fallback_source: logger.Source = undefined;

            var input_file_fd: FD = .invalid;

            const is_main = vm.main.len == path.text.len and
                vm.main_hash == hash and
                strings.eqlLong(vm.main, path.text, false);

            const module_type: ModuleType = switch (this.resolved_source.tag) {
                .source => |kind| switch (kind) {
                    .package_json_type_commonjs => .cjs,
                    .package_json_type_module => .esm,
                    else => .unknown,
                },
                .builtin => .unknown,
            };

            var parse_options = Transpiler.ParseOptions{
                .allocator = allocator,
                .path = path,
                .loader = loader,
                .dirname_fd = .invalid,
                .file_fd_ptr = &input_file_fd,
                .macro_remappings = macro_remappings,
                .jsx = transpiler.options.jsx,
                .emit_decorator_metadata = transpiler.options.emit_decorator_metadata,
                .experimental_decorators = transpiler.options.experimental_decorators,
                .virtual_source = null,
                .dont_bundle_twice = true,
                .allow_commonjs = true,
                .inject_jest_globals = transpiler.options.rewrite_jest_for_tests,
                .set_breakpoint_on_first_line = vm.debugger != null and
                    vm.debugger.?.set_breakpoint_on_first_line and
                    is_main and
                    setBreakPointOnFirstLine(),
                .runtime_transpiler_cache = if (!bun.js_parser.RuntimeTranspilerCache.is_disabled) &cache else null,
                .remove_cjs_module_wrapper = is_main and vm.module_loader.eval_source != null,
                .module_type = module_type,
                .allow_bytecode_cache = true,
            };

            defer {
                if (input_file_fd.isValid()) {
                    input_file_fd.close();
                    input_file_fd = .invalid;
                }
            }

            if (is_node_override) {
                if (node_fallbacks.contentsFromPath(vm.io, specifier)) |code| {
                    const fallback_path = Fs.Path.initWithNamespace(specifier, "node");
                    fallback_source = logger.Source{ .path = fallback_path, .contents = code };
                    parse_options.virtual_source = &fallback_source;
                }
            }

            var parse_result: bun.transpiler.ParseResult = (try transpiler.parseMaybeReturnFileOnlyAllowSharedBuffer(
                parse_options,
                null,
                false,
                false,
            )) orelse {
                if (vm.isWatcherEnabled()) {
                    if (input_file_fd.isValid()) {
                        if (!is_node_override and std.fs.path.isAbsolute(path.text) and !strings.contains(path.text, "node_modules")) {
                            _ = vm.bun_watcher.addFileByPathSlow(path.text, loader, package_json);
                        }
                    }
                }

                this.parse_error = error.ParseError;

                return;
            };

            if (vm.isWatcherEnabled()) {
                if (input_file_fd.isValid()) {
                    if (!is_node_override and
                        std.fs.path.isAbsolute(path.text) and !strings.contains(path.text, "node_modules"))
                    {
                        _ = vm.bun_watcher.addFileByPathSlow(path.text, loader, package_json);
                    }
                }
            }

            if (cache.entry) |*entry| {
                const module_info: ?*analyze_transpiled_module.ModuleInfoDeserialized =
                    if (vm.useIsolationSourceProviderCache() and entry.metadata.module_type != .cjs and entry.esm_record.len > 0)
                        try analyze_transpiled_module.ModuleInfoDeserialized.createFromCachedRecord(entry.esm_record, bun.default_allocator)
                    else
                        null;
                errdefer if (module_info) |info| info.deinit();

                try vm.source_mappings.putMappings(&parse_result.source, .{
                    .list = .fromOwnedSlice(@constCast(entry.sourcemap)),
                    .allocator = bun.default_allocator,
                });

                if (comptime Environment.dump_source) {
                    dumpSourceString(vm, specifier, entry.output_code.byteSlice());
                }

                this.resolved_source = ResolvedSource{
                    .source_code = switch (entry.output_code) {
                        .string => entry.output_code.string.dupeRef(),
                        .utf8 => brk: {
                            var result = try bun.bindgen.DOMString.fromUTF8(entry.output_code.utf8);
                            break :brk result.takeBunString();
                        },
                    },
                    .is_commonjs_module = entry.metadata.module_type == .cjs,
                    .module_info = if (module_info) |value| ResolvedSource.ModuleInfoHandle.initNative(value) else null,
                    .tag = this.resolved_source.tag,
                };

                return;
            }

            if (parse_result.already_bundled != .none) {
                const bytecode_slice = parse_result.already_bundled.bytecodeSlice();
                errdefer if (bytecode_slice.len > 0) bun.default_allocator.free(bytecode_slice);
                var source_code = try bun.bindgen.DOMString.fromLatin1(parse_result.source.contents);
                this.resolved_source = ResolvedSource{
                    .source_code = source_code.takeBunString(),
                    .already_bundled = true,
                    .bytecode_cache = if (bytecode_slice.len > 0)
                        .{ .owned = bytecode_slice }
                    else
                        null,
                    .is_commonjs_module = parse_result.already_bundled.isCommonJS(),
                    .tag = this.resolved_source.tag,
                };
                this.resolved_source.source_code.ensureHash();
                return;
            }

            for (parse_result.ast.import_records.slice()) |*import_record_| {
                var import_record: *bun.ImportRecord = import_record_;

                if (HardcodedModule.Alias.get(import_record.path.text, transpiler.options.target, .{ .rewrite_jest_for_tests = transpiler.options.rewrite_jest_for_tests })) |replacement| {
                    import_record.path.text = replacement.path;
                    import_record.tag = replacement.tag;
                    import_record.flags.is_external_without_side_effects = true;
                    continue;
                }

                if (strings.hasPrefixComptime(import_record.path.text, "bun:")) {
                    import_record.path = Fs.Path.init(import_record.path.text["bun:".len..]);
                    import_record.path.namespace = "bun";
                    import_record.flags.is_external_without_side_effects = true;
                }
            }

            if (source_code_printer == null) {
                const writer = js_printer.BufferWriter.init(bun.default_allocator);
                source_code_printer = try bun.default_allocator.create(js_printer.BufferPrinter);
                source_code_printer.?.* = js_printer.BufferPrinter.init(writer);
            }

            var printer = source_code_printer.?.*;
            printer.ctx.reset();

            // Cap buffer size to prevent unbounded growth
            const max_buffer_cap = 512 * 1024;
            if (printer.ctx.buffer.list.capacity > max_buffer_cap) {
                printer.ctx.buffer.deinit();
                const writer = js_printer.BufferWriter.init(bun.default_allocator);
                source_code_printer.?.* = js_printer.BufferPrinter.init(writer);
                printer = source_code_printer.?.*;
            }

            const is_commonjs_module = parse_result.ast.has_commonjs_export_names or parse_result.ast.exports_kind == .cjs;
            const module_info: ?*analyze_transpiled_module.ModuleInfo =
                if (vm.useIsolationSourceProviderCache() and !is_commonjs_module and loader.isJavaScriptLike())
                    try analyze_transpiled_module.ModuleInfo.create(bun.default_allocator, loader.isTypeScript())
                else
                    null;
            errdefer if (module_info) |info| info.destroy();

            {
                var mapper = vm.sourceMapHandler(&printer);
                defer source_code_printer.?.* = printer;
                _ = try transpiler.printWithSourceMap(
                    parse_result,
                    @TypeOf(&printer),
                    &printer,
                    .esm_ascii,
                    mapper.get(),
                    module_info,
                );
            }

            if (comptime Environment.dump_source) {
                dumpSource(this.vm, specifier, &printer);
            }

            const source_code = brk: {
                const written = printer.ctx.getWritten();

                var output = try bun.bindgen.DOMString.fromBunString(if (cache.output_code) |cached|
                    cached.dupeRef()
                else
                    bun.String.cloneLatin1(written));
                const result = output.takeBunString();

                if (written.len > 1024 * 1024 * 2 or vm.smol) {
                    printer.ctx.buffer.deinit();
                    const writer = js_printer.BufferWriter.init(bun.default_allocator);
                    source_code_printer.?.* = js_printer.BufferPrinter.init(writer);
                } else {
                    source_code_printer.?.* = printer;
                }

                result.ensureHash();

                break :brk result;
            };
            this.resolved_source = ResolvedSource{
                .source_code = source_code,
                .is_commonjs_module = is_commonjs_module,
                .module_info = if (module_info) |mi| ResolvedSource.ModuleInfoHandle.initNative(mi.asDeserialized()) else null,
                .tag = this.resolved_source.tag,
            };
        }
    };
};

const Fs = @import("../resolver/fs.zig");
const analyze_transpiled_module = @import("../bundler/analyze_transpiled_module.zig");
const node_fallbacks = @import("../resolver/node_fallbacks.zig");
const std = @import("std");
const AsyncModule = @import("./AsyncModule.zig").AsyncModule;
const HardcodedModule = @import("../resolve_builtins/HardcodedModule.zig").HardcodedModule;

const options = @import("../bundler/options.zig");
const ModuleType = options.ModuleType;

const MacroRemap = @import("../resolver/package_json.zig").MacroMap;
const PackageJSON = @import("../resolver/package_json.zig").PackageJSON;

const bun = @import("bun");
const Async = bun.Async;
const Environment = bun.Environment;
const FD = bun.FD;
const Output = bun.Output;
const String = bun.String;
const Transpiler = bun.Transpiler;
const js_ast = bun.ast;
const js_printer = bun.js_printer;
const logger = bun.logger;
const strings = bun.strings;

const jsc = bun.jsc;
const JSGlobalObject = bun.jsc.JSGlobalObject;
const ResolvedSource = bun.jsc.ResolvedSource;
const VirtualMachine = bun.jsc.VirtualMachine;
