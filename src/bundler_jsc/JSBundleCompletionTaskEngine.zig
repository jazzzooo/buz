//! JavaScript completion bridge for `Bun.build()`.

pub const BuildResult = bv2.BundleV2.BuildResult;
pub const Result = bv2.BundleV2.Result;

pub const JSBundleThread = BundleThread(JSBundleCompletionTask);

pub fn createCompletionTask(
    config: bun.jsc.API.JSBundler.Config,
    plugins: ?*bun.jsc.API.JSBundler.Plugin,
    globalThis: *jsc.JSGlobalObject,
) OOM!*JSBundleCompletionTask {
    const registry = try (try globalThis.bunVM().tryRareData()).nativeCompletionRegistry(globalThis.bunVM());
    const producer = try JSBundleCompletionTask.Producer.create(registry);
    errdefer producer.deref();
    const environment = try bun.DotEnv.Loader.Snapshot.create(globalThis.bunVM().transpiler.env);
    errdefer environment.destroy();
    const completion = try bun.tryNew(JSBundleCompletionTask, .{
        .ref_count = .init(),
        .config = config,
        .producer = producer,
        .globalThis = globalThis,
        .io = globalThis.bunVM().io,
        .engine_capabilities = globalThis.bunVM().transpiler.engine_capabilities,
        .poll_ref = Async.KeepAlive.init(),
        .environment = environment,
        .plugins = plugins,
        .log = Logger.Log.init(bun.default_allocator),
    });
    producer.entry = .{
        .context = .init(completion),
        .deliver = JSBundleCompletionTask.deliver,
        .cancel = JSBundleCompletionTask.cancelBeforeDetach,
        .detach = JSBundleCompletionTask.detach,
    };

    if (plugins) |plugin| plugin.ref();
    return completion;
}

pub fn generateFromJavaScript(
    config: bun.jsc.API.JSBundler.Config,
    plugins: ?*bun.jsc.API.JSBundler.Plugin,
    globalThis: *jsc.JSGlobalObject,
    build_completion: JSBundleCompletionTask.BuildCompletion.Owned,
) OOM!void {
    var owned = build_completion;
    errdefer owned.release();
    const completion = try createCompletionTask(config, plugins, globalThis);
    completion.completion = owned;
    if (plugins) |plugin| plugin.deinit();
    completion.start();
}

