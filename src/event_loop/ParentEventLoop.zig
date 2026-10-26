const ParentEventLoop = @This();

pub const Context = bun.bindgen.NativeCallbackContext(.vm);

context: Context,
kind: Kind,
vtable: *const VTable,

pub const VTable = struct {
    io: *const fn (Context) std.Io,
    background_tasks: *const fn (Context) *bun.BackgroundTaskGroup,
    runtime_loop_handle: *const fn (Context) RuntimeLoopHandle,
    platform_event_loop: *const fn (Context) *PlatformEventLoop,
    native_completion_registry: *const fn (Context) bun.OOM!?*NativeCompletionRegistry,
};

pub fn io(this: ParentEventLoop) std.Io {
    return this.vtable.io(this.context);
}

pub fn backgroundTasks(this: ParentEventLoop) *bun.BackgroundTaskGroup {
    return this.vtable.background_tasks(this.context);
}

pub fn runtimeLoopHandle(this: ParentEventLoop) RuntimeLoopHandle {
    return this.vtable.runtime_loop_handle(this.context);
}

pub fn platformEventLoop(this: ParentEventLoop) *PlatformEventLoop {
    return this.vtable.platform_event_loop(this.context);
}

pub fn nativeCompletionRegistry(this: ParentEventLoop) bun.OOM!?*NativeCompletionRegistry {
    return this.vtable.native_completion_registry(this.context);
}

pub fn parentEventLoop(this: ParentEventLoop) ParentEventLoop {
    return this;
}

const std = @import("std");
const bun = @import("bun");
const Kind = @import("./types.zig").Kind;
const RuntimeLoopHandle = @import("./RuntimeLoopHandle.zig");
const NativeCompletionRegistry = @import("./NativeCompletionRegistry.zig");
pub const PlatformEventLoop = if (bun.Environment.isPosix) bun.uws.Loop else bun.Async.Loop;
