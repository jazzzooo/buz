const NativeCompletionRegistryMini = @This();

loop: *MiniEventLoop,
registry: *Registry,
task: Task,

pub fn create(loop: *MiniEventLoop) bun.OOM!*Registry {
    const this = try bun.default_allocator.create(NativeCompletionRegistryMini);
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
    const this = context.get(*NativeCompletionRegistryMini);
    this.loop.enqueueTaskConcurrent(&this.task);
}

fn cancel(context: Registry.Context) bool {
    const this = context.get(*NativeCompletionRegistryMini);
    return this.loop.cancelTask(&this.task);
}

fn run(context: Task.Context, _: *anyopaque) void {
    const this = context.get(*NativeCompletionRegistryMini);
    this.registry.run();
}

fn cancelDelivery(context: Task.Context) void {
    const this = context.get(*NativeCompletionRegistryMini);
    this.registry.cancelDelivery();
}

fn destroy(context: Registry.Context) void {
    const this = context.get(*NativeCompletionRegistryMini);
    bun.default_allocator.destroy(this);
}

const bun = @import("bun");
const MiniEventLoop = @import("./MiniEventLoop.zig");
const Registry = @import("./NativeCompletionRegistry.zig");
const Task = @import("./AnyTaskWithExtraContext.zig");
