path_or_port: ?[]const u8 = null,
from_environment_variable: []const u8 = "",
script_execution_context_id: u32 = 0,
next_debugger_id: u64 = 1,
poll_ref: bun.Async.KeepAlive = .{},
wait_for_connection: Wait = .off,
// wait_for_connection: bool = false,
set_breakpoint_on_first_line: bool = false,
mode: enum {
    /// Bun acts as the server. https://debug.bun.sh/ uses this
    listen,
    /// Bun connects to this path. The VSCode extension uses this.
    connect,
} = .listen,

test_reporter_agent: TestReporterAgent = .{},
lifecycle_reporter_agent: LifecycleAgent = .{},
frontend_dev_server_agent: BunFrontendDevServerAgent = .{},
http_server_agent: HTTPServerAgent = .{},
must_block_until_connected: bool = false,
thread: ?std.Thread = null,
started: bool = false,
startup_event: std.Io.Event = .unset,
startup_result: StartupResult = .pending,
stop_requested: std.atomic.Value(bool) = .init(false),
thread_vm_mutex: std.Io.Mutex = .init,
thread_vm: ?*VirtualMachine = null,

pub const Wait = enum { off, shortly, forever };
pub const StartupResult = union(enum) {
    pending,
    ready,
    stopped,
    failed: anyerror,
};

pub const log = Output.scoped(.debugger, .visible);

pub fn waitForDebuggerIfNecessary(this: *VirtualMachine) !void {
    const debugger = &(this.debugger orelse return);
    bun.analytics.Features.debugger += 1;
    if (!debugger.must_block_until_connected) {
        return;
    }
    defer debugger.must_block_until_connected = false;

    Debugger.log("spin", .{});
    debugger.startup_event.waitUncancelable(this.pinned_threads.io());
    switch (debugger.startup_result) {
        .ready => {},
        .failed => |err| return err,
        .stopped => return error.DebuggerStopped,
        .pending => unreachable,
    }
    if (comptime Environment.enable_logs)
        Debugger.log("waitForDebugger: {f}", .{Output.ElapsedFormatter{
            .colors = Output.enable_ansi_colors_stderr,
            .duration_ns = @truncate(@as(u128, @intCast(bun.awakeNanoseconds(this.io) - bun.cli.start_time))),
        }});

    // Sleep up to 30ms for automatic inspection.
    const wait_for_connection_delay_ms = 30;

    var deadline: bun.timespec = if (debugger.wait_for_connection == .shortly) bun.timespec.now(.force_real_time).addMs(wait_for_connection_delay_ms) else undefined;

    if (comptime Environment.isWindows) {
        // TODO: remove this when tickWithTimeout actually works properly on Windows.
        if (debugger.wait_for_connection == .shortly) {
            uv.uv_update_time(this.uvLoop());
            var timer = bun.handleOom(bun.default_allocator.create(uv.Timer));
            timer.* = std.mem.zeroes(uv.Timer);
            timer.init(this.uvLoop());
            const onDebuggerTimer = struct {
                fn call(handle: *uv.Timer) callconv(.c) void {
                    const vm = VirtualMachine.get();
                    vm.debugger.?.poll_ref.unref(vm);
                    uv.uv_close(@ptrCast(handle), deinitTimer);
                }

                fn deinitTimer(handle: *anyopaque) callconv(.c) void {
                    bun.default_allocator.destroy(@as(*uv.Timer, @ptrCast(@alignCast(handle))));
                }
            }.call;
            timer.start(wait_for_connection_delay_ms, 0, &onDebuggerTimer);
            timer.ref();
        }
    }

    while (debugger.wait_for_connection != .off) {
        this.eventLoop().tick();
        switch (debugger.wait_for_connection) {
            .forever => {
                this.eventLoop().autoTickActive();

                if (comptime Environment.enable_logs)
                    log("waited: {d}ns", .{@as(i64, @truncate(bun.awakeNanoseconds(this.io) - bun.cli.start_time))});
            },
            .shortly => {
                // Handle .incrementRefConcurrently
                if (comptime Environment.isPosix) {
                    const pending_unref = this.pending_unref_counter;
                    if (pending_unref > 0) {
                        this.pending_unref_counter = 0;
                        this.uwsLoop().unrefCount(pending_unref);
                    }
                }

                this.uwsLoop().tickWithTimeout(&deadline);

                if (comptime Environment.enable_logs)
                    log("waited: {d}ns", .{@as(i64, @truncate(bun.awakeNanoseconds(this.io) - bun.cli.start_time))});

                const elapsed = bun.timespec.now(.force_real_time);
                if (elapsed.order(&deadline) != .lt) {
                    debugger.poll_ref.unref(this);
                    log("Timed out waiting for the debugger", .{});
                    break;
                }
            },
            .off => {
                break;
            },
        }
    }
}

