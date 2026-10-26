fn bindVirtualMachineIsShuttingDown(
    args: bun.bindgen.Args(VirtualMachineIsShuttingDownSchema),
) bun.bindgen.Return(VirtualMachineIsShuttingDownSchema) {
    const vm: *const VirtualMachine = @ptrCast(@alignCast(args.vm));
    return vm.isShuttingDown();
}

fn bindGetVirtualMachine(
    args: bun.bindgen.Args(GetVirtualMachineSchema),
) bun.bindgen.Return(GetVirtualMachineSchema) {
    _ = args;
    return @ptrCast(jsc.VirtualMachine.get());
}

fn bindDrainMicrotasks(
    _: bun.bindgen.CallContext(DrainMicrotasksSchema),
    _: bun.bindgen.Args(DrainMicrotasksSchema),
) bun.JSError!bun.bindgen.Return(DrainMicrotasksSchema) {
    jsc.VirtualMachine.get().eventLoop().tick();
}

fn bindReadOriginTimer(
    args: bun.bindgen.Args(ReadOriginTimerSchema),
) bun.bindgen.Return(ReadOriginTimerSchema) {
    const vm: *jsc.VirtualMachine = @ptrCast(@alignCast(args.vm));
    // Check if performance.now() is overridden (for fake timers)
    if (vm.overridden_performance_now) |overridden| {
        return overridden;
    }
    return vm.origin_timer.read();
}

fn bindReadOriginTimerStart(
    args: bun.bindgen.Args(ReadOriginTimerStartSchema),
) bun.bindgen.Return(ReadOriginTimerStartSchema) {
    const vm: *jsc.VirtualMachine = @ptrCast(@alignCast(args.vm));
    return @as(f64, @floatCast((@as(f64, @floatFromInt(vm.origin_timestamp)) + jsc.VirtualMachine.origin_relative_epoch) / 1_000_000.0));
}

fn bindReadOriginMonotonicNanoseconds(
    args: bun.bindgen.Args(ReadOriginMonotonicNanosecondsSchema),
) bun.bindgen.Return(ReadOriginMonotonicNanosecondsSchema) {
    const vm: *const jsc.VirtualMachine = @ptrCast(@alignCast(args.vm));
    return vm.origin_timer.started_ns;
}

fn bindGlobalObjectConnectedIPC(
    args: bun.bindgen.Args(GlobalObjectConnectedIPCSchema),
) bun.bindgen.Return(GlobalObjectConnectedIPCSchema) {
    const global: *JSGlobalObject = @ptrCast(@alignCast(args.global));
    if (global.bunVM().ipc) |ipc| {
        if (ipc == .initialized) {
            return ipc.initialized.data.isConnected();
        }
        return true;
    }
    return false;
}
fn bindGlobalObjectHasIPC(
    args: bun.bindgen.Args(GlobalObjectHasIPCSchema),
) bun.bindgen.Return(GlobalObjectHasIPCSchema) {
    const global: *JSGlobalObject = @ptrCast(@alignCast(args.global));
    if (global.bunVM().ipc != null) {
        return true;
    }
    return false;
}

fn bindVirtualMachineExitDuringUncaughtException(
    args: bun.bindgen.Args(VirtualMachineExitDuringUncaughtExceptionSchema),
) bun.bindgen.Return(VirtualMachineExitDuringUncaughtExceptionSchema) {
    const vm: *jsc.VirtualMachine = @ptrCast(@alignCast(args.vm));
    vm.exit_on_uncaught_exception = true;
}

fn processSend(
    context: bun.bindgen.CallContext(ProcessSendSchema),
    args: bun.bindgen.Args(ProcessSendSchema),
) bun.bindgen.CallError(ProcessSendSchema)!bool {
    return jsc.IPC.processSendFromBinding(context, args);
}

fn bindIsBunMain(
    _: bun.bindgen.CallContext(IsBunMainSchema),
    args: bun.bindgen.Args(IsBunMainSchema),
) bun.bindgen.Return(IsBunMainSchema) {
    return jsc.ModuleRunMainOperations.MainEntry.isBunMain(args.main);
}

/// When IPC environment variables are passed, the socket is not immediately opened,
/// but rather we wait for process.on('message') or process.send() to be called, THEN
/// we open the socket. This is to avoid missing messages at the start of the program.
fn bindEnsureProcessIPCInitialized(
    context: bun.bindgen.CallContext(EnsureProcessIPCInitializedSchema),
    _: bun.bindgen.Args(EnsureProcessIPCInitializedSchema),
) bun.JSError!bun.bindgen.Return(EnsureProcessIPCInitializedSchema) {
    try jsc.IPC.ensureProcessIPCInitialized(context.viewToken().globalObject());
}

