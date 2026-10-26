const log = bun.Output.scoped(.StatWatcher, .visible);

fn statToOwnedStats(globalThis: *jsc.JSGlobalObject, stats: *const bun.sys.PosixStat, bigint: bool) bun.JSError!OwnedStats {
    return NodeStatEngine.createOwned(globalThis, stats, bigint);
}

const StatWatcherWork = struct {
    ref_count: RefCount = .init(),
    closed: std.atomic.Value(bool) = .init(false),
    path: [:0]const u8,
    registry: *jsc.NativeCompletionRegistry,
    entry: jsc.NativeCompletionRegistry.Entry,
    task: bun.BackgroundTaskGroup.Task = .{ .callback = read, .on_cancel = cancel },
    // Registry notification publishes the result; only delivery can schedule another read.
    result: union(enum) { stat: bun.sys.PosixStat, missing, cancelled } = undefined,

    const RefCount = bun.ptr.ThreadSafeRefCount(StatWatcherWork, "ref_count", deinit, .{});
    const ref = RefCount.ref;
    const deref = RefCount.deref;

    fn deinit(this: *StatWatcherWork) void {
        const registry = this.registry;
        bun.default_allocator.free(this.path);
        bun.destroy(this);
        registry.release();
    }

    fn read(task: *bun.BackgroundTaskGroup.Task) void {
        const this: *StatWatcherWork = @fieldParentPtr("task", task);
        defer this.deref();
        if (this.closed.load(.acquire)) return;
        this.result = switch (StatWatcherCore.read(this.path)) {
            .result => |stat| .{ .stat = stat },
            .err => .missing,
        };
        _ = this.registry.notify(&this.entry);
    }

    fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
        const this: *StatWatcherWork = @fieldParentPtr("task", task);
        defer this.deref();
        this.result = .cancelled;
        _ = this.registry.notify(&this.entry);
    }
};