pub const JSBundleCompletionTask = struct {
    pub const RefCount = bun.ptr.ThreadSafeRefCount(@This(), "ref_count", @This().deinit, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;

    ref_count: RefCount,
    config: bun.jsc.API.JSBundler.Config,
    producer: *Producer,
    producer_started: bool = false,
    globalThis: *jsc.JSGlobalObject,
    io: std.Io,
    engine_capabilities: Transpiler.EngineCapabilities,
    completion: ?BuildCompletion.Owned = null,
    poll_ref: Async.KeepAlive = Async.KeepAlive.init(),
    environment: *bun.DotEnv.Loader.Snapshot,
    log: Logger.Log,
    cancellation: BundleV2.Cancellation = .{},
    started: bool = false,

    html_build_task: ?*jsc.API.HTMLBundle.HTMLBundleRoute = null,

    result: Result = .{ .pending = {} },
    prepared_result: ?PreparedBuildResult = null,

    next: ?*JSBundleCompletionTask = null,
    plugins: ?*bun.jsc.API.JSBundler.Plugin = null,
    started_at_ns: u64 = 0,

    const Producer = struct {
        ref_count: ProducerRefCount = .init(),
        registry: *jsc.NativeCompletionRegistry,
        entry: jsc.NativeCompletionRegistry.Entry = undefined,
        done: std.Io.Event = .unset,
        finish_mutex: std.atomic.Mutex = .unlocked,

        const ProducerRefCount = bun.ptr.ThreadSafeRefCount(@This(), "ref_count", destroy, .{});
        const ref = ProducerRefCount.ref;
        const deref = ProducerRefCount.deref;

        fn create(registry: *jsc.NativeCompletionRegistry) OOM!*Producer {
            const producer = try bun.tryNew(Producer, .{ .registry = registry });
            registry.retain();
            return producer;
        }

        fn finish(producer: *Producer, io: std.Io) void {
            while (!producer.finish_mutex.tryLock()) std.atomic.spinLoopHint();
            producer.done.set(io);
            producer.finish_mutex.unlock();
            _ = producer.registry.submit(&producer.entry);
            producer.deref();
        }

        fn wait(producer: *Producer, io: std.Io) void {
            producer.done.waitUncancelable(io);
            // Join the final wake before the VM can release its I/O provider.
            while (!producer.finish_mutex.tryLock()) std.atomic.spinLoopHint();
            producer.finish_mutex.unlock();
        }

        fn destroy(producer: *Producer) void {
            producer.registry.release();
            bun.destroy(producer);
        }
    };

    pub fn start(this: *JSBundleCompletionTask) void {
        bun.assert(!this.started);
        bun.assert((this.completion != null) != (this.html_build_task != null));
        this.started = true;
        this.poll_ref.ref(this.globalThis.bunVM());
        if (!this.producer.registry.register(&this.producer.entry)) {
            detach(.init(this));
            return;
        }
        this.producer.ref();
        this.producer_started = true;
        JSBundleThread.singleton.enqueue(this);
    }

    fn deliver(raw: bun.bindgen.NativeCallbackContext(.vm)) void {
        const this = raw.get(*JSBundleCompletionTask);
        this.producer.wait(this.io);
        this.onComplete();
    }

    fn cancelBeforeDetach(raw: bun.bindgen.NativeCallbackContext(.vm)) void {
        const this = raw.get(*JSBundleCompletionTask);
        this.ref();
        defer this.deref();
        this.cancel();
    }

    fn detach(raw: bun.bindgen.NativeCallbackContext(.vm)) void {
        const this = raw.get(*JSBundleCompletionTask);
        defer this.deref();
        this.cancel();
        if (this.producer_started) this.producer.wait(this.io);
        this.poll_ref.unref(this.globalThis.bunVM());
        if (this.html_build_task) |route| route.onBuildCancelled(this);
    }

    pub fn bundlerEndpoint(this: *JSBundleCompletionTask) bv2.CompletionEndpoint {
        return .{
            .context = .init(@as(*const JSBundleCompletionTask, this)),
            .did_fail = didBundlingFail,
        };
    }

    pub fn bytecodeGenerator(_: *JSBundleCompletionTask) bv2.BytecodeGenerator {
        return BundlerEngine.bytecode_generator;
    }

    pub fn configureBundleV2(this: *JSBundleCompletionTask, bundle: *BundleV2) void {
        bundle.parent_cancellation = &this.cancellation;
        bundle.plugin_host = if (this.plugins) |plugin| plugin.host() else null;
        bundle.completion_endpoint = this.bundlerEndpoint();
        bundle.file_map = if (this.config.files.map.count() > 0) &this.config.files else null;
    }

    pub fn cancel(this: *JSBundleCompletionTask) void {
        this.cancellation.request();
        if (this.plugins) |plugin| plugin.cancelBuild(&this.cancellation);
    }

    pub fn isCancelled(this: *const JSBundleCompletionTask) bool {
        return this.cancellation.isRequested();
    }

    fn didBundlingFail(context: bun.bindgen.NativeCallbackContext(.vm)) bool {
        const this = context.get(*const JSBundleCompletionTask);
        return this.result == .err;
    }

    pub fn configureBundler(
        completion: *JSBundleCompletionTask,
        transpiler: *Transpiler,
        alloc: std.mem.Allocator,
    ) !void {
        return JSBundleConfig.configure(
            &completion.config,
            completion.io,
            &completion.log,
            completion.engine_capabilities,
            &completion.environment.loader,
            transpiler,
            alloc,
        );
    }

    pub fn completeOnBundleThread(completion: *JSBundleCompletionTask) void {
        const producer = completion.producer;
        const io = completion.io;
        producer.finish(io);
    }

    fn deinit(this: *JSBundleCompletionTask) void {
        bun.assert(!this.producer_started or this.producer.done.isSet());
        if (this.prepared_result) |*prepared| prepared.deinit();
        this.result.deinit();
        this.log.deinit();
        this.poll_ref.disable();
        if (this.plugins) |plugin| {
            plugin.deinit();
        }
        this.config.deinit(bun.default_allocator);
        if (this.completion) |*owned| {
            owned.release();
            this.completion = null;
        }
        if (this.html_build_task) |route| {
            this.html_build_task = null;
            route.deref();
        }
        this.environment.destroy();
        this.producer.deref();
        bun.destroy(this);
    }

    fn doCompilation(this: *JSBundleCompletionTask, output_files: *std.array_list.Managed(options.OutputFile)) bun.StandaloneModuleGraph.CompileResult {
        const compile_options = &(this.config.compile orelse @panic("Unexpected: No compile options provided"));

        const entry_point_index: usize = brk: {
            for (output_files.items, 0..) |*output_file, i| {
                if (output_file.output_kind == .@"entry-point" and (output_file.side orelse .server) == .server) {
                    break :brk i;
                }
            }
            return bun.StandaloneModuleGraph.CompileResult.fail(.no_entry_point);
        };

        const output_file = &output_files.items[entry_point_index];
        const outbuf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(outbuf);

        // Always get an absolute path for the outfile to ensure it works correctly with PE metadata operations
        var full_outfile_path = if (this.config.outdir.slice().len > 0) brk: {
            const outdir_slice = this.config.outdir.slice();
            const top_level_dir = bun.fs.FileSystem.instance.top_level_dir;
            break :brk bun.path.joinAbsStringBuf(top_level_dir, outbuf, &[_][]const u8{ outdir_slice, compile_options.outfile.slice() }, .auto);
        } else if (std.fs.path.isAbsolute(compile_options.outfile.slice()))
            compile_options.outfile.slice()
        else brk: {
            // For relative paths, ensure we make them absolute relative to the current working directory
            const top_level_dir = bun.fs.FileSystem.instance.top_level_dir;
            break :brk bun.path.joinAbsStringBuf(top_level_dir, outbuf, &[_][]const u8{compile_options.outfile.slice()}, .auto);
        };

        // Add .exe extension for Windows targets if not already present
        if (compile_options.compile_target.os == .windows and !strings.hasSuffixComptime(full_outfile_path, ".exe")) {
            full_outfile_path = std.fmt.allocPrint(bun.default_allocator, "{s}.exe", .{full_outfile_path}) catch |err| bun.handleOom(err);
        } else {
            full_outfile_path = bun.handleOom(bun.default_allocator.dupe(u8, full_outfile_path));
        }

        const dirname = std.fs.path.dirname(full_outfile_path) orelse ".";
        const basename = std.fs.path.basename(full_outfile_path);

        var root_dir = bun.FD.cwd().stdDir();
        defer {
            if (bun.FD.fromStdDir(root_dir) != bun.FD.cwd()) {
                root_dir.close(this.io);
            }
        }

        // On Windows, don't change root_dir, just pass the full relative path
        // On POSIX, change root_dir to the target directory and pass basename
        const outfile_for_executable = if (Environment.isWindows) full_outfile_path else basename;

        if (Environment.isPosix and !(dirname.len == 0 or strings.eqlComptime(dirname, "."))) {
            // On POSIX, makeOpenPath and change root_dir
            root_dir = bun.MakePath.makeOpenPath(this.io, root_dir, dirname, .{}) catch |err| {
                return bun.StandaloneModuleGraph.CompileResult.failFmt("Failed to open output directory {s}: {s}", .{ dirname, @errorName(err) });
            };
        } else if (Environment.isWindows and !(dirname.len == 0 or strings.eqlComptime(dirname, "."))) {
            // On Windows, ensure directories exist but don't change root_dir
            _ = bun.makePath(root_dir, this.io, dirname) catch |err| {
                return bun.StandaloneModuleGraph.CompileResult.failFmt("Failed to create output directory {s}: {s}", .{ dirname, @errorName(err) });
            };
        }

        // Use the target-specific base path for compile mode, not the user-configured public_path
        const module_prefix = bun.StandaloneModuleGraph.targetBasePublicPath(compile_options.compile_target.os, "root/");

        const result = bun.StandaloneModuleGraph.toExecutable(
            &compile_options.compile_target,
            bun.default_allocator,
            this.io,
            this.engine_capabilities.javascript_semantics,
            output_files.items,
            root_dir,
            module_prefix,
            outfile_for_executable,
            &this.environment.loader,
            this.config.format,
            .{
                .hide_console = compile_options.windows_hide_console,
                .icon = if (compile_options.windows_icon_path.slice().len > 0)
                    compile_options.windows_icon_path.slice()
                else
                    null,
                .title = if (compile_options.windows_title.slice().len > 0)
                    compile_options.windows_title.slice()
                else
                    null,
                .publisher = if (compile_options.windows_publisher.slice().len > 0)
                    compile_options.windows_publisher.slice()
                else
                    null,
                .version = if (compile_options.windows_version.slice().len > 0)
                    compile_options.windows_version.slice()
                else
                    null,
                .description = if (compile_options.windows_description.slice().len > 0)
                    compile_options.windows_description.slice()
                else
                    null,
                .copyright = if (compile_options.windows_copyright.slice().len > 0)
                    compile_options.windows_copyright.slice()
                else
                    null,
            },
            compile_options.exec_argv.slice(),
            if (compile_options.executable_path.slice().len > 0)
                compile_options.executable_path.slice()
            else
                null,
            .{
                .disable_default_env_files = !compile_options.autoload_dotenv,
                .disable_autoload_bunfig = !compile_options.autoload_bunfig,
                .disable_autoload_tsconfig = !compile_options.autoload_tsconfig,
                .disable_autoload_package_json = !compile_options.autoload_package_json,
            },
        ) catch |err| {
            return bun.StandaloneModuleGraph.CompileResult.failFmt("{s}", .{@errorName(err)});
        };

        if (result == .success) {
            output_file.dest_path = full_outfile_path;
            output_file.is_executable = true;
        }

        // Write external sourcemap files next to the compiled executable and
        // keep them in the output array. Destroy all other non-entry-point files.
        // With --splitting, there can be multiple sourcemap files (one per chunk).
        var kept: usize = 0;
        for (output_files.items, 0..) |*current, i| {
            if (i == entry_point_index) {
                output_files.items[kept] = current.*;
                kept += 1;
            } else if (result == .success and current.output_kind == .sourcemap and current.value == .buffer) {
                const sourcemap_bytes = current.value.buffer.bytes;
                if (sourcemap_bytes.len > 0) {
                    // Derive the .map filename from the sourcemap's own dest_path,
                    // placed in the same directory as the compiled executable.
                    const map_basename = if (current.dest_path.len > 0)
                        std.fs.path.basename(current.dest_path)
                    else
                        std.fs.path.basename(bun.handleOom(std.fmt.allocPrint(bun.default_allocator, "{s}.map", .{full_outfile_path})));

                    const sourcemap_full_path = if (dirname.len == 0 or strings.eqlComptime(dirname, "."))
                        bun.handleOom(bun.default_allocator.dupe(u8, map_basename))
                    else
                        bun.handleOom(std.fmt.allocPrint(bun.default_allocator, "{s}{c}{s}", .{ dirname, std.fs.path.sep, map_basename }));

                    // Write the sourcemap file to disk next to the executable
                    var pathbuf: bun.PathBuffer = undefined;
                    const write_path = if (Environment.isWindows) sourcemap_full_path else map_basename;
                    switch (NodeFSCore.writeFileWithPathBuffer(
                        &pathbuf,
                        .{
                            .data = .{ .buffer = NodeTypes.NodeBuffer.borrow(sourcemap_bytes) },
                            .encoding = .buffer,
                            .dirfd = .fromStdDir(root_dir),
                            .file = .{ .path = .{
                                .string = bun.PathString.init(write_path),
                            } },
                        },
                    )) {
                        .err => |err| {
                            bun.Output.err(err, "failed to write sourcemap file '{s}'", .{write_path});
                            current.deinit();
                        },
                        .result => {
                            current.dest_path = sourcemap_full_path;
                            output_files.items[kept] = current.*;
                            kept += 1;
                        },
                    }
                } else {
                    current.deinit();
                }
            } else {
                current.deinit();
            }
        }
        output_files.items.len = kept;

        return result;
    }

    const PreparedArtifact = struct {
        native: ?*jsc.API.BuildArtifact,
        source_map_index: ?usize = null,

        pub fn deinit(artifact: *PreparedArtifact) void {
            const native = artifact.native orelse return;
            artifact.native = null;
            native.destroy();
        }
    };

    const PreparedLog = union(enum) {
        build: ?*bun.api.BuildMessage,
        resolve: ?*bun.api.ResolveMessage,

        pub fn deinit(entry: *PreparedLog) void {
            switch (entry.*) {
                inline .build, .resolve => |*native| if (bun.take(native)) |value| value.destroy(),
            }
        }
    };

    const PreparedArtifacts = bun.bindgen.OwnedNativeSlice(PreparedArtifact, .any);
    const PreparedLogs = bun.bindgen.OwnedNativeSlice(PreparedLog, .any);

    const PreparedBuildResult = struct {
        outputs: PreparedArtifacts = .empty,
        logs: PreparedLogs = .empty,
        metafile_json: ?bun.bindgen.DOMString = null,
        success: bool,
        throw_on_error: bool,

        fn deinit(prepared: *PreparedBuildResult) void {
            prepared.outputs.deinit();
            prepared.logs.deinit();
            if (prepared.metafile_json) |*metafile| metafile.deinit();
            prepared.metafile_json = null;
        }
    };

    fn outputPath(this: *JSBundleCompletionTask, output_file: *const options.OutputFile) bun.OOM![]u8 {
        if (!this.config.outdir.isEmpty()) {
            if (std.fs.path.isAbsolute(this.config.outdir.list.items)) {
                return std.fs.path.resolve(
                    bun.default_allocator,
                    &.{ this.config.outdir.slice(), output_file.dest_path },
                );
            }
            return std.fs.path.resolve(
                bun.default_allocator,
                &.{ bun.fs.FileSystem.instance.top_level_dir, this.config.dir.slice(), this.config.outdir.slice(), output_file.dest_path },
            );
        }
        return bun.default_allocator.dupe(u8, output_file.dest_path);
    }

    fn prepareArtifacts(
        this: *JSBundleCompletionTask,
        output_files: []options.OutputFile,
    ) bun.OOM!PreparedArtifacts {
        var prepared = try std.array_list.Managed(PreparedArtifact).initCapacity(
            bun.default_allocator,
            output_files.len,
        );
        errdefer {
            for (prepared.items) |*artifact| artifact.deinit();
            prepared.deinit();
        }
        const original_to_prepared = try bun.default_allocator.alloc(?usize, output_files.len);
        defer bun.default_allocator.free(original_to_prepared);
        @memset(original_to_prepared, null);

        for (output_files, 0..) |*output_file, original_index| {
            const path = try this.outputPath(output_file);
            const artifact = try OutputFileEngine.toBuildArtifact(output_file, path);
            if (artifact) |native| {
                original_to_prepared[original_index] = prepared.items.len;
                prepared.appendAssumeCapacity(.{ .native = native });
            }
        }

        for (output_files, 0..) |output_file, original_index| {
            const prepared_index = original_to_prepared[original_index] orelse continue;
            if (output_file.source_map_index == std.math.maxInt(u32)) continue;
            const source_index: usize = output_file.source_map_index;
            if (source_index >= original_to_prepared.len) continue;
            prepared.items[prepared_index].source_map_index = original_to_prepared[source_index];
        }
        return .fromOwnedSlice(try prepared.toOwnedSlice());
    }

    fn prepareLogs(this: *JSBundleCompletionTask) bun.OOM!PreparedLogs {
        const messages = this.log.msgs.items;
        var builder = try PreparedLogs.Builder.init(messages.len);
        defer builder.deinit();
        for (messages) |message| {
            builder.appendOwned(switch (message.metadata) {
                .build => .{ .build = try bun.api.BuildMessage.createNative(message) },
                .resolve => .{ .resolve = try bun.api.ResolveMessage.createNative(message, "") },
            });
        }
        return builder.finish();
    }

    fn prepareResult(this: *JSBundleCompletionTask) bun.OOM!void {
        if (this.prepared_result != null) @panic("bundle result prepared twice");
        if (this.result == .err and this.result.err == error.OutOfMemory) return error.OutOfMemory;
        if (this.result == .value and this.config.compile != null) {
            var compile_result = this.doCompilation(&this.result.value.output_files);
            defer compile_result.deinit();
            if (compile_result != .success) {
                try this.log.addError(
                    null,
                    Logger.Loc.Empty,
                    try this.log.msgs.allocator.dupe(u8, compile_result.err.slice()),
                );
                this.result.value.deinit();
                this.result = .{ .err = error.CompilationFailed };
            }
        }

        var prepared: PreparedBuildResult = .{
            .success = this.result == .value,
            .throw_on_error = this.config.throw_on_error,
        };
        errdefer prepared.deinit();
        prepared.logs = try this.prepareLogs();
        if (this.result == .value) {
            const build = &this.result.value;
            prepared.outputs = try this.prepareArtifacts(build.output_files.items);
            if (build.metafile) |metafile| {
                prepared.metafile_json = try bun.bindgen.DOMString.fromUTF8(metafile);
            }
        }
        this.prepared_result = prepared;
    }

    const NativeBuildResult = bun.bindgen.Return(BuildFunctionSchema);
    const NativeBuildOutputs = @FieldType(NativeBuildResult, "outputs");
    const NativeBuildLogs = @FieldType(NativeBuildResult, "logs");

    fn takeOutputs(
        this: *JSBundleCompletionTask,
        context: anytype,
    ) bun.JSError!NativeBuildOutputs {
        const prepared = &this.prepared_result.?;
        var references = try bun.bindgen.OwnedNativeSlice(NativeBuildOutputs.Element, .vm).Builder.init(prepared.outputs.values.len);
        defer references.deinit();
        for (prepared.outputs.values) |*artifact| {
            const native = artifact.native orelse @panic("prepared build artifact was already consumed");
            artifact.native = null;
            references.appendOwned(try jsc.API.BuildArtifact.adoptResult(native, context));
        }
        const refs = references.slice();
        for (prepared.outputs.values, 0..) |artifact, index| {
            if (artifact.source_map_index) |source_map_index| {
                jsc.API.BuildArtifact.linkSourceMap(&refs[index], &refs[source_map_index]);
            }
        }
        var outputs = try NativeBuildOutputs.Builder.init(refs.len);
        defer outputs.deinit();
        for (refs) |*reference| outputs.appendOwned(reference.take());
        return outputs.finish();
    }

    fn takeLogs(
        this: *JSBundleCompletionTask,
        context: anytype,
    ) bun.JSError!NativeBuildLogs {
        const prepared = &this.prepared_result.?;
        var builder = try NativeBuildLogs.Builder.init(prepared.logs.values.len);
        errdefer builder.deinit();
        for (prepared.logs.values) |*entry| {
            builder.appendOwned(switch (entry.*) {
                inline .build, .resolve => |*native, tag| blk: {
                    const value = bun.take(native) orelse @panic("prepared build log was already consumed");
                    const Native = @typeInfo(@TypeOf(value)).pointer.child;
                    break :blk @unionInit(NativeBuildLogs.Element, @tagName(tag), try Native.adoptResult(value, context));
                },
            });
        }
        return builder.finish();
    }

    const BuildCompletionOps = struct {
        pub fn materialize(
            comptime FunctionSchema: type,
            context: bun.bindgen.MaterializationContext(FunctionSchema),
            task: *JSBundleCompletionTask,
        ) bun.bindgen.MaterializationError(FunctionSchema)!bun.bindgen.Return(FunctionSchema) {
            if (comptime FunctionSchema != BuildFunctionSchema) {
                @compileError("unsupported build completion endpoint");
            }
            const prepared = &task.prepared_result.?;
            var outputs = try task.takeOutputs(context);
            errdefer outputs.deinit();
            var logs = try task.takeLogs(context);
            errdefer logs.deinit();
            const callbacks = if (task.plugins) |plugin|
                try context.engineIn("JSBundlerPlugin", "onEndCallbacks").call(.{ .plugin = plugin.value.operand(context) })
            else
                null;
            const metafile_json = if (prepared.metafile_json) |*metafile| metafile.take() else null;
            return .{
                .outputs = outputs,
                .success = prepared.success,
                .logs = logs,
                .metafile_json = metafile_json,
                .on_end_callbacks = if (callbacks) |values| values.take() else null,
                .throw_on_error = prepared.throw_on_error,
            };
        }

        pub fn destroyPayload(task: *JSBundleCompletionTask) void {
            task.deref();
        }

    };

    pub const BuildCompletion = bun.bindgen.MaterializedCompletion(
        BuildFunctionSchema,
        JSBundleCompletionTask,
        void,
        BuildCompletionOps,
    );

    fn onComplete(this: *JSBundleCompletionTask) void {
        const globalThis = this.globalThis;
        defer this.deref();

        this.poll_ref.unref(globalThis.bunVM());
        if (this.cancellation.isRequested()) {
            if (this.html_build_task) |route| route.onBuildCancelled(this);
            return;
        }

        if (this.html_build_task) |html_build_task| {
            html_build_task.onComplete(this);
            return;
        }

        var owned = this.completion orelse return;
        this.completion = null;
        this.prepareResult() catch {
            owned.outOfMemory();
            return;
        };
        this.ref();
        owned.complete(this);
    }
};

const string = []const u8;

const std = @import("std");

const bv2 = @import("../bundler/bundle_v2.zig");
const BundlerEngine = @import("../bundler/BundlerEngine.zig");
const JSBundleConfig = @import("../bundler/JSBundleConfig.zig");
const BundleThread = bv2.BundleThread;
const BundleV2 = bv2.BundleV2;
const NodeFSCore = @import("../runtime/node/NodeFSCore.zig");
const NodeTypes = @import("../runtime/node/types.zig");
const OutputFileEngine = @import("OutputFileEngine.zig");

const bun = @import("bun");
const Async = bun.Async;
const Environment = bun.Environment;
const Logger = bun.logger;
const OOM = bun.OOM;
const StandaloneModuleGraph = bun.StandaloneModuleGraph;
const String = bun.String;
const jsc = bun.jsc;
const logger = bun.logger;
const options = bun.options;
const sourcemap = bun.sourcemap;
const strings = bun.strings;
const Transpiler = bun.transpiler.Transpiler;

const BuildFunctionSchema = bun.bindgen.Module("BunObject").function("buildNative");
