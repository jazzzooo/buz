const NativeCompletionRegistryEngine = @This();

loop: *jsc.EventLoop,
registry: *Registry,
task: NativeTask,

pub fn create(loop: *jsc.EventLoop) bun.OOM!*Registry {
    const this = try bun.default_allocator.create(NativeCompletionRegistryEngine);
    errdefer bun.default_allocator.destroy(this);
    const registry = try Registry.create(.{
        .context = .init(this),
        .schedule = schedule,
        .cancel = cancel,
        .destroy = destroy,
    });
    this.* = .{
        .loop = loop,
        .registry = registry,
        .task = .{
            .ctx = .init(this),
            .callback = run,
            .on_cancel = cancelDelivery,
        },
    };
    return registry;
}

fn schedule(context: Registry.Context) void {
    const this = context.get(*NativeCompletionRegistryEngine);
    this.loop.enqueueNativeTaskConcurrent(&this.task);
}

fn cancel(context: Registry.Context) bool {
    const this = context.get(*NativeCompletionRegistryEngine);
    return this.loop.cancelNativeTask(&this.task);
}

fn run(context: NativeTask.Context, _: *anyopaque) void {
    const this = context.get(*NativeCompletionRegistryEngine);
    this.registry.run();
}

fn cancelDelivery(context: NativeTask.Context) void {
    const this = context.get(*NativeCompletionRegistryEngine);
    this.registry.cancelDelivery();
}

fn destroy(context: Registry.Context) void {
    const this = context.get(*NativeCompletionRegistryEngine);
    bun.default_allocator.destroy(this);
}

const bun = @import("bun");
const jsc = bun.jsc;
const Registry = @import("../event_loop/NativeCompletionRegistry.zig");
const NativeTask = @import("../event_loop/AnyTaskWithExtraContext.zig");
