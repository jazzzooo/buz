const EventLoop = @This();

tasks: Queue = .{},
accepts_cancellable_tasks: bool = true,
native_completion_registry: ?*jsc.NativeCompletionRegistry = null,

/// setImmediate() gets it's own two task queues
/// When you call `setImmediate` in JS, it queues to the start of the next tick
/// This is confusing, but that is how it works in Node.js.
///
/// So we have two queues:
///   - next_immediate_tasks: tasks that will run on the next tick
///   - immediate_tasks: tasks that will run on the current tick
///
/// Having two queues avoids infinite loops creating by calling `setImmediate` in a `setImmediate` callback.
immediate_tasks: std.ArrayList(*Timer.ImmediateObject) = .empty,
next_immediate_tasks: std.ArrayList(*Timer.ImmediateObject) = .empty,

concurrent_tasks: ConcurrentTask.Queue = ConcurrentTask.Queue{},
global: *jsc.JSGlobalObject = undefined,
virtual_machine: *VirtualMachine = undefined,
deferred_tasks: DeferredTaskQueue = .{},
uws_loop: if (Environment.isWindows) ?*uws.Loop else void = if (Environment.isWindows) null,

debug: Debug = .{},
entered_event_loop_count: isize = 0,
concurrent_ref: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
imminent_gc_timer: std.atomic.Value(?*Timer.WTFTimer) = .{ .raw = null },

signal_handler: if (Environment.isPosix) ?*PosixSignalHandle else void = if (Environment.isPosix) null,

pub const Debug = if (Environment.isDebug) struct {
    is_inside_tick_queue: bool = false,
    js_call_count_outside_tick_queue: usize = 0,
    drain_microtasks_count_outside_tick_queue: usize = 0,
    _prev_is_inside_tick_queue: bool = false,
    last_fn_name: bun.String = bun.String.empty,
    track_last_fn_name: bool = false,

    pub fn enter(this: *Debug) void {
        this._prev_is_inside_tick_queue = this.is_inside_tick_queue;
        this.is_inside_tick_queue = true;
        this.js_call_count_outside_tick_queue = 0;
        this.drain_microtasks_count_outside_tick_queue = 0;
    }

    pub fn exit(this: *Debug) void {
        this.is_inside_tick_queue = this._prev_is_inside_tick_queue;
        this._prev_is_inside_tick_queue = false;
        this.js_call_count_outside_tick_queue = 0;
        this.drain_microtasks_count_outside_tick_queue = 0;
        this.last_fn_name.deref();
        this.last_fn_name = bun.String.empty;
    }
} else struct {
    pub inline fn enter(_: Debug) void {}
    pub inline fn exit(_: Debug) void {}
};

/// Before your code enters JavaScript at the top of the event loop, call
/// `loop.enter()`. Typed callback dispatch manages this scope automatically.
///
/// When we call into JavaScript, we must drain process.nextTick & microtasks
/// afterwards (so that promises run). We must only do that once per task in the
/// event loop. To make that work, we count enter/exit calls and once that
/// counter reaches 0, we drain the microtasks.
///
/// This function increments the counter for the number of times we've entered
/// the event loop.
pub fn enter(this: *EventLoop) void {
    log("enter() = {d}", .{this.entered_event_loop_count});
    this.entered_event_loop_count += 1;
    this.debug.enter();
}

/// "exit" a microtask context in the event loop.
///
/// See the documentation for `enter` for more information.
pub fn exit(this: *EventLoop) void {
    const count = this.entered_event_loop_count;
    log("exit() = {d}", .{count - 1});

    defer this.debug.exit();

    if (count == 1 and !this.virtual_machine.is_inside_deferred_task_queue) {
        this.drainMicrotasksWithGlobal(this.global, this.virtual_machine.jsc_vm) catch |err|
            this.global.reportActiveExceptionAsUnhandled(err);
    }

    this.entered_event_loop_count -= 1;
}

