pub const Pending = struct {
    head: ?*Entry = null,

    const Entry = struct {
        previous: ?*Entry = null,
        next: ?*Entry = null,
        linked: bool = false,
        discard: *const fn (*Entry) void,
    };

    fn append(this: *Pending, entry: *Entry) void {
        bun.assert(!entry.linked);
        entry.linked = true;
        entry.next = this.head;
        if (this.head) |head| head.previous = entry;
        this.head = entry;
    }

    fn remove(this: *Pending, entry: *Entry) void {
        bun.assert(entry.linked);
        if (entry.previous) |previous| previous.next = entry.next else this.head = entry.next;
        if (entry.next) |next| next.previous = entry.previous;
        entry.* = .{ .discard = entry.discard };
    }

    pub fn discardAll(this: *Pending) void {
        while (this.head) |entry| entry.discard(entry);
    }
};

/// Runs `Context.run` in the work pool and transfers delivery to `Context.then` on the VM thread.
/// The context remains caller-owned until scheduling; `then` or VM-thread `discard` consumes it.
/// `requestCancel` runs concurrently with native work; the scope joins it before `discard`.
pub fn WorkTask(comptime Context: type) type {
    const Impl = struct {
        const TaskType = BackgroundTask;

        const This = @This();
        ctx: *Context,
        task: TaskType = .{ .callback = &runInBackground, .on_cancel = cancelBeforeRun },
        operation: bun.BackgroundTaskGroup.Operation = .{ .request_cancel = requestCancel },
        pending: Pending.Entry = .{ .discard = discard },
        event_loop: *jsc.EventLoop,
        globalThis: *jsc.JSGlobalObject,
        concurrent_task: ConcurrentTask = .{},
        async_task_tracker: jsc.Debugger.AsyncTaskTracker,

        ref: Async.KeepAlive = .{},

        pub fn createOnJSThread(globalThis: *jsc.JSGlobalObject, value: *Context) bun.OOM!*This {
            const vm = globalThis.bunVM();
            return try bun.tryNew(This, .{
                .event_loop = vm.eventLoop(),
                .ctx = value,
                .globalThis = globalThis,
                .async_task_tracker = jsc.Debugger.AsyncTaskTracker.init(vm),
            });
        }

        pub fn deinit(this: *This) void {
            bun.assert(!this.pending.linked);
            this.ref.unref(this.event_loop.virtual_machine);
            bun.destroy(this);
        }

        fn requestCancel(operation: *bun.BackgroundTaskGroup.Operation) void {
            const this: *This = @fieldParentPtr("operation", operation);
            this.ctx.requestCancel();
        }

        fn cancelBeforeRun(task: *TaskType) void {
            const this: *This = @fieldParentPtr("task", task);
            this.ctx.requestCancel();
            this.ctx.onScheduleError(error.Canceled);
            this.onFinish();
        }

        fn discard(entry: *Pending.Entry) void {
            const this: *This = @fieldParentPtr("pending", entry);
            const vm = this.event_loop.virtual_machine;
            const removed = this.event_loop.cancelTask(&this.concurrent_task);
            bun.assert(removed);
            vm.pending_work.remove(entry);
            this.async_task_tracker.didCancel(this.globalThis);
            this.ref.unref(vm);
            this.ctx.discard();
            this.deinit();
        }

        pub fn runInBackground(task: *TaskType) void {
            const this: *This = @fieldParentPtr("task", task);
            Context.run(this.ctx, WorkTaskContext{
                .background_tasks = &this.event_loop.virtual_machine.background_tasks,
                .task_context = this,
                .finish_task = finishFromContext,
            });
        }

        fn finishFromContext(context: *anyopaque) void {
            @as(*This, @ptrCast(@alignCast(context))).onFinish();
        }

        pub fn runFromJS(this: *This) bun.JSTerminated!void {
            const ctx = this.ctx;
            const tracker = this.async_task_tracker;
            const vm = this.event_loop.virtual_machine;
            const globalThis = this.globalThis;
            vm.pending_work.remove(&this.pending);
            this.ref.unref(vm);

            tracker.willDispatch(globalThis);
            defer tracker.didDispatch(globalThis);
            return ctx.then();
        }

        pub fn schedule(this: *This) void {
            const vm = this.event_loop.virtual_machine;
            if (vm.background_tasks_deinitialized) {
                this.ctx.discard();
                this.deinit();
                return;
            }
            vm.pending_work.append(&this.pending);
            this.ref.ref(vm);
            this.async_task_tracker.didSchedule(this.globalThis);
            vm.background_tasks.scheduleOperation(&this.operation, &this.task) catch |err| {
                this.ctx.onScheduleError(err);
                this.onFinish();
            };
        }

        pub fn onFinish(this: *This) void {
            const event_loop = this.event_loop;
            const task = this.concurrent_task.from(this, .manual_deinit);
            this.operation.finish();
            event_loop.enqueueTaskConcurrent(task);
        }
    };
    return Impl;
}

const bun = @import("bun");
const Async = bun.Async;

const jsc = bun.jsc;
const ConcurrentTask = jsc.ConcurrentTask;
const BackgroundTask = bun.BackgroundTaskGroup.Task;
const WorkTaskContext = bun.WorkTaskContext;
