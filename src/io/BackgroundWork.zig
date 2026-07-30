pub const Batch = BackgroundTaskGroup.Batch;
pub const Task = BackgroundTaskGroup.Task;

pub const BackgroundWork = struct {
    pub fn schedule(group: *BackgroundTaskGroup, task: *Task) std.Io.ConcurrentError!void {
        try group.scheduleTask(task);
    }

    pub fn scheduleContinuation(group: *BackgroundTaskGroup, task: *Task) void {
        group.scheduleContinuationTask(task);
    }

    pub fn go(
        group: *BackgroundTaskGroup,
        allocator: std.mem.Allocator,
        comptime Context: type,
        context: Context,
        comptime function: fn (Context) void,
    ) !void {
        const TaskType = struct {
            task: Task,
            context: Context,
            allocator: std.mem.Allocator,

            pub fn callback(task: *Task) void {
                var this_task: *@This() = @fieldParentPtr("task", task);
                function(this_task.context);
                this_task.allocator.destroy(this_task);
            }

            pub fn cancel(task: *Task) void {
                const this_task: *@This() = @fieldParentPtr("task", task);
                this_task.allocator.destroy(this_task);
            }
        };

        var task_ = try allocator.create(TaskType);
        task_.* = .{
            .task = .{
                .callback = TaskType.callback,
                .on_cancel = TaskType.cancel,
            },
            .context = context,
            .allocator = allocator,
        };
        errdefer allocator.destroy(task_);
        try schedule(group, &task_.task);
    }
};

const std = @import("std");

const bun = @import("bun");
const BackgroundTaskGroup = bun.BackgroundTaskGroup;
