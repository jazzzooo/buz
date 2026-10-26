const JSCScheduler = @This();

pub const JSCDeferredWorkTask = opaque {
    pub fn run(task: *JSCScheduler.JSCDeferredWorkTask, globalThis: *jsc.JSGlobalObject) bun.JSError!void {
        defer task.deinit();
        return bun.bindgen.Engine(RunJSCDeferredWorkSchema).call(globalThis, .{ .task = @ptrCast(task) });
    }

    pub fn deinit(task: *JSCDeferredWorkTask) void {
        var owner = Owner.initNative(task);
        owner.deinit();
    }

    const Owner = @FieldType(bun.bindgen.Args(QueueJSCDeferredWorkTaskConcurrentlySchema), "task");
};

fn bindEventLoopRefConcurrently(
    args: bun.bindgen.Args(EventLoopRefConcurrentlySchema),
) bun.bindgen.Return(EventLoopRefConcurrentlySchema) {
    const jsc_vm: *VirtualMachine = @ptrCast(@alignCast(args.vm));
    jsc_vm.event_loop.refConcurrently();
}

fn bindEventLoopUnrefConcurrently(
    args: bun.bindgen.Args(EventLoopUnrefConcurrentlySchema),
) bun.bindgen.Return(EventLoopUnrefConcurrentlySchema) {
    const jsc_vm: *VirtualMachine = @ptrCast(@alignCast(args.vm));
    jsc_vm.event_loop.unrefConcurrently();
}

fn bindQueueJSCDeferredWorkTaskConcurrently(
    args: *bun.bindgen.Args(QueueJSCDeferredWorkTaskConcurrentlySchema),
) bun.bindgen.Return(QueueJSCDeferredWorkTaskConcurrentlySchema) {
    const jsc_vm: *VirtualMachine = @ptrCast(@alignCast(args.vm));
    const task = args.task.takeNative();
    var loop = jsc_vm.eventLoop();
    loop.enqueueTaskConcurrent(ConcurrentTask.new(.{
        .task = Task.init(task),
        .node = .{ .kind = .engine, .auto_delete = true },
    }));
}

const EventLoopBindings = bun.bindgen.Module("EventLoop");
const RunJSCDeferredWorkSchema = EventLoopBindings.engineShim("runJSCDeferredWork");
const EventLoopRefConcurrentlySchema = EventLoopBindings.nativeExport("eventLoopRefConcurrently");
const EventLoopUnrefConcurrentlySchema = EventLoopBindings.nativeExport("eventLoopUnrefConcurrently");
const QueueJSCDeferredWorkTaskConcurrentlySchema = EventLoopBindings.nativeExport("queueJSCDeferredWorkTaskConcurrently");
const EventLoopRefConcurrentlyBinding = bun.bindgen.Fn(EventLoopRefConcurrentlySchema, bindEventLoopRefConcurrently);
const EventLoopUnrefConcurrentlyBinding = bun.bindgen.Fn(EventLoopUnrefConcurrentlySchema, bindEventLoopUnrefConcurrently);
const QueueJSCDeferredWorkTaskConcurrentlyBinding = bun.bindgen.Fn(
    QueueJSCDeferredWorkTaskConcurrentlySchema,
    bindQueueJSCDeferredWorkTaskConcurrently,
);

comptime {
    _ = EventLoopRefConcurrentlyBinding;
    _ = EventLoopUnrefConcurrentlyBinding;
    _ = QueueJSCDeferredWorkTaskConcurrentlyBinding;
}

const bun = @import("bun");

const jsc = bun.jsc;
const ConcurrentTask = jsc.ConcurrentTask;
const Task = jsc.Task;
const VirtualMachine = jsc.VirtualMachine;
