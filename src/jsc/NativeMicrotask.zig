const NativeMicrotask = @This();

run_fn: *const fn (*NativeMicrotask) bun.JSError!void,
destroy_fn: *const fn (*NativeMicrotask) void,

pub fn init(comptime Owner: type) NativeMicrotask {
    return .{
        .run_fn = struct {
            fn run(task: *NativeMicrotask) bun.JSError!void {
                const owner: *Owner = @fieldParentPtr("task", task);
                return owner.run();
            }
        }.run,
        .destroy_fn = struct {
            fn destroy(task: *NativeMicrotask) void {
                const owner: *Owner = @fieldParentPtr("task", task);
                owner.deinit();
                bun.default_allocator.destroy(owner);
            }
        }.destroy,
    };
}

pub fn create(comptime Owner: type, initial: Owner) bun.OOM!*Owner {
    const owner = bun.default_allocator.create(Owner) catch |err| {
        var discarded = initial;
        discarded.deinit();
        return err;
    };
    owner.* = initial;
    owner.task = init(Owner);
    return owner;
}

pub fn run(task: *NativeMicrotask) bun.JSError!void {
    try task.run_fn(task);
}

pub fn destroy(task: *NativeMicrotask) void {
    task.destroy_fn(task);
}

const bun = @import("bun");