fn bindCloseChildIPC(
    context: bun.bindgen.CallContext(CloseChildIPCSchema),
    _: bun.bindgen.Args(CloseChildIPCSchema),
) bun.JSError!bun.bindgen.Return(CloseChildIPCSchema) {
    try jsc.IPC.closeChildIPC(context.viewToken().globalObject());
}

/// This function is called on the main thread
/// The bunVM() call will assert this
fn bindQueueTask(
    args: *bun.bindgen.Args(QueueTaskSchema),
) bun.bindgen.Return(QueueTaskSchema) {
    const global: *JSGlobalObject = @ptrCast(@alignCast(args.global));
    const loop = global.bunVM().eventLoop();
    if (!loop.accepts_cancellable_tasks) return;
    const task = args.task.takeNative();
    loop.enqueueTask(jsc.Task.init(task));
}

fn bindReportUnhandledError(
    context: bun.bindgen.CallContext(ReportUnhandledErrorSchema),
    args: bun.bindgen.Args(ReportUnhandledErrorSchema),
) bun.bindgen.Return(ReportUnhandledErrorSchema) {
    context.reportUnhandledError(args.value.operand(context).asAny());
}

/// This function is called on another thread
/// The main difference: we need to allocate the task & wakeup the thread
/// We can avoid that if we run it from the main thread.
fn bindQueueTaskConcurrently(
    args: *bun.bindgen.Args(QueueTaskConcurrentlySchema),
) bun.bindgen.Return(QueueTaskConcurrentlySchema) {
    const global: *JSGlobalObject = @ptrCast(@alignCast(args.global));
    const task = args.task.takeNative();
    global.bunVMConcurrently().eventLoop().enqueueTaskConcurrent(
        jsc.ConcurrentTask.create(jsc.Task.init(task)),
    );
}

fn bindHandleRejectedPromise(
    context: bun.bindgen.CallContext(HandleRejectedPromiseSchema),
    args: bun.bindgen.Args(HandleRejectedPromiseSchema),
) bun.JSError!bun.bindgen.Return(HandleRejectedPromiseSchema) {
    try jsc.PromiseRejectionOperations.handleRejected(context, args);
}

fn bindHandleHandledPromise(
    call_context: bun.bindgen.CallContext(HandleHandledPromiseSchema),
    args: bun.bindgen.Args(HandleHandledPromiseSchema),
) bun.JSError!bun.bindgen.Return(HandleHandledPromiseSchema) {
    try jsc.PromiseRejectionOperations.handleHandled(call_context, args);
}

fn bindOnDidAppendPlugin(
    _: bun.bindgen.CallContext(OnDidAppendPluginSchema),
    _: bun.bindgen.Args(OnDidAppendPluginSchema),
) bun.bindgen.Return(OnDidAppendPluginSchema) {
    jsc.ModuleLoader.ensurePluginRunner();
}

fn bindVirtualMachineUVLoop(
    _: bun.bindgen.CallContext(VirtualMachineUVLoopSchema),
    _: bun.bindgen.Args(VirtualMachineUVLoopSchema),
) bun.bindgen.Return(VirtualMachineUVLoopSchema) {
    return jsc.VirtualMachine.get().uvLoop();
}

fn bindSetTLSRejectUnauthorizedValue(
    args: bun.bindgen.Args(SetTLSRejectUnauthorizedValueSchema),
) bun.bindgen.Return(SetTLSRejectUnauthorizedValueSchema) {
    VirtualMachine.get().default_tls_reject_unauthorized = args.value != 0;
}

fn bindGetTLSRejectUnauthorizedValue(
    args: bun.bindgen.Args(GetTLSRejectUnauthorizedValueSchema),
) bun.bindgen.Return(GetTLSRejectUnauthorizedValueSchema) {
    _ = args;
    return if (jsc.VirtualMachine.get().getTLSRejectUnauthorized()) 1 else 0;
}

