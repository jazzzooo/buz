pub const Executor = struct {
    io: std.Io,
    parse_lane: Lane,
    read_lane: Lane,
    operation_workers: ?*Worker = null,
    v2: *BundleV2,

    const debug = Output.scoped(.BundlerExecutor, .visible);
    const read_worker_limit = 4;

    /// File opens contend in the macOS kernel, so the read cap spans all bundles.
    var read_lane_permits: std.Io.Semaphore = .{ .permits = read_worker_limit };

    pub const Task = struct {
        node: struct {
            next: ?*Task = null,
        } = .{},
        callback: *const fn (*Task) void,
    };

    pub const Batch = struct {
        len: usize = 0,
        head: ?*Task = null,
        tail: ?*Task = null,

        pub fn from(task: *Task) Batch {
            task.node.next = null;
            return .{ .len = 1, .head = task, .tail = task };
        }

        pub fn push(this: *Batch, batch: Batch) void {
            if (batch.len == 0) return;
            if (this.len == 0) {
                this.* = batch;
            } else {
                this.tail.?.node.next = batch.head;
                this.tail = batch.tail;
                this.len += batch.len;
            }
        }

        pub fn pop(this: *Batch) ?*Task {
            const task = this.head orelse return null;
            this.head = task.node.next;
            task.node.next = null;
            this.len -= 1;
            if (this.head == null) this.tail = null;
            return task;
        }
    };

    const LaneKind = enum {
        parse,
        read,
    };

    const Lane = struct {
        executor: *Executor,
        kind: LaneKind,
        group: std.Io.Group = .init,
        mutex: std.Io.Mutex = .init,
        condition: std.Io.Condition = .init,
        pending: Batch = .{},
        stopping: bool = false,
        workers: []*Worker,
        worker_count: usize = 0,
        active_workers: usize = 0,

        fn init(this: *Lane, executor: *Executor, kind: LaneKind, max_workers: usize) !void {
            const workers = try bun.default_allocator.alloc(*Worker, max_workers);
            errdefer bun.default_allocator.free(workers);
            this.* = .{
                .executor = executor,
                .kind = kind,
                .workers = workers,
            };

            if (max_workers > 0) {
                this.mutex.lockUncancelable(executor.io);
                defer this.mutex.unlock(executor.io);
                try this.spawnWorkerAssumeLocked();
            }
        }

        fn deinit(this: *Lane) void {
            const io = this.executor.io;
            this.mutex.lockUncancelable(io);
            this.stopping = true;
            this.mutex.unlock(io);
            this.condition.broadcast(io);

            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            this.group.await(io) catch |err| switch (err) {
                error.Canceled => unreachable,
            };

            bun.assert(this.pending.len == 0);
            bun.assert(this.active_workers == 0);
            for (this.workers[0..this.worker_count]) |worker| worker.deinit();
            bun.default_allocator.free(this.workers);
        }

        fn spawnWorkerAssumeLocked(this: *Lane) !void {
            bun.assert(this.worker_count < this.workers.len);
            const worker = try bun.default_allocator.create(Worker);
            errdefer bun.default_allocator.destroy(worker);
            worker.* = .{
                .ctx = this.executor.v2,
                .lane = this.kind,
                .heap = undefined,
                .allocator = undefined,
            };
            try this.group.concurrent(this.executor.io, workerMain, .{ this, worker });
            this.workers[this.worker_count] = worker;
            this.worker_count += 1;
        }

        fn workerMain(this: *Lane, worker: *Worker) std.Io.Cancelable!void {
            bun.assert(Worker.current == null);
            Worker.current = worker;
            defer Worker.current = null;

            const io = this.executor.io;
            while (true) {
                this.mutex.lockUncancelable(io);
                while (this.pending.len == 0 and !this.stopping) {
                    this.condition.wait(io, &this.mutex) catch |err| {
                        this.mutex.unlock(io);
                        return err;
                    };
                }
                const task = this.pending.pop() orelse {
                    bun.assert(this.stopping);
                    this.mutex.unlock(io);
                    return;
                };
                this.active_workers += 1;
                this.mutex.unlock(io);
                this.runTask(task);

                this.mutex.lockUncancelable(io);
                bun.assert(this.active_workers > 0);
                this.active_workers -= 1;
                this.mutex.unlock(io);
            }
        }

        fn runTask(this: *Lane, task: *Task) void {
            if (this.kind == .read) {
                read_lane_permits.waitUncancelable(this.executor.io);
                defer read_lane_permits.post(this.executor.io);
                task.callback(task);
                return;
            }
            task.callback(task);
        }

        fn scheduleBatch(this: *Lane, batch: Batch) void {
            if (batch.len == 0) return;
            const io = this.executor.io;
            this.mutex.lockUncancelable(io);
            bun.assert(!this.stopping);
            this.pending.push(batch);
            const desired_workers = @min(this.pending.len + this.active_workers, this.workers.len);
            while (this.worker_count < desired_workers) {
                this.spawnWorkerAssumeLocked() catch break;
            }
            const worker_count = this.worker_count;
            this.mutex.unlock(io);
            for (0..@min(batch.len, worker_count)) |_| {
                this.condition.signal(io);
            }
        }
    };

    pub fn init(this: *Executor, v2: *BundleV2) !void {
        this.* = .{
            .io = v2.transpiler.io,
            .v2 = v2,
            .parse_lane = undefined,
            .read_lane = undefined,
        };

        const parse_worker_count = bun.getThreadCount();
        try this.parse_lane.init(this, .parse, parse_worker_count);
        errdefer this.parse_lane.deinit();

        const read_worker_count = if (usesReadLane())
            std.math.clamp(parse_worker_count, 2, read_worker_limit)
        else
            0;
        try this.read_lane.init(this, .read, read_worker_count);

        debug("up to {d} parse workers and {d} read workers", .{ parse_worker_count, read_worker_count });
    }

    pub fn deinit(this: *Executor) void {
        this.read_lane.deinit();
        this.parse_lane.deinit();
        while (this.operation_workers) |worker| {
            this.operation_workers = worker.next_all;
            worker.deinit();
        }
    }

    fn usesReadLane() bool {
        if (bun.feature_flag.BUN_FEATURE_FLAG_FORCE_IO_POOL.get()) return true;
        if (bun.feature_flag.BUN_FEATURE_FLAG_DISABLE_IO_POOL.get()) return false;
        return (Environment.isMac or Environment.isWindows) and bun.getThreadCount() > 3;
    }

    pub fn schedule(this: *Executor, parse_task: *ParseTask) void {
        if (parse_task.contents_or_fd == .contents and parse_task.stage == .needs_source_code) {
            parse_task.stage = .{
                .needs_parse = .{
                    .contents = parse_task.contents_or_fd.contents,
                    .fd = bun.invalid_fd,
                },
            };
        }
        const lane = if (parse_task.stage == .needs_source_code and this.read_lane.workers.len > 0)
            &this.read_lane
        else
            &this.parse_lane;
        lane.scheduleBatch(.from(&parse_task.task));
    }

    pub fn scheduleTask(this: *Executor, task: *Task) void {
        this.parse_lane.scheduleBatch(.from(task));
    }

    pub fn scheduleBatch(this: *Executor, batch: Batch) void {
        this.parse_lane.scheduleBatch(batch);
    }

    pub fn runBatch(this: *Executor, allocator: std.mem.Allocator, batch: Batch) !void {
        const tasks = try allocator.alloc(*Task, batch.len);
        defer allocator.free(tasks);
        var remaining = batch;
        for (tasks) |*task| task.* = remaining.pop().?;
        bun.assert(remaining.len == 0);

        const Context = struct {
            tasks: []*Task,
            next: std.atomic.Value(usize) = .init(0),
        };
        var context: Context = .{ .tasks = tasks };
        try this.parallel(&context, tasks.len, struct {
            fn run(ctx: *Context) std.Io.Cancelable!void {
                while (true) {
                    try std.Io.checkCancel(Worker.current.?.ctx.transpiler.io);
                    const index = ctx.next.fetchAdd(1, .monotonic);
                    if (index >= ctx.tasks.len) return;
                    const task = ctx.tasks[index];
                    task.callback(task);
                }
            }
        }.run);
    }

    pub fn each(
        this: *Executor,
        ctx: anytype,
        comptime run_fn: anytype,
        values: anytype,
    ) !void {
        const Context = struct {
            ctx: @TypeOf(ctx),
            values: @TypeOf(values),
            next: std.atomic.Value(usize) = .init(0),
        };
        var context: Context = .{ .ctx = ctx, .values = values };
        try this.parallel(&context, values.len, struct {
            fn run(state: *Context) std.Io.Cancelable!void {
                while (true) {
                    try std.Io.checkCancel(Worker.current.?.ctx.transpiler.io);
                    const index = state.next.fetchAdd(1, .monotonic);
                    if (index >= state.values.len) return;
                    run_fn(state.ctx, state.values[index], index);
                }
            }
        }.run);
    }

    pub fn eachPtr(
        this: *Executor,
        ctx: anytype,
        comptime run_fn: anytype,
        values: anytype,
    ) !void {
        const Context = struct {
            ctx: @TypeOf(ctx),
            values: @TypeOf(values),
            next: std.atomic.Value(usize) = .init(0),
        };
        var context: Context = .{ .ctx = ctx, .values = values };
        try this.parallel(&context, values.len, struct {
            fn run(state: *Context) std.Io.Cancelable!void {
                while (true) {
                    try std.Io.checkCancel(Worker.current.?.ctx.transpiler.io);
                    const index = state.next.fetchAdd(1, .monotonic);
                    if (index >= state.values.len) return;
                    run_fn(state.ctx, &state.values[index], index);
                }
            }
        }.run);
    }

    fn parallel(this: *Executor, context: anytype, len: usize, comptime run: anytype) !void {
        const count = @min(len, bun.getThreadCount());
        if (count == 0) return;

        var group: std.Io.Group = .init;
        errdefer group.cancel(this.io);

        for (0..count - 1) |_| {
            const worker = this.createOperationWorker();
            group.async(this.io, runParallelShard(@TypeOf(context), run), .{ worker, context });
        }
        try runParallelShard(@TypeOf(context), run)(this.createOperationWorker(), context);
        try group.await(this.io);
    }

    pub const Worker = struct {
        threadlocal var current: ?*Worker = null;

        heap: ThreadLocalArena,

        /// Thread-local memory allocator
        /// All allocations are freed in `deinit` at the very end of bundling.
        allocator: std.mem.Allocator,

        ctx: *BundleV2,
        lane: LaneKind,

        data: WorkerData = undefined,
        ast_memory_allocator: js_ast.ASTMemoryAllocator = undefined,
        has_created: bool = false,

        temporary_arena: bun.ArenaAllocator = undefined,
        stmt_list: LinkerContext.StmtList = undefined,
        next_all: ?*Worker = null,

        pub fn deinit(this: *Worker) void {
            if (this.has_created) {
                this.heap.deinit();
            }

            bun.default_allocator.destroy(this);
        }

        pub fn get(ctx: *BundleV2) *Worker {
            var worker = current orelse @panic("bundler task has no logical worker");
            bun.assert(worker.ctx == ctx);
            if (!worker.has_created) {
                worker.create();
            }

            worker.ast_memory_allocator.push();

            if (comptime FeatureFlags.help_catch_memory_issues) {
                worker.heap.helpCatchMemoryIssues();
            }

            return worker;
        }

        pub fn unget(this: *Worker) void {
            if (comptime FeatureFlags.help_catch_memory_issues) {
                this.heap.helpCatchMemoryIssues();
            }

            this.ast_memory_allocator.pop();
        }

        pub const WorkerData = struct {
            log: Logger.Log,
            transpiler: Transpiler,
            other_transpiler: ?Transpiler = null,
        };

        fn create(this: *Worker) void {
            const trace = bun.perf.trace("Bundler.Worker.create");
            defer trace.end();

            this.has_created = true;
            Output.Source.configureThread();
            this.heap = ThreadLocalArena.init();
            this.allocator = this.heap.allocator();

            const allocator = this.allocator;

            this.ast_memory_allocator = .{ .allocator = this.allocator };
            this.ast_memory_allocator.reset();

            this.data = WorkerData{
                .log = Logger.Log.init(allocator),
                .transpiler = this.ctx.transpiler.*,
            };
            this.temporary_arena = bun.ArenaAllocator.init(this.allocator);
            this.stmt_list = LinkerContext.StmtList.init(this.allocator);
            this.configureTranspiler(&this.data.transpiler, allocator);

            debug("Worker.create()", .{});
        }

        fn configureTranspiler(this: *Worker, transpiler: *Transpiler, allocator: std.mem.Allocator) void {
            transpiler.setLog(&this.data.log);
            transpiler.setAllocator(allocator);
            transpiler.linker.resolver = &transpiler.resolver;
            transpiler.macro_context = js_ast.Macro.MacroContext.init(transpiler);
            const CacheSet = @import("./cache.zig");
            transpiler.resolver.caches = CacheSet.Set.init(allocator);
        }

        pub fn transpilerForTarget(this: *Worker, target: bun.options.Target) *Transpiler {
            if (target == .browser and this.data.transpiler.options.target != target) {
                const other_transpiler = if (this.data.other_transpiler) |*other|
                    other
                else blk: {
                    this.data.other_transpiler = this.ctx.client_transpiler.?.*;
                    const other = &this.data.other_transpiler.?;
                    this.configureTranspiler(other, this.allocator);
                    break :blk other;
                };
                bun.debugAssert(other_transpiler.options.target == target);
                return other_transpiler;
            }

            return &this.data.transpiler;
        }
    };

    fn createOperationWorker(this: *Executor) *Worker {
        const worker = bun.handleOom(bun.default_allocator.create(Worker));
        worker.* = .{
            .ctx = this.v2,
            .lane = .parse,
            .heap = undefined,
            .allocator = undefined,
            .next_all = this.operation_workers,
        };
        this.operation_workers = worker;
        return worker;
    }

    fn runParallelShard(comptime Context: type, comptime run: anytype) fn (*Worker, Context) std.Io.Cancelable!void {
        return struct {
            fn call(worker: *Worker, context: Context) std.Io.Cancelable!void {
                bun.assert(Worker.current == null);
                Worker.current = worker;
                defer Worker.current = null;
                try run(context);
            }
        }.call;
    }
};

const Logger = @import("../logger/logger.zig");
const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const FeatureFlags = bun.FeatureFlags;
const Output = bun.Output;
const Transpiler = bun.Transpiler;
const js_ast = bun.ast;

const ThreadLocalArena = bun.allocators.MimallocArena;

const BundleV2 = bun.bundle_v2.BundleV2;
const LinkerContext = bun.bundle_v2.LinkerContext;
const ParseTask = bun.bundle_v2.ParseTask;
