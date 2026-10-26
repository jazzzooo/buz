/// To add a new task to the task queue:
/// 1. Add the type to the TaggedPointerUnion
/// 2. Update the switch statement in tickQueueWithCount() to run the task
pub const Task = TaggedPointerUnion(.{
    AnyTask,
    bun.bake.DevServer.HotReloadEvent,
    CppTask,
    CopyFileTask,
    FSWatchTask,
    GetAddrInfoRequestTask,
    HotReloadTask,
    ImmediateObject,
    JSCDeferredWorkTask,
    IntrusiveTask,
    ManagedTask,
    napi_async_work,
    NapiFinalizerTask,
    PollPendingModulesTask,
    PosixSignalTask,
    ReadFileTask,
    NativeTask,
    S3HttpDownloadStreamingTask,
    S3HttpSimpleTask,
    ThreadSafeFunction,
    TimeoutObject,
    WriteFileTask,
});

pub fn tickQueueWithCount(this: *EventLoop, virtual_machine: *VirtualMachine, counter: *u32) bun.JSTerminated!void {
    var global = this.global;
    const global_vm = global.vm();

    if (comptime Environment.isDebug) {
        if (this.debug.js_call_count_outside_tick_queue > this.debug.drain_microtasks_count_outside_tick_queue) {
            if (this.debug.track_last_fn_name) {
                bun.Output.panic(
                    \\<b>{d} JavaScript functions<r> were called outside of the microtask queue without draining microtasks.
                    \\
                    \\Last function name: {f}
                    \\
                    \\Use typed callback dispatch, or pair EventLoop.enter() with exit(), when invoking JavaScript outside the task queue.
                    \\
                    \\Failing to do this can lead to a large number of microtasks being queued and not being drained, which can lead to a large amount of memory being used and application slowdown.
                ,
                    .{
                        this.debug.js_call_count_outside_tick_queue - this.debug.drain_microtasks_count_outside_tick_queue,
                        this.debug.last_fn_name,
                    },
                );
            } else {
                bun.Output.panic(
                    \\<b>{d} JavaScript functions<r> were called outside of the microtask queue without draining microtasks. To track the last function name, set the BUN_TRACK_LAST_FN_NAME environment variable.
                    \\
                    \\Use typed callback dispatch, or pair EventLoop.enter() with exit(), when invoking JavaScript outside the task queue.
                    \\
                    \\Failing to do this can lead to a large number of microtasks being queued and not being drained, which can lead to a large amount of memory being used and application slowdown.
                ,
                    .{this.debug.js_call_count_outside_tick_queue - this.debug.drain_microtasks_count_outside_tick_queue},
                );
            }
        }
    }

    while (this.tasks.readItem()) |task| {
        log("run {s}", .{@tagName(task.tag())});
        defer counter.* += 1;
        switch (task.tag()) {
            Task.case(NativeTask) => {
                task.get(NativeTask).?.run(virtual_machine);
            },
            Task.case(S3HttpSimpleTask) => {
                var s3_task: *S3HttpSimpleTask = task.get(S3HttpSimpleTask).?;
                s3_task.onResponse();
            },
            Task.case(S3HttpDownloadStreamingTask) => {
                var s3_task: *S3HttpDownloadStreamingTask = task.get(S3HttpDownloadStreamingTask).?;
                s3_task.onResponse();
            },
            Task.case(bun.api.napi.napi_async_work) => {
                const transform_task: *bun.api.napi.napi_async_work = task.get(bun.api.napi.napi_async_work).?;
                transform_task.runFromJS(virtual_machine, global);
            },
            Task.case(ThreadSafeFunction) => {
                var transform_task: *ThreadSafeFunction = task.as(ThreadSafeFunction);
                transform_task.onDispatch();
            },
            Task.case(ReadFileTask) => {
                var transform_task: *ReadFileTask = task.get(ReadFileTask).?;
                defer transform_task.deinit();
                try transform_task.runFromJS();
            },
            Task.case(JSCDeferredWorkTask) => {
                var jsc_task: *JSCDeferredWorkTask = task.get(JSCDeferredWorkTask).?;
                jsc_task.run(global) catch |err| try reportErrorOrTerminate(global, err);
            },
            Task.case(WriteFileTask) => {
                var transform_task: *WriteFileTask = task.get(WriteFileTask).?;
                defer transform_task.deinit();
                try transform_task.runFromJS();
            },
            Task.case(CopyFileTask) => {
                const copy_task = task.get(CopyFileTask).?;
                defer copy_task.deinit();
                try copy_task.runFromJS();
            },
            Task.case(HotReloadTask) => {
                const transform_task: *HotReloadTask = task.get(HotReloadTask).?;
                defer transform_task.deinit();
                transform_task.run();
                // special case: we return
                // hot reload runs immediately so it should not drain microtasks
                counter.* = 0;
                return;
            },
            Task.case(bun.bake.DevServer.HotReloadEvent) => {
                const hmr_task: *bun.bake.DevServer.HotReloadEvent = task.get(bun.bake.DevServer.HotReloadEvent).?;
                hmr_task.run();
            },
            Task.case(FSWatchTask) => {
                var transform_task: *FSWatchTask = task.get(FSWatchTask).?;
                defer transform_task.deinit();
                transform_task.run();
            },
            Task.case(AnyTask) => {
                var any: *AnyTask = task.get(AnyTask).?;
                any.run() catch |err| try reportErrorOrTerminate(global, err);
            },
            Task.case(ManagedTask) => {
                var any: *ManagedTask = task.get(ManagedTask).?;
                any.run() catch |err| try reportErrorOrTerminate(global, err);
            },
            Task.case(IntrusiveTask) => {
                task.get(IntrusiveTask).?.run();
            },
            Task.case(CppTask) => {
                var any: *CppTask = task.get(CppTask).?;
                any.run(global) catch |err| try reportErrorOrTerminate(global, err);
            },
            Task.case(PollPendingModulesTask) => {
                virtual_machine.modules.onPoll();
            },
            Task.case(GetAddrInfoRequestTask) => {
                const any: *GetAddrInfoRequestTask = task.get(GetAddrInfoRequestTask).?;
                defer any.deinit();
                try any.runFromJS();
            },
            Task.case(PosixSignalTask) => {
                PosixSignalTask.runFromJSThread(@intCast(task.asUintptr()), global) catch |err|
                    try reportErrorOrTerminate(global, err);
            },
            Task.case(NapiFinalizerTask) => {
                var any: *NapiFinalizerTask = task.get(NapiFinalizerTask).?;
                any.runOnJSThread();
            },
            else => {
                bun.Output.panic("Unexpected Task tag: {d}", .{@backingInt(task.tag())});
            },
        }

        try this.drainMicrotasksWithGlobal(global, global_vm);
    }
}