pub fn exitMaybeDrainMicrotasks(this: *EventLoop, allow_drain_microtask: bool) bun.JSTerminated!void {
    const count = this.entered_event_loop_count;
    log("exit() = {d}", .{count - 1});

    defer this.debug.exit();

    if (allow_drain_microtask and count == 1 and !this.virtual_machine.is_inside_deferred_task_queue) {
        try this.drainMicrotasksWithGlobal(this.global, this.virtual_machine.jsc_vm);
    }

    this.entered_event_loop_count -= 1;
}

pub inline fn getVmImpl(this: *EventLoop) *VirtualMachine {
    return this.virtual_machine;
}

pub fn pipeReadBuffer(this: *const EventLoop) []u8 {
    return this.virtual_machine.rareData().pipeReadBuffer();
}

pub const Queue = @import("../event_loop/TaskQueue.zig");
const log = bun.Output.scoped(.EventLoop, .hidden);

pub fn tickWhilePaused(this: *EventLoop, done: *bool) void {
    while (!done.*) {
        this.virtual_machine.event_loop_handle.?.tick();
    }
}

pub fn drainMicrotasksWithGlobal(this: *EventLoop, globalObject: *jsc.JSGlobalObject, jsc_vm: *jsc.VM) bun.JSTerminated!void {
    // During spawnSync, the isolated event loop shares the same VM/GlobalObject.
    // Draining microtasks would execute user JavaScript, which must not happen.
    if (this.virtual_machine.suppress_microtask_drain) return;

    jsc_vm.releaseWeakRefs();

    bun.bindgen.Engine(DrainMicrotasksSchema).call(globalObject, .{}) catch return error.JSTerminated;

    {
        const was_inside = this.virtual_machine.is_inside_deferred_task_queue;
        this.virtual_machine.is_inside_deferred_task_queue = true;
        defer this.virtual_machine.is_inside_deferred_task_queue = was_inside;
        this.deferred_tasks.run();
    }

    if (this.virtual_machine.event_loop_handle != null) {
        this.virtual_machine.uwsLoop().drainQuicIfNecessary();
    }

    if (comptime bun.Environment.isDebug) {
        this.debug.drain_microtasks_count_outside_tick_queue += @as(usize, @intFromBool(!this.debug.is_inside_tick_queue));
    }
}

pub fn drainMicrotasks(this: *EventLoop) bun.JSTerminated!void {
    try this.drainMicrotasksWithGlobal(this.global, this.virtual_machine.jsc_vm);
}

// should be called after exit()
pub fn maybeDrainMicrotasks(this: *EventLoop) void {
    if (this.entered_event_loop_count == 0 and !this.virtual_machine.is_inside_deferred_task_queue) {
        this.drainMicrotasksWithGlobal(this.global, this.virtual_machine.jsc_vm) catch |err|
            this.global.reportActiveExceptionAsUnhandled(err);
    }
}

fn bindEnter(
    _: bun.bindgen.CallContext(EnterSchema),
    _: bun.bindgen.Args(EnterSchema),
) bun.bindgen.Return(EnterSchema) {
    jsc.VirtualMachine.get().eventLoop().enter();
}

fn bindExit(
    _: bun.bindgen.CallContext(ExitSchema),
    _: bun.bindgen.Args(ExitSchema),
) bun.bindgen.Return(ExitSchema) {
    jsc.VirtualMachine.get().eventLoop().exit();
}

fn tickWithCount(this: *EventLoop, virtual_machine: *VirtualMachine) u32 {
    var counter: u32 = 0;
    this.tickQueueWithCount(virtual_machine, &counter) catch |err|
        this.global.reportActiveExceptionAsUnhandled(err);
    return counter;
}