fn bindIsNoProxy(
    args: bun.bindgen.Args(IsNoProxySchema),
) bun.bindgen.Return(IsNoProxySchema) {
    const vm = jsc.VirtualMachine.get();
    const hostname_bytes = args.hostname.unsafePtr("The generated native-export frame owns the hostname bytes until isNoProxy finishes matching");
    const host_bytes = args.host.unsafePtr("The generated native-export frame owns the host bytes until isNoProxy finishes matching");
    const hostname: ?[]const u8 = if (hostname_bytes.len > 0) hostname_bytes else null;
    const host: ?[]const u8 = if (host_bytes.len > 0) host_bytes else null;
    return vm.transpiler.env.isNoProxy(hostname, host);
}

fn bindSetVerboseFetchValue(
    args: bun.bindgen.Args(SetVerboseFetchValueSchema),
) bun.bindgen.Return(SetVerboseFetchValueSchema) {
    VirtualMachine.get().default_verbose_fetch = if (args.value == 1) .headers else if (args.value == 2) .curl else .none;
}

fn bindGetVerboseFetchValue(
    args: bun.bindgen.Args(GetVerboseFetchValueSchema),
) bun.bindgen.Return(GetVerboseFetchValueSchema) {
    _ = args;
    return switch (jsc.VirtualMachine.get().getVerboseFetch()) {
        .none => 0,
        .headers => 1,
        .curl => 2,
    };
}

fn captureSourceMapInput(source: bun.bindgen.DOMStringView, external_json: ?[]const u8, allow_external_file: bool) bun.OOM!*bun.SourceMap.SourceMapInput {
    const text: bun.TextView = source.unsafePtr("The generated native-export frame owns the source string until SourceMapInput.capture finishes copying its source-map URL").textView();
    return bun.SourceMap.SourceMapInput.capture(text, external_json, allow_external_file);
}

fn bindAddBakeSourceProviderSourceMap(
    args: bun.bindgen.Args(AddBakeSourceProviderSourceMapSchema),
) bun.OOM!bun.bindgen.Return(AddBakeSourceProviderSourceMapSchema) {
    const vm: *VirtualMachine = @ptrCast(@alignCast(args.vm));
    const path = try args.specifier.toUTF8(bun.default_allocator);
    defer path.deinit();
    const external_json: ?[]const u8 = json: {
        const per_thread = args.perThreadData orelse break :json null;
        const output = per_thread.source_maps.get(path.slice()) orelse break :json null;
        break :json per_thread.bundled_outputs[output.get()].value.asSlice();
    };
    const input = try captureSourceMapInput(args.source, external_json, args.perThreadData == null);
    errdefer input.deref();
    return vm.source_mappings.putInput(path.slice(), input);
}

fn bindAddDevServerSourceProvider(
    args: bun.bindgen.Args(AddDevServerSourceProviderSchema),
) bun.OOM!bun.bindgen.Return(AddDevServerSourceProviderSchema) {
    const vm: *VirtualMachine = @ptrCast(@alignCast(args.vm));
    const path = try args.specifier.toUTF8(bun.default_allocator);
    defer path.deinit();
    const json = args.sourceMapJSON.unsafePtr("The generated native-export frame owns the copied JSON until captureSourceMapInput finishes copying it into native storage");
    const input = try captureSourceMapInput(args.source, json, false);
    errdefer input.deref();
    return vm.source_mappings.putInput(path.slice(), input);
}

fn bindAddSourceProviderSourceMap(
    args: bun.bindgen.Args(AddSourceProviderSourceMapSchema),
) bun.OOM!bun.bindgen.Return(AddSourceProviderSourceMapSchema) {
    const vm: *VirtualMachine = @ptrCast(@alignCast(args.vm));
    const path = try args.specifier.toUTF8(bun.default_allocator);
    defer path.deinit();
    const input = try captureSourceMapInput(args.source, null, true);
    errdefer input.deref();
    return vm.source_mappings.putInput(path.slice(), input);
}

fn bindRemoveSourceMapRegistration(
    args: bun.bindgen.Args(RemoveSourceMapRegistrationSchema),
) bun.bindgen.Return(RemoveSourceMapRegistrationSchema) {
    const vm: *VirtualMachine = @ptrCast(@alignCast(args.vm));
    vm.source_mappings.removeRegistration(args.registration, args.specifier);
}

