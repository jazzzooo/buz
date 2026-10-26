const WorkTaskContext = @This();

background_tasks: *bun.BackgroundTaskGroup,
task_context: *anyopaque,
finish_task: *const fn (*anyopaque) void,

pub fn scheduleContinuation(this: WorkTaskContext, task: *bun.BackgroundTaskGroup.Task) void {
    bun.BackgroundWork.scheduleContinuation(this.background_tasks, task);
}

pub fn finish(this: WorkTaskContext) void {
    this.finish_task(this.task_context);
}

const bun = @import("bun");