pub fn tickImmediateTasks(this: *EventLoop, virtual_machine: *VirtualMachine) void {
    var to_run_now = this.immediate_tasks;

    this.immediate_tasks = this.next_immediate_tasks;
    this.next_immediate_tasks = .empty;

    var exception_thrown = false;
    for (to_run_now.items) |task| {
        exception_thrown = task.runImmediateTask(virtual_machine);
    }

    // make sure microtasks are drained if the last task had an exception
    if (exception_thrown) {
        this.maybeDrainMicrotasks();
    }

    if (this.next_immediate_tasks.capacity > 0) {
        // this would only occur if we were recursively running tickImmediateTasks.
        @branchHint(.unlikely);
        bun.handleOom(this.immediate_tasks.appendSlice(bun.default_allocator, this.next_immediate_tasks.items));
        this.next_immediate_tasks.deinit(bun.default_allocator);
    }

    if (to_run_now.capacity > 1024 * 128) {
        // once in a while, deinit the array to free up memory
        to_run_now.clearAndFree(bun.default_allocator);
    } else {
        to_run_now.clearRetainingCapacity();
    }

    this.next_immediate_tasks = to_run_now;
}

fn tickConcurrent(this: *EventLoop) void {
    _ = this.tickConcurrentWithCount();
}

/// Check whether refConcurrently has been called but the change has not yet been applied to the
/// underlying event loop's `active` counter
pub fn hasPendingRefs(this: *const EventLoop) bool {
    return this.concurrent_ref.load(.seq_cst) > 0;
}

fn updateCounts(this: *EventLoop) void {
    const delta = this.concurrent_ref.swap(0, .seq_cst);
    const loop = this.virtual_machine.event_loop_handle.?;
    if (comptime Environment.isWindows) {
        if (delta > 0) {
            loop.addActive(@intCast(delta));
        } else {
            loop.subActive(@intCast(-delta));
        }
    } else {
        if (delta > 0) {
            loop.num_polls += @intCast(delta);
            loop.active +|= @as(u32, @intCast(delta));
        } else {
            loop.num_polls -= @intCast(-delta);
            loop.active -|= @as(u32, @intCast(-delta));
        }
    }
}

pub fn runImminentGCTimer(this: *EventLoop) void {
    if (this.imminent_gc_timer.swap(null, .seq_cst)) |timer| {
        timer.run(this.virtual_machine);
    }
}

pub fn tickConcurrentWithCount(this: *EventLoop) usize {
    this.updateCounts();

    if (comptime Environment.isPosix) {
        if (this.signal_handler) |signal_handler| {
            signal_handler.drain(this);
        }
    }

    this.runImminentGCTimer();

    const concurrent = this.concurrent_tasks.popBatch();
    this.tasks.appendBatch(concurrent);
    return concurrent.count;
}

pub fn cancelTask(this: *EventLoop, task: *ConcurrentTask) bool {
    this.tasks.appendBatch(this.concurrent_tasks.popBatch());
    return this.tasks.remove(&task.node);
}

pub fn cancelNativeTask(this: *EventLoop, task: *AnyTaskWithExtraContext) bool {
    this.tasks.appendBatch(this.concurrent_tasks.popBatch());
    return this.tasks.remove(&task.event_loop_node);
}

pub fn usocketsLoop(this: *const EventLoop) *uws.Loop {
    if (comptime Environment.isWindows) {
        return this.uws_loop.?;
    }

    return this.virtual_machine.event_loop_handle.?;
}