fn bindRemapStackFramePosition(
    args: bun.bindgen.Args(RemapStackFramePositionSchema),
) bun.OOM!bun.bindgen.Return(RemapStackFramePositionSchema) {
    const vm: *VirtualMachine = @ptrCast(@alignCast(args.vm));
    var owner: jsc.Diagnostic.Frames.ElementOwner = .{ .value = .{
        .functionName = .empty(),
        .sourceURL = args.sourceURL.toOwned(),
        .line = args.line,
        .column = args.column,
        .bytePosition = args.bytePosition,
        .codeType = .none,
        .isAsync = false,
        .remapped = args.remapped,
    } };
    defer owner.deinit();
    const frame = &owner.value;
    if (args.line != null and args.column != null)
        try vm.remapStackFramePosition(frame);
    return .{
        .sourceURL = frame.sourceURL.take(),
        .line = frame.line,
        .column = frame.column,
        .bytePosition = frame.bytePosition,
        .remapped = frame.remapped,
    };
}

fn bindProcessStdioFdType(
    args: bun.bindgen.Args(ProcessStdioFdTypeSchema),
) bun.bindgen.Return(ProcessStdioFdTypeSchema) {
    const mode: bun.Mode = switch (bun.sys.fstat(bun.FD.fromUV(args.fd))) {
        .result => |stat| @intCast(stat.mode),
        .err => 0,
    };
    if (bun.S.ISFIFO(@intCast(mode))) return .pipe;
    if (bun.S.ISSOCK(@intCast(mode))) return .socket;
    return .file;
}

fn bindOutputStdioIsTTY(
    args: bun.bindgen.Args(OutputStdioIsTTYSchema),
) bun.bindgen.Return(OutputStdioIsTTYSchema) {
    if (args.fd < 0) return false;
    const fd: usize = @intCast(args.fd);
    if (fd >= bun.Output.stdio_is_tty.len) return false;
    return bun.Output.stdio_is_tty[fd];
}

pub fn Bun__setSyntheticAllocationLimitForTesting(
    _: bun.bindgen.CallContext(SetSyntheticAllocationLimitSchema),
    args: bun.bindgen.Args(SetSyntheticAllocationLimitSchema),
) bun.JSError!usize {
    const limit: usize = @intCast(@max(args.limit, 1024 * 1024));
    const prev = bun.JavaScriptLimits.syntheticAllocationLimit();
    VirtualMachine.setSyntheticAllocationLimit(limit);
    return prev;
}

const std = @import("std");

const bun = @import("bun");

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const VirtualMachine = jsc.VirtualMachine;

