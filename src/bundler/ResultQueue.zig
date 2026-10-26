const ResultQueue = @This();

mutex: std.atomic.Mutex = .unlocked,
available: std.Io.Event = .unset,
head: ?*Node = null,
tail: ?*Node = null,
notification: ?Notification = null,

pub const Notification = struct {
    context: bun.bindgen.NativeCallbackContext(.vm),
    notify: *const fn (bun.bindgen.NativeCallbackContext(.vm)) void,
};

pub const Message = union(enum) {
    parse: *bundler.ParseTask.Result,
    load: *bundler.PluginLoad,
    resolve: *bundler.PluginResolve,
    defer_load: *bundler.PluginLoad,

    pub fn deliver(message: Message) void {
        switch (message) {
            .parse => |result| bundler.BundleV2.onParseTaskComplete(result, result.ctx),
            .load => |load| bundler.BundleV2.onLoad(load, load.bv2),
            .resolve => |resolve| bundler.BundleV2.onResolve(resolve, resolve.bv2),
            .defer_load => |load| bundler.BundleV2.onNotifyDefer(load),
        }
    }
};

pub const Node = struct {
    next: ?*Node = null,
    state: enum { idle, queued, consumed } = .idle,
    message: Message = undefined,
};

pub fn post(this: *ResultQueue, io: std.Io, node: *Node, message: Message) void {
    this.lock();
    defer this.mutex.unlock();
    bun.assert(node.state == .idle and node.next == null);
    node.state = .queued;
    node.message = message;
    if (this.tail) |tail| tail.next = node else this.head = node;
    this.tail = node;
    if (this.notification) |notification| {
        notification.notify(notification.context);
    } else {
        this.available.set(io);
    }
}

pub fn pop(this: *ResultQueue) ?Message {
    this.lock();
    defer this.mutex.unlock();
    const node = this.head orelse {
        this.available.reset();
        return null;
    };
    bun.assert(node.state == .queued);
    this.head = node.next;
    if (this.head == null) this.tail = null;
    node.next = null;
    node.state = .consumed;
    return node.message;
}

pub fn wait(this: *ResultQueue, io: std.Io) void {
    this.available.waitUncancelable(io);
}

pub fn assertEmpty(this: *ResultQueue) void {
    this.lock();
    defer this.mutex.unlock();
    bun.assert(this.head == null and this.tail == null);
}

pub fn hasPending(this: *ResultQueue) bool {
    this.lock();
    defer this.mutex.unlock();
    return this.head != null;
}

fn lock(this: *ResultQueue) void {
    while (!this.mutex.tryLock()) std.atomic.spinLoopHint();
}

const std = @import("std");
const bun = @import("bun");
const bundler = @import("./bundle_v2.zig");
