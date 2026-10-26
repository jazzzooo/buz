const NativeTaskQueue = @This();

head: ?*Task = null,
tail: ?*Task = null,
count: usize = 0,

pub fn writeItem(this: *NativeTaskQueue, task: *Task) void {
    bun.assert(task.next == null);
    this.appendBatch(.{ .front = task, .last = task, .count = 1 });
}

pub fn appendBatch(this: *NativeTaskQueue, batch: ConcurrentQueue.Batch) void {
    if (batch.count == 0) return;
    bun.assert(batch.front != null and batch.last != null);
    bun.assert(batch.last.?.next == null);
    if (this.tail) |tail| tail.next = batch.front else this.head = batch.front;
    this.tail = batch.last;
    this.count += batch.count;
}

pub fn readItem(this: *NativeTaskQueue) ?*Task {
    const task = this.head orelse return null;
    this.head = task.next;
    if (this.head == null) this.tail = null;
    this.count -= 1;
    task.next = null;
    return task;
}

pub fn remove(this: *NativeTaskQueue, target: *Task) bool {
    var previous: ?*Task = null;
    var current = this.head;
    while (current) |task| {
        if (task == target) {
            if (previous) |parent| parent.next = task.next else this.head = task.next;
            if (this.tail == task) this.tail = previous;
            this.count -= 1;
            task.next = null;
            return true;
        }
        previous = task;
        current = task.next;
    }
    return false;
}

pub fn deinit(this: *NativeTaskQueue) void {
    while (this.readItem()) |task| task.cancel();
}

const bun = @import("bun");
const Task = @import("./AnyTaskWithExtraContext.zig");
const ConcurrentQueue = bun.UnboundedQueue(Task, .next);