pub const StatWatcher = struct {
    pub const JSBinding = struct {
        bindgen_state: bindgen.ClassState = .{},
        watcher: bindgen.OwnedNative(StatWatcher, .vm),

        pub fn construct(
            context: bindgen.CallContext(StatWatcherConstructorSchema),
            method_args: bindgen.Args(StatWatcherConstructorSchema),
        ) bindgen.CallError(StatWatcherConstructorSchema)!*JSBinding {
            const args = try argumentsFromBindgen(method_args);
            defer args.deinit();
            return StatWatcher.init(args, context.viewToken().globalObject());
        }

        pub fn wrapperCreated(this: *JSBinding, wrapper: bindgen.ClassRefView(StatWatcherSchema)) bun.JSError!void {
            const watcher = this.watcher.get();
            try watcher.this_value.setStrongClassView(StatWatcherSchema, wrapper);
            watcher.ref();
            if (!watcher.work.registry.register(&watcher.work.entry)) {
                detach(.init(watcher));
                return;
            }
            watcher.scheduleRead();
        }

        pub const destroy = @This().deinit;

        fn deinit(this: *JSBinding) void {
            this.watcher.deinit();
            bun.destroy(this);
        }

        pub fn memoryUsage(this: *const JSBinding, _: bun.bindgen.MemoryUsageContext(.vm)) usize {
            const watcher = this.watcher.get();
            return @sizeOf(JSBinding) + @sizeOf(StatWatcher) + @sizeOf(StatWatcherWork) + watcher.work.path.len + 1;
        }

        pub fn doClose(
            this: *JSBinding,
            _: bindgen.CallContext(StatWatcherCloseSchema),
            _: bindgen.Args(StatWatcherCloseSchema),
        ) bun.JSError!void {
            this.watcher.get().close();
        }

        pub fn doRef(
            this: *JSBinding,
            _: bindgen.CallContext(StatWatcherRefSchema),
            _: bindgen.Args(StatWatcherRefSchema),
        ) bun.JSError!void {
            this.watcher.get().refFromJS();
        }

        pub fn doUnref(
            this: *JSBinding,
            _: bindgen.CallContext(StatWatcherUnrefSchema),
            _: bindgen.Args(StatWatcherUnrefSchema),
        ) bun.JSError!void {
            this.watcher.get().unrefFromJS();
        }
    };

    ctx: *VirtualMachine,
    ref_count: RefCount,
    closed: bool,
    persistent: bool,
    bigint: bool,
    interval: u32,
    globalThis: *jsc.JSGlobalObject,
    this_value: bindgen.WrapperReference(.{StatWatcherSchema}),
    listener: ?StatWatcherListener,
    previous_stat: ?OwnedStats = null,
    previous_native_stat: ?bun.sys.PosixStat = null,
    poll_ref: bun.Async.KeepAlive = .{},
    event_loop_timer: EventLoopTimer = .initPaused(.StatWatcher),
    next_check: bun.timespec = .epoch,
    work: *StatWatcherWork,
    read_pending: bool = false,

    const RefCount = bun.ptr.RefCount(StatWatcher, "ref_count", deinit, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;

    fn deinit(this: *StatWatcher) void {
        log("deinit {x}", .{@intFromPtr(this)});
        bun.assert(this.closed);
        bun.assert(this.event_loop_timer.in_heap == .none);
        if (this.ctx.test_isolation_enabled) this.ctx.rareData().removeStatWatcherForIsolation(this);
        this.work.deref();
        bun.destroy(this);
    }

    pub const Arguments = StatWatcherTypes.Arguments;

    fn refFromJS(this: *StatWatcher) void {
        if (!this.closed and !this.persistent) {
            this.persistent = true;
            this.poll_ref.ref(this.ctx);
        }
    }

    fn unrefFromJS(this: *StatWatcher) void {
        if (this.persistent) {
            this.persistent = false;
            this.poll_ref.unref(this.ctx);
        }
    }

    pub fn close(this: *StatWatcher) void {
        this.ref();
        defer this.deref();
        this.stop();
        this.work.registry.detach(&this.work.entry);
    }

    fn stop(this: *StatWatcher) void {
        if (this.closed) return;
        this.closed = true;
        this.work.closed.store(true, .release);
        if (this.event_loop_timer.in_heap != .none) this.ctx.timer.remove(&this.event_loop_timer);
        this.event_loop_timer.state = .CANCELLED;
        this.persistent = false;
        this.poll_ref.unref(this.ctx);
        this.this_value.deinit();
        if (this.listener) |*listener| listener.deinit();
        this.listener = null;
        if (this.previous_stat) |*previous| previous.deinit();
        this.previous_stat = null;
    }

    pub fn destroy(this: *StatWatcher) void {
        this.close();
        this.deref();
    }

    fn detach(raw: bun.bindgen.NativeCallbackContext(.vm)) void {
        const this = raw.get(*StatWatcher);
        defer this.deref();
        this.stop();
    }

    pub fn timerCallback(this: *StatWatcher) void {
        this.event_loop_timer.state = .FIRED;
        this.event_loop_timer.heap = .{};
        if (this.closed) return;
        if (this.ctx.scriptExecutionStatus() != .running) {
            this.close();
            return;
        }
        this.scheduleRead();
    }

    fn scheduleRead(this: *StatWatcher) void {
        bun.assert(!this.closed and !this.read_pending);
        this.read_pending = true;
        this.next_check = bun.timespec.msFromNow(.force_real_time, this.interval);
        this.work.ref();
        bun.BackgroundWork.schedule(&this.ctx.background_tasks, &this.work.task) catch {
            StatWatcherWork.read(&this.work.task);
        };
    }

    fn deliver(raw: bun.bindgen.NativeCallbackContext(.vm)) void {
        const this = raw.get(*StatWatcher);
        this.ref();
        defer this.deref();
        bun.assert(this.read_pending);
        this.read_pending = false;
        if (this.closed) return;
        defer if (!this.closed) this.ctx.timer.update(&this.event_loop_timer, &this.next_check);

        const result = this.work.result;
        const stat = switch (result) {
            .stat => |stat| stat,
            .missing => std.mem.zeroes(bun.sys.PosixStat),
            .cancelled => return this.close(),
        };
        if (this.previous_native_stat) |*previous| {
            if (StatWatcherCore.equivalent(previous, &stat)) return;
        }
        const globalThis = this.globalThis;
        var current_stat = statToOwnedStats(globalThis, &stat, this.bigint) catch |err|
            return globalThis.reportActiveExceptionAsUnhandled(err);
        defer current_stat.deinit();
        var previous_stat = this.previous_stat;
        defer if (previous_stat) |*previous| previous.deinit();
        this.previous_stat = current_stat.clone();
        this.previous_native_stat = stat;
        if (previous_stat) |*previous| {
            this.dispatchStats(&current_stat, previous);
        } else if (result == .missing) {
            this.dispatchStats(&current_stat, &current_stat);
        }
    }

    fn dispatchStats(this: *StatWatcher, current: *const OwnedStats, previous: *const OwnedStats) void {
        var listener = this.listener.?.clone();
        defer listener.deinit();
        var invocation: StatWatcherListener.Invocation = undefined;
        listener.beginInvocation(&invocation);
        defer invocation.deinit();
        invocation.call(.{
            .current = current.operand(&invocation),
            .previous = previous.operand(&invocation),
        }) catch |err| invocation.reportActiveException(err);
    }

    pub fn init(args: Arguments, global_this: *jsc.JSGlobalObject) bun.JSError!*JSBinding {
        log("init", .{});

        const buf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(buf);
        const parts = [_][]const u8{args.path.slice()};
        const file_path = Path.joinAbsStringBuf(
            fs.FileSystem.instance.top_level_dir,
            buf,
            &parts,
            .auto,
        );

        const alloc_file_path = try bun.default_allocator.allocSentinel(u8, file_path.len, 0);
        errdefer bun.default_allocator.free(alloc_file_path);
        @memcpy(alloc_file_path, file_path);

        const vm = global_this.bunVM();
        const rare = try vm.tryRareData();
        const registry = try rare.nativeCompletionRegistry(vm);
        const work = try bun.default_allocator.create(StatWatcherWork);
        errdefer bun.destroy(work);
        const this = try bun.default_allocator.create(StatWatcher);
        errdefer bun.destroy(this);
        const binding = try bun.default_allocator.create(JSBinding);
        errdefer bun.destroy(binding);
        if (vm.test_isolation_enabled) try rare.addStatWatcherForIsolation(this);

        registry.retain();
        work.* = .{
            .path = alloc_file_path,
            .registry = registry,
            .entry = .{ .context = .init(this), .deliver = deliver, .detach = detach, .delivery = .repeating },
        };
        this.* = .{
            .ctx = vm,
            .persistent = args.persistent,
            .bigint = args.bigint,
            .interval = @max(5, args.interval),
            .globalThis = global_this,
            .this_value = .empty(),
            .listener = args.listener.clone(),
            .previous_stat = null,
            .closed = false,
            .work = work,
            .ref_count = .init(),
        };
        if (this.persistent) {
            this.poll_ref.ref(this.ctx);
        }
        binding.* = .{ .watcher = .init(this) };
        return binding;
    }
};

const Path = @import("../../paths/resolve_path.zig");
const fs = @import("../../resolver/fs.zig");
const std = @import("std");

const bun = @import("bun");
const EventLoopTimer = bun.api.Timer.EventLoopTimer;

const jsc = bun.jsc;
const bindgen = bun.bindgen;
const VirtualMachine = jsc.VirtualMachine;

const StatWatcherBindingModule = bindgen.Module("StatWatcher");
const StatWatcherSchema = StatWatcherBindingModule.class("StatWatcher");
const StatWatcherClass = bindgen.Class(StatWatcherSchema, StatWatcher.JSBinding);
const StatWatcherConstructorSchema = StatWatcherSchema.constructor();
const StatWatcherCloseSchema = StatWatcherSchema.member("close");
const StatWatcherRefSchema = StatWatcherSchema.member("ref");
const StatWatcherUnrefSchema = StatWatcherSchema.member("unref");
const StatWatcherListener = StatWatcherTypes.Listener;

comptime {
    _ = StatWatcherClass;
}

const NodeStatEngine = @import("./NodeStatEngine.zig");
const OwnedStats = NodeStatEngine.OwnedStats;
const StatWatcherCore = @import("./stat_watcher.zig");
const StatWatcherTypes = @import("./StatWatcherTypes.zig");
const PathLike = @import("./PathLike.zig").PathLike;

fn argumentsFromBindgen(args: anytype) bun.JSError!StatWatcherTypes.Arguments {
    const path = try PathLike.fromBindingView(args.path);
    errdefer path.deinit();
    return .{
        .path = path,
        .listener = try args.listener.toOwned(),
        .persistent = if (args.options) |options| options.persistent else true,
        .bigint = if (args.options) |options| options.bigint else false,
        .interval = if (args.options) |options| options.interval else 5007,
    };
}