pub fn create(this: *VirtualMachine, globalObject: *JSGlobalObject) !void {
    log("create", .{});
    const debugger = &this.debugger.?;
    if (debugger.started) return;
    debugger.script_execution_context_id = try bun.bindgen.Engine(CreateJSDebuggerShim).call(globalObject, .{
        .pauseOnStart = debugger.wait_for_connection != .off,
    });
    debugger.thread = try std.Thread.spawn(.{}, startJSDebuggerThread, .{this});
    debugger.started = true;
    this.eventLoop().ensureWaker();

    if (debugger.wait_for_connection != .off) {
        debugger.poll_ref.ref(this);
        debugger.must_block_until_connected = true;
    }
}

fn signalStartup(debugger: *Debugger, owner: *VirtualMachine, result: StartupResult) void {
    debugger.startup_result = result;
    debugger.startup_event.set(owner.pinned_threads.io());
    owner.eventLoop().wakeup();
}

fn bindStart(args: bun.bindgen.Args(DebuggerStartSchema)) bun.bindgen.Return(DebuggerStartSchema) {
    const owner: *VirtualMachine = @ptrCast(@alignCast(args.owner));
    const vm = VirtualMachine.get();
    start(owner) catch |err| {
        const result: StartupResult = switch (err) {
            error.OutOfMemory => .{ .failed = error.OutOfMemory },
            error.JSTerminated => .stopped,
            error.JSError => failed: {
                vm.printFailureToConsole(err);
                break :failed .{ .failed = error.DebuggerStartupFailed };
            },
        };
        signalStartup(&owner.debugger.?, owner, result);
    };
    prepareDebuggerShutdown(owner, vm);
}

pub const InspectorConnection = struct {
    bindgen_state: bun.bindgen.ClassState = .{},
    channel: InspectorChannel,

    pub fn destroy(this: *InspectorConnection) void {
        this.channel.deinit();
        bun.default_allocator.destroy(this);
    }
};

fn createConnection(
    context: bun.bindgen.CallContext(CreateConnectionSchema),
    args: bun.bindgen.Args(CreateConnectionSchema),
) bun.JSError!bun.bindgen.Return(CreateConnectionSchema) {
    const callback = args.onMessage orelse return null;
    const native = owned: {
        var channel = try context.engineIn("BunDebugger", "createInspectorConnection").call(.{
            .scriptId = args.scriptId,
            .shouldNotRef = args.shouldNotRef,
            .onMessage = callback.operand(context),
        }) orelse return null;
        errdefer channel.deinit();
        const result = try bun.default_allocator.create(InspectorConnection);
        result.* = .{ .channel = channel.take() };
        break :owned result;
    };
    return try InspectorConnectionClass.adoptResult(native, context);
}

fn send(
    context: bun.bindgen.CallContext(SendSchema),
    args: bun.bindgen.Args(SendSchema),
) bun.JSError!void {
    const receiver = args.bindingThis orelse return;
    const message = args.message orelse return;
    const connection = receiver.get(InspectorConnection);
    switch (message) {
        .string => |value| try context.engineIn("BunDebugger", "sendInspectorMessages").call(.{
            .connection = &connection.channel,
            .messages = &.{value.operand()},
        }),
        .strings => |values| {
            const operation = context.engineIn("BunDebugger", "sendInspectorMessages");
            try operation.call(.{
                .connection = &connection.channel,
                .messages = try operation.argument("messages", values),
            });
        },
    }
}

