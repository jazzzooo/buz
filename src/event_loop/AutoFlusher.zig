pub const Task = @import("./DeferredTaskQueue.zig").Task;

task: Task = .{},

pub fn isRegistered(this: *const @This()) bool {
    return this.task.registered;
}
