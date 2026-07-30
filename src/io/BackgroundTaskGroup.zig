const BackgroundTaskGroup = @This();

executor: *Executor,
mutex: std.Io.Mutex = .init,
condition: std.Io.Condition = .init,
outstanding: usize = 0,
state: std.atomic.Value(State) = .init(.open),

const State = enum(u8) {
    open,
    draining,
    cancel_pending,
    closed,
};

pub const CloseMode = enum {
    drain,
    cancel_pending,
};

pub const Task = struct {
    node: struct {
        next: ?*Task = null,
    } = .{},
    callback: *const fn (*Task) void,
    on_schedule_error: ?*const fn (*Task, std.Io.ConcurrentError) void = null,
    on_cancel: ?*const fn (*Task) void = null,
    scope: ?*BackgroundTaskGroup = null,

    fn cancel(this: *Task) void {
        const callback = this.on_cancel orelse
            @panic("background task has no cancellation handler");
        callback(this);
    }
};

pub const Batch = struct {
    len: usize = 0,
    head: ?*Task = null,
    tail: ?*Task = null,

    pub fn from(task: *Task) Batch {
        task.node.next = null;
        return .{ .len = 1, .head = task, .tail = task };
    }

    pub fn push(this: *Batch, batch: Batch) void {
        if (batch.len == 0) return;
        if (this.len == 0) {
            this.* = batch;
        } else {
            this.tail.?.node.next = batch.head;
            this.tail = batch.tail;
            this.len += batch.len;
        }
    }

    pub fn pop(this: *Batch) ?*Task {
        const task = this.head orelse return null;
        this.head = task.node.next;
        task.node.next = null;
        this.len -= 1;
        if (this.head == null) this.tail = null;
        return task;
    }

    pub fn fail(this: *Batch, err: std.Io.ConcurrentError) void {
        while (this.pop()) |task| {
            const callback = task.on_schedule_error orelse
                @panic("background task batch has no scheduling error handler");
            callback(task, err);
        }
    }

    fn setScope(this: Batch, scope: *BackgroundTaskGroup) void {
        var task = this.head;
        while (task) |item| : (task = item.node.next) {
            item.scope = scope;
        }
    }
};

pub const Executor = struct {
    io: std.Io,
    group: std.Io.Group = .init,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    pending: Batch = .{},
    worker_count: usize = 0,
    active_workers: usize = 0,
    max_workers: usize,
    stopping: bool = false,

    threadlocal var current_scope: ?*BackgroundTaskGroup = null;

    pub fn init(io: std.Io, max_workers: usize) Executor {
        return .{
            .io = io,
            .max_workers = @max(max_workers, 1),
        };
    }

    pub fn deinit(this: *Executor) void {
        this.mutex.lockUncancelable(this.io);
        this.stopping = true;
        this.mutex.unlock(this.io);
        this.condition.broadcast(this.io);

        const protection = this.io.swapCancelProtection(.blocked);
        defer _ = this.io.swapCancelProtection(protection);
        this.group.await(this.io) catch |err| switch (err) {
            error.Canceled => unreachable,
        };
        bun.assert(this.pending.len == 0);
        bun.assert(this.active_workers == 0);
    }

    fn schedule(this: *Executor, batch: Batch) std.Io.ConcurrentError!void {
        this.mutex.lockUncancelable(this.io);
        errdefer this.mutex.unlock(this.io);
        if (this.stopping) return error.ConcurrencyUnavailable;
        if (this.worker_count == 0) try this.spawnWorkerAssumeLocked();
        this.pending.push(batch);
        const desired_workers = @min(this.pending.len + this.active_workers, this.max_workers);
        while (this.worker_count < desired_workers) {
            this.spawnWorkerAssumeLocked() catch break;
        }
        const worker_count = this.worker_count;
        this.mutex.unlock(this.io);
        for (0..@min(batch.len, worker_count)) |_| {
            this.condition.signal(this.io);
        }
    }

    fn scheduleContinuation(this: *Executor, batch: Batch) void {
        this.mutex.lockUncancelable(this.io);
        bun.assert(this.worker_count > 0);
        this.pending.push(batch);
        if (!this.stopping) {
            const desired_workers = @min(this.pending.len + this.active_workers, this.max_workers);
            while (this.worker_count < desired_workers) {
                this.spawnWorkerAssumeLocked() catch break;
            }
        }
        const worker_count = this.worker_count;
        this.mutex.unlock(this.io);
        for (0..@min(batch.len, worker_count)) |_| {
            this.condition.signal(this.io);
        }
    }

    fn spawnWorkerAssumeLocked(this: *Executor) std.Io.ConcurrentError!void {
        try this.group.concurrent(this.io, workerMain, .{this});
        this.worker_count += 1;
    }

    fn workerMain(this: *Executor) std.Io.Cancelable!void {
        bun.mimalloc.mi_thread_set_in_threadpool();
        bun.Output.Source.configureNamedThread("Bun Background");

        while (true) {
            this.mutex.lockUncancelable(this.io);
            while (this.pending.len == 0 and !this.stopping) {
                this.condition.wait(this.io, &this.mutex) catch |err| {
                    this.mutex.unlock(this.io);
                    return err;
                };
            }
            const task = this.pending.pop() orelse {
                bun.assert(this.stopping);
                this.mutex.unlock(this.io);
                return;
            };
            this.active_workers += 1;
            this.mutex.unlock(this.io);

            const scope = task.scope orelse @panic("background task has no owner scope");
            if (scope.state.load(.acquire) == .cancel_pending) {
                task.cancel();
            } else {
                bun.assert(current_scope == null);
                current_scope = scope;
                task.callback(task);
                current_scope = null;
            }
            scope.completeOne();

            this.mutex.lockUncancelable(this.io);
            bun.assert(this.active_workers > 0);
            this.active_workers -= 1;
            this.mutex.unlock(this.io);
        }
    }

    fn cancel(this: *Executor, scope: *BackgroundTaskGroup) void {
        var retained: Batch = .{};
        var canceled: Batch = .{};

        this.mutex.lockUncancelable(this.io);
        while (this.pending.pop()) |task| {
            const destination = if (task.scope == scope) &canceled else &retained;
            destination.push(.from(task));
        }
        this.pending = retained;
        this.mutex.unlock(this.io);

        while (canceled.pop()) |task| {
            task.cancel();
            scope.completeOne();
        }
    }
};