fn disconnect(
    context: bun.bindgen.CallContext(DisconnectSchema),
    args: bun.bindgen.Args(DisconnectSchema),
) bun.JSError!void {
    const receiver = args.bindingThis orelse return;
    const connection = receiver.get(InspectorConnection);
    try context.engineIn("BunDebugger", "disconnectInspectorConnection").call(.{ .connection = &connection.channel });
}

pub fn startJSDebuggerThread(other_vm: *VirtualMachine) void {
    const debugger = &other_vm.debugger.?;
    var arena = bun.MimallocArena.init();
    defer arena.deinit();
    defer bun.deleteAllPoolsForThreadExit();
    defer jsc.wtf.prepareForThreadExit();
    Output.Source.configureNamedThread("Debugger");
    log("startJSDebuggerThread", .{});

    const vm = createDebuggerVM(other_vm, &arena) catch |err| {
        signalStartup(debugger, other_vm, .{ .failed = err });
        return;
    };

    vm.transpiler.configureDefines() catch |err| {
        signalStartup(debugger, other_vm, .{ .failed = err });
        // Publish the initialized VM so start() can use the normal teardown path.
    };
    vm.is_main_thread = false;
    vm.eventLoop().ensureWaker();

    const io = other_vm.pinned_threads.io();
    debugger.thread_vm_mutex.lockUncancelable(io);
    debugger.thread_vm = vm;
    debugger.thread_vm_mutex.unlock(io);

    bun.bindgen.Engine(DebuggerRunWithAPILockShim).call(.{
        .vm = @ptrCast(vm.global.vm()),
        .owner = @ptrCast(other_vm),
    });
    teardownDebuggerVM(vm);
}

fn createDebuggerVM(owner: *VirtualMachine, arena: *bun.MimallocArena) !*VirtualMachine {
    const allocator = arena.allocator();
    const env_map = try allocator.create(DotEnv.Map);
    env_map.* = DotEnv.Map.init(allocator);
    const env_loader = try allocator.create(DotEnv.Loader);
    env_loader.* = DotEnv.Loader.init(env_map, allocator);
    const vm = try VirtualMachine.init(.{
        .allocator = allocator,
        .io = owner.pinned_threads.io(),
        .pinned_threads = owner.pinned_threads,
        .args = std.mem.zeroes(bun.schema.api.TransformOptions),
        .store_fd = false,
        .env_loader = env_loader,
        .debugger = null,
    });
    vm.arena = arena;
    return vm;
}

fn prepareDebuggerShutdown(owner: *VirtualMachine, vm: *VirtualMachine) void {
    const debugger = &owner.debugger.?;
    const io = owner.pinned_threads.io();
    debugger.thread_vm_mutex.lockUncancelable(io);
    debugger.thread_vm = null;
    debugger.thread_vm_mutex.unlock(io);

    vm.jsc_vm.clearHasTerminationRequest();
    vm.is_shutting_down = true;
    bun.assert(vm.stopChildThreads(null) == .completed);
    vm.onExit();
    vm.prepareForJSCDestruction();
}

fn teardownDebuggerVM(vm: *VirtualMachine) void {
    const loop = vm.uwsLoop();
    bun.bindgen.Engine(TeardownThreadJSCVMShim).call(.{ .globalObject = @ptrCast(vm.global) });
    jsc.setLoopVM(loop, null);
    vm.gc_controller.deinit();
    if (comptime Environment.isWindows) {
        bun.windows.libuv.Loop.shutdown();
    }
    vm.deinit();
}

pub fn stopAndJoin(owner: *VirtualMachine) void {
    const debugger = &(owner.debugger orelse return);
    const thread = debugger.thread orelse return;

    debugger.stop_requested.store(true, .release);
    const io = owner.pinned_threads.io();
    debugger.thread_vm_mutex.lockUncancelable(io);
    if (debugger.thread_vm) |vm| {
        vm.eventLoop().wakeup();
    }
    debugger.thread_vm_mutex.unlock(io);

    thread.join();
    debugger.thread = null;
    bun.assert(debugger.thread_vm == null);
}

