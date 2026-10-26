/// A non-owning reference to either the JS event loop or the mini event loop.
pub const EventLoopHandle = union(EventLoopKind) {
    js: *jsc.EventLoop,
    mini: *MiniEventLoop,

    pub fn globalObject(this: EventLoopHandle) ?*jsc.JSGlobalObject {
        return switch (this) {
            .js => this.js.global,
            .mini => null,
        };
    }

    pub fn bunVM(this: EventLoopHandle) ?*VirtualMachine {
        if (this == .js) {
            return this.js.virtual_machine;
        }

        return null;
    }

    pub fn cast(this: EventLoopHandle, comptime tag: EventLoopKind) tag.Type() {
        return @field(this, @tagName(tag));
    }

    pub fn enter(this: EventLoopHandle) void {
        switch (this) {
            .js => this.js.enter(),
            .mini => {},
        }
    }

    pub fn exit(this: EventLoopHandle) void {
        switch (this) {
            .js => this.js.exit(),
            .mini => {},
        }
    }

    pub fn init(context: anytype) EventLoopHandle {
        const Context = @TypeOf(context);
        return switch (Context) {
            *VirtualMachine => .{ .js = context.eventLoop() },
            *jsc.EventLoop => .{ .js = context },
            *jsc.MiniEventLoop => .{ .mini = context },
            *RuntimeLoop => fromParentEventLoop(context.parentEventLoop()),
            EventLoopHandle => context,
            else => @compileError("Invalid context type for EventLoopHandle.init " ++ @typeName(Context)),
        };
    }

    pub fn parentEventLoop(this: EventLoopHandle) ParentEventLoop {
        return switch (this) {
            .js => |event_loop| .{
                .context = .init(event_loop),
                .kind = .js,
                .vtable = &js_parent_event_loop_vtable,
            },
            .mini => |mini_loop| mini_loop.parentEventLoop(),
        };
    }

    pub fn runtimeLoopHandle(this: EventLoopHandle) RuntimeLoopHandle {
        return switch (this) {
            .js => |event_loop| .{
                .context = .init(event_loop),
                .kind = .js,
                .vtable = &js_runtime_loop_handle_vtable,
            },
            .mini => |mini_loop| mini_loop.runtimeLoopHandle(),
        };
    }

    pub fn fromParentEventLoop(parent: ParentEventLoop) EventLoopHandle {
        return switch (parent.kind) {
            .js => .{ .js = parent.context.get(*jsc.EventLoop) },
            .mini => .{ .mini = parent.context.get(*MiniEventLoop) },
        };
    }

    pub fn attach(this: EventLoopHandle, platform_loop: *bun.uws.Loop) void {
        platform_loop.internal_loop_data.setParent(this.parentEventLoop());
    }

    pub fn filePolls(this: EventLoopHandle) *bun.Async.FilePoll.Store {
        return switch (this) {
            .js => this.js.virtual_machine.rareData().filePolls(this.js.virtual_machine),
            .mini => this.mini.filePolls(),
        };
    }

    pub fn putFilePoll(this: *EventLoopHandle, poll: *Async.FilePoll) void {
        switch (this.*) {
            .js => this.js.virtual_machine.rareData().filePolls(this.js.virtual_machine).put(poll, this.js.virtual_machine, poll.flags.contains(.was_ever_registered)),
            .mini => this.mini.filePolls().put(poll, &this.mini, poll.flags.contains(.was_ever_registered)),
        }
    }

    pub fn enqueueTaskConcurrent(this: EventLoopHandle, context: EventLoopTaskPtr) void {
        switch (this) {
            .js => {
                this.js.enqueueTaskConcurrent(context.js);
            },
            .mini => {
                this.mini.enqueueTaskConcurrent(context.mini);
            },
        }
    }

    pub fn loop(this: EventLoopHandle) *bun.uws.Loop {
        return switch (this) {
            .js => this.js.usocketsLoop(),
            .mini => this.mini.loop,
        };
    }

    pub fn io(this: EventLoopHandle) std.Io {
        return switch (this) {
            .js => this.js.virtual_machine.io,
            .mini => this.mini.io,
        };
    }

    pub fn backgroundTasks(this: EventLoopHandle) *bun.BackgroundTaskGroup {
        return switch (this) {
            .js => &this.js.virtual_machine.background_tasks,
            .mini => this.mini.backgroundTasks(),
        };
    }

    pub fn pipeReadBuffer(this: EventLoopHandle) []u8 {
        return switch (this) {
            .js => this.js.pipeReadBuffer(),
            .mini => this.mini.pipeReadBuffer(),
        };
    }

    pub const platformEventLoop = loop;

    pub fn ref(this: EventLoopHandle) void {
        this.loop().ref();
    }

    pub fn unref(this: EventLoopHandle) void {
        this.loop().unref();
    }

    pub inline fn createNullDelimitedEnvMap(this: @This(), alloc: Allocator) ![:null]?[*:0]const u8 {
        return switch (this) {
            .js => this.js.virtual_machine.transpiler.env.map.createNullDelimitedEnvMap(alloc),
            .mini => this.mini.env.?.map.createNullDelimitedEnvMap(alloc),
        };
    }

    pub inline fn allocator(this: EventLoopHandle) Allocator {
        return switch (this) {
            .js => this.js.virtual_machine.allocator,
            .mini => this.mini.allocator,
        };
    }

    pub inline fn topLevelDir(this: EventLoopHandle) []const u8 {
        return switch (this) {
            .js => this.js.virtual_machine.transpiler.fs.top_level_dir,
            .mini => this.mini.top_level_dir,
        };
    }

    pub inline fn env(this: EventLoopHandle) *bun.DotEnv.Loader {
        return switch (this) {
            .js => this.js.virtual_machine.transpiler.env,
            .mini => this.mini.env.?,
        };
    }
};