pub fn autoTick(this: *EventLoop) void {
    const loop = this.usocketsLoop();
    const ctx = this.virtual_machine;

    this.tickImmediateTasks(ctx);
    if (comptime Environment.isWindows) {
        if (this.immediate_tasks.items.len > 0) {
            this.wakeup();
        }
    }
    // On POSIX, pending immediates are handled via an immediate timeout in
    // getTimeout() instead of writing to the eventfd, avoiding that overhead.

    if (comptime Environment.isPosix) {
        // Some tasks need to keep the event loop alive for one more tick.
        // We want to keep the event loop alive long enough to process those ticks and any microtasks
        //
        // BUT. We don't actually have an idle event in that case.
        // That means the process will be waiting forever on nothing.
        // So we need to drain the counter immediately before entering uSockets loop
        const pending_unref = ctx.pending_unref_counter;
        if (pending_unref > 0) {
            ctx.pending_unref_counter = 0;
            loop.unrefCount(pending_unref);
        }
    }

    ctx.timer.updateDateHeaderTimerIfNecessary(loop, ctx);

    this.runImminentGCTimer();

    if (loop.isActive()) {
        this.processGCTimer();
        var event_loop_sleep_timer = if (comptime Environment.isDebug) bun.SystemTimer.start() catch unreachable;
        // for the printer, this is defined:
        var timespec: bun.timespec = if (Environment.isDebug) .{ .sec = 0, .nsec = 0 } else undefined;
        loop.tickWithTimeout(if (ctx.timer.getTimeout(&timespec, ctx)) &timespec else null);

        if (comptime Environment.isDebug) {
            log("tick {d}ns, timeout: {d}ns", .{ event_loop_sleep_timer.read(), timespec.ns() });
        }
    } else {
        loop.tickWithoutIdle();
        if (comptime Environment.isDebug) {
            log("tickWithoutIdle", .{});
        }
    }

    if (Environment.isPosix) {
        ctx.timer.drainTimers(ctx);
    }

    ctx.onAfterEventLoop();
    this.global.handleRejectedPromises();
}

pub fn tickPossiblyForever(this: *EventLoop) void {
    const ctx = this.virtual_machine;
    const loop = this.usocketsLoop();

    if (comptime Environment.isPosix) {
        const pending_unref = ctx.pending_unref_counter;
        if (pending_unref > 0) {
            ctx.pending_unref_counter = 0;
            loop.unrefCount(pending_unref);
        }
    }

    loop.ref();
    defer loop.unref();

    this.processGCTimer();
    var timeout: bun.timespec = undefined;
    loop.tickWithTimeout(if (ctx.timer.getTimeout(&timeout, ctx)) &timeout else null);
    if (comptime Environment.isPosix) ctx.timer.drainTimers(ctx);

    ctx.onAfterEventLoop();
    this.tickConcurrent();
    this.tick();
}

pub fn autoTickActive(this: *EventLoop) void {
    var loop = this.usocketsLoop();
    var ctx = this.virtual_machine;

    this.tickImmediateTasks(ctx);
    if (comptime Environment.isWindows) {
        if (this.immediate_tasks.items.len > 0) {
            this.wakeup();
        }
    }
    // On POSIX, pending immediates are handled via an immediate timeout in
    // getTimeout() instead of writing to the eventfd, avoiding that overhead.

    if (comptime Environment.isPosix) {
        const pending_unref = ctx.pending_unref_counter;
        if (pending_unref > 0) {
            ctx.pending_unref_counter = 0;
            loop.unrefCount(pending_unref);
        }
    }

    ctx.timer.updateDateHeaderTimerIfNecessary(loop, ctx);

    if (loop.isActive()) {
        this.processGCTimer();
        var timespec: bun.timespec = undefined;

        loop.tickWithTimeout(if (ctx.timer.getTimeout(&timespec, ctx)) &timespec else null);
    } else {
        loop.tickWithoutIdle();
    }

    if (Environment.isPosix) {
        ctx.timer.drainTimers(ctx);
    }

    ctx.onAfterEventLoop();
}

pub fn processGCTimer(this: *EventLoop) void {
    this.virtual_machine.gc_controller.processGCTimer();
}

pub fn tick(this: *EventLoop) void {
    this.entered_event_loop_count += 1;
    this.debug.enter();
    defer {
        this.entered_event_loop_count -= 1;
        this.debug.exit();
    }

    const ctx = this.virtual_machine;
    defer ctx.drainNativeFinalizers();
    this.tickConcurrent();
    this.processGCTimer();

    const global = ctx.global;
    const global_vm = ctx.jsc_vm;

    while (true) {
        while (this.tickWithCount(ctx) > 0) : (this.global.handleRejectedPromises()) {
            this.tickConcurrent();
        } else {
            this.drainMicrotasksWithGlobal(global, global_vm) catch return;
            if (this.global.hasExceptionIncludingTraps()) return;
            this.tickConcurrent();
            if (this.tasks.count > 0) continue;
        }
        break;
    }

    while (this.tickWithCount(ctx) > 0) {
        this.tickConcurrent();
    }

    this.global.handleRejectedPromises();
}