fn bindDidConnect(
    args: bun.bindgen.Args(DebuggerDidConnectSchema),
) bun.bindgen.Return(DebuggerDidConnectSchema) {
    _ = args;
    var this = VirtualMachine.get();
    if (this.debugger.?.wait_for_connection != .off) {
        this.debugger.?.wait_for_connection = .off;
        this.debugger.?.poll_ref.unref(this);
        this.eventLoop().wakeup();
    }
}

fn start(other_vm: *VirtualMachine) bun.JSError!void {
    var this = VirtualMachine.get();
    const debugger = &other_vm.debugger.?;
    const loop = this.eventLoop();

    switch (debugger.startup_result) {
        .failed => return,
        else => {},
    }

    if (debugger.stop_requested.load(.acquire)) {
        signalStartup(debugger, other_vm, .stopped);
        return;
    }

    if (debugger.from_environment_variable.len > 0) {
        var bound_url = try bun.bindgen.DOMString.fromUTF8(debugger.from_environment_variable);
        defer bound_url.deinit();

        loop.enter();
        defer loop.exit();
        try bun.bindgen.Engine(StartJSDebuggerThreadShim).call(this.global, .{
            .scriptId = debugger.script_execution_context_id,
            .portOrPath = bound_url.operand(),
            .isAutomatic = true,
            .isURLServer = debugger.mode == .connect,
        });
    }

    if (debugger.path_or_port) |path_or_port| {
        var bound_url = try bun.bindgen.DOMString.fromUTF8(path_or_port);
        defer bound_url.deinit();

        loop.enter();
        defer loop.exit();
        try bun.bindgen.Engine(StartJSDebuggerThreadShim).call(this.global, .{
            .scriptId = debugger.script_execution_context_id,
            .portOrPath = bound_url.operand(),
            .isAutomatic = false,
            .isURLServer = debugger.mode == .connect,
        });
    }

    this.global.handleRejectedPromises();

    if (this.log.msgs.items.len > 0) {
        this.log.print(Output.errorWriter()) catch {};
        Output.prettyErrorln("\n", .{});
        Output.flush();
    }

    log("wake", .{});
    signalStartup(debugger, other_vm, .ready);

    if (debugger.stop_requested.load(.acquire)) {
        return;
    }
    this.eventLoop().tick();

    other_vm.eventLoop().wakeup();

    while (!debugger.stop_requested.load(.acquire)) {
        while (!debugger.stop_requested.load(.acquire) and this.isEventLoopAlive()) {
            this.tick();
            this.eventLoop().autoTickActive();
        }

        if (debugger.stop_requested.load(.acquire)) break;
        this.eventLoop().tickPossiblyForever();
    }
}

pub const AsyncTaskTracker = struct {
    id: u64,

    pub fn init(vm: *VirtualMachine) AsyncTaskTracker {
        return .{ .id = vm.nextAsyncTaskID() };
    }

    pub fn didSchedule(this: AsyncTaskTracker, globalObject: *JSGlobalObject) void {
        if (this.id == 0) return;

        didScheduleAsyncCall(globalObject, AsyncCallType.EventListener, this.id, true);
    }

    pub fn didCancel(this: AsyncTaskTracker, globalObject: *JSGlobalObject) void {
        if (this.id == 0) return;

        didCancelAsyncCall(globalObject, AsyncCallType.EventListener, this.id);
    }

    pub fn willDispatch(this: AsyncTaskTracker, globalObject: *JSGlobalObject) void {
        if (this.id == 0) {
            return;
        }

        willDispatchAsyncCall(globalObject, AsyncCallType.EventListener, this.id);
    }

    pub fn didDispatch(this: AsyncTaskTracker, globalObject: *JSGlobalObject) void {
        if (this.id == 0) {
            return;
        }

        didDispatchAsyncCall(globalObject, AsyncCallType.EventListener, this.id);
    }
};

