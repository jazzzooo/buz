const debug = Output.scoped(.AsyncModule, .hidden);
const AsyncModuleBindings = bun.bindgen.Module("AsyncModule");
const PromiseBindings = bun.bindgen.Module("promises");
const FulfillAsyncModuleSchema = AsyncModuleBindings.engineShim("fulfill");
const CreateAsyncModuleErrorSchema = AsyncModuleBindings.engineShim("createError");
const PromiseRejectAsHandledSchema = PromiseBindings.engineShim("promiseRejectAsHandled");
const PromiseRejectSchema = PromiseBindings.engineShim("promiseReject");
const CreateErrorSchema = bun.bindgen.Module("errors").engineShim("createError");

const string = []const u8;

const AsyncModuleError = struct {
    message: []const u8,
    name: []const u8,
    url: ?[]const u8,
    pkg: []const u8,
    specifier: []const u8,
    source_url: []const u8,
    line: i32,
    line_text: ?[]const u8,
    column: i32,
    referrer: ?[]const u8,
};

fn createAsyncModuleError(scope: *bun.bindgen.FocusedEngineScope, data: AsyncModuleError) @TypeOf(scope.engine(CreateAsyncModuleErrorSchema)).Return {
    const operation = scope.engine(CreateAsyncModuleErrorSchema);
    const Input = @FieldType(@TypeOf(operation).Args, "data");
    const fields = @typeInfo(Input).@"struct".field_names;
    var owned_strings: [fields.len]bun.bindgen.DOMString = @splat(.empty());
    defer for (&owned_strings) |*text| text.deinit();
    var input: Input = undefined;
    inline for (fields, 0..) |field, index| {
        const value = @field(data, field);
        @field(input, field) = switch (@TypeOf(value)) {
            i32 => value,
            []const u8 => text: {
                owned_strings[index] = try bun.bindgen.DOMString.fromUTF8(value);
                break :text owned_strings[index].operand();
            },
            ?[]const u8 => if (value) |bytes| text: {
                owned_strings[index] = try bun.bindgen.DOMString.fromUTF8(bytes);
                break :text owned_strings[index].operand();
            } else null,
            else => @compileError("unsupported async-module error field: " ++ field),
        };
    }
    return operation.call(.{ .data = input });
}