/// Tick the task queue without draining microtasks afterward.
/// Used by SpawnSyncEventLoop to process I/O completion tasks (pipe read/write,
/// process exit) without running user JavaScript via the global microtask queue.
///
/// `tickQueueWithCount` unconditionally calls `drainMicrotasksWithGlobal` after
/// every task (Task.zig), which drains the shared JSC microtask queue and can
/// execute arbitrary user JS. This method sets a flag to suppress that drain.
pub fn tickTasksOnly(this: *EventLoop) void {
    this.tickConcurrent();

    const vm = this.virtual_machine;
    const prev = vm.suppress_microtask_drain;
    vm.suppress_microtask_drain = true;
    defer vm.suppress_microtask_drain = prev;

    while (this.tickWithCount(vm) > 0) {
        this.tickConcurrent();
    }
}

pub fn enqueueTask(this: *EventLoop, task: Task) void {
    this.tasks.writeItem(task) catch unreachable;
}

pub fn enqueueImmediateTask(this: *EventLoop, task: *Timer.ImmediateObject) void {
    bun.handleOom(this.immediate_tasks.append(bun.default_allocator, task));
}

pub fn ensureWaker(this: *EventLoop) void {
    if (this.virtual_machine.event_loop_handle == null) {
        if (comptime Environment.isWindows) {
            this.uws_loop = bun.uws.Loop.get();
            this.virtual_machine.event_loop_handle = Async.Loop.get();
        } else {
            this.virtual_machine.event_loop_handle = bun.Async.Loop.get();
        }

        this.virtual_machine.gc_controller.init(this.virtual_machine);
    }
    if (comptime Environment.isWindows) {
        if (this.uws_loop == null) {
            this.uws_loop = bun.uws.Loop.get();
        }
    }
    bun.jsc.EventLoopHandle.init(this).attach(bun.uws.Loop.get());
}

/// Asynchronously run the garbage collector and track how much memory is now allocated
pub fn performGC(this: *EventLoop) void {
    this.virtual_machine.gc_controller.performGC();
}

pub fn wakeup(this: *EventLoop) void {
    if (comptime Environment.isWindows) {
        if (this.uws_loop) |loop| {
            loop.wakeup();
        }
        return;
    }

    if (this.virtual_machine.event_loop_handle) |loop| {
        loop.wakeup();
    }
}
pub fn enqueueTaskConcurrent(this: *EventLoop, task: *ConcurrentTask) void {
    if (comptime Environment.allow_assert) {
        if (this.virtual_machine.has_terminated) {
            @panic("EventLoop.enqueueTaskConcurrent: VM has terminated");
        }
    }

    if (comptime Environment.isDebug) {
        log("enqueueTaskConcurrent({s})", .{task.task.typeName() orelse "[unknown]"});
    }

    this.concurrent_tasks.push(&task.node);
    this.wakeup();
}

pub fn enqueueNativeTaskConcurrent(this: *EventLoop, task: *AnyTaskWithExtraContext) void {
    bun.assert(!this.virtual_machine.has_terminated);
    this.concurrent_tasks.push(&task.event_loop_node);
    this.wakeup();
}

pub fn enqueueNativeTask(this: *EventLoop, task: *AnyTaskWithExtraContext) void {
    bun.assert(!this.virtual_machine.has_terminated);
    this.tasks.appendBatch(.{
        .front = &task.event_loop_node,
        .last = &task.event_loop_node,
        .count = 1,
    });
}

pub fn enqueueTaskConcurrentBatch(this: *EventLoop, batch: ConcurrentTask.Queue.Batch) void {
    if (comptime Environment.allow_assert) {
        if (this.virtual_machine.has_terminated) {
            @panic("EventLoop.enqueueTaskConcurrent: VM has terminated");
        }
    }

    if (comptime Environment.isDebug) {
        log("enqueueTaskConcurrentBatch({d})", .{batch.count});
    }

    this.concurrent_tasks.pushBatch(batch.front.?, batch.last.?);
    this.wakeup();
}

