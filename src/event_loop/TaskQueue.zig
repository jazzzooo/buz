const TaskQueue = @This();

head: ?*Node = null,
tail: ?*Node = null,
recycled: ?*Node = null,
count: usize = 0,

pub fn init() TaskQueue {
    return .{};
}

pub fn writeItem(this: *TaskQueue, task: Task) bun.OOM!void {
    const owner: *EngineTask = if (this.recycled) |available| take: {
        this.recycled = available.next;
        break :take @fieldParentPtr("node", available);
    } else try bun.tryNew(EngineTask, .{});
    owner.* = .{ .task = task, .node = .{ .kind = .engine, .auto_delete = true } };
    this.appendBatch(.{ .front = &owner.node, .last = &owner.node, .count = 1 });
}

pub fn appendBatch(this: *TaskQueue, batch: Node.Queue.Batch) void {
    if (batch.count == 0) return;
    bun.assert(batch.front != null and batch.last != null);
    bun.assert(batch.last.?.next == null);
    if (this.tail) |tail| {
        tail.next = batch.front;
    } else {
        this.head = batch.front;
    }
    this.tail = batch.last;
    this.count += batch.count;
}

pub fn readItem(this: *TaskQueue) ?Task {
    const node = this.head orelse return null;
    const task = taskFromNode(node);
    this.head = node.next;
    this.count -= 1;
    if (this.head == null) this.tail = null;
    this.releaseNode(node);
    return task;
}

pub fn remove(this: *TaskQueue, target: *Node) bool {
    var previous: ?*Node = null;
    var current = this.head;
    while (current) |node| {
        const next = node.next;
        if (node == target) {
            if (previous) |parent| parent.next = next else this.head = next;
            if (this.tail == node) this.tail = previous;
            this.count -= 1;
            this.releaseNode(node);
            return true;
        }
        previous = node;
        current = next;
    }
    return false;
}

pub fn takeMatching(this: *TaskQueue, comptime matches: fn (Task) bool) ?Task {
    var previous: ?*Node = null;
    var current = this.head;
    while (current) |node| {
        const next = node.next;
        const task = taskFromNode(node);
        if (matches(task)) {
            if (previous) |parent| parent.next = next else this.head = next;
            if (this.tail == node) this.tail = previous;
            this.count -= 1;
            this.releaseNode(node);
            return task;
        }
        previous = node;
        current = next;
    }
    return null;
}

fn releaseNode(this: *TaskQueue, node: *Node) void {
    if (node.auto_delete) {
        bun.assert(node.kind == .engine);
        const owner: *EngineTask = @fieldParentPtr("node", node);
        owner.task = undefined;
        node.next = this.recycled;
        this.recycled = node;
    } else {
        // An embedded node can be reused or freed by its task's callback.
        node.next = null;
    }
}

fn taskFromNode(node: *Node) Task {
    return switch (node.kind) {
        .engine => @as(*EngineTask, @fieldParentPtr("node", node)).task,
        .native => Task.init(@as(*NativeTask, @fieldParentPtr("event_loop_node", node))),
    };
}

pub fn deinit(this: *TaskQueue) void {
    while (this.readItem() != null) {}
    while (this.recycled) |node| {
        this.recycled = node.next;
        @as(*EngineTask, @fieldParentPtr("node", node)).deinit();
    }
    this.* = .{};
}

const bun = @import("bun");
const Task = bun.jsc.Task;
const EngineTask = bun.jsc.ConcurrentTask;
const NativeTask = @import("./AnyTaskWithExtraContext.zig");
const Node = @import("./EventLoopTaskNode.zig");