pub const AsyncModule = struct {
    // This is all the state used by the printer to print the module
    parse_result: ParseResult,
    promise: bun.bindgen.PromiseRoot.Optional = .empty,
    path: Fs.Path,
    specifier: string = "",
    referrer: string = "",
    string_buf: []u8 = &[_]u8{},
    watch_source: bool,
    package_json: ?*PackageJSON = null,
    loader: api.Loader,
    globalThis: *JSGlobalObject = undefined,
    arena: *bun.ArenaAllocator,
    source_buffer: ?bun.MutableString = null,
    transpiler_cache: ?bun.js_parser.RuntimeTranspilerCache = null,

    // This is the specific state for making it async
    poll_ref: Async.KeepAlive = .{},
    delivery_task: jsc.AnyTaskWithExtraContext = .{},

    pub const Id = u32;

    const PackageDownloadError = struct {
        name: []const u8,
        resolution: Install.Resolution,
        err: anyerror,
        url: []const u8,
    };

    const PackageResolveError = struct {
        name: []const u8,
        err: anyerror,
        url: []const u8,
        version: Dependency.Version,
    };

    pub const Queue = struct {
        map: Map = .empty,
        scheduled: usize = 0,
        closed: bool = false,
        // Package-manager callbacks can remove the module while polling is on the stack.
        polling: ?*AsyncModule = null,
        polling_removed: bool = false,
        wake_pending: std.atomic.Value(bool) = .init(false),
        wake_task: jsc.AnyTaskWithExtraContext = .{},
        wake_loop: ?*jsc.EventLoop = null,
        running_tasks: bool = false,
        poll_again: bool = false,

        pub const Map = std.ArrayListUnmanaged(*AsyncModule);

        pub fn initWakeHandler(this: *Queue) PackageManager.WakeHandler {
            bun.assert(this.wake_loop == null);
            this.wake_loop = this.vm().eventLoop();
            this.wake_task = .{
                .ctx = .init(this),
                .callback = deliverWake,
                .on_cancel = cancelWake,
            };
            return .{
                .context = .init(this),
                .handler = onWakeHandler,
                .onDependencyError = onDependencyError,
            };
        }

        pub fn enqueue(this: *Queue, globalObject: *JSGlobalObject, opts: anytype) bun.JSError!void {
            debug("enqueue: {s}", .{opts.specifier});
            bun.assert(!this.closed);
            try this.map.ensureUnusedCapacity(this.vm().allocator, 1);
            const module = try AsyncModule.create(opts, globalObject);
            if (module.parse_result.source.contents_is_recycled) {
                const fs = &this.vm().transpiler.resolver.caches.fs;
                const buffer = fs.sharedBuffer();
                module.source_buffer = buffer.*;
                fs.resetSharedBuffer(buffer);
            }
            module.poll_ref.ref(this.vm());

            this.map.appendAssumeCapacity(module);
            this.vm().packageManager().drainDependencyList();
            if (!this.closed) this.scheduleWake();
        }

        pub fn close(this: *Queue) void {
            if (this.closed) return;
            this.closed = true;
            this.vm().transpiler.resolver.onWakePackageManager = .{};
            if (this.vm().transpiler.resolver.package_manager) |manager| manager.detachWakeHandler();
            if (this.wake_loop) |loop| {
                _ = loop.cancelNativeTask(&this.wake_task);
                this.wake_pending.store(false, .release);
            }
            for (this.map.items) |module| this.retire(module);
            this.map.deinit(this.vm().allocator);
            this.map = .empty;
        }

        fn retire(this: *Queue, module: *AsyncModule) void {
            if (this.polling == module) {
                this.polling_removed = true;
            } else {
                module.destroy();
            }
        }

        pub fn onDependencyError(ctx: PackageManager.WakeHandler.Context, dependency: Dependency, root_dependency_id: Install.DependencyID, err: anyerror) void {
            const this = ctx.get(*Queue);
            if (this.closed) return;
            debug("onDependencyError: {s}", .{this.vm().packageManager().lockfile.str(&dependency.name)});

            var i: usize = 0;
            outer: while (i < this.map.items.len) {
                const module = this.map.items[i];
                const root_dependency_ids = module.parse_result.pending_imports.items(.root_dependency_id);
                for (root_dependency_ids, 0..) |dep, dep_i| {
                    if (dep != root_dependency_id) continue;
                    _ = this.map.orderedRemove(i);
                    module.resolveError(
                        this.vm(),
                        module.parse_result.pending_imports.items(.import_record_id)[dep_i],
                        .{
                            .name = this.vm().packageManager().lockfile.str(&dependency.name),
                            .err = err,
                            .url = "",
                            .version = dependency.version,
                        },
                    ) catch |failure| module.reportFailure(failure);
                    this.retire(module);
                    continue :outer;
                }

                i += 1;
            }
        }
        pub fn onWakeHandler(ctx: PackageManager.WakeHandler.Context, _: *PackageManager) void {
            debug("onWake", .{});
            const this = ctx.get(*Queue);
            this.scheduleWake();
        }

        fn scheduleWake(this: *Queue) void {
            if (!this.wake_pending.swap(true, .acq_rel)) {
                this.wake_loop.?.enqueueNativeTaskConcurrent(&this.wake_task);
            }
        }

        fn deliverWake(ctx: jsc.AnyTaskWithExtraContext.Context, _: *anyopaque) void {
            const this = ctx.get(*Queue);
            this.wake_pending.store(false, .release);
            this.onPoll();
        }

        fn cancelWake(ctx: jsc.AnyTaskWithExtraContext.Context) void {
            const this = ctx.get(*Queue);
            this.close();
        }

        pub fn onPoll(this: *Queue) void {
            if (this.closed) return;
            if (this.running_tasks) {
                this.poll_again = true;
                return;
            }
            this.running_tasks = true;
            this.poll_again = false;
            defer {
                this.running_tasks = false;
                if (this.poll_again and !this.closed) this.scheduleWake();
            }
            debug("onPoll", .{});
            this.runTasks() catch |err| {
                this.failPending(err);
                return;
            };
            this.pollModules();
        }

        fn failPending(this: *Queue, err: anyerror) void {
            var modules = this.map;
            this.map = .empty;
            defer modules.deinit(this.vm().allocator);
            for (modules.items) |module| {
                if (!this.closed) {
                    module.rejectInstallFailure(err) catch |failure| module.reportFailure(failure);
                }
                this.retire(module);
            }
            this.vm().packageManager().endProgressBar();
        }

        fn runTasks(this: *Queue) !void {
            var pm = this.vm().packageManager();

            if (Output.enable_ansi_colors_stderr) {
                pm.startProgressBarIfNone();
                try pm.runTasks(
                    *Queue,
                    this,
                    .{
                        .onExtract = {},
                        .onResolve = onResolve,
                        .onPackageManifestError = onPackageManifestError,
                        .onPackageDownloadError = onPackageDownloadError,
                        .progress_bar = true,
                    },
                    true,
                    PackageManager.Options.LogLevel.default,
                );
            } else {
                try pm.runTasks(
                    *Queue,
                    this,
                    .{
                        .onExtract = {},
                        .onResolve = onResolve,
                        .onPackageManifestError = onPackageManifestError,
                        .onPackageDownloadError = onPackageDownloadError,
                    },
                    true,
                    PackageManager.Options.LogLevel.default_no_progress,
                );
            }
        }

        pub fn onResolve(_: *Queue) void {
            debug("onResolve", .{});
        }

        pub fn onPackageManifestError(
            this: *Queue,
            name: []const u8,
            err: anyerror,
            url: []const u8,
        ) void {
            if (this.closed) return;
            debug("onPackageManifestError: {s}", .{name});

            var i: usize = 0;
            outer: while (i < this.map.items.len) {
                const module = this.map.items[i];
                const tags = module.parse_result.pending_imports.items(.tag);
                for (tags, 0..) |tag, tag_i| {
                    if (tag == .resolve) {
                        const esms = module.parse_result.pending_imports.items(.esm);
                        const esm = esms[tag_i];
                        const string_bufs = module.parse_result.pending_imports.items(.string_buf);

                        if (!strings.eql(esm.name.slice(string_bufs[tag_i]), name)) continue;

                        const versions = module.parse_result.pending_imports.items(.dependency);

                        _ = this.map.orderedRemove(i);
                        module.resolveError(
                            this.vm(),
                            module.parse_result.pending_imports.items(.import_record_id)[tag_i],
                            .{
                                .name = name,
                                .err = err,
                                .url = url,
                                .version = versions[tag_i],
                            },
                        ) catch |failure| module.reportFailure(failure);
                        this.retire(module);
                        continue :outer;
                    }
                }

                i += 1;
            }
        }

        pub fn onPackageDownloadError(
            this: *Queue,
            package_id: Install.PackageID,
            name: []const u8,
            resolution: *const Install.Resolution,
            err: anyerror,
            url: []const u8,
        ) void {
            if (this.closed) return;
            debug("onPackageDownloadError: {s}", .{name});

            var i: usize = 0;
            outer: while (i < this.map.items.len) {
                const module = this.map.items[i];
                const resolution_ids = this.vm().packageManager().lockfile.buffers.resolutions.items;
                const record_ids = module.parse_result.pending_imports.items(.import_record_id);
                const root_dependency_ids = module.parse_result.pending_imports.items(.root_dependency_id);
                for (root_dependency_ids, 0..) |dependency_id, import_id| {
                    if (resolution_ids[dependency_id] != package_id) continue;
                    _ = this.map.orderedRemove(i);
                    module.downloadError(
                        this.vm(),
                        record_ids[import_id],
                        .{
                            .name = name,
                            .resolution = resolution.*,
                            .err = err,
                            .url = url,
                        },
                    ) catch |failure| module.reportFailure(failure);
                    this.retire(module);
                    continue :outer;
                }

                i += 1;
            }
        }

        pub fn pollModules(this: *Queue) void {
            if (this.closed or this.polling != null) return;
            var pm = this.vm().packageManager();
            if (pm.pending_tasks.load(.monotonic) > 0) return;

            var i: usize = 0;

            while (i < this.map.items.len) {
                const module = this.map.items[i];
                this.polling = module;
                this.polling_removed = false;
                var tags = module.parse_result.pending_imports.items(.tag);
                const root_dependency_ids = module.parse_result.pending_imports.items(.root_dependency_id);
                var done_count: usize = 0;
                for (tags, 0..) |tag, tag_i| {
                    const root_id = root_dependency_ids[tag_i];
                    const resolution_ids = pm.lockfile.buffers.resolutions.items;
                    if (root_id >= resolution_ids.len) continue;
                    const package_id = resolution_ids[root_id];

                    switch (tag) {
                        .resolve => {
                            if (package_id == Install.invalid_package_id) {
                                continue;
                            }

                            // if we get here, the package has already been resolved.
                            tags[tag_i] = .download;
                        },
                        .download => {
                            if (package_id == Install.invalid_package_id) {
                                unreachable;
                            }
                        },
                        .done => {
                            done_count += 1;
                            continue;
                        },
                    }

                    if (package_id == Install.invalid_package_id) {
                        continue;
                    }

                    const package = pm.lockfile.packages.get(package_id);
                    bun.assert(package.resolution.tag != .root);

                    var name_and_version_hash: ?u64 = null;
                    var patchfile_hash: ?u64 = null;
                    switch (pm.determinePreinstallState(package, pm.lockfile, &name_and_version_hash, &patchfile_hash)) {
                        .done => {
                            // we are only truly done if all the dependencies are done.
                            const current_tasks = pm.total_tasks;
                            // so if enqueuing all the dependencies produces no new tasks, we are done.
                            pm.enqueueDependencyList(package.dependencies);
                            if (this.polling_removed) break;
                            if (current_tasks == pm.total_tasks) {
                                tags[tag_i] = .done;
                                done_count += 1;
                            }
                        },
                        .extracting => {
                            // we are extracting the package
                            // we need to wait for the next poll
                            continue;
                        },
                        .extract => {},
                        else => {},
                    }
                }

                this.polling = null;
                if (this.polling_removed) {
                    module.destroy();
                    if (this.closed) return;
                    i = 0;
                    continue;
                }
                i = std.mem.indexOfScalar(*AsyncModule, this.map.items, module).?;
                if (done_count == tags.len) {
                    _ = this.map.orderedRemove(i);
                    module.done(this.vm());
                } else {
                    i += 1;
                }
            }
            if (this.map.items.len == 0) {
                // ensure we always end the progress bar
                this.vm().packageManager().endProgressBar();
            }
        }

        pub fn vm(this: *Queue) *VirtualMachine {
            return @alignCast(@fieldParentPtr("modules", this));
        }

        comptime {
            // Ensure VirtualMachine has a field named "modules" of the correct type
            // If this fails, the @fieldParentPtr in vm() above needs to be updated
            const VM = @import("./VirtualMachine.zig");
            if (!@hasField(VM, "modules")) {
                @compileError("VirtualMachine must have a 'modules' field for AsyncModule.Queue.vm() to work");
            }
        }
    };

    fn create(opts: anytype, globalObject: *JSGlobalObject) bun.JSError!*AsyncModule {
        if (opts.parse_result.runtime_transpiler_cache) |cache| {
            bun.assert(cache.entry == null and cache.output_code == null);
        }
        const module = try globalObject.bunVM().allocator.create(AsyncModule);
        errdefer globalObject.bunVM().allocator.destroy(module);
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(globalObject);
        defer scope.deinit();
        const created = try scope.engineIn("promises", "promiseCreate").call(.{});
        var returned_promise = try created.toOwned();
        errdefer returned_promise.deinit();
        var promise: bun.bindgen.PromiseRoot.Optional = .empty;
        errdefer promise.deinit();
        try promise.set(created.operand(&scope).asPromise());

        var buffer_length: usize = 0;
        for ([_][]const u8{
            opts.referrer,
            opts.specifier,
            opts.path.text,
            opts.path.pretty,
            opts.path.namespace,
            opts.parse_result.source.path.text,
            opts.parse_result.source.path.pretty,
            opts.parse_result.source.path.namespace,
        }) |text| {
            buffer_length = std.math.add(usize, buffer_length, text.len) catch return error.OutOfMemory;
        }
        var buf = try bun.StringBuilder.initCapacity(bun.default_allocator, buffer_length);
        const referrer = buf.append(opts.referrer);
        const specifier = buf.append(opts.specifier);
        const path = copyPath(&buf, opts.path);
        const source_path = copyPath(&buf, opts.parse_result.source.path);

        module.* = .{
            .parse_result = opts.parse_result,
            .promise = promise,
            .path = path,
            .specifier = specifier,
            .referrer = referrer,
            .watch_source = opts.watch_source,
            .package_json = opts.package_json,
            .loader = opts.loader.toAPI(),
            .string_buf = buf.allocatedSlice(),
            .globalThis = globalObject,
            .arena = opts.arena,
            .transpiler_cache = if (opts.parse_result.runtime_transpiler_cache) |cache| cache.* else null,
        };
        module.parse_result.source.path = source_path;
        module.parse_result.input_fd = null;
        module.parse_result.runtime_transpiler_cache = if (module.transpiler_cache) |*cache| cache else null;
        opts.promise_ptr.?.* = returned_promise.take();
        return module;
    }

    fn copyPath(buf: *bun.StringBuilder, path: Fs.Path) Fs.Path {
        var copy = path;
        copy.text = buf.append(path.text);
        copy.pretty = buf.append(path.pretty);
        copy.namespace = buf.append(path.namespace);
        return copy;
    }

    pub fn done(this: *AsyncModule, jsc_vm: *VirtualMachine) void {
        jsc_vm.modules.scheduled += 1;
        this.delivery_task = jsc.AnyTaskWithExtraContext.New(AsyncModule, void, onDone).init(this);
        this.delivery_task.on_cancel = cancelDelivery;
        jsc_vm.eventLoop().enqueueNativeTask(&this.delivery_task);
    }

    fn finishDelivery(this: *AsyncModule) void {
        const vm = this.globalThis.bunVM();
        vm.modules.scheduled -= 1;
        if (vm.modules.scheduled == 0) vm.packageManager().endProgressBar();
    }

    fn cancelDelivery(context: jsc.AnyTaskWithExtraContext.Context) void {
        const this = context.get(*AsyncModule);
        this.finishDelivery();
        this.destroy();
    }

    pub fn onDone(this: *AsyncModule, _: *void) void {
        defer this.destroy();
        this.finishDelivery();
        this.finishLoading() catch |err| this.reportFailure(err);
    }

    fn reportFailure(this: *AsyncModule, err: bun.JSError) void {
        this.rejectFailure(err) catch |failure| this.globalThis.reportActiveExceptionAsUnhandled(failure);
    }

    fn rejectFailure(this: *AsyncModule, failure: bun.JSError) bun.JSError!void {
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const reason = try scope.takeThrownException(failure);
        const promise = (try this.promise.view(&scope)) orelse @panic("async module lost its pending promise");
        try scope.engine(PromiseRejectSchema).call(.{ .promise = promise.operand(&scope), .value = reason.operand(&scope).asEngine() });
    }

    fn rejectInstallFailure(this: *AsyncModule, failure: anyerror) bun.JSError!void {
        if (failure == error.OutOfMemory) return this.rejectFailure(error.OutOfMemory);
        const message = try std.fmt.allocPrint(bun.default_allocator, "Failed to install dependencies for \"{s}\": {s}", .{ this.specifier, @errorName(failure) });
        defer bun.default_allocator.free(message);
        var bound_message = try bun.bindgen.DOMString.fromUTF8(message);
        defer bound_message.deinit();
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const reason = try scope.engine(CreateErrorSchema).call(.{ .message = bound_message.operand() });
        try scope.engine(PromiseRejectSchema).call(.{ .promise = this.promise.operand(&scope) orelse @panic("async module has no pending promise"), .value = reason.operand(&scope).asEngine() });
    }

    fn finishLoading(this: *AsyncModule) bun.JSError!void {
        const jsc_vm = this.globalThis.bunVM();
        var log = logger.Log.init(jsc_vm.allocator);
        defer log.deinit();
        var bound_specifier = try bun.bindgen.DOMString.fromUTF8(this.specifier);
        const specifier_string = bound_specifier.takeBunString();
        defer specifier_string.deref();
        var result: jsc.ResolvedSourceResult = undefined;
        outer: {
            result = jsc.ResolvedSourceResult.ok(this.resumeLoadingModule(&log) catch |err| {
                switch (err) {
                    error.OutOfMemory, error.JSTerminated => |failure| return failure,
                    error.JSError => {
                        result = .fail(try jsc.ModuleLoaderEngine.takeFailureAsRoot(this.globalThis, error.JSError));
                        break :outer;
                    },
                    else => {
                        var bound_referrer = try bun.bindgen.DOMString.fromUTF8(this.referrer);
                        const referrer_string = bound_referrer.takeBunString();
                        defer referrer_string.deref();
                        try VirtualMachine.processFetchLog(
                            this.globalThis,
                            specifier_string,
                            referrer_string,
                            &log,
                            &result,
                            err,
                        );
                        break :outer;
                    },
                }
            });
        }

        defer result.deinit();
        try fulfillFetchPromise(
            this.globalThis,
            &this.promise,
            &result,
            specifier_string,
        );
    }

    fn fulfillFetchPromise(
        globalThis: *JSGlobalObject,
        promise: *const bun.bindgen.PromiseRoot.Optional,
        result: *jsc.ResolvedSourceResult,
        specifier: bun.String,
    ) bun.JSError!void {
        var bound_specifier = bun.bindgen.DOMString.fromBunString(specifier.dupeRef()) catch
            return globalThis.throwOutOfMemory();
        defer bound_specifier.deinit();
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(globalThis);
        defer scope.deinit();
        var engine_args: bun.bindgen.Args(FulfillAsyncModuleSchema) = .{
            .promise = promise.operand(&scope) orelse @panic("async module has no pending promise"),
            .result = result.takeWireAs(bun.bindgen.EngineTransferredArgumentType(FulfillAsyncModuleSchema, "result"), &scope) catch
                return globalThis.throwOutOfMemory(),
            .specifier = bound_specifier.operand(),
        };
        try scope.engine(FulfillAsyncModuleSchema).call(&engine_args);
    }

    pub fn fulfill(
        globalThis: *JSGlobalObject,
        promise: *const bun.bindgen.PromiseRoot.Optional,
        resolved_source: *ResolvedSource,
        err: ?anyerror,
        specifier_: bun.String,
        referrer_: bun.String,
        log: *logger.Log,
    ) bun.JSError!void {
        defer log.deinit();
        defer resolved_source.deinit();
        var specifier = specifier_;
        var referrer = referrer_;
        defer {
            specifier.deref();
            referrer.deref();
        }

        var result: jsc.ResolvedSourceResult = undefined;
        if (err) |e| {
            if (e == error.JSError or e == error.OutOfMemory) {
                result = .fail(try jsc.ModuleLoaderEngine.takeFailureAsRoot(globalThis, @errorCast(e)));
            } else if (e == error.JSTerminated) {
                return error.JSTerminated;
            } else {
                try VirtualMachine.processFetchLog(
                    globalThis,
                    specifier,
                    referrer,
                    log,
                    &result,
                    e,
                );
            }
        } else {
            result = jsc.ResolvedSourceResult.ok(resolved_source.*);
            resolved_source.* = .{};
        }
        defer result.deinit();

        debug("fulfill: {f}", .{specifier});

        try fulfillFetchPromise(globalThis, promise, &result, specifier);
    }

    pub fn resolveError(this: *AsyncModule, vm: *VirtualMachine, import_record_id: u32, result: PackageResolveError) !void {
        if (result.err == error.OutOfMemory) return error.OutOfMemory;
        const globalThis = this.globalThis;

        const msg: []u8 = try switch (result.err) {
            error.PackageManifestHTTP400 => std.fmt.allocPrint(
                bun.default_allocator,
                "HTTP 400 while resolving package '{s}' at '{s}'",
                .{ result.name, result.url },
            ),
            error.PackageManifestHTTP401 => std.fmt.allocPrint(
                bun.default_allocator,
                "HTTP 401 while resolving package '{s}' at '{s}'",
                .{ result.name, result.url },
            ),
            error.PackageManifestHTTP402 => std.fmt.allocPrint(
                bun.default_allocator,
                "HTTP 402 while resolving package '{s}' at '{s}'",
                .{ result.name, result.url },
            ),
            error.PackageManifestHTTP403 => std.fmt.allocPrint(
                bun.default_allocator,
                "HTTP 403 while resolving package '{s}' at '{s}'",
                .{ result.name, result.url },
            ),
            error.PackageManifestHTTP404 => std.fmt.allocPrint(
                bun.default_allocator,
                "Package '{s}' was not found",
                .{result.name},
            ),
            error.PackageManifestHTTP4xx => std.fmt.allocPrint(
                bun.default_allocator,
                "HTTP 4xx while resolving package '{s}' at '{s}'",
                .{ result.name, result.url },
            ),
            error.PackageManifestHTTP5xx => std.fmt.allocPrint(
                bun.default_allocator,
                "HTTP 5xx while resolving package '{s}' at '{s}'",
                .{ result.name, result.url },
            ),
            error.DistTagNotFound, error.NoMatchingVersion => brk: {
                const prefix: []const u8 = if (result.err == error.NoMatchingVersion and result.version.tag == .npm and result.version.value.npm.version.isExact())
                    "Version not found"
                else if (result.version.tag == .npm and !result.version.value.npm.version.isExact())
                    "No matching version found"
                else
                    "No match found";

                break :brk std.fmt.allocPrint(
                    bun.default_allocator,
                    "{s} '{s}' for package '{s}' (but package exists)",
                    .{ prefix, vm.packageManager().lockfile.str(&result.version.literal), result.name },
                );
            },
            else => |err| std.fmt.allocPrint(
                bun.default_allocator,
                "{s} resolving package '{s}' at '{s}'",
                .{ bun.asByteSlice(@errorName(err)), result.name, result.url },
            ),
        };
        defer bun.default_allocator.free(msg);

        const name: []const u8 = switch (result.err) {
            error.NoMatchingVersion => "PackageVersionNotFound",
            error.DistTagNotFound => "PackageTagNotFound",
            error.PackageManifestHTTP403 => "PackageForbidden",
            error.PackageManifestHTTP404 => "PackageNotFound",
            else => "PackageResolveError",
        };

        const location = logger.rangeData(&this.parse_result.source, this.parse_result.ast.import_records.at(import_record_id).range, "").location.?;
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(globalThis);
        defer scope.deinit();
        const error_value = try createAsyncModuleError(&scope, .{
            .message = msg,
            .name = name,
            .url = if (result.url.len > 0) result.url else null,
            .pkg = result.name,
            .specifier = this.specifier,
            .source_url = this.parse_result.source.path.text,
            .line = location.line,
            .line_text = location.line_text,
            .column = location.column,
            .referrer = if (this.referrer.len > 0 and !strings.eqlComptime(this.referrer, "undefined")) this.referrer else null,
        });

        try scope.engine(PromiseRejectAsHandledSchema).call(.{
            .promise = this.promise.operand(&scope) orelse @panic("async module has no pending promise"),
            .value = error_value.operand(&scope).asEngine(),
        });
    }
    pub fn downloadError(this: *AsyncModule, vm: *VirtualMachine, import_record_id: u32, result: PackageDownloadError) !void {
        if (result.err == error.OutOfMemory) return error.OutOfMemory;
        const globalThis = this.globalThis;

        const msg_args = .{
            result.name,
            result.resolution.fmt(vm.packageManager().lockfile.buffers.string_bytes.items, .any),
        };

        const msg: []u8 = try switch (result.err) {
            error.TarballHTTP400 => std.fmt.allocPrint(
                bun.default_allocator,
                "HTTP 400 downloading package '{s}@{f}'",
                msg_args,
            ),
            error.TarballHTTP401 => std.fmt.allocPrint(
                bun.default_allocator,
                "HTTP 401 downloading package '{s}@{f}'",
                msg_args,
            ),
            error.TarballHTTP402 => std.fmt.allocPrint(
                bun.default_allocator,
                "HTTP 402 downloading package '{s}@{f}'",
                msg_args,
            ),
            error.TarballHTTP403 => std.fmt.allocPrint(
                bun.default_allocator,
                "HTTP 403 downloading package '{s}@{f}'",
                msg_args,
            ),
            error.TarballHTTP404 => std.fmt.allocPrint(
                bun.default_allocator,
                "HTTP 404 downloading package '{s}@{f}'",
                msg_args,
            ),
            error.TarballHTTP4xx => std.fmt.allocPrint(
                bun.default_allocator,
                "HTTP 4xx downloading package '{s}@{f}'",
                msg_args,
            ),
            error.TarballHTTP5xx => std.fmt.allocPrint(
                bun.default_allocator,
                "HTTP 5xx downloading package '{s}@{f}'",
                msg_args,
            ),
            error.TarballFailedToExtract => std.fmt.allocPrint(
                bun.default_allocator,
                "Failed to extract tarball for package '{s}@{f}'",
                msg_args,
            ),
            else => |err| std.fmt.allocPrint(
                bun.default_allocator,
                "{s} downloading package '{s}@{f}'",
                .{
                    bun.asByteSlice(@errorName(err)),
                    result.name,
                    result.resolution.fmt(vm.packageManager().lockfile.buffers.string_bytes.items, .any),
                },
            ),
        };
        defer bun.default_allocator.free(msg);

        const name: []const u8 = switch (result.err) {
            error.TarballFailedToExtract => "PackageExtractionError",
            error.TarballHTTP403 => "TarballForbiddenError",
            error.TarballHTTP404 => "TarballNotFoundError",
            else => "TarballDownloadError",
        };

        const location = logger.rangeData(&this.parse_result.source, this.parse_result.ast.import_records.at(import_record_id).range, "").location.?;
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(globalThis);
        defer scope.deinit();
        const error_value = try createAsyncModuleError(&scope, .{
            .message = msg,
            .name = name,
            .url = if (result.url.len > 0) result.url else null,
            .pkg = result.name,
            .specifier = this.parse_result.ast.import_records.at(import_record_id).path.text,
            .source_url = this.parse_result.source.path.text,
            .line = location.line,
            .line_text = location.line_text,
            .column = location.column,
            .referrer = if (this.specifier.len > 0 and !strings.eqlComptime(this.specifier, "undefined")) this.specifier else null,
        });

        try scope.engine(PromiseRejectAsHandledSchema).call(.{
            .promise = this.promise.operand(&scope) orelse @panic("async module has no pending promise"),
            .value = error_value.operand(&scope).asEngine(),
        });
    }

    pub fn resumeLoadingModule(this: *AsyncModule, log: *logger.Log) !ResolvedSource {
        debug("resumeLoadingModule: {s}", .{this.specifier});
        const parse_result = &this.parse_result;
        const path = this.path;
        var jsc_vm = VirtualMachine.get();
        const specifier = this.specifier;
        const old_log = jsc_vm.log;

        jsc_vm.transpiler.linker.log = log;
        jsc_vm.transpiler.log = log;
        jsc_vm.transpiler.resolver.log = log;
        jsc_vm.packageManager().log = log;
        defer {
            jsc_vm.transpiler.linker.log = old_log;
            jsc_vm.transpiler.log = old_log;
            jsc_vm.transpiler.resolver.log = old_log;
            jsc_vm.packageManager().log = old_log;
        }

        // We _must_ link because:
        // - node_modules bundle won't be properly
        try jsc_vm.transpiler.linker.link(
            path,
            parse_result,
            jsc_vm.origin,
            .absolute_path,
            false,
            true,
        );
        var printer = VirtualMachine.source_code_printer.?.*;
        printer.ctx.reset();

        {
            var mapper = jsc_vm.sourceMapHandler(&printer);
            defer VirtualMachine.source_code_printer.?.* = printer;
            _ = try jsc_vm.transpiler.printWithSourceMap(
                parse_result.*,
                @TypeOf(&printer),
                &printer,
                .esm_ascii,
                mapper.get(),
                null,
            );
        }

        if (comptime Environment.dump_source) {
            dumpSource(jsc_vm, specifier, &printer);
        }

        if (jsc_vm.isWatcherEnabled()) {
            const specifier_string = bun.String.cloneUTF8(specifier);
            defer specifier_string.deref();
            var resolved_source = jsc_vm.refCountedResolvedSource(printer.ctx.written, specifier_string, path.text, null, false);

            if (this.watch_source) {
                if (std.fs.path.isAbsolute(path.text) and !strings.contains(path.text, "node_modules")) {
                    _ = jsc_vm.bun_watcher.addFileByPathSlow(path.text, options.Loader.fromAPI(this.loader), this.package_json);
                }
            }

            resolved_source.is_commonjs_module = parse_result.ast.has_commonjs_export_names or parse_result.ast.exports_kind == .cjs;

            return resolved_source;
        }

        return ResolvedSource{
            .source_code = bun.String.cloneLatin1(printer.ctx.getWritten()),
            .source_url = String.cloneUTF8(path.text),
            .is_commonjs_module = parse_result.ast.has_commonjs_export_names or parse_result.ast.exports_kind == .cjs,
        };
    }

    fn destroy(this: *AsyncModule) void {
        const vm = this.globalThis.bunVM();
        this.poll_ref.unref(vm);
        this.promise.deinit();
        // The arena owns the AST; pending imports and recycled file storage have separate owners.
        bun.resolver.PendingResolution.deinitListItems(this.parse_result.pending_imports, bun.default_allocator);
        this.parse_result.pending_imports.deinit(bun.default_allocator);
        if (this.source_buffer) |*buffer| buffer.deinit();
        if (this.transpiler_cache) |*cache| {
            if (cache.output_code) |output_code| output_code.deref();
            bun.assert(cache.entry == null);
        }
        this.arena.deinit();
        vm.allocator.destroy(this.arena);
        bun.default_allocator.free(this.string_buf);
        vm.allocator.destroy(this);
    }
};

const Dependency = @import("../install/dependency.zig");
const Fs = @import("../resolver/fs.zig");
const options = @import("../bundler/options.zig");
const std = @import("std");
const PackageJSON = @import("../resolver/package_json.zig").PackageJSON;
const dumpSource = @import("./RuntimeTranspilerStore.zig").dumpSource;

const Install = @import("../install/install.zig");
const PackageManager = @import("../install/install.zig").PackageManager;

const bun = @import("bun");
const Async = bun.Async;
const Environment = bun.Environment;
const Output = bun.Output;
const String = bun.String;
const logger = bun.logger;
const strings = bun.strings;
const ParseResult = bun.transpiler.ParseResult;
const api = bun.schema.api;

const jsc = bun.jsc;
const JSGlobalObject = bun.jsc.JSGlobalObject;
const ResolvedSource = bun.jsc.ResolvedSource;
const VirtualMachine = bun.jsc.VirtualMachine;
