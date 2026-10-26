const RuntimeLoopHandle = @This();

pub const Context = bun.bindgen.NativeCallbackContext(.vm);

context: Context,
kind: Kind,
vtable: *const VTable,

pub const VTable = struct {
    io: *const fn (Context) std.Io,
    file_polls: *const fn (Context) bun.OOM!*Async.FilePoll.Store,
    platform_loop: *const fn (Context) *ParentEventLoop.PlatformEventLoop,
    pipe_read_buffer: *const fn (Context) []u8,
    parent_event_loop: *const fn (Context) ParentEventLoop,
};

pub fn io(this: RuntimeLoopHandle) std.Io {
    return this.vtable.io(this.context);
}

pub fn filePolls(this: RuntimeLoopHandle) *Async.FilePoll.Store {
    return bun.handleOom(this.tryFilePolls());
}

pub fn tryFilePolls(this: RuntimeLoopHandle) bun.OOM!*Async.FilePoll.Store {
    return this.vtable.file_polls(this.context);
}

pub fn platformLoop(this: RuntimeLoopHandle) *ParentEventLoop.PlatformEventLoop {
    return this.vtable.platform_loop(this.context);
}

pub const loop = platformLoop;
pub const platformEventLoop = platformLoop;

pub fn pipeReadBuffer(this: RuntimeLoopHandle) []u8 {
    return this.vtable.pipe_read_buffer(this.context);
}

pub fn parentEventLoop(this: RuntimeLoopHandle) ParentEventLoop {
    return this.vtable.parent_event_loop(this.context);
}

pub fn runtimeLoopHandle(this: RuntimeLoopHandle) RuntimeLoopHandle {
    return this;
}

const std = @import("std");
const bun = @import("bun");
const Async = bun.Async;
const Kind = @import("./types.zig").Kind;
const ParentEventLoop = @import("./ParentEventLoop.zig");
