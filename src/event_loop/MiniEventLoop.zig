//! MiniEventLoop: A lightweight event loop for non-JavaScript contexts
//!
//! This is a simplified version of jsc.EventLoop that provides event loop functionality
//! without requiring a JavaScript runtime. It enables code reuse between JavaScript-enabled
//! contexts (like `bun run`) and JavaScript-free contexts (like `bun build`, `bun install`,
//! and the Bun Shell).
//!
//! Key characteristics:
//! - Wraps the uSockets event loop, same as jsc.EventLoop
//! - Supports concurrent task execution via thread pools
//! - Provides file polling capabilities for watching filesystem changes
//! - Manages stdout/stderr streams without JavaScript bindings
//! - Handles environment variable loading and management
//!
//! Use cases:
//! - Build processes that need async I/O without JavaScript execution
//! - Package installation with concurrent network requests
//! - Shell command execution with proper I/O handling
//! - Any Bun subsystem that needs event-driven architecture without JS overhead
//!

const MiniEventLoop = @This();

tasks: Queue = .{},
concurrent_tasks: ConcurrentTaskQueue = .{},
native_completion_registry: ?*NativeCompletionRegistry = null,
closing: bool = false,
io: std.Io,
loop: *uws.Loop,
allocator: std.mem.Allocator,
background_tasks: ?bun.BackgroundTaskGroup = null,
borrowed_background_tasks: ?*bun.BackgroundTaskGroup = null,
background_executor: *bun.BackgroundExecutor,
file_polls_: ?*Async.FilePoll.Store = null,
env: ?*bun.DotEnv.Loader = null,
top_level_dir: []const u8 = "",
pending_file_poll_frees: ?*Async.FilePoll.Store = null,
pipe_read_buffer: ?*PipeReadBuffer = null,
const PipeReadBuffer = [256 * 1024]u8;

pub threadlocal var globalInitialized: bool = false;
pub threadlocal var global: *MiniEventLoop = undefined;

pub const ConcurrentTaskQueue = UnboundedQueue(AnyTaskWithExtraContext, .next);

pub fn initGlobal(io: std.Io, env: ?*bun.DotEnv.Loader, cwd: ?[]const u8) anyerror!*MiniEventLoop {
    if (globalInitialized) return global;
    const loop = try MiniEventLoop.init(io, bun.default_allocator, bun.cli.Cli.pinnedThreads().backgroundExecutor());
    const instance = try bun.default_allocator.create(MiniEventLoop);
    errdefer bun.default_allocator.destroy(instance);
    instance.* = loop;
    errdefer instance.deinit();

    var owned_cwd: ?[]const u8 = null;
    errdefer if (owned_cwd) |dir| bun.default_allocator.free(dir);
    if (cwd) |dir| {
        instance.top_level_dir = dir;
    } else if (instance.top_level_dir.len == 0) {
        var buf: bun.PathBuffer = undefined;
        switch (bun.sys.getcwd(&buf)) {
            .result => |p| {
                owned_cwd = try bun.default_allocator.dupe(u8, p);
                instance.top_level_dir = owned_cwd.?;
            },
            .err => {
                instance.top_level_dir = "";
            },
        }
    }

    instance.env = env orelse bun.DotEnv.instance orelse env_loader: {
        const map = try bun.default_allocator.create(bun.DotEnv.Map);
        errdefer bun.default_allocator.destroy(map);
        map.* = bun.DotEnv.Map.init(bun.default_allocator);
        errdefer map.map.deinit(map.allocator);
        const loader = try bun.default_allocator.create(bun.DotEnv.Loader);
        loader.* = bun.DotEnv.Loader.init(map, bun.default_allocator);
        break :env_loader loader;
    };
    instance.loop.internal_loop_data.setParent(instance.parentEventLoop());
    global = instance;
    globalInitialized = true;
    return global;
}

const Queue = @import("./NativeTaskQueue.zig");
const NativeCompletionRegistry = @import("./NativeCompletionRegistry.zig");

pub const Task = AnyTaskWithExtraContext;

pub inline fn getVmImpl(this: *MiniEventLoop) *MiniEventLoop {
    return this;
}

pub fn throwError(_: *MiniEventLoop, err: bun.sys.Error) void {
    bun.Output.prettyErrorln("{}", .{err});
    bun.Output.flush();
}

pub fn pipeReadBuffer(this: *MiniEventLoop) []u8 {
    return this.pipe_read_buffer orelse {
        this.pipe_read_buffer = bun.handleOom(this.allocator.create(PipeReadBuffer));
        return this.pipe_read_buffer.?;
    };
}

pub fn onAfterEventLoop(this: *MiniEventLoop) void {
    if (bun.take(&this.pending_file_poll_frees)) |store| {
        store.processDeferredFrees();
    }
}

