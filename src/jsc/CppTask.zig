/// A task created from C++ code, usually via ScriptExecutionContext.
pub const CppTask = opaque {
    pub fn run(this: *CppTask, global: *jsc.JSGlobalObject) bun.JSError!void {
        defer this.deinit();
        return bun.bindgen.Engine(PerformTaskSchema).call(global, .{ .task = @ptrCast(this) });
    }

    pub fn deinit(this: *CppTask) void {
        var owner = Owner.initNative(this);
        owner.deinit();
    }

    const Owner = @FieldType(bun.bindgen.Args(bun.bindgen.Module("EventLoop").nativeExport("queueTask")), "task");
};

const PerformTaskSchema = bun.bindgen.Module("EventLoop").engineShim("performTask");

pub const NativeEventTarget = opaque {};

pub const NativeEventSignal = struct {
    references: std.atomic.Value(usize) = .init(2),
    registry: *jsc.NativeCompletionRegistry,
    entry: jsc.NativeCompletionRegistry.Entry = undefined,

    const TargetOwner = bun.bindgen.Return(RetainTargetSchema);
    const Endpoint = struct {
        global: *jsc.JSGlobalObject,
        target: TargetOwner,
        signal: *NativeEventSignal,

        fn deliver(raw: bun.bindgen.NativeCallbackContext(.vm)) void {
            const endpoint = raw.get(*Endpoint);
            var target = bun.bindgen.Engine(RetainTargetSchema).call(.{ .target = endpoint.target.get() });
            defer target.deinit();
            const global = endpoint.global;
            bun.bindgen.Engine(RunTargetSchema).call(global, .{ .target = target.get() }) catch |err|
                global.reportActiveExceptionAsUnhandled(err);
        }

        fn detach(raw: bun.bindgen.NativeCallbackContext(.vm)) void {
            const endpoint = raw.get(*Endpoint);
            const signal = endpoint.signal;
            defer signal.release();
            var target = endpoint.target.take();
            bun.default_allocator.destroy(endpoint);
            defer target.deinit();
            bun.bindgen.Engine(StopTargetSchema).call(.{ .target = target.get() });
        }
    };

    fn retain(signal: *NativeEventSignal) void {
        if (signal.references.fetchAdd(1, .monotonic) == 0)
            @panic("native event signal retained after destruction");
    }

    fn release(signal: *NativeEventSignal) void {
        const previous = signal.references.fetchSub(1, .acq_rel);
        if (previous == 0) @panic("native event signal released twice");
        if (previous == 1) {
            const registry = signal.registry;
            bun.default_allocator.destroy(signal);
            registry.release();
        }
    }

    fn bindCreate(
        context: bun.bindgen.CallContext(CreateSignalSchema),
        args: bun.bindgen.Args(CreateSignalSchema),
    ) bun.JSError!bun.bindgen.Return(CreateSignalSchema) {
        const global = context.viewToken().globalObject();
        const vm = global.bunVM();
        const registry = try (try vm.tryRareData()).nativeCompletionRegistry(vm);
        const endpoint = try bun.default_allocator.create(Endpoint);
        errdefer bun.default_allocator.destroy(endpoint);
        const signal = try bun.default_allocator.create(NativeEventSignal);
        registry.retain();
        signal.* = .{ .registry = registry };
        endpoint.* = .{
            .global = global,
            .target = bun.bindgen.Engine(RetainTargetSchema).call(.{ .target = args.target }),
            .signal = signal,
        };
        signal.entry = .{
            .context = .init(endpoint),
            .deliver = Endpoint.deliver,
            .detach = Endpoint.detach,
            .delivery = .repeating,
        };
        if (!registry.register(&signal.entry)) {
            Endpoint.detach(.init(endpoint));
            signal.release();
            return null;
        }
        const Owner = @typeInfo(bun.bindgen.Return(CreateSignalSchema)).optional.child;
        return Owner.initNative(signal);
    }

    fn bindNotify(args: bun.bindgen.Args(NotifySignalSchema)) bun.bindgen.Return(NotifySignalSchema) {
        return args.signal.registry.notify(&args.signal.entry);
    }

    fn bindRetain(args: bun.bindgen.Args(RetainSignalSchema)) bun.bindgen.Return(RetainSignalSchema) {
        args.signal.retain();
        return bun.bindgen.Return(RetainSignalSchema).initNative(args.signal);
    }

    fn bindClose(args: bun.bindgen.Args(CloseSignalSchema)) bun.bindgen.Return(CloseSignalSchema) {
        args.signal.retain();
        defer args.signal.release();
        args.signal.registry.detach(&args.signal.entry);
    }

    fn bindRelease(args: bun.bindgen.Args(ReleaseSignalSchema)) bun.bindgen.Return(ReleaseSignalSchema) {
        args.signal.release();
    }
};