pub const AsyncCallType = @FieldType(bun.bindgen.Args(DebuggerDidScheduleAsyncCallShim), "callType");
pub fn didScheduleAsyncCall(globalObject: *JSGlobalObject, call: AsyncCallType, id: u64, single_shot: bool) void {
    bun.bindgen.Engine(DebuggerDidScheduleAsyncCallShim).call(globalObject, .{
        .callType = call,
        .callbackId = id,
        .singleShot = single_shot,
    });
}
pub fn didCancelAsyncCall(globalObject: *JSGlobalObject, call: AsyncCallType, id: u64) void {
    bun.bindgen.Engine(DebuggerDidCancelAsyncCallShim).call(globalObject, .{
        .callType = call,
        .callbackId = id,
    });
}
pub fn didDispatchAsyncCall(globalObject: *JSGlobalObject, call: AsyncCallType, id: u64) void {
    bun.bindgen.Engine(DebuggerDidDispatchAsyncCallShim).call(globalObject, .{
        .callType = call,
        .callbackId = id,
    });
}
pub fn willDispatchAsyncCall(globalObject: *JSGlobalObject, call: AsyncCallType, id: u64) void {
    bun.bindgen.Engine(DebuggerWillDispatchAsyncCallShim).call(globalObject, .{
        .callType = call,
        .callbackId = id,
    });
}