const ProcessTTYBindings = bun.bindgen.Module("ProcessTTY");
const SourceProviderBindings = bun.bindgen.Module("source_providers");
const EventLoopBindings = bun.bindgen.Module("EventLoop");
const VirtualMachineBindings = bun.bindgen.Module("virtual_machine");
const GetVirtualMachineSchema = VirtualMachineBindings.nativeExport("getVirtualMachine");
const VirtualMachineIsShuttingDownSchema = VirtualMachineBindings.nativeExport("virtualMachineIsShuttingDown");
const ReadOriginTimerSchema = VirtualMachineBindings.nativeExport("readOriginTimer");
const ReadOriginTimerStartSchema = VirtualMachineBindings.nativeExport("readOriginTimerStart");
const ReadOriginMonotonicNanosecondsSchema = VirtualMachineBindings.nativeExport("readOriginMonotonicNanoseconds");
const IPCBindings = bun.bindgen.Module("IPC");
const GlobalObjectConnectedIPCSchema = IPCBindings.nativeExport("globalObjectConnectedIPC");
const GlobalObjectHasIPCSchema = IPCBindings.nativeExport("globalObjectHasIPC");
const VirtualMachineExitDuringUncaughtExceptionSchema = VirtualMachineBindings.nativeExport("virtualMachineExitDuringUncaughtException");
const DrainMicrotasksSchema = EventLoopBindings.nativeExport("tickEventLoop");
const ModuleRunMainBindings = bun.bindgen.Module("module_run_main");
const IsBunMainSchema = ModuleRunMainBindings.nativeExport("isBunMain");
const EnsureProcessIPCInitializedSchema = IPCBindings.nativeExport("ensureProcessIPCInitialized");
const CloseChildIPCSchema = IPCBindings.nativeExport("closeChildIPC");
const QueueTaskSchema = EventLoopBindings.nativeExport("queueTask");
const QueueTaskConcurrentlySchema = EventLoopBindings.nativeExport("queueTaskConcurrently");
const ErrorBindings = bun.bindgen.Module("errors");
const ReportUnhandledErrorSchema = ErrorBindings.nativeExport("reportUnhandledError");
const PromiseBindings = bun.bindgen.Module("promises");
const HandleRejectedPromiseSchema = PromiseBindings.nativeExport("handleRejectedPromise");
const HandleHandledPromiseSchema = PromiseBindings.nativeExport("handleHandledPromise");
const ModuleLoaderBindings = bun.bindgen.Module("ModuleLoader");
const OnDidAppendPluginSchema = ModuleLoaderBindings.nativeExport("onDidAppendPlugin");
const AddBakeSourceProviderSourceMapSchema = SourceProviderBindings.nativeExport("addBakeSourceProviderSourceMap");
const AddDevServerSourceProviderSchema = SourceProviderBindings.nativeExport("addDevServerSourceProvider");
const AddSourceProviderSourceMapSchema = SourceProviderBindings.nativeExport("addSourceProviderSourceMap");
const RemoveSourceMapRegistrationSchema = SourceProviderBindings.nativeExport("removeSourceMapRegistration");
const RemapStackFramePositionSchema = SourceProviderBindings.nativeExport("remapStackFramePosition");
const ProcessStdioFdTypeSchema = ProcessBindings.nativeExport("processStdioFdType");
const OutputStdioIsTTYSchema = ProcessTTYBindings.nativeExport("outputStdioIsTTY");
const VirtualMachineUVLoopSchema = VirtualMachineBindings.nativeExport("virtualMachineUVLoop");
const GetVirtualMachineBinding = bun.bindgen.Fn(GetVirtualMachineSchema, bindGetVirtualMachine);
const VirtualMachineIsShuttingDownBinding = bun.bindgen.Fn(VirtualMachineIsShuttingDownSchema, bindVirtualMachineIsShuttingDown);
const ReadOriginTimerBinding = bun.bindgen.Fn(ReadOriginTimerSchema, bindReadOriginTimer);
const ReadOriginTimerStartBinding = bun.bindgen.Fn(ReadOriginTimerStartSchema, bindReadOriginTimerStart);
const ReadOriginMonotonicNanosecondsBinding = bun.bindgen.Fn(ReadOriginMonotonicNanosecondsSchema, bindReadOriginMonotonicNanoseconds);
const GlobalObjectConnectedIPCBinding = bun.bindgen.Fn(GlobalObjectConnectedIPCSchema, bindGlobalObjectConnectedIPC);
const GlobalObjectHasIPCBinding = bun.bindgen.Fn(GlobalObjectHasIPCSchema, bindGlobalObjectHasIPC);
const VirtualMachineExitDuringUncaughtExceptionBinding = bun.bindgen.Fn(
    VirtualMachineExitDuringUncaughtExceptionSchema,
    bindVirtualMachineExitDuringUncaughtException,
);
const DrainMicrotasksBinding = bun.bindgen.Fn(DrainMicrotasksSchema, bindDrainMicrotasks);
const IsBunMainBinding = bun.bindgen.Fn(IsBunMainSchema, bindIsBunMain);
const EnsureProcessIPCInitializedBinding = bun.bindgen.Fn(EnsureProcessIPCInitializedSchema, bindEnsureProcessIPCInitialized);
const CloseChildIPCBinding = bun.bindgen.Fn(CloseChildIPCSchema, bindCloseChildIPC);
const QueueTaskBinding = bun.bindgen.Fn(QueueTaskSchema, bindQueueTask);
const QueueTaskConcurrentlyBinding = bun.bindgen.Fn(QueueTaskConcurrentlySchema, bindQueueTaskConcurrently);
const ReportUnhandledErrorBinding = bun.bindgen.Fn(ReportUnhandledErrorSchema, bindReportUnhandledError);
const HandleRejectedPromiseBinding = bun.bindgen.Fn(HandleRejectedPromiseSchema, bindHandleRejectedPromise);
const HandleHandledPromiseBinding = bun.bindgen.Fn(HandleHandledPromiseSchema, bindHandleHandledPromise);
const OnDidAppendPluginBinding = bun.bindgen.Fn(OnDidAppendPluginSchema, bindOnDidAppendPlugin);
const AddBakeSourceProviderSourceMapBinding = bun.bindgen.Fn(AddBakeSourceProviderSourceMapSchema, bindAddBakeSourceProviderSourceMap);
const AddDevServerSourceProviderBinding = bun.bindgen.Fn(AddDevServerSourceProviderSchema, bindAddDevServerSourceProvider);
const AddSourceProviderSourceMapBinding = bun.bindgen.Fn(AddSourceProviderSourceMapSchema, bindAddSourceProviderSourceMap);
const RemoveSourceMapRegistrationBinding = bun.bindgen.Fn(RemoveSourceMapRegistrationSchema, bindRemoveSourceMapRegistration);
const RemapStackFramePositionBinding = bun.bindgen.Fn(RemapStackFramePositionSchema, bindRemapStackFramePosition);
const ProcessStdioFdTypeBinding = bun.bindgen.Fn(ProcessStdioFdTypeSchema, bindProcessStdioFdType);
const OutputStdioIsTTYBinding = bun.bindgen.Fn(OutputStdioIsTTYSchema, bindOutputStdioIsTTY);
const VirtualMachineUVLoopBinding = bun.bindgen.Fn(VirtualMachineUVLoopSchema, bindVirtualMachineUVLoop);

