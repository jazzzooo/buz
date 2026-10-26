//! Coalesces writes until the end of the microtask checkpoint. Each registration
//! owns a native reference, including while its callback is running.

const DeferredTaskQueue = @This();

pub const Context = bun.bindgen.NativeCallbackContext(.vm);
pub const DeferredRepeatingTask = *const fn (Context) bool;

pub const Task = struct {
    registered: bool = false,
    previous: ?*Task = null,
    next: ?*Task = null,
    list: ?*List = null,
    invocation: ?*Invocation = null,
    context: ?Context = null,
    callbacks: ?*const Callbacks = null,

    pub const Callbacks = struct {
        run: DeferredRepeatingTask,
        retain: *const fn (Context) void,
        release: *const fn (Context) void,
    };

    pub fn cancel(this: *Task) void {
        if (!this.registered) return;
        this.registered = false;
        if (this.invocation) |invocation| {
            invocation.cancelled = true;
            this.invocation = null;
        } else {
            this.list.?.remove(this);
            const context = this.context.?;
            const callbacks = this.callbacks.?;
            callbacks.release(context);
        }
    }
};

const Invocation = struct {
    cancelled: bool = false,
};

const List = struct {
    first: ?*Task = null,
    last: ?*Task = null,

    fn append(this: *List, task: *Task) void {
        bun.assert(task.list == null);
        task.previous = this.last;
        task.next = null;
        task.list = this;
        if (this.last) |last| last.next = task else this.first = task;
        this.last = task;
    }

    fn remove(this: *List, task: *Task) void {
        bun.assert(task.list == this);
        if (task.previous) |previous| previous.next = task.next else this.first = task.next;
        if (task.next) |next| next.previous = task.previous else this.last = task.previous;
        task.previous = null;
        task.next = null;
        task.list = null;
    }
};

pending: List = .{},
batch: List = .{},
current: ?*Task = null,
running: bool = false,
closed: bool = false,

pub fn postTask(this: *DeferredTaskQueue, task: *Task, context: Context, callbacks: *const Task.Callbacks) void {
    bun.assert(!task.registered);
    if (this.closed) return;
    callbacks.retain(context);
    task.context = context;
    task.callbacks = callbacks;
    task.registered = true;
    this.pending.append(task);
}

pub fn run(this: *DeferredTaskQueue) void {
    if (this.running or this.closed) return;
    this.running = true;
    defer this.running = false;

    bun.assert(this.batch.first == null);
    this.batch = this.pending;
    this.pending = .{};
    var next = this.batch.first;
    while (next) |task| : (next = task.next) task.list = &this.batch;

    while (this.batch.first) |task| {
        this.batch.remove(task);
        var invocation: Invocation = .{};
        task.invocation = &invocation;
        this.current = task;
        const context = task.context.?;
        const callbacks = task.callbacks.?;
        const repeat = callbacks.run(context);
        this.current = null;

        // Cancellation transfers responsibility for any new registration to its
        // own queue entry; the old callback's result cannot remove that entry.
        if (!invocation.cancelled) {
            task.invocation = null;
            if (repeat and !this.closed) {
                this.pending.append(task);
                continue;
            }
            task.registered = false;
        }
        callbacks.release(context);
    }
}

pub fn deinit(this: *DeferredTaskQueue) void {
    this.closed = true;
    if (this.current) |task| task.cancel();
    while (this.batch.first) |task| task.cancel();
    while (this.pending.first) |task| task.cancel();
}

const bun = @import("bun");