pub fn reportErrorOrTerminate(global: *jsc.JSGlobalObject, proof: bun.JSError) bun.JSTerminated!void {
    @branchHint(.cold);
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    _ = try scope.reportPendingException(proof);
}

const log = bun.Output.scoped(.Task, .hidden);

const JSCScheduler = @import("../jsc/JSCScheduler.zig");
const JSCDeferredWorkTask = JSCScheduler.JSCDeferredWorkTask;

const bun = @import("bun");
const Async = bun.Async;
const Environment = bun.Environment;
const TaggedPointerUnion = bun.TaggedPointerUnion;
const GetAddrInfoRequestTask = bun.api.dns.GetAddrInfoRequest.Task;
const CopyFileTask = @import("../runtime/webcore/blob/CopyFileEngine.zig").Task;
const ReadFileTask = @import("../runtime/webcore/blob/ReadFileEngine.zig").Task;
const WriteFileTask = bun.webcore.Blob.write_file.WriteFileTask;
const FSWatchTask = bun.jsc.NodeFSWatcherEngine.FSWatcher.FSWatchTask;
const NativeTask = @import("../event_loop/AnyTaskWithExtraContext.zig");

const S3 = bun.S3;
const S3HttpDownloadStreamingTask = S3.S3HttpDownloadStreamingTask;
const S3HttpSimpleTask = S3.S3HttpSimpleTask;

const NapiFinalizerTask = bun.api.napi.NapiFinalizerTask;
const ThreadSafeFunction = bun.api.napi.ThreadSafeFunction;
const napi_async_work = bun.api.napi.napi_async_work;

const jsc = bun.jsc;
const AnyTask = jsc.AnyTask;
const CppTask = jsc.CppTask;
const EventLoop = jsc.EventLoop;
const IntrusiveTask = jsc.IntrusiveTask;
const ManagedTask = jsc.ManagedTask;
const PosixSignalTask = jsc.PosixSignalTask;
const VirtualMachine = jsc.VirtualMachine;
const HotReloadTask = jsc.hot_reloader.HotReloader.Task;

const Timer = jsc.API.Timer;
const ImmediateObject = Timer.ImmediateObject;
const TimeoutObject = Timer.TimeoutObject;

const PollPendingModulesTask = jsc.ModuleLoader.AsyncModule.Queue;