pub fn filePolls(this: *MiniEventLoop) *Async.FilePoll.Store {
    return bun.handleOom(this.tryFilePolls());
}

pub fn tryFilePolls(this: *MiniEventLoop) bun.OOM!*Async.FilePoll.Store {
    return this.file_polls_ orelse {
        this.file_polls_ = try this.allocator.create(Async.FilePoll.Store);
        this.file_polls_.?.* = Async.FilePoll.Store.init();
        return this.file_polls_.?;
    };
}

pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    background_executor: *bun.BackgroundExecutor,
) anyerror!MiniEventLoop {
    return .{
        .io = io,
        .allocator = allocator,
        .background_executor = background_executor,
        .loop = try uws.Loop.ensure(),
    };
}

pub fn deinit(this: *MiniEventLoop) void {
    this.closing = true;
    if (this.native_completion_registry) |registry| {
        this.native_completion_registry = null;
        registry.close();
        registry.release();
    }
    if (this.background_tasks) |*group| group.deinit();
    _ = this.tickConcurrentWithCount();
    this.tasks.deinit();
    bun.assert(this.concurrent_tasks.isEmpty());
}

pub fn nativeCompletionRegistry(this: *MiniEventLoop) bun.OOM!?*NativeCompletionRegistry {
    if (this.closing) return null;
    if (this.native_completion_registry) |registry| return registry;
    const registry = try @import("./NativeCompletionRegistryMini.zig").create(this);
    this.native_completion_registry = registry;
    return registry;
}

pub fn attachBackgroundTasks(this: *MiniEventLoop, group: *bun.BackgroundTaskGroup) void {
    bun.assert(this.background_tasks == null);
    bun.assert(this.borrowed_background_tasks == null);
    this.borrowed_background_tasks = group;
}

pub fn backgroundTasks(this: *MiniEventLoop) *bun.BackgroundTaskGroup {
    if (this.borrowed_background_tasks) |group| return group;
    if (this.background_tasks == null)
        this.background_tasks = .init(this.background_executor);
    return &this.background_tasks.?;
}

pub fn parentEventLoop(this: *MiniEventLoop) ParentEventLoop {
    return .{
        .context = .init(this),
        .kind = .mini,
        .vtable = &parent_event_loop_vtable,
    };
}

pub fn runtimeLoopHandle(this: *MiniEventLoop) RuntimeLoopHandle {
    return .{
        .context = .init(this),
        .kind = .mini,
        .vtable = &runtime_loop_handle_vtable,
    };
}

const runtime_loop_handle_vtable = RuntimeLoopHandle.VTable{
    .io = struct {
        fn call(context: RuntimeLoopHandle.Context) std.Io {
            return context.get(*MiniEventLoop).io;
        }
    }.call,
    .file_polls = struct {
        fn call(context: RuntimeLoopHandle.Context) bun.OOM!*Async.FilePoll.Store {
            return context.get(*MiniEventLoop).tryFilePolls();
        }
    }.call,
    .platform_loop = struct {
        fn call(context: RuntimeLoopHandle.Context) *ParentEventLoop.PlatformEventLoop {
            return context.get(*MiniEventLoop).parentEventLoop().platformEventLoop();
        }
    }.call,
    .pipe_read_buffer = struct {
        fn call(context: RuntimeLoopHandle.Context) []u8 {
            return context.get(*MiniEventLoop).pipeReadBuffer();
        }
    }.call,
    .parent_event_loop = struct {
        fn call(context: RuntimeLoopHandle.Context) ParentEventLoop {
            return context.get(*MiniEventLoop).parentEventLoop();
        }
    }.call,
};

const parent_event_loop_vtable = ParentEventLoop.VTable{
    .native_completion_registry = struct {
        fn call(context: ParentEventLoop.Context) bun.OOM!?*NativeCompletionRegistry {
            return context.get(*MiniEventLoop).nativeCompletionRegistry();
        }
    }.call,
    .io = struct {
        fn call(context: ParentEventLoop.Context) std.Io {
            const loop = context.get(*MiniEventLoop);
            return loop.io;
        }
    }.call,
    .background_tasks = struct {
        fn call(context: ParentEventLoop.Context) *bun.BackgroundTaskGroup {
            const loop = context.get(*MiniEventLoop);
            return loop.backgroundTasks();
        }
    }.call,
    .runtime_loop_handle = struct {
        fn call(context: ParentEventLoop.Context) RuntimeLoopHandle {
            return context.get(*MiniEventLoop).runtimeLoopHandle();
        }
    }.call,
    .platform_event_loop = struct {
        fn call(context: ParentEventLoop.Context) *PlatformEventLoop {
            const loop = context.get(*MiniEventLoop);
            if (comptime Environment.isWindows) return loop.loop.uv_loop;
            return loop.loop;
        }
    }.call,
};

