//! A task that runs concurrently in the work pool.
//!
//! This is used to run tasks that are CPU-intensive or blocking on the work pool.
//! It's also used to run tasks that need to be run on a different thread than the main JavaScript thread.
//!
//! The task is run on a thread pool and then the result is returned to the main JavaScript thread.
//!
//! If `auto_delete` is true, the task is automatically deallocated when it's finished.
//! Otherwise, it's expected that the containing struct will deallocate the task.

const ConcurrentTask = @This();

task: Task = undefined,
node: Node = .{ .kind = .engine },

pub const Queue = Node.Queue;
pub const new = bun.TrivialNew(@This());
pub const deinit = bun.TrivialDeinit(@This());

pub const AutoDeinit = enum {
    manual_deinit,
    auto_deinit,
};

pub fn create(task: Task) *ConcurrentTask {
    return ConcurrentTask.new(.{
        .task = task,
        .node = .{ .kind = .engine, .auto_delete = true },
    });
}

pub fn createFrom(task: anytype) *ConcurrentTask {
    return create(Task.init(task));
}

pub fn fromCallback(ptr: anytype, comptime callback: anytype) *ConcurrentTask {
    return create(ManagedTask.New(std.meta.Child(@TypeOf(ptr)), callback).init(ptr));
}

pub fn from(this: *ConcurrentTask, of: anytype, auto_deinit: AutoDeinit) *ConcurrentTask {
    this.* = .{
        .task = Task.init(of),
        .node = .{ .kind = .engine, .auto_delete = auto_deinit == .auto_deinit },
    };
    return this;
}

const std = @import("std");

const bun = @import("bun");
const Node = @import("./EventLoopTaskNode.zig");

const jsc = bun.jsc;
const ManagedTask = jsc.ManagedTask;
const Task = jsc.Task;