pub fn init(executor: *Executor) BackgroundTaskGroup {
    return .{ .executor = executor };
}

pub fn deinit(this: *BackgroundTaskGroup) void {
    this.close(.drain);
}

pub fn close(this: *BackgroundTaskGroup, mode: CloseMode) void {
    bun.assert(Executor.current_scope != this);

    this.mutex.lockUncancelable(this.executor.io);
    bun.assert(this.state.load(.monotonic) == .open);
    this.state.store(switch (mode) {
        .drain => .draining,
        .cancel_pending => .cancel_pending,
    }, .release);
    this.mutex.unlock(this.executor.io);

    if (mode == .cancel_pending) this.executor.cancel(this);

    this.mutex.lockUncancelable(this.executor.io);
    while (this.outstanding > 0) {
        this.condition.waitUncancelable(this.executor.io, &this.mutex);
    }
    this.state.store(.closed, .release);
    this.mutex.unlock(this.executor.io);
}

pub fn schedule(this: *BackgroundTaskGroup, batch: Batch) std.Io.ConcurrentError!void {
    if (batch.len == 0) return;

    this.mutex.lockUncancelable(this.executor.io);
    defer this.mutex.unlock(this.executor.io);
    if (this.state.load(.monotonic) != .open) return error.ConcurrencyUnavailable;

    batch.setScope(this);
    this.outstanding += batch.len;
    this.executor.schedule(batch) catch |err| {
        this.outstanding -= batch.len;
        return err;
    };
}

pub fn scheduleTask(this: *BackgroundTaskGroup, task: *Task) std.Io.ConcurrentError!void {
    try this.schedule(.from(task));
}

pub fn scheduleContinuation(this: *BackgroundTaskGroup, batch: Batch) void {
    if (batch.len == 0) return;

    this.mutex.lockUncancelable(this.executor.io);
    const state = this.state.load(.monotonic);
    if (state == .cancel_pending) {
        this.mutex.unlock(this.executor.io);
        var canceled = batch;
        while (canceled.pop()) |task| {
            task.cancel();
        }
        return;
    }
    bun.assert(state != .closed);
    batch.setScope(this);
    this.outstanding += batch.len;
    this.mutex.unlock(this.executor.io);
    this.executor.scheduleContinuation(batch);
}

pub fn scheduleContinuationTask(this: *BackgroundTaskGroup, task: *Task) void {
    this.scheduleContinuation(.from(task));
}

fn completeOne(this: *BackgroundTaskGroup) void {
    this.mutex.lockUncancelable(this.executor.io);
    bun.assert(this.outstanding > 0);
    this.outstanding -= 1;
    const finished = this.outstanding == 0;
    this.mutex.unlock(this.executor.io);
    if (finished) this.condition.broadcast(this.executor.io);
}

const std = @import("std");
const bun = @import("bun");
