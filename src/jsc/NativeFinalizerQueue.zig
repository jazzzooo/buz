const NativeFinalizerQueue = @This();

const Context = bun.bindgen.NativeCallbackContext(.vm);

pub const Node = struct {
    context: ?Context = null,
    finalize: ?*const fn (Context) void = null,
    next: ?*Node = null,
    queued: bool = false,

    pub fn isUnused(node: *const Node) bool {
        return !node.queued and node.next == null and node.context == null and node.finalize == null;
    }
};

lock: std.atomic.Mutex = .unlocked,
state: State = .open,
head: ?*Node = null,
tail: ?*Node = null,
vm: *jsc.VirtualMachine,

const State = enum {
    open,
    closing,
    closed,
};

pub fn init(queue: *NativeFinalizerQueue, vm: *jsc.VirtualMachine) void {
    queue.* = .{ .vm = vm };
}

pub fn enqueue(
    queue: *NativeFinalizerQueue,
    node: *Node,
    context: anytype,
    comptime finalize: *const fn (@TypeOf(context)) void,
) void {
    queue.lockQueue();
    if (queue.state == .closed) {
        queue.lock.unlock();
        @panic("native finalizer queued after VM teardown");
    }
    if (!node.isUnused()) {
        queue.lock.unlock();
        @panic("native finalizer node queued twice");
    }
    node.context = .init(context);
    node.finalize = struct {
        fn run(value: Context) void {
            finalize(value.get(@TypeOf(context)));
        }
    }.run;
    node.queued = true;
    if (queue.tail) |tail| {
        tail.next = node;
    } else {
        queue.head = node;
    }
    queue.tail = node;
    if (queue.state == .open) queue.vm.eventLoop().wakeup();
    queue.lock.unlock();
}

pub fn drain(queue: *NativeFinalizerQueue) void {
    while (true) {
        queue.lockQueue();
        const finalizer = queue.takeFirst();
        queue.lock.unlock();
        const work = finalizer orelse return;
        work.finalize(work.context);
    }
}

pub fn close(queue: *NativeFinalizerQueue) void {
    queue.lockQueue();
    switch (queue.state) {
        .open, .closing => queue.state = .closing,
        .closed => {
            queue.lock.unlock();
            return;
        },
    }
    queue.lock.unlock();

    while (true) {
        queue.lockQueue();
        const finalizer = queue.takeFirst() orelse {
            queue.state = .closed;
            queue.lock.unlock();
            return;
        };
        queue.lock.unlock();
        finalizer.finalize(finalizer.context);
    }
}

pub fn isClosed(queue: *NativeFinalizerQueue) bool {
    queue.lockQueue();
    defer queue.lock.unlock();
    return queue.state == .closed;
}

const Finalizer = struct {
    context: Context,
    finalize: *const fn (Context) void,
};

fn takeFirst(queue: *NativeFinalizerQueue) ?Finalizer {
    const node = queue.head orelse return null;
    const result: Finalizer = .{
        .context = node.context orelse @panic("queued native finalizer has no context"),
        .finalize = node.finalize orelse @panic("queued native finalizer has no callback"),
    };
    // Keep the remaining nodes visible to teardown re-entered by this finalizer.
    queue.head = node.next;
    if (queue.head == null) queue.tail = null;
    node.* = .{};
    return result;
}

fn lockQueue(queue: *NativeFinalizerQueue) void {
    while (!queue.lock.tryLock()) std.atomic.spinLoopHint();
}

const std = @import("std");
const bun = @import("bun");
const jsc = bun.jsc;
