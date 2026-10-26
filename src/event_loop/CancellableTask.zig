//! VM-thread task embedded in an owner. Cancel before moving or freeing its storage.
const CancellableTask = @This();
const Capture = bun.bindgen.NativeCallbackContext(.vm);

loop: ?*jsc.EventLoop = null,
node: jsc.ConcurrentTask = .{},
task: jsc.IntrusiveTask = undefined,
context: Capture = undefined,
callback: *const fn (Capture) void = undefined,
on_cancel: ?*const fn (Capture) void = null,

pub fn isScheduled(this: *const CancellableTask) bool {
    return this.loop != null;
}

pub fn schedule(this: *CancellableTask, loop: *jsc.EventLoop, context: anytype, comptime callback: anytype) void {
    _ = this.scheduleWithCancel(loop, context, callback, null);
}

pub fn scheduleWithCancel(
    this: *CancellableTask,
    loop: *jsc.EventLoop,
    context: anytype,
    comptime callback: anytype,
    comptime on_cancel: ?*const fn (@TypeOf(context)) void,
) bool {
    bun.assert(!this.isScheduled());
    if (!loop.accepts_cancellable_tasks) return false;
    const Context = @TypeOf(context);
    const Adapter = struct {
        fn call(raw: Capture) void {
            callback(raw.get(Context));
        }

        fn cancel(raw: Capture) void {
            on_cancel.?(raw.get(Context));
        }
    };
    this.context = .init(context);
    this.callback = Adapter.call;
    this.on_cancel = if (on_cancel != null) Adapter.cancel else null;
    this.task = .{ .context = .init(this), .callback = run, .on_cancel = cancelled };
    _ = this.node.from(&this.task, .manual_deinit);
    this.loop = loop;
    loop.tasks.appendBatch(.{ .front = &this.node.node, .last = &this.node.node, .count = 1 });
    return true;
}

pub fn cancel(this: *CancellableTask) void {
    const loop = this.loop orelse return;
    this.loop = null;
    const removed = loop.cancelTask(&this.node);
    bun.assert(removed);
    if (this.on_cancel) |callback| callback(this.context);
}

fn run(raw: Capture) void {
    const this = raw.get(*CancellableTask);
    bun.assert(this.isScheduled());
    const callback = this.callback;
    const context = this.context;
    this.loop = null;
    callback(context);
}

fn cancelled(raw: Capture) void {
    const this = raw.get(*CancellableTask);
    this.loop = null;
    if (this.on_cancel) |callback| callback(this.context);
}

const bun = @import("bun");
const jsc = bun.jsc;