pub const TestReporterAgent = struct {
    handle: ?*Handle = null,
    const debug = Output.scoped(.TestReporterAgent, .visible);

    pub const TestStatus = @FieldType(bun.bindgen.Args(InspectorTestReporterAgentReportTestEndShim), "status");
    pub const TestType = @FieldType(bun.bindgen.Args(InspectorTestReporterAgentReportTestFoundShim), "itemType");

    pub const Handle = opaque {
        pub fn reportTestFound(this: *Handle, caller_frame: *bun.bindgen.CallerFrameHandle, testId: i32, name: *bun.String, item_type: TestType, parentId: i32) void {
            var bound_name = bun.bindgen.DOMString.fromBunString(name.dupeRef()) catch bun.outOfMemory();
            defer bound_name.deinit();
            bun.bindgen.Engine(InspectorTestReporterAgentReportTestFoundShim).call(.{
                .agent = @ptrCast(this),
                .callFrame = @ptrCast(caller_frame),
                .testId = testId,
                .name = bound_name.operand(),
                .itemType = item_type,
                .parentId = parentId,
            });
        }

        pub fn reportTestFoundWithLocation(this: *Handle, testId: i32, name: *bun.String, item_type: TestType, parentId: i32, sourceURL: *bun.String, line: i32) void {
            var bound_name = bun.bindgen.DOMString.fromBunString(name.dupeRef()) catch bun.outOfMemory();
            defer bound_name.deinit();
            var bound_source_url = bun.bindgen.DOMString.fromBunString(sourceURL.dupeRef()) catch bun.outOfMemory();
            defer bound_source_url.deinit();
            bun.bindgen.Engine(InspectorTestReporterAgentReportTestFoundWithLocationShim).call(.{
                .agent = @ptrCast(this),
                .testId = testId,
                .name = bound_name.operand(),
                .itemType = item_type,
                .parentId = parentId,
                .sourceURL = bound_source_url.operand(),
                .line = line,
            });
        }

        pub fn reportTestStart(this: *Handle, testId: c_int) void {
            bun.bindgen.Engine(InspectorTestReporterAgentReportTestStartShim).call(.{
                .agent = @ptrCast(this),
                .testId = testId,
            });
        }

        pub fn reportTestEnd(this: *Handle, testId: c_int, bunTestStatus: TestStatus, elapsed: f64) void {
            bun.bindgen.Engine(InspectorTestReporterAgentReportTestEndShim).call(.{
                .agent = @ptrCast(this),
                .testId = testId,
                .status = bunTestStatus,
                .elapsed = elapsed,
            });
        }
    };
    fn bindSetAgent(
        args: bun.bindgen.Args(SetInspectorTestReporterAgentSchema),
    ) bun.bindgen.Return(SetInspectorTestReporterAgentSchema) {
        const agent: *Handle = @ptrCast(args.agent);
        if (VirtualMachine.get().debugger) |*debugger| {
            if (args.enabled) {
                debug("enable", .{});
                debugger.test_reporter_agent.handle = agent;
                retroactivelyReportDiscoveredTests(agent);
            } else if (debugger.test_reporter_agent.handle == agent) {
                debug("disable", .{});
                debugger.test_reporter_agent.handle = null;
            }
        }
    }

    /// When TestReporter.enable is called after test collection has started/finished,
    /// we need to retroactively assign test IDs and report discovered tests.
    fn retroactivelyReportDiscoveredTests(agent: *Handle) void {
        const Jest = jsc.Jest.Jest;
        const runner = Jest.runner orelse return;
        const active_file = runner.bun_test_root.active_file.get() orelse return;

        // Only report if we're in collection or execution phase (tests have been discovered)
        switch (active_file.phase) {
            .collection, .execution => {},
            .done => return,
        }

        // Get the file path for source location info
        const file_path = runner.files.get(active_file.file_id).source.path.text;
        var source_url = bun.String.cloneUTF8(file_path);
        defer source_url.deref();

        // Track the maximum ID we assign
        var max_id: i32 = 0;

        // Recursively report all discovered tests starting from root scope
        const root_scope = active_file.collection.root_scope;
        retroactivelyReportScope(agent, root_scope, -1, &max_id, &source_url);

        debug("retroactively reported {} tests", .{max_id});
    }

    fn retroactivelyReportScope(agent: *Handle, scope: *bun_test.DescribeScope, parent_id: i32, max_id: *i32, source_url: *bun.String) void {
        for (scope.entries.items) |*entry| {
            switch (entry.*) {
                .describe => |describe| {
                    // Only report and assign ID if not already assigned
                    if (describe.base.test_id_for_debugger == 0) {
                        max_id.* += 1;
                        const test_id = max_id.*;
                        // Assign the ID so start/end events will fire during execution
                        describe.base.test_id_for_debugger = test_id;
                        var name = bun.String.cloneUTF8(describe.base.name orelse "(unnamed)");
                        defer name.deref();
                        agent.reportTestFoundWithLocation(
                            test_id,
                            &name,
                            .describe,
                            parent_id,
                            source_url,
                            @intCast(describe.base.line_no),
                        );
                        // Recursively report children with this describe as parent
                        retroactivelyReportScope(agent, describe, test_id, max_id, source_url);
                    } else {
                        // Already has ID, just recurse with existing ID as parent
                        retroactivelyReportScope(agent, describe, describe.base.test_id_for_debugger, max_id, source_url);
                    }
                },
                .test_callback => |test_entry| {
                    // Only report and assign ID if not already assigned
                    if (test_entry.base.test_id_for_debugger == 0) {
                        max_id.* += 1;
                        const test_id = max_id.*;
                        // Assign the ID so start/end events will fire during execution
                        test_entry.base.test_id_for_debugger = test_id;
                        var name = bun.String.cloneUTF8(test_entry.base.name orelse "(unnamed)");
                        defer name.deref();
                        agent.reportTestFoundWithLocation(
                            test_id,
                            &name,
                            .@"test",
                            parent_id,
                            source_url,
                            @intCast(test_entry.base.line_no),
                        );
                    }
                },
            }
        }
    }

    const bun_test = jsc.Jest.bun_test;
    /// Caller must ensure that it is enabled first.
    ///
    /// Since we may have to call .deinit on the name string.
    pub fn reportTestFound(this: TestReporterAgent, caller_source_location: bun.bindgen.CallerSourceLocationView, test_id: i32, name: *bun.String, item_type: TestType, parentId: i32) void {
        debug("reportTestFound", .{});

        this.handle.?.reportTestFound(caller_source_location.frameHandle(), test_id, name, item_type, parentId);
    }

    /// Caller must ensure that it is enabled first.
    pub fn reportTestStart(this: TestReporterAgent, test_id: i32) void {
        debug("reportTestStart", .{});
        this.handle.?.reportTestStart(test_id);
    }

    /// Caller must ensure that it is enabled first.
    pub fn reportTestEnd(this: TestReporterAgent, test_id: i32, bunTestStatus: TestStatus, elapsed: f64) void {
        debug("reportTestEnd", .{});
        this.handle.?.reportTestEnd(test_id, bunTestStatus, elapsed);
    }

    pub fn isEnabled(this: TestReporterAgent) bool {
        return this.handle != null;
    }
};