pub fn refConcurrently(this: *EventLoop) void {
    _ = this.concurrent_ref.fetchAdd(1, .seq_cst);
    this.wakeup();
}

pub fn unrefConcurrently(this: *EventLoop) void {
    // TODO maybe this should be AcquireRelease
    _ = this.concurrent_ref.fetchSub(1, .seq_cst);
    this.wakeup();
}

/// Testing API to expose event loop state
pub fn getActiveTasks(
    _: bun.bindgen.CallContext(GetActiveTasksSchema),
    _: bun.bindgen.Args(GetActiveTasksSchema),
) bun.JSError!bun.bindgen.Return(GetActiveTasksSchema) {
    const vm = jsc.VirtualMachine.get();
    const event_loop = vm.event_loop;

    // Get num_polls from uws loop (POSIX) or active_handles from libuv (Windows)
    const num_polls: i32 = if (Environment.isWindows)
        @intCast(bun.windows.libuv.Loop.get().active_handles)
    else
        uws.Loop.get().num_polls;
    return .{
        .active_tasks = vm.active_tasks,
        .concurrent_ref = event_loop.concurrent_ref.load(.seq_cst),
        .num_polls = num_polls,
    };
}

pub fn discardEngineTasks(this: *EventLoop) usize {
    this.accepts_cancellable_tasks = false;
    const EngineTasks = struct {
        fn matches(task: Task) bool {
            if (task.get(AnyTaskWithExtraContext)) |native| return native.on_cancel != null;
            return task.get(CppTask) != null or task.get(JSCDeferredWorkTask) != null or
                task.get(jsc.IntrusiveTask) != null;
        }
    };
    var discarded: usize = 0;
    while (true) {
        this.tasks.appendBatch(this.concurrent_tasks.popBatch());
        const task = this.tasks.takeMatching(EngineTasks.matches) orelse break;
        discarded += 1;
        if (task.get(CppTask)) |callback| {
            callback.deinit();
        } else if (task.get(jsc.IntrusiveTask)) |callback| {
            callback.cancel();
        } else if (task.get(AnyTaskWithExtraContext)) |callback| {
            callback.cancel();
        } else {
            task.get(JSCDeferredWorkTask).?.deinit();
        }
    }
    return discarded;
}

pub fn deinit(this: *EventLoop) void {
    this.deferred_tasks.deinit();
    if (this.native_completion_registry) |registry| {
        this.native_completion_registry = null;
        registry.close();
        this.virtual_machine.rare_data.?.unregisterNativeCompletionRegistry(registry);
        registry.release();
    }
    this.tasks.appendBatch(this.concurrent_tasks.popBatch());
    this.tasks.deinit();
    this.immediate_tasks.clearAndFree(bun.default_allocator);
    this.next_immediate_tasks.clearAndFree(bun.default_allocator);
}

pub const WorkTask = @import("./WorkTask.zig").WorkTask;
pub const AnyTask = @import("../event_loop/AnyTaskEngine.zig");
pub const ManagedTask = @import("../event_loop/ManagedTaskEngine.zig");
pub const AnyTaskWithExtraContext = @import("../event_loop/AnyTaskWithExtraContext.zig");
pub const CppTaskModule = @import("./CppTask.zig");
pub const CppTask = @import("./CppTask.zig").CppTask;
pub const ConcurrentCppTask = @import("./CppTask.zig").ConcurrentCppTask;
pub const JSCScheduler = @import("./JSCScheduler.zig");
const JSCDeferredWorkTask = JSCScheduler.JSCDeferredWorkTask;
pub const Task = @import("./Task.zig").Task;
pub const ConcurrentTask = @import("../event_loop/ConcurrentTaskEngine.zig");
pub const GarbageCollectionController = @import("./GarbageCollectionController.zig");
pub const DeferredTaskQueue = @import("../event_loop/DeferredTaskQueue.zig");
pub const DeferredRepeatingTask = DeferredTaskQueue.DeferredRepeatingTask;
pub const PosixSignalHandle = @import("./PosixSignalHandle.zig");
pub const PosixSignalTask = PosixSignalHandle.PosixSignalTask;
pub const MiniEventLoop = @import("../event_loop/MiniEventLoop.zig");
pub const MiniVM = MiniEventLoop.MiniVM;
pub const EventLoopKind = @import("../event_loop/types.zig").Kind;

