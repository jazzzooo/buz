const StaticPipeWriterSchedulerEngine = @This();

event_loop: jsc.EventLoopHandle,

pub const Task = jsc.AnyTaskWithExtraContext;

pub fn init(event_loop: anytype) StaticPipeWriterSchedulerEngine {
    return .{ .event_loop = jsc.EventLoopHandle.init(event_loop) };
}

pub fn runtimeLoopHandle(this: StaticPipeWriterSchedulerEngine) bun.RuntimeLoopHandle {
    return this.event_loop.runtimeLoopHandle();
}

pub fn enqueue(this: StaticPipeWriterSchedulerEngine, task: *Task, target: anytype) void {
    const Target = std.meta.Child(@TypeOf(target));
    const Adapter = struct {
        fn run(instance: *Target, _: *void) void {
            instance.runFromMainThread();
        }

        fn cancel(context: jsc.AnyTaskWithExtraContext.Context) void {
            context.get(*Target).runFromMainThread();
        }
    };
    task.* = jsc.AnyTaskWithExtraContext.New(Target, void, Adapter.run).init(target);
    // The descriptor is closed; cancellation must still release its pending close reference.
    task.on_cancel = Adapter.cancel;
    switch (this.event_loop) {
        .js => |event_loop| {
            event_loop.enqueueNativeTask(task);
        },
        .mini => |event_loop| {
            event_loop.enqueueTaskConcurrent(task);
        },
    }
}

const std = @import("std");
const bun = @import("bun");
const jsc = bun.jsc;