const ProcessBindings = bun.bindgen.Module("Process");
const ProcessSendSchema = ProcessBindings.function("send");
const ProcessSendBinding = bun.bindgen.Fn(ProcessSendSchema, processSend);
const SetTLSRejectUnauthorizedValueSchema = ProcessBindings.nativeExport("setTLSRejectUnauthorizedValue");
const GetTLSRejectUnauthorizedValueSchema = ProcessBindings.nativeExport("getTLSRejectUnauthorizedValue");
const SetVerboseFetchValueSchema = ProcessBindings.nativeExport("setVerboseFetchValue");
const GetVerboseFetchValueSchema = ProcessBindings.nativeExport("getVerboseFetchValue");
const IsNoProxySchema = ProcessBindings.nativeExport("isNoProxy");
const SetTLSRejectUnauthorizedValueBinding = bun.bindgen.Fn(SetTLSRejectUnauthorizedValueSchema, bindSetTLSRejectUnauthorizedValue);
const GetTLSRejectUnauthorizedValueBinding = bun.bindgen.Fn(GetTLSRejectUnauthorizedValueSchema, bindGetTLSRejectUnauthorizedValue);
const SetVerboseFetchValueBinding = bun.bindgen.Fn(SetVerboseFetchValueSchema, bindSetVerboseFetchValue);
const GetVerboseFetchValueBinding = bun.bindgen.Fn(GetVerboseFetchValueSchema, bindGetVerboseFetchValue);
const IsNoProxyBinding = bun.bindgen.Fn(IsNoProxySchema, bindIsNoProxy);

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const SetSyntheticAllocationLimitSchema = InternalTestingBindings.function("setSyntheticAllocationLimit");
const SetSyntheticAllocationLimitBinding = bun.bindgen.Fn(SetSyntheticAllocationLimitSchema, Bun__setSyntheticAllocationLimitForTesting);

comptime {
    _ = GetVirtualMachineBinding;
    _ = VirtualMachineIsShuttingDownBinding;
    _ = ReadOriginTimerBinding;
    _ = ReadOriginTimerStartBinding;
    _ = ReadOriginMonotonicNanosecondsBinding;
    _ = GlobalObjectConnectedIPCBinding;
    _ = GlobalObjectHasIPCBinding;
    _ = VirtualMachineExitDuringUncaughtExceptionBinding;
    _ = DrainMicrotasksBinding;
    _ = IsBunMainBinding;
    _ = EnsureProcessIPCInitializedBinding;
    _ = CloseChildIPCBinding;
    _ = QueueTaskBinding;
    _ = QueueTaskConcurrentlyBinding;
    _ = ReportUnhandledErrorBinding;
    _ = HandleRejectedPromiseBinding;
    _ = HandleHandledPromiseBinding;
    _ = OnDidAppendPluginBinding;
    _ = AddBakeSourceProviderSourceMapBinding;
    _ = AddDevServerSourceProviderBinding;
    _ = AddSourceProviderSourceMapBinding;
    _ = RemoveSourceMapRegistrationBinding;
    _ = RemapStackFramePositionBinding;
    _ = ProcessStdioFdTypeBinding;
    _ = OutputStdioIsTTYBinding;
    _ = VirtualMachineUVLoopBinding;
    _ = ProcessSendBinding;
    _ = SetTLSRejectUnauthorizedValueBinding;
    _ = GetTLSRejectUnauthorizedValueBinding;
    _ = SetVerboseFetchValueBinding;
    _ = GetVerboseFetchValueBinding;
    _ = IsNoProxyBinding;
    _ = SetSyntheticAllocationLimitBinding;
}
