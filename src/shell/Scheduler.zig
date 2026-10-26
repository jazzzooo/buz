const Scheduler = @This();
pub const Context = bun.bindgen.NativeCallbackContext(.vm);

runtime_loop: bun.RuntimeLoopHandle,
environment: *bun.DotEnv.Loader,
top_level_dir: []const u8,
allocator: std.mem.Allocator,
context: Context,
vtable: *const VTable,

pub const VTable = struct {
    enqueue: *const fn (Context, *Task) void,
    tick: *const fn (Context) void,
    report_shell_error: *const fn (Context, *const bun.shell.ShellErr) void,
    report_out_of_memory: *const fn (Context) void,
    throw_message: *const fn (Context, []const u8) void,
    throw_invalid_arguments: *const fn (Context, []const u8) void,
    with_shell_value_blob: *const fn (Context, *const ShellValue.Value, []const u8, *anyopaque, BlobConsumer) ?bun.shell.Yield,
    positional_arg: *const fn (Context, u8) []const u8,
    is_javascript: bool,
};

pub fn initMini(loop: *bun.MiniEventLoop) Scheduler {
    return .{
        .runtime_loop = loop.runtimeLoopHandle(),
        .environment = loop.env.?,
        .top_level_dir = loop.top_level_dir,
        .allocator = loop.allocator,
        .context = .init(loop),
        .vtable = &mini_vtable,
    };
}

pub fn runtimeLoopHandle(this: Scheduler) bun.RuntimeLoopHandle {
    return this.runtime_loop;
}

pub fn parentEventLoop(this: Scheduler) bun.ParentEventLoop {
    return this.runtime_loop.parentEventLoop();
}

pub fn platformLoop(this: Scheduler) *bun.Async.Loop {
    return this.runtime_loop.platformLoop();
}

pub fn io(this: Scheduler) std.Io {
    return this.runtime_loop.io();
}

pub fn backgroundTasks(this: Scheduler) *bun.BackgroundTaskGroup {
    return this.parentEventLoop().backgroundTasks();
}

pub fn ref(this: Scheduler, keep_alive: *bun.Async.KeepAlive) void {
    keep_alive.ref(this.runtime_loop);
}

pub fn unref(this: Scheduler, keep_alive: *bun.Async.KeepAlive) void {
    keep_alive.unref(this.runtime_loop);
}

pub fn disable(this: Scheduler, keep_alive: *bun.Async.KeepAlive) void {
    this.unref(keep_alive);
    keep_alive.disable();
}

pub const Task = struct {
    queue_entry: AnyTaskWithExtraContext = .{},
    target: ?Context = null,
    callback: ?*const fn (Context) void = null,

    pub fn runFromMainThread(this: *Task, _: *void) void {
        const target = this.target.?;
        const callback = this.callback.?;
        this.target = null;
        this.callback = null;
        callback(target);
    }

    pub fn taskForQueue(this: *Task) *AnyTaskWithExtraContext {
        this.queue_entry = AnyTaskWithExtraContext.New(Task, void, runFromMainThread).init(this);
        return &this.queue_entry;
    }
};

pub fn enqueue(this: Scheduler, task: *Task, target: anytype) void {
    const Target = std.meta.Child(@TypeOf(target));
    const Adapter = struct {
        fn run(raw_target: Context) void {
            raw_target.get(*Target).runFromMainThread();
        }
    };
    bun.assert(task.target == null);
    task.target = .init(target);
    task.callback = Adapter.run;
    this.vtable.enqueue(this.context, task);
}

pub fn tick(this: Scheduler) void {
    this.vtable.tick(this.context);
}

pub fn isJavaScript(this: Scheduler) bool {
    return this.vtable.is_javascript;
}

pub fn reportShellError(this: Scheduler, err: *const bun.shell.ShellErr) void {
    this.vtable.report_shell_error(this.context, err);
}

pub fn reportOutOfMemory(this: Scheduler) void {
    this.vtable.report_out_of_memory(this.context);
}

pub fn throwMessage(this: Scheduler, message: []const u8) void {
    this.vtable.throw_message(this.context, message);
}

pub fn throwInvalidArguments(this: Scheduler, message: []const u8) void {
    this.vtable.throw_invalid_arguments(this.context, message);
}

pub const BlobConsumer = *const fn (*anyopaque, *bun.webcore.Blob.Any) ?bun.shell.Yield;

pub fn withShellValueBlob(
    this: Scheduler,
    value: *const ShellValue.Value,
    unavailable_message: []const u8,
    consumer_context: *anyopaque,
    consumer: BlobConsumer,
) ?bun.shell.Yield {
    return this.vtable.with_shell_value_blob(this.context, value, unavailable_message, consumer_context, consumer);
}

pub fn positionalArg(this: Scheduler, index: u8) []const u8 {
    return this.vtable.positional_arg(this.context, index);
}

pub fn integrationContext(this: Scheduler) Context {
    return this.context;
}

pub fn createNullDelimitedEnvMap(this: Scheduler, allocator: std.mem.Allocator) ![:null]?[*:0]const u8 {
    return this.environment.map.createNullDelimitedEnvMap(allocator);
}

const mini_vtable: VTable = .{
    .enqueue = struct {
        fn call(raw_loop: Context, task: *Task) void {
            const loop = raw_loop.get(*bun.MiniEventLoop);
            loop.enqueueTaskConcurrent(task.taskForQueue());
        }
    }.call,
    .tick = struct {
        fn call(raw_loop: Context) void {
            const loop = raw_loop.get(*bun.MiniEventLoop);
            loop.loop.tick();
        }
    }.call,
    .report_shell_error = struct {
        fn call(_: Context, err: *const bun.shell.ShellErr) void {
            err.throwMini();
        }
    }.call,
    .report_out_of_memory = struct {
        fn call(_: Context) void {
            bun.Output.prettyErrorln("<r><red>error<r>: Out of memory", .{});
            bun.Global.exit(1);
        }
    }.call,
    .throw_message = struct {
        fn call(_: Context, _: []const u8) void {
            @panic("JavaScript shell error requested from a standalone interpreter");
        }
    }.call,
    .throw_invalid_arguments = struct {
        fn call(_: Context, _: []const u8) void {
            @panic("JavaScript shell argument error requested from a standalone interpreter");
        }
    }.call,
    .with_shell_value_blob = struct {
        fn call(_: Context, _: *const ShellValue.Value, _: []const u8, _: *anyopaque, _: BlobConsumer) ?bun.shell.Yield {
            @panic("JavaScript shell value requested from a standalone interpreter");
        }
    }.call,
    .positional_arg = struct {
        fn call(_: Context, _: u8) []const u8 {
            return "";
        }
    }.call,
    .is_javascript = false,
};

const std = @import("std");
const bun = @import("bun");
const AnyTaskWithExtraContext = @import("../event_loop/AnyTaskWithExtraContext.zig");
const ShellValue = @import("./ShellValue.zig");