const js_parent_event_loop_vtable = ParentEventLoop.VTable{
    .native_completion_registry = struct {
        fn call(context: ParentEventLoop.Context) bun.OOM!?*jsc.NativeCompletionRegistry {
            const loop = context.get(*jsc.EventLoop);
            const vm = loop.virtual_machine;
            if (vm.isShuttingDown()) return null;
            const rare = try vm.tryRareData();
            return try rare.nativeCompletionRegistryForLoop(vm, loop);
        }
    }.call,
    .io = struct {
        fn call(context: ParentEventLoop.Context) std.Io {
            const loop = context.get(*jsc.EventLoop);
            return loop.virtual_machine.io;
        }
    }.call,
    .background_tasks = struct {
        fn call(context: ParentEventLoop.Context) *bun.BackgroundTaskGroup {
            const loop = context.get(*jsc.EventLoop);
            return &loop.virtual_machine.background_tasks;
        }
    }.call,
    .runtime_loop_handle = struct {
        fn call(context: ParentEventLoop.Context) RuntimeLoopHandle {
            return (EventLoopHandle{ .js = context.get(*jsc.EventLoop) }).runtimeLoopHandle();
        }
    }.call,
    .platform_event_loop = struct {
        fn call(context: ParentEventLoop.Context) *jsc.PlatformEventLoop {
            const loop = context.get(*jsc.EventLoop);
            return loop.virtual_machine.event_loop_handle.?;
        }
    }.call,
};

const js_runtime_loop_handle_vtable = RuntimeLoopHandle.VTable{
    .io = struct {
        fn call(context: RuntimeLoopHandle.Context) std.Io {
            return context.get(*jsc.EventLoop).virtual_machine.io;
        }
    }.call,
    .file_polls = struct {
        fn call(context: RuntimeLoopHandle.Context) bun.OOM!*Async.FilePoll.Store {
            const loop = context.get(*jsc.EventLoop);
            const rare = try loop.virtual_machine.tryRareData();
            return rare.tryFilePolls(loop.virtual_machine);
        }
    }.call,
    .platform_loop = struct {
        fn call(context: RuntimeLoopHandle.Context) *ParentEventLoop.PlatformEventLoop {
            const loop = context.get(*jsc.EventLoop);
            return (EventLoopHandle{ .js = loop }).parentEventLoop().platformEventLoop();
        }
    }.call,
    .pipe_read_buffer = struct {
        fn call(context: RuntimeLoopHandle.Context) []u8 {
            return context.get(*jsc.EventLoop).pipeReadBuffer();
        }
    }.call,
    .parent_event_loop = struct {
        fn call(context: RuntimeLoopHandle.Context) ParentEventLoop {
            return (EventLoopHandle{ .js = context.get(*jsc.EventLoop) }).parentEventLoop();
        }
    }.call,
};

pub const EventLoopTask = union(EventLoopKind) {
    js: jsc.ConcurrentTask,
    mini: jsc.AnyTaskWithExtraContext,

    pub fn init(kind: EventLoopKind) EventLoopTask {
        switch (kind) {
            .js => return .{ .js = .{} },
            .mini => return .{ .mini = .{} },
        }
    }

    pub fn fromEventLoop(loop: jsc.EventLoopHandle) EventLoopTask {
        switch (loop) {
            .js => return .{ .js = .{} },
            .mini => return .{ .mini = .{} },
        }
    }
};

pub const EventLoopTaskPtr = union {
    js: *jsc.ConcurrentTask,
    mini: *jsc.AnyTaskWithExtraContext,
};

const std = @import("std");
const Allocator = std.mem.Allocator;

const bun = @import("bun");
const Async = bun.Async;

const jsc = bun.jsc;
const EventLoopKind = jsc.EventLoopKind;
const MiniEventLoop = jsc.MiniEventLoop;
const VirtualMachine = jsc.VirtualMachine;
const ParentEventLoop = @import("../event_loop/ParentEventLoop.zig");
const RuntimeLoop = @import("../event_loop/RuntimeLoop.zig").RuntimeLoop;
const RuntimeLoopHandle = @import("../event_loop/RuntimeLoopHandle.zig");