pub const LifecycleAgent = struct {
    handle: ?*Handle = null,
    const debug = Output.scoped(.LifecycleAgent, .visible);

    pub const Handle = opaque {
        pub fn reportReload(this: *Handle) void {
            debug("reportReload", .{});
            bun.bindgen.Engine(InspectorLifecycleAgentReportReloadShim).call(.{ .agent = @ptrCast(this) });
        }

        pub fn reportError(this: *Handle, exception: *const Diagnostic.Value) bun.OOM!void {
            debug("reportError", .{});
            const Frame = std.meta.Elem(bun.bindgen.EngineArgumentType(InspectorLifecycleAgentReportErrorShim, "frames"));
            const Line = std.meta.Elem(bun.bindgen.EngineArgumentType(InspectorLifecycleAgentReportErrorShim, "sourceLines"));
            const frames = try bun.default_allocator.alloc(Frame, exception.frames.len());
            defer bun.default_allocator.free(frames);
            for (exception.frames.slice(), frames) |*frame, *operand| operand.* = .{
                .functionName = frame.functionName.operand(),
                .sourceURL = frame.sourceURL.operand(),
                .line = frame.line,
                .column = frame.column,
                .bytePosition = frame.bytePosition,
                .codeType = frame.codeType,
                .isAsync = frame.isAsync,
                .remapped = frame.remapped,
            };
            const lines = try bun.default_allocator.alloc(Line, exception.sourceLines.len());
            defer bun.default_allocator.free(lines);
            for (exception.sourceLines.slice(), lines) |*line, *operand| operand.* = .{ .text = line.text.operand(), .line = line.line };
            try bun.bindgen.Engine(InspectorLifecycleAgentReportErrorShim).call(.{
                .agent = @ptrCast(this),
                .message = exception.details.message.operand(),
                .name = exception.details.name.operand(),
                .frames = frames,
                .sourceLines = lines,
            });
        }
    };

    fn bindSetAgent(
        args: bun.bindgen.Args(SetInspectorLifecycleAgentSchema),
    ) bun.bindgen.Return(SetInspectorLifecycleAgentSchema) {
        const agent: *Handle = @ptrCast(args.agent);
        if (VirtualMachine.get().debugger) |*debugger| {
            if (args.enabled) {
                debug("enable", .{});
                debugger.lifecycle_reporter_agent.handle = agent;
            } else if (debugger.lifecycle_reporter_agent.handle == agent) {
                debug("disable", .{});
                debugger.lifecycle_reporter_agent.handle = null;
            }
        }
    }

    pub fn reportReload(this: *LifecycleAgent) void {
        if (this.handle) |handle| {
            handle.reportReload();
        }
    }

    pub fn reportError(this: *LifecycleAgent, exception: *const Diagnostic.Value) bun.OOM!void {
        if (this.handle) |handle| {
            try handle.reportError(exception);
        }
    }

    pub fn isEnabled(this: *const LifecycleAgent) bool {
        return this.handle != null;
    }
};

pub const DebuggerId = bun.GenericIndex(i32, Debugger);
pub const BunFrontendDevServerAgentModule = @import("../runtime/server/InspectorBunFrontendDevServerAgentEngine.zig");
pub const BunFrontendDevServerAgent = BunFrontendDevServerAgentModule.BunFrontendDevServerAgent;
pub const HTTPServerAgent = @import("./HTTPServerAgent.zig");

const DotEnv = @import("../dotenv/env_loader.zig");
const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const Output = bun.Output;
const uv = bun.windows.libuv;