/// A task created from C++ code that runs inside the workpool, usually via ScriptExecutionContext.
pub const ConcurrentCppTask = struct {
    cpp_task: @FieldType(bun.bindgen.Args(CreateAndRunSchema), "task"),
    event_loop: *jsc.EventLoop,
    workpool_task: bun.BackgroundTaskGroup.Task = .{
        .callback = &runFromWorkpool,
        .on_cancel = &cancelFromWorkpool,
    },

    pub const EventLoopTaskNoContext = opaque {
        pub fn run(this: *EventLoopTaskNoContext) void {
            bun.bindgen.Engine(EventLoopTaskNoContextPerformSchema).call(.{ .task = @ptrCast(this) });
        }

        /// Get the VM that created this task
        pub fn getVM(this: *const EventLoopTaskNoContext) ?*VirtualMachine {
            const result = bun.bindgen.Engine(EventLoopTaskNoContextCreatedInBunVMSchema).call(.{ .task = @ptrCast(@constCast(this)) });
            return if (result) |vm| @ptrCast(@alignCast(vm)) else null;
        }
    };

    pub fn runFromWorkpool(task: *bun.BackgroundTaskGroup.Task) void {
        const this: *ConcurrentCppTask = @fieldParentPtr("workpool_task", task);
        var cpp_task = this.cpp_task.take();
        const event_loop = this.event_loop;
        bun.default_allocator.destroy(this);
        defer event_loop.unrefConcurrently();
        defer cpp_task.deinit();
        cpp_task.get().run();
    }

    fn cancelFromWorkpool(task: *bun.BackgroundTaskGroup.Task) void {
        const this: *ConcurrentCppTask = @fieldParentPtr("workpool_task", task);
        var cpp_task = this.cpp_task.take();
        const event_loop = this.event_loop;
        bun.default_allocator.destroy(this);
        defer event_loop.unrefConcurrently();
        cpp_task.deinit();
    }

    fn bindCreateAndRun(
        args: *bun.bindgen.Args(CreateAndRunSchema),
    ) bun.OOM!bun.bindgen.Return(CreateAndRunSchema) {
        const cpp_task = args.task.get();
        const vm = cpp_task.getVM() orelse {
            cpp_task.run();
            return;
        };
        const cpp = try bun.default_allocator.create(ConcurrentCppTask);
        const event_loop = vm.event_loop;
        cpp.* = .{ .cpp_task = args.task.take(), .event_loop = event_loop };
        event_loop.refConcurrently();
        bun.BackgroundWork.schedule(&vm.background_tasks, &cpp.workpool_task) catch {
            runFromWorkpool(&cpp.workpool_task);
        };
    }
};

const CreateAndRunSchema = EventLoopBindings.nativeExport("concurrentCppTaskCreateAndRun");
const CreateAndRunBinding = bun.bindgen.Fn(CreateAndRunSchema, ConcurrentCppTask.bindCreateAndRun);
const CreateSignalSchema = EventLoopBindings.nativeExport("createNativeEventSignal");
const NotifySignalSchema = EventLoopBindings.nativeExport("notifyNativeEventSignal");
const RetainSignalSchema = EventLoopBindings.nativeExport("retainNativeEventSignal");
const CloseSignalSchema = EventLoopBindings.nativeExport("closeNativeEventSignal");
const ReleaseSignalSchema = EventLoopBindings.nativeExport("releaseNativeEventSignal");
const RetainTargetSchema = EventLoopBindings.engineShim("retainNativeEventTarget");
const RunTargetSchema = EventLoopBindings.engineShim("runNativeEventTarget");
const StopTargetSchema = EventLoopBindings.engineShim("stopNativeEventTarget");

comptime {
    _ = CreateAndRunBinding;
    _ = bun.bindgen.Fn(CreateSignalSchema, NativeEventSignal.bindCreate);
    _ = bun.bindgen.Fn(NotifySignalSchema, NativeEventSignal.bindNotify);
    _ = bun.bindgen.Fn(RetainSignalSchema, NativeEventSignal.bindRetain);
    _ = bun.bindgen.Fn(CloseSignalSchema, NativeEventSignal.bindClose);
    _ = bun.bindgen.Fn(ReleaseSignalSchema, NativeEventSignal.bindRelease);
}

const std = @import("std");
const bun = @import("bun");

const jsc = bun.jsc;
const VirtualMachine = jsc.VirtualMachine;
const EventLoopBindings = bun.bindgen.Module("EventLoop");
const EventLoopTaskNoContextPerformSchema = EventLoopBindings.engineShim("eventLoopTaskNoContextPerform");
const EventLoopTaskNoContextCreatedInBunVMSchema = EventLoopBindings.engineShim("eventLoopTaskNoContextCreatedInBunVM");