pub const JsVM = struct {
    vm: *VirtualMachine,

    pub inline fn init(inner: *VirtualMachine) JsVM {
        return .{ .vm = inner };
    }

    pub inline fn loop(this: JsVM) *EventLoop {
        return this.vm.event_loop;
    }

    pub inline fn platformEventLoop(this: JsVM) *jsc.PlatformEventLoop {
        return this.vm.event_loop_handle.?;
    }

    pub inline fn incrementPendingUnrefCounter(this: JsVM) void {
        this.vm.pending_unref_counter +|= 1;
    }

    pub inline fn filePolls(this: JsVM) *Async.FilePoll.Store {
        return this.vm.rareData().filePolls(this.vm);
    }
};

pub fn AbstractVM(inner: anytype) switch (@TypeOf(inner)) {
    *VirtualMachine => JsVM,
    *MiniEventLoop => MiniVM,
    RuntimeLoopHandle => RuntimeLoopHandle,
    else => @compileError("Invalid event loop ctx: " ++ @typeName(@TypeOf(inner))),
} {
    if (comptime @TypeOf(inner) == *VirtualMachine) return JsVM.init(inner);
    if (comptime @TypeOf(inner) == *MiniEventLoop) return MiniVM.init(inner);
    if (comptime @TypeOf(inner) == RuntimeLoopHandle) return inner;
    @compileError("Invalid event loop ctx: " ++ @typeName(@TypeOf(inner)));
}

pub fn setLoopVM(loop: *uws.Loop, vm: ?*jsc.VM) void {
    loop.internal_loop_data.setBeforeWait(vm, if (vm == null) null else onBeforeWait);
}

fn onBeforeWait(context: ?*anyopaque) callconv(.c) void {
    const vm: *jsc.VM = @ptrCast(@alignCast(context orelse unreachable));
    vm.onBeforeWait();
}

pub const EventLoopHandle = @import("./EventLoopHandle.zig").EventLoopHandle;
pub const EventLoopTask = @import("./EventLoopHandle.zig").EventLoopTask;
pub const EventLoopTaskPtr = @import("./EventLoopHandle.zig").EventLoopTaskPtr;

const std = @import("std");
const tickQueueWithCount = @import("./Task.zig").tickQueueWithCount;

const bun = @import("bun");
const Environment = bun.Environment;
const uws = bun.uws;
const Timer = bun.api.Timer;

const Async = bun.Async;

const jsc = bun.jsc;
const VirtualMachine = bun.jsc.VirtualMachine;
const RuntimeLoopHandle = bun.RuntimeLoopHandle;
const DrainMicrotasksSchema = bun.bindgen.Module("microtasks").engineShim("drainMicrotasks");

const EventLoopBindings = bun.bindgen.Module("EventLoop");
const EnterSchema = EventLoopBindings.nativeExport("enter");
const ExitSchema = EventLoopBindings.nativeExport("exit");
const EnterBinding = bun.bindgen.Fn(EnterSchema, bindEnter);
const ExitBinding = bun.bindgen.Fn(ExitSchema, bindExit);

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const GetActiveTasksSchema = InternalTestingBindings.function("getActiveTasks");
const GetActiveTasksBinding = bun.bindgen.Fn(GetActiveTasksSchema, getActiveTasks);

comptime {
    _ = EnterBinding;
    _ = ExitBinding;
    _ = GetActiveTasksBinding;
}