const jsc = bun.jsc;
const Debugger = jsc.Debugger;
const JSGlobalObject = jsc.JSGlobalObject;
const VirtualMachine = jsc.VirtualMachine;
const Diagnostic = jsc.Diagnostic;
const JSCThreadTeardownBindings = bun.bindgen.Module("jsc_thread_teardown");
const BunDebuggerBindings = bun.bindgen.Module("BunDebugger");
const InspectorConnectionSchema = BunDebuggerBindings.class("InspectorConnection");
const InspectorConnectionClass = bun.bindgen.Class(InspectorConnectionSchema, InspectorConnection);
const InspectorChannel = @typeInfo(bun.bindgen.Return(BunDebuggerBindings.engineShim("createInspectorConnection"))).optional.child;
const CreateConnectionSchema = BunDebuggerBindings.function("createConnection");
const SendSchema = BunDebuggerBindings.function("send");
const DisconnectSchema = BunDebuggerBindings.function("disconnect");
const CreateConnectionBinding = bun.bindgen.Fn(CreateConnectionSchema, createConnection);
const SendBinding = bun.bindgen.Fn(SendSchema, send);
const DisconnectBinding = bun.bindgen.Fn(DisconnectSchema, disconnect);
const InspectorAgentBindings = bun.bindgen.Module("inspector_agents");
const CreateJSDebuggerShim = BunDebuggerBindings.engineShim("createJSDebugger");
const StartJSDebuggerThreadShim = BunDebuggerBindings.engineShim("startJSDebuggerThread");
const DebuggerRunWithAPILockShim = BunDebuggerBindings.engineShim("debuggerRunWithAPILock");
const TeardownThreadJSCVMShim = JSCThreadTeardownBindings.engineShim("teardownThreadJSCVM");
const DebuggerDidScheduleAsyncCallShim = BunDebuggerBindings.engineShim("debuggerDidScheduleAsyncCall");
const DebuggerDidCancelAsyncCallShim = BunDebuggerBindings.engineShim("debuggerDidCancelAsyncCall");
const DebuggerDidDispatchAsyncCallShim = BunDebuggerBindings.engineShim("debuggerDidDispatchAsyncCall");
const DebuggerWillDispatchAsyncCallShim = BunDebuggerBindings.engineShim("debuggerWillDispatchAsyncCall");
const InspectorLifecycleAgentReportReloadShim = InspectorAgentBindings.engineShim("inspectorLifecycleAgentReportReload");
const InspectorLifecycleAgentReportErrorShim = InspectorAgentBindings.engineShim("inspectorLifecycleAgentReportError");
const InspectorTestReporterAgentReportTestFoundShim = InspectorAgentBindings.engineShim("inspectorTestReporterAgentReportTestFound");
const InspectorTestReporterAgentReportTestFoundWithLocationShim = InspectorAgentBindings.engineShim("inspectorTestReporterAgentReportTestFoundWithLocation");
const InspectorTestReporterAgentReportTestStartShim = InspectorAgentBindings.engineShim("inspectorTestReporterAgentReportTestStart");
const InspectorTestReporterAgentReportTestEndShim = InspectorAgentBindings.engineShim("inspectorTestReporterAgentReportTestEnd");
const SetInspectorTestReporterAgentSchema = InspectorAgentBindings.nativeExport("setInspectorTestReporterAgent");
const SetInspectorLifecycleAgentSchema = InspectorAgentBindings.nativeExport("setInspectorLifecycleAgent");
const DebuggerDidConnectSchema = BunDebuggerBindings.nativeExport("debuggerDidConnect");
const DebuggerStartSchema = BunDebuggerBindings.nativeExport("debuggerStart");
const SetInspectorTestReporterAgentBinding = bun.bindgen.Fn(SetInspectorTestReporterAgentSchema, TestReporterAgent.bindSetAgent);
const SetInspectorLifecycleAgentBinding = bun.bindgen.Fn(SetInspectorLifecycleAgentSchema, LifecycleAgent.bindSetAgent);
const DebuggerDidConnectBinding = bun.bindgen.Fn(DebuggerDidConnectSchema, bindDidConnect);
const DebuggerStartBinding = bun.bindgen.Fn(DebuggerStartSchema, bindStart);

comptime {
    _ = InspectorConnectionClass;
    _ = CreateConnectionBinding;
    _ = SendBinding;
    _ = DisconnectBinding;
    _ = SetInspectorTestReporterAgentBinding;
    _ = SetInspectorLifecycleAgentBinding;
    _ = DebuggerDidConnectBinding;
    _ = DebuggerStartBinding;
}
