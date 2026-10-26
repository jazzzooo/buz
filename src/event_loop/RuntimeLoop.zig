pub const RuntimeLoop = union(Kind) {
    js: JavaScript,
    mini: MiniEventLoop,

    pub const JavaScript = struct {
        pub const Context = bun.bindgen.NativeCallbackContext(.vm);
        context: Context,
        parent: ParentEventLoop,
        vtable: *const VTable,

        pub const VTable = struct {
            iteration_number: *const fn (Context) u64,
            file_polls: *const fn (Context) bun.OOM!*Async.FilePoll.Store,
            put_file_poll: *const fn (Context, *Async.FilePoll) void,
            loop: *const fn (Context) *uws.Loop,
            pipe_read_buffer: *const fn (Context) []u8,
            tick: *const fn (Context, *anyopaque, *const fn (*anyopaque) bool) void,
            tick_once: *const fn (Context) void,
        };
    };

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        background_executor: *bun.BackgroundExecutor,
    ) anyerror!RuntimeLoop {
        return .{ .mini = try MiniEventLoop.init(io, allocator, background_executor) };
    }

    pub fn fromJavaScript(context: JavaScript.Context, parent: ParentEventLoop, vtable: *const JavaScript.VTable) RuntimeLoop {
        return .{ .js = .{
            .context = context,
            .parent = parent,
            .vtable = vtable,
        } };
    }

    pub fn iterationNumber(this: *const RuntimeLoop) u64 {
        return switch (this.*) {
            .js => |js| js.vtable.iteration_number(js.context),
            .mini => |*mini| mini.loop.iterationNumber(),
        };
    }

    pub fn wakeup(this: *RuntimeLoop) void {
        this.platformLoop().wakeup();
    }

    pub fn filePolls(this: *RuntimeLoop) *Async.FilePoll.Store {
        return bun.handleOom(this.tryFilePolls());
    }

    pub fn tryFilePolls(this: *RuntimeLoop) bun.OOM!*Async.FilePoll.Store {
        return switch (this.*) {
            .js => |js| js.vtable.file_polls(js.context),
            .mini => |*mini| mini.tryFilePolls(),
        };
    }

    pub fn putFilePoll(this: *RuntimeLoop, poll: *Async.FilePoll) void {
        switch (this.*) {
            .js => |js| js.vtable.put_file_poll(js.context, poll),
            .mini => |*mini| mini.filePolls().put(poll, mini, poll.flags.contains(.was_ever_registered)),
        }
    }

    pub fn platformLoop(this: *RuntimeLoop) *uws.Loop {
        return switch (this.*) {
            .js => |js| js.vtable.loop(js.context),
            .mini => |*mini| mini.loop,
        };
    }

    pub const loop = platformLoop;

    pub fn pipeReadBuffer(this: *RuntimeLoop) []u8 {
        return switch (this.*) {
            .js => |js| js.vtable.pipe_read_buffer(js.context),
            .mini => |*mini| mini.pipeReadBuffer(),
        };
    }

    pub fn parentEventLoop(this: *RuntimeLoop) ParentEventLoop {
        return switch (this.*) {
            .js => |js| js.parent,
            .mini => |*mini| mini.parentEventLoop(),
        };
    }

    pub fn runtimeLoopHandle(this: *RuntimeLoop) RuntimeLoopHandle {
        return .{
            .context = .init(this),
            .kind = std.meta.activeTag(this.*),
            .vtable = &handle_vtable,
        };
    }

    pub fn tick(
        this: *RuntimeLoop,
        context: anytype,
        comptime isDone: *const fn (@TypeOf(context)) bool,
    ) void {
        const erased_is_done = struct {
            fn call(erased: *anyopaque) bool {
                return isDone(@ptrCast(@alignCast(erased)));
            }
        }.call;

        switch (this.*) {
            .js => |js| js.vtable.tick(js.context, @ptrCast(context), erased_is_done),
            .mini => |*mini| mini.tick(@ptrCast(context), @ptrCast(isDone)),
        }
    }

    pub fn tickOnce(this: *RuntimeLoop, context: anytype) void {
        switch (this.*) {
            .js => |js| js.vtable.tick_once(js.context),
            .mini => |*mini| mini.tickWithoutIdle(@ptrCast(context)),
        }
    }

    const std = @import("std");
    const bun = @import("bun");
    const Async = bun.Async;
    const uws = bun.uws;
    const Kind = @import("./types.zig").Kind;
    const MiniEventLoop = @import("./MiniEventLoop.zig");
    const ParentEventLoop = @import("./ParentEventLoop.zig");
    const RuntimeLoopHandle = @import("./RuntimeLoopHandle.zig");

    const handle_vtable = RuntimeLoopHandle.VTable{
        .io = struct {
            fn call(context: RuntimeLoopHandle.Context) std.Io {
                const runtime_loop = context.get(*RuntimeLoop);
                return runtime_loop.parentEventLoop().io();
            }
        }.call,
        .file_polls = struct {
            fn call(context: RuntimeLoopHandle.Context) bun.OOM!*Async.FilePoll.Store {
                return context.get(*RuntimeLoop).tryFilePolls();
            }
        }.call,
        .platform_loop = struct {
            fn call(context: RuntimeLoopHandle.Context) *ParentEventLoop.PlatformEventLoop {
                return context.get(*RuntimeLoop).parentEventLoop().platformEventLoop();
            }
        }.call,
        .pipe_read_buffer = struct {
            fn call(context: RuntimeLoopHandle.Context) []u8 {
                return context.get(*RuntimeLoop).pipeReadBuffer();
            }
        }.call,
        .parent_event_loop = struct {
            fn call(context: RuntimeLoopHandle.Context) ParentEventLoop {
                return context.get(*RuntimeLoop).parentEventLoop();
            }
        }.call,
    };
};