pub fn tickConcurrentWithCount(this: *MiniEventLoop) usize {
    const concurrent = this.concurrent_tasks.popBatch();
    this.tasks.appendBatch(concurrent);
    return concurrent.count;
}

pub fn cancelTask(this: *MiniEventLoop, task: *AnyTaskWithExtraContext) bool {
    _ = this.tickConcurrentWithCount();
    return this.tasks.remove(task);
}

pub fn tickOnce(
    this: *MiniEventLoop,
    context: *anyopaque,
) void {
    if (this.tickConcurrentWithCount() == 0 and this.tasks.count == 0) {
        defer this.onAfterEventLoop();
        this.loop.inc();
        this.loop.tick();
        this.loop.dec();
    }

    while (this.tasks.readItem()) |task| {
        task.run(context);
    }
}

pub fn tickWithoutIdle(
    this: *MiniEventLoop,
    context: *anyopaque,
) void {
    defer this.onAfterEventLoop();

    while (true) {
        _ = this.tickConcurrentWithCount();
        while (this.tasks.readItem()) |task| {
            task.run(context);
        }

        this.loop.tickWithoutIdle();

        if (this.tasks.count == 0 and this.tickConcurrentWithCount() == 0) break;
    }
}

pub fn tick(
    this: *MiniEventLoop,
    context: *anyopaque,
    comptime isDone: *const fn (*anyopaque) bool,
) void {
    while (!isDone(context)) {
        if (this.tickConcurrentWithCount() == 0 and this.tasks.count == 0) {
            defer this.onAfterEventLoop();
            this.loop.inc();
            this.loop.tick();
            this.loop.dec();
        }

        while (this.tasks.readItem()) |task| {
            task.run(context);
        }
    }
}

pub fn enqueueTask(
    this: *MiniEventLoop,
    comptime Context: type,
    ctx: *Context,
    comptime Callback: fn (*Context) void,
    comptime field: std.meta.FieldEnum(Context),
) void {
    const Adapter = struct {
        fn run(context: AnyTaskWithExtraContext.Context, _: *anyopaque) void {
            Callback(context.get(*Context));
        }
    };
    @field(ctx, @tagName(field)) = .{ .ctx = .init(ctx), .callback = Adapter.run };
    const task = &@field(ctx, @tagName(field));
    if (this.closing) {
        task.cancel();
        return;
    }
    this.tasks.writeItem(task);
}

pub fn enqueueTaskConcurrent(this: *MiniEventLoop, task: *AnyTaskWithExtraContext) void {
    this.concurrent_tasks.push(task);
    this.loop.wakeup();
}

pub fn enqueueTaskConcurrentWithExtraCtx(
    this: *MiniEventLoop,
    comptime Context: type,
    comptime ParentContext: type,
    ctx: *Context,
    comptime Callback: fn (*Context, *ParentContext) void,
    comptime field: std.meta.FieldEnum(Context),
) void {
    const TaskType = MiniEventLoop.Task.New(Context, ParentContext, Callback);
    @field(ctx, @tagName(field)) = TaskType.init(ctx);

    this.concurrent_tasks.push(&@field(ctx, @tagName(field)));

    this.loop.wakeup();
}

pub const MiniVM = struct {
    mini: *MiniEventLoop,

    pub fn init(inner: *MiniEventLoop) MiniVM {
        return .{
            .mini = inner,
        };
    }

    pub inline fn loop(this: @This()) *MiniEventLoop {
        return this.mini;
    }

    pub inline fn platformEventLoop(this: @This()) *PlatformEventLoop {
        if (comptime Environment.isWindows) {
            return this.mini.loop.uv_loop;
        }
        return this.mini.loop;
    }

    pub inline fn incrementPendingUnrefCounter(this: @This()) void {
        _ = this;
        @panic("FIXME TODO");
    }

    pub inline fn filePolls(this: @This()) *Async.FilePoll.Store {
        return this.mini.filePolls();
    }
};

const std = @import("std");

const bun = @import("bun");
const Async = bun.Async;
const Environment = bun.Environment;
const uws = bun.uws;
const UnboundedQueue = bun.threading.UnboundedQueue;
const AnyTaskWithExtraContext = @import("./AnyTaskWithExtraContext.zig");
const ParentEventLoop = @import("./ParentEventLoop.zig");
const RuntimeLoopHandle = @import("./RuntimeLoopHandle.zig");
const PlatformEventLoop = if (Environment.isPosix) uws.Loop else Async.Loop;
