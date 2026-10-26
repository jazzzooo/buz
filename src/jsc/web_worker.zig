//! Shared implementation of Web and Node `Worker`.
//!
//! Lifetime / threading model
//! ==========================
//!
//! Three objects, two threads, one ownership rule:
//!
//!   ┌─ PARENT THREAD ───────────────────────────────────────────────────────┐
//!   │  JSWorker (GC'd JSCell) ──Ref──► WebCore::Worker (ThreadSafeRefCounted)│
//!   │                                    └─ impl_ ──owns──► Zig WebWorker    │
//!   └───────────────────────────────────────────────────────┬───────────────┘
//!                                                            │
//!   ┌─ WORKER THREAD ───────────────────────────────────────┴───────────────┐
//!   │  runs threadMain() → spin() → shutdown(); reads this struct directly  │
//!   └───────────────────────────────────────────────────────────────────────┘
//!
//! Ownership rule: this struct is OWNED BY the C++ `WebCore::Worker`. It is
//! allocated in `create()` and freed by `WebCore::Worker::~Worker()` through
//! the generated boundary. The worker thread NEVER frees it. Because `JSWorker`
//! holds a `Ref<Worker>`, `impl_` is valid for the entire time JS can call
//! `terminate()`/`ref()`/`unref()` — those calls cannot UAF.
//!
//! Refs on `WebCore::Worker`:
//!   - `JSWorker` wrapper  +1  (dropped at GC)
//!   - worker thread       +1  taken in `Worker::create()` BEFORE the thread is
//!                             spawned, dropped on the parent by exit delivery
//!                             or the parent's thread join.
//!
//! Lifecycle of the worker thread (`threadMain`):
//!   1. `startVM()`  — build a mimalloc arena, clone env, initialise a
//!      `jsc.VirtualMachine`, publish `vm` under `vm_lock`.
//!   2. `spin()`     — load the entry point, call `dispatchOnline` +
//!      `fireEarlyMessages`, run the event loop until it drains or
//!      `requested_terminate` is observed, run `beforeExit`.
//!   3. `prepareShutdown()` — unpublish the VM and run exit handlers under
//!      the API lock, then return through the generated call frames.
//!   4. `shutdown()` — tear down the JSC VM, signal
//!      `dispatchExit` (which releases `parent_poll_ref` + the thread ref on
//!      the parent), free the arena, exit the thread. After `dispatchExit`
//!      `this` may be freed at any time; nothing below it dereferences `this`.
//!
//! `vm_lock` exists solely to close the TOCTOU between the parent reading a
//! non-null `vm` (in `notifyNeedTermination`) and the worker freeing the arena
//! that backs it. It is held only while (a) publishing `vm` in `startVM`,
//! (b) nulling `vm` in `shutdown`, (c) reading `vm` + calling `wakeup()` in
//! `notifyNeedTermination`.
//!
//! Every field below is grouped by which thread may touch it.
//!
//! Each VM owns a closed-before-shutdown tree of its direct children. A worker
//! recursively stops and joins that tree before tearing down its own VM, so
//! the main VM joining its direct children joins the complete descendant tree.

const WebWorker = @This();

const log = Output.scoped(.Worker, .hidden);

pub const HeapSnapshotTask = struct {
    completion: bun.bindgen.OwnedCompletion(WorkerGetHeapSnapshotSchema),

    fn resolve(this: *HeapSnapshotTask, snapshot: bun.bindgen.ThreadSafeDOMString) void {
        this.completion.resolve(snapshot);
        bun.destroy(this);
    }

    fn rejectNotRunning(this: *HeapSnapshotTask) void {
        this.completion.fail(.worker_not_running, {});
        bun.destroy(this);
    }
};

const WorkerBinding = opaque {
    pub fn getHeapSnapshot(
        this: *WorkerBinding,
        context: bun.bindgen.CallContext(WorkerGetHeapSnapshotSchema),
        _: bun.bindgen.Args(WorkerGetHeapSnapshotSchema),
    ) bun.bindgen.CallError(WorkerGetHeapSnapshotSchema)!void {
        const task = bun.default_allocator.create(HeapSnapshotTask) catch {
            var completion = context.completion();
            completion.outOfMemory();
            return;
        };
        var completion = context.completion();
        task.* = .{ .completion = completion.take() };

        const operation = context.engineIn("WebWorkerEngine", "webWorkerStartHeapSnapshot");
        const EngineArgs = @TypeOf(operation).Args;
        const TaskOwner = @FieldType(EngineArgs, "task");
        const WorkerHandle = @FieldType(EngineArgs, "worker");
        var engine_args: EngineArgs = .{
            .worker = @as(WorkerHandle, @ptrCast(this)),
            .task = TaskOwner.initNative(task),
        };
        operation.call(&engine_args);
    }
};

// ---- Immutable after `create()` (safe from any thread) ----------------------

/// The owning C++ `WebCore::Worker`. Never null; this struct is freed by
/// `~Worker`, so the pointer cannot dangle.
cpp_worker: *anyopaque,
/// Parent `jsc.VirtualMachine`. Read on the worker thread by `startVM()`
/// (transform options, env, proxy storage, standalone graph) and on the
/// parent thread by `setRef()` / `releaseParentPollRef()`.
///
/// The parent closes its child registry and joins every registered thread
/// before freeing the VM, including when the parent is itself a worker.
parent: *jsc.VirtualMachine,
parent_context_id: u32,
execution_context_id: u32,
mini: bool,
eval_mode: bool,
store_fd: bool,
/// Heap-owned UTF-8 copies; freed in `destroy()`.
argv: []const []const u8,
exec_argv: ?[]const []const u8,
/// Heap-owned by this struct; freed in `destroy()`.
unresolved_specifier: []const u8,
preloads: [][]const u8,
name: [:0]const u8,

// ---- Cross-thread signalling ------------------------------------------------

/// Intrusive node in `parent.worker_children`.
parent_node: std.DoublyLinkedList.Node = .{},
registered_with_parent: bool = false,

/// Stored before `create()` returns and consumed exactly once by the parent.
thread: ?std.Thread = null,
completed: std.Io.Event = .unset,
startup_ready: std.Io.Event = .unset,
startup: std.atomic.Value(enum(u32) { pending, run, canceled }) = .init(.pending),

/// Set by the parent (`notifyNeedTermination`) or by the worker itself
/// (`exit`). The worker loop polls this between ticks.
requested_terminate: std.atomic.Value(bool) = .init(false),

/// The worker's `jsc.VirtualMachine`, or null before `startVM()` / after
/// `prepareShutdown()` nulls it. Lives inside `arena`. `vm_lock` must be held for any
/// cross-thread read (see header comment).
vm: ?*jsc.VirtualMachine = null,
vm_lock: std.Io.Mutex = .init,

// ---- Parent-thread only -----------------------------------------------------

/// Keep-alive on the parent's event loop. `Async.KeepAlive` is not thread-safe;
/// it is reffed in `create()`, toggled by `setRef()` (JS `.ref()`/`.unref()`),
/// and released by `releaseParentPollRef()` from the close task — all on the
/// parent thread.
parent_poll_ref: Async.KeepAlive = .{},

// ---- Worker-thread only -----------------------------------------------------

status: Status = .start,
arena: ?bun.MimallocArena = null,
/// Set by `exit()` so that `spin()`'s error paths don't clobber an explicit
/// `process.exit(code)`.
exit_called: bool = false,
exit_code: i32 = 0,

pub const Status = enum(u8) {
    /// Thread not yet started / startVM in progress.
    start,
    /// `spin()` has begun; entry point is loading.
    starting,
    /// `dispatchOnline` has fired; event loop is running.
    running,
    /// `shutdown()` has begun; no further JS will run.
    terminated,
};

pub const Children = struct {
    mutex: std.Io.Mutex = .init,
    list: std.DoublyLinkedList = .{},
    accepting: bool = true,

    pub const Shutdown = enum {
        completed,
        timed_out,
    };

    fn register(this: *Children, parent: *jsc.VirtualMachine, worker: *WebWorker) bool {
        const io = parent.pinned_threads.io();
        this.mutex.lockUncancelable(io);
        defer this.mutex.unlock(io);
        if (!this.accepting) return false;
        this.list.append(&worker.parent_node);
        worker.registered_with_parent = true;
        return true;
    }

    fn remove(this: *Children, parent: *jsc.VirtualMachine, worker: *WebWorker) ?std.Thread {
        const io = parent.pinned_threads.io();
        this.mutex.lockUncancelable(io);
        defer this.mutex.unlock(io);
        if (worker.registered_with_parent) {
            this.list.remove(&worker.parent_node);
            worker.registered_with_parent = false;
        }
        const thread = worker.thread;
        worker.thread = null;
        return thread;
    }

    fn waitForCompletion(worker: *WebWorker, io: std.Io, deadline: ?std.Io.Clock.Timestamp) bool {
        const until = deadline orelse {
            worker.completed.waitUncancelable(io);
            return true;
        };
        while (!worker.completed.isSet()) {
            worker.completed.waitTimeout(io, .{ .deadline = until }) catch |err| switch (err) {
                error.Canceled => unreachable,
                error.Timeout => {
                    if (worker.completed.isSet()) return true;
                    if (std.Io.Clock.awake.now(io).nanoseconds >= until.raw.nanoseconds) return false;
                },
            };
        }
        return true;
    }

    pub fn closeAndJoin(this: *Children, parent: *jsc.VirtualMachine, timeout_ms: ?u64) Shutdown {
        const io = parent.pinned_threads.io();
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);

        this.mutex.lockUncancelable(io);
        this.accepting = false;
        var node = this.list.first;
        while (node) |current| : (node = current.next) {
            const worker: *WebWorker = @fieldParentPtr("parent_node", current);
            worker.requestTermination();
        }
        node = this.list.first;
        this.mutex.unlock(io);

        const deadline: ?std.Io.Clock.Timestamp = if (timeout_ms) |ms| .{
            .raw = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(@intCast(ms))),
            .clock = .awake,
        } else null;

        while (node) |current| : (node = current.next) {
            const worker: *WebWorker = @fieldParentPtr("parent_node", current);
            if (!waitForCompletion(worker, io, deadline)) return .timed_out;
        }

        while (true) {
            this.mutex.lockUncancelable(io);
            const current = this.list.popFirst() orelse {
                this.mutex.unlock(io);
                return .completed;
            };
            const worker: *WebWorker = @fieldParentPtr("parent_node", current);
            worker.registered_with_parent = false;
            const thread = worker.thread.?;
            worker.thread = null;
            this.mutex.unlock(io);

            thread.join();
            bun.bindgen.Engine(WebWorkerFinishExitShim).call(.{
                .worker = @ptrCast(worker.cpp_worker),
                .exitCode = worker.exit_code,
                .dispatchEvent = false,
            });
        }
    }

    pub fn deinit(this: *Children) void {
        bun.assert(!this.accepting);
        bun.assert(this.list.first == null);
    }
};

fn bindWebWorkerGetParent(
    _: bun.bindgen.CallContext(WebWorkerGetParentSchema),
    _: bun.bindgen.Args(WebWorkerGetParentSchema),
) bun.bindgen.Return(WebWorkerGetParentSchema) {
    const worker = jsc.VirtualMachine.get().worker orelse return null;
    return @ptrCast(worker.cpp_worker);
}

fn bindWebWorkerNotifyNeedTermination(args: bun.bindgen.Args(WebWorkerNotifyNeedTerminationSchema)) bun.bindgen.Return(WebWorkerNotifyNeedTerminationSchema) {
    notifyNeedTermination(args.worker);
}

fn bindWebWorkerSetRef(args: bun.bindgen.Args(WebWorkerSetRefSchema)) bun.bindgen.Return(WebWorkerSetRefSchema) {
    setRef(args.worker, args.value);
}

fn bindWebWorkerReleaseParentPollRef(args: bun.bindgen.Args(WebWorkerReleaseParentPollRefSchema)) bun.bindgen.Return(WebWorkerReleaseParentPollRefSchema) {
    releaseParentPollRef(args.worker);
}

fn bindWebWorkerDestroy(args: bun.bindgen.Args(WebWorkerDestroySchema)) bun.bindgen.Return(WebWorkerDestroySchema) {
    if (args.worker.thread != null) {
        args.worker.requestTermination();
        args.worker.releaseParentPollRef();
    }
    destroy(args.worker);
}

fn bindWebWorkerCommitStartup(args: bun.bindgen.Args(WebWorkerCommitStartupSchema)) bun.bindgen.Return(WebWorkerCommitStartupSchema) {
    if (args.worker.startup.cmpxchgStrong(.pending, .run, .release, .monotonic) != null)
        @panic("worker startup committed after cancellation or commit");
    args.worker.startup_ready.set(args.worker.parent.pinned_threads.io());
}

fn bindWebWorkerHeapSnapshotTaskResolve(
    args: *bun.bindgen.Args(WebWorkerHeapSnapshotTaskResolveSchema),
) bun.bindgen.Return(WebWorkerHeapSnapshotTaskResolveSchema) {
    const task = args.task.takeNative();
    const snapshot = args.snapshot.toOwned() catch {
        task.completion.outOfMemory();
        bun.destroy(task);
        return;
    };
    task.resolve(snapshot);
}

fn bindWebWorkerHeapSnapshotTaskRejectNotRunning(
    args: *bun.bindgen.Args(WebWorkerHeapSnapshotTaskRejectNotRunningSchema),
) bun.bindgen.Return(WebWorkerHeapSnapshotTaskRejectNotRunningSchema) {
    args.task.takeNative().rejectNotRunning();
}

pub fn hasRequestedTerminate(this: *const WebWorker) bool {
    return this.requested_terminate.load(.acquire);
}

fn setRequestedTerminate(this: *WebWorker) bool {
    return this.requested_terminate.swap(true, .release);
}

pub fn requestTermination(this: *WebWorker) void {
    if (this.setRequestedTerminate()) return;
    log("[{d}] requestTermination", .{this.execution_context_id});

    const io = this.parent.pinned_threads.io();
    if (this.startup.cmpxchgStrong(.pending, .canceled, .release, .monotonic) == null)
        this.startup_ready.set(io);
    this.vm_lock.lockUncancelable(io);
    defer this.vm_lock.unlock(io);
    if (this.vm) |vm| {
        vm.jsc_vm.notifyNeedTermination();
        vm.eventLoop().wakeup();
    }
}

// =============================================================================
// Construction (parent thread)
// =============================================================================

/// Allocate the struct, take a keep-alive on the parent event loop, and spawn
/// a thread waiting for startup commit. Failed results contain no live worker state.
fn bindWebWorkerCreate(
    _: bun.bindgen.CallContext(WebWorkerCreateSchema),
    args: bun.bindgen.Args(WebWorkerCreateSchema),
) bun.JSError!bun.bindgen.Return(WebWorkerCreateSchema) {
    return createFromBinding(jsc.VirtualMachine.get(), args);
}

pub fn createFromBinding(
    parent: *jsc.VirtualMachine,
    args: bun.bindgen.Args(WebWorkerCreateSchema),
) bun.JSError!bun.bindgen.Return(WebWorkerCreateSchema) {
    log("[{d}] create", .{args.contextID});

    var name = try args.name.toUTF8(bun.default_allocator);
    defer name.deinit();
    var specifier = try args.url.toUTF8(bun.default_allocator);
    defer specifier.deinit();
    var error_message = bun.String.empty;
    defer error_message.deref();

    const prev_log = parent.transpiler.log;
    var temp_log = bun.logger.Log.init(bun.default_allocator);
    parent.transpiler.setLog(&temp_log);
    defer parent.transpiler.setLog(prev_log);
    defer temp_log.deinit();

    var preloads = try std.array_list.Managed([]const u8).initCapacity(bun.default_allocator, args.preloadModules.len());
    defer {
        for (preloads.items) |preload| bun.default_allocator.free(preload);
        preloads.deinit();
    }
    for (0..args.preloadModules.len()) |index| {
        const module = args.preloadModules.at(index).?;
        const utf8_slice = try module.toUTF8(bun.default_allocator);
        defer utf8_slice.deinit();
        if (try resolveEntryPointSpecifier(parent, utf8_slice.slice(), &error_message, &temp_log)) |preload| {
            preloads.appendAssumeCapacity(try bun.default_allocator.dupe(u8, preload));
        }

        if (!error_message.isEmpty()) {
            return webWorkerCreateFailure(error_message.dupeRef());
        }
    }

    const worker = create: {
        const allocation = try bun.default_allocator.create(WebWorker);
        errdefer bun.default_allocator.destroy(allocation);
        const unresolved_specifier = try bun.default_allocator.dupe(u8, specifier.slice());
        errdefer bun.default_allocator.free(unresolved_specifier);
        const worker_name = if (name.slice().len > 0)
            try bun.default_allocator.dupeSentinel(u8, name.slice(), 0)
        else
            "";
        errdefer if (worker_name.len > 0) bun.default_allocator.free(worker_name);
        const argv = try cloneStringSequence(args.argv);
        errdefer freeStringSequence(argv);
        const exec_argv = if (args.defaultExecArgv) null else try cloneStringSequence(args.execArgv);
        errdefer if (exec_argv) |strings| freeStringSequence(strings);

        allocation.* = WebWorker{
            .cpp_worker = @ptrCast(args.worker),
            .parent = parent,
            .parent_context_id = args.parentContextID,
            .execution_context_id = args.contextID,
            .mini = args.miniMode,
            .eval_mode = args.evalMode,
            .unresolved_specifier = unresolved_specifier,
            .store_fd = parent.transpiler.resolver.store_fd,
            .name = worker_name,
            .argv = argv,
            .exec_argv = exec_argv,
            .preloads = try preloads.toOwnedSlice(),
        };
        break :create allocation;
    };
    var spawned = false;
    defer if (!spawned) worker.destroy();

    // Keep the parent's event loop alive until the close task releases this.
    // If the user passed `{ ref: false }` we skip — they've opted out of the
    // worker keeping the process alive.
    if (!args.unrefByDefault) {
        worker.parent_poll_ref.ref(parent);
    }
    defer if (!spawned) worker.parent_poll_ref.unref(parent);

    if (!parent.worker_children.register(parent, worker)) {
        return webWorkerCreateFailure(bun.String.static("Cannot create a worker while its parent is shutting down"));
    }
    defer if (!spawned) {
        _ = parent.worker_children.remove(parent, worker);
    };

    const thread = std.Thread.spawn(
        .{ .stack_size = bun.default_thread_stack_size },
        threadMain,
        .{worker},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return webWorkerCreateFailure(bun.String.static("Failed to spawn worker thread")),
    };
    worker.thread = thread;
    spawned = true;
    const StateOwner = @typeInfo(@FieldType(bun.bindgen.Return(WebWorkerCreateSchema), "state")).optional.child;
    return .{ .state = StateOwner.initNative(worker), .errorMessage = .empty() };
}

fn webWorkerCreateFailure(error_message: bun.String) bun.OOM!bun.bindgen.Return(WebWorkerCreateSchema) {
    return .{
        .state = null,
        .errorMessage = try bun.bindgen.DOMString.fromBunString(error_message),
    };
}

fn cloneStringSequence(strings: anytype) bun.OOM![]const []const u8 {
    if (strings.len() == 0) return &.{};
    var result: std.ArrayList([]const u8) = try .initCapacity(bun.default_allocator, strings.len());
    errdefer {
        for (result.items) |string| bun.default_allocator.free(string);
        result.deinit(bun.default_allocator);
    }
    for (0..strings.len()) |index| {
        result.appendAssumeCapacity(try strings.at(index).?.toOwnedSlice(bun.default_allocator));
    }
    return result.toOwnedSlice(bun.default_allocator);
}

fn freeStringSequence(strings: []const []const u8) void {
    for (strings) |string| bun.default_allocator.free(string);
    if (strings.len > 0) bun.default_allocator.free(strings);
}

/// Free the struct and its owned strings. Called from `WebCore::Worker::~Worker()`
/// (or from worker creation on spawn failure). The allocator is mimalloc (thread-safe),
/// so the caller's thread doesn't matter.
fn destroy(this: *WebWorker) void {
    log("[{d}] destroy", .{this.execution_context_id});
    bun.assert(!this.registered_with_parent);
    bun.assert(this.thread == null);
    bun.default_allocator.free(this.unresolved_specifier);
    freeStringSequence(this.preloads);
    freeStringSequence(this.argv);
    if (this.exec_argv) |exec_argv| freeStringSequence(exec_argv);
    if (this.name.len > 0) bun.default_allocator.free(this.name);
    bun.default_allocator.destroy(this);
}

// =============================================================================
// Parent-thread API (called from C++ via JS)
// =============================================================================

/// worker.ref()/.unref() from JS. The struct is guaranteed alive: it's freed
/// by `~Worker`, which can't run while JSWorker (the caller) holds its
/// `Ref<Worker>`. `Worker::setKeepAlive()` gates out calls after terminate()
/// or the close task, so this can unconditionally toggle.
fn setRef(this: *WebWorker, value: bool) void {
    if (value) {
        this.parent_poll_ref.ref(this.parent);
    } else {
        this.parent_poll_ref.unref(this.parent);
    }
}

/// worker.terminate() from JS. Sets `requested_terminate`, interrupts running
/// JS in the worker (TerminationException at the next safepoint), and wakes
/// the worker loop so it observes the flag. `parent_poll_ref` stays held until
/// the close task runs so that `await worker.terminate()` keeps the parent
/// alive until 'close' fires.
fn notifyNeedTermination(this: *WebWorker) void {
    this.requestTermination();
}

/// Release the keep-alive on the parent's event loop. Called on the parent
/// thread from the close task posted by `dispatchExit`.
fn releaseParentPollRef(this: *WebWorker) void {
    if (this.parent.worker_children.remove(this.parent, this)) |thread| {
        thread.join();
    }
    this.parent_poll_ref.unref(this.parent);
}

// =============================================================================
// Worker thread
// =============================================================================

fn threadMain(this: *WebWorker) void {
    const io = this.parent.pinned_threads.io();
    this.startup_ready.waitUncancelable(io);
    if (this.startup.load(.acquire) != .run) {
        this.completed.set(io);
        return;
    }
    bun.analytics.Features.workers_spawned += 1;

    if (this.name.len > 0) {
        Output.Source.configureNamedThread(this.name);
    } else {
        Output.Source.configureNamedThread("Worker");
    }

    // Terminated before we even started — skip straight to shutdown so the
    // parent still gets a close event and the thread ref is dropped.
    if (this.hasRequestedTerminate()) {
        return this.shutdown(null);
    }

    this.startVM() catch |err| {
        Output.panic("An unhandled error occurred while starting a worker: {s}\n", .{@errorName(err)});
    };

    const vm = this.vm;
    if (vm) |worker_vm| {
        const api_lock = worker_vm.global.vm().getAPILock();
        defer api_lock.release();
        this.spin();
        this.prepareShutdown();
    }
    this.shutdown(vm);
}

/// Phase 1: build the worker's arena + VirtualMachine and publish `vm`.
fn startVM(this: *WebWorker) !void {
    assert(this.status == .start);
    assert(this.vm == null);

    var transform_options = this.parent.transpiler.options.transform_options;

    if (this.exec_argv) |exec_argv| parse_new_args: {
        var diag: bun.clap.Diagnostic = .{};
        var iter: bun.clap.args.SliceIterator = .init(exec_argv);

        var args = bun.clap.parseEx(bun.clap.Help, bun.cli.Command.tagParams(.RunCommand), &iter, .{
            .diagnostic = &diag,
            .allocator = bun.default_allocator,

            // just one for executable
            .stop_after_positional_at = 1,
        }) catch {
            // ignore param parsing errors
            break :parse_new_args;
        };
        defer args.deinit();

        // override the existing even if it was set
        transform_options.allow_addons = !args.flag("--no-addons");

        // TODO: currently this only checks for --no-addons. I think
        // this should go through most flags and update the options.
    }

    this.arena = bun.MimallocArena.init();
    const allocator = this.arena.?.allocator();

    // Proxy-env values may be RefCountedEnvValue bytes owned by the parent's
    // proxy_env_storage. We need a consistent snapshot of (storage slots +
    // env.map entries) so every slice we copy is backed by a ref we hold.
    // The parent's storage.lock serialises against proxy-environment writes on the
    // main thread — it covers both the slot swap and the map.put, so
    // cloneFrom and cloneWithAllocator see the same state.
    var temp_proxy_storage: jsc.RareData.ProxyEnvStorage = .{};
    errdefer temp_proxy_storage.deinit();

    const map = try allocator.create(bun.DotEnv.Map);
    {
        const parent_storage = &this.parent.proxy_env_storage;
        parent_storage.lock.lockUncancelable(this.parent.io);
        defer parent_storage.lock.unlock(this.parent.io);

        temp_proxy_storage.cloneFrom(parent_storage);
        map.* = try this.parent.transpiler.env.map.cloneWithAllocator(allocator);
    }
    const loader = try allocator.create(bun.DotEnv.Loader);
    loader.* = bun.DotEnv.Loader.init(map, allocator);

    // Checkpoint before the expensive part: initWorker builds a full JSC
    // VM. If parent shutdown started while we were cloning the env
    // above, bail now rather than spending ~50–100ms (release) creating a
    // VM that will immediately tear down.
    if (this.hasRequestedTerminate()) {
        temp_proxy_storage.deinit();
        return;
    }

    var vm = try jsc.VirtualMachine.initWorker(this, .{
        .io = this.parent.pinned_threads.io(),
        .pinned_threads = this.parent.pinned_threads,
        .allocator = allocator,
        .args = transform_options,
        .env_loader = loader,
        .store_fd = this.store_fd,
        .graph = this.parent.standalone_module_graph,
    });
    vm.allocator = allocator;
    vm.arena = &this.arena.?;

    // Move the pre-cloned proxy storage into the worker VM.
    vm.proxy_env_storage = temp_proxy_storage;
    temp_proxy_storage = .{};

    vm.is_main_thread = false;
    jsc.VirtualMachine.is_main_thread_vm = false;
    WorkerErrorEngine.install(vm);

    // Publish before fallible configuration so termination can wake the VM
    // and threadMain can run exit handlers under its API lock on every path.
    {
        const io = this.parent.pinned_threads.io();
        this.vm_lock.lockUncancelable(io);
        defer this.vm_lock.unlock(io);
        this.vm = vm;
    }

    var b = &vm.transpiler;
    b.resolver.env_loader = b.env;

    if (this.parent.standalone_module_graph) |graph| {
        bun.bun_js.applyStandaloneRuntimeFlags(b, graph);
    }

    // Second checkpoint: initWorker just spent the bulk of startup time;
    // if terminate arrived during it, skip configureDefines() (which
    // walks the resolver's global dir_cache) and entry-point loading.
    // spin() observes the flag before loading the entry point.
    if (this.hasRequestedTerminate()) return;

    b.configureDefines() catch {
        // flushLogs runs under the API lock in spin().
        vm.exit_handler.exit_code = 1;
        _ = this.setRequestedTerminate();
        return;
    };

    vm.loadExtraEnvAndSourceCodePrinter();
}

fn recordResolveError(vm: *jsc.VirtualMachine, message: bun.String) bun.OOM!void {
    const utf8 = try message.toUTF8(bun.default_allocator);
    defer utf8.deinit();
    try vm.log.addError(null, .Empty, utf8.slice());
}

/// Phase 2: load the entry point, dispatch 'online', run the event loop.
/// Runs while the JSC API lock is held.
fn spin(this: *WebWorker) void {
    log("[{d}] spin start", .{this.execution_context_id});

    var vm = this.vm.?;
    assert(this.status == .start);
    this.setStatus(.starting);

    // Terminated during startVM() (or startVM() short-circuited here on
    // configureDefines failure) — shut down under the API lock so the
    // JSC::VM built by initWorker is torn down rather than leaked.
    if (this.hasRequestedTerminate()) {
        this.flushLogs(vm);
        return;
    }

    vm.preload = this.preloads;

    // The resolved path borrows the worker's resolver or standalone graph.
    var resolve_error = bun.String.empty;
    defer resolve_error.deref();
    const path = (resolveEntryPointSpecifier(vm, this.unresolved_specifier, &resolve_error, vm.log) catch |err| {
        if (!this.exit_called) vm.exit_handler.exit_code = 1;
        WorkerErrorEngine.reportFailure(vm.global, err);
        return;
    }) orelse {
        vm.exit_handler.exit_code = 1;
        if (vm.log.errors == 0 and !resolve_error.isEmpty()) {
            recordResolveError(vm, resolve_error) catch |err| {
                WorkerErrorEngine.reportFailure(vm.global, err);
                return;
            };
        }
        this.flushLogs(vm);
        return;
    };
    // Terminated while resolving — exit code 0, no error.
    if (this.hasRequestedTerminate()) {
        this.flushLogs(vm);
        return;
    }

    var promise = vm.loadEntryPointForWebWorker(path) catch |err| {
        if (err == error.WorkerTerminated or this.hasRequestedTerminate()) {
            if (!this.exit_called) vm.exit_handler.exit_code = 1;
            this.flushLogs(vm);
            return;
        }
        if (err == error.JSError or err == error.OutOfMemory) WorkerErrorEngine.reportFailure(vm.global, @errorCast(err));
        // process.exit() may have run during load; don't clobber its code.
        if (!this.exit_called) vm.exit_handler.exit_code = 1;
        this.flushLogs(vm);
        return;
    };
    defer promise.deinit();
    if (this.hasRequestedTerminate()) return;

    if (vm.entryPointPromiseStatus(&promise) == .rejected) {
        const handled = vm.reportEntryPointRejection(&promise) catch |err| {
            if (!this.exit_called) vm.exit_handler.exit_code = 1;
            WorkerErrorEngine.reportFailure(vm.global, err);
            return;
        };

        if (!handled) {
            vm.exit_handler.exit_code = 1;
            return;
        }
    }

    this.flushLogs(vm);
    if (this.hasRequestedTerminate()) return;
    log("[{d}] event loop start", .{this.execution_context_id});
    // dispatchOnline fires the parent-side 'open' event and flips the C++
    // state to Running (which routes postMessage directly instead of
    // queuing). It is placed after the entry point has loaded so the parent
    // observes 'online' only once the worker's top-level code has completed;
    // moving it earlier would change that observable ordering.
    bun.bindgen.Engine(WebWorkerDispatchOnlineShim).call(vm.global, .{ .worker = @ptrCast(this.cpp_worker) }) catch |err| {
        if (err != error.JSTerminated) {
            vm.global.reportActiveExceptionAsUnhandled(err);
            if (!this.exit_called and !this.hasRequestedTerminate()) vm.exit_handler.exit_code = 1;
        }
        return;
    };
    bun.bindgen.Engine(WebWorkerFireEarlyMessagesShim).call(vm.global, .{ .worker = @ptrCast(this.cpp_worker) });
    this.setStatus(.running);

    // don't run the GC if we don't actually need to
    if (vm.isEventLoopAlive() or
        vm.eventLoop().tickConcurrentWithCount() > 0)
    {
        vm.global.vm().releaseWeakRefs();
        _ = vm.arena.gc();
        _ = vm.global.vm().runGC(false);
    }

    // Always do a first tick so we call CppTask without delay after
    // dispatchOnline.
    vm.tick();

    while (!this.hasRequestedTerminate() and vm.isEventLoopAlive()) {
        vm.tick();
        if (this.hasRequestedTerminate()) break;
        vm.eventLoop().autoTickActive();
        if (this.hasRequestedTerminate()) break;
    }

    log("[{d}] before exit {s}", .{ this.execution_context_id, if (this.hasRequestedTerminate()) "(terminated)" else "(event loop dead)" });

    // Only emit 'beforeExit' on a natural drain, not on terminate().
    if (!this.hasRequestedTerminate()) {
        // TODO: is this able to allow the event loop to continue?
        vm.onBeforeExit();
    }

    this.flushLogs(vm);
}

fn prepareShutdown(this: *WebWorker) void {
    const vm = this.vm.?;
    {
        const io = this.parent.pinned_threads.io();
        this.vm_lock.lockUncancelable(io);
        defer this.vm_lock.unlock(io);
        this.vm = null;
    }
    this.setStatus(.terminated);
    vm.jsc_vm.clearHasTerminationRequest();
    vm.is_shutting_down = true;
    bun.assert(vm.stopChildThreads(null) == .completed);
    vm.onExit();
    vm.prepareForJSCDestruction();
}

/// Generated call frames and their API-lock owner have returned before teardown.
/// Posting the close event releases the parent-held worker reference, so only
/// local snapshots may be used after dispatchExit.
fn shutdown(this: *WebWorker, vm_to_deinit: ?*jsc.VirtualMachine) void {
    this.setStatus(.terminated);
    bun.analytics.Features.workers_terminated += 1;
    log("[{d}] shutdown", .{this.execution_context_id});

    // Snapshot everything needed after the parent can free this worker.
    const cpp_worker = this.cpp_worker;
    var arena = this.arena;
    this.arena = null;

    const loop = if (vm_to_deinit) |vm| vm.uwsLoop() else null;
    const exit_code: i32 = if (vm_to_deinit) |vm| vm.exit_handler.exit_code else 0;

    if (vm_to_deinit) |vm| {
        bun.bindgen.Engine(TeardownThreadJSCVMShim).call(.{ .globalObject = @ptrCast(vm.global) });
    }

    this.exit_code = exit_code;
    this.completed.set(this.parent.pinned_threads.io());
    bun.bindgen.Engine(WebWorkerDispatchExitShim).call(.{
        .worker = @ptrCast(cpp_worker),
        .exitCode = exit_code,
    });
    // `this` may be freed past this point.

    if (loop) |loop_| {
        jsc.setLoopVM(loop_, null);
    }
    if (vm_to_deinit) |vm| {
        // Must precede Loop.shutdown so uv_close isn't called twice on the
        // GC timer.
        vm.gc_controller.deinit();
    }
    if (comptime Environment.isWindows) {
        bun.windows.libuv.Loop.shutdown();
    }
    if (vm_to_deinit) |vm| {
        vm.deinit();
    }
    jsc.wtf.prepareForThreadExit();
    bun.deleteAllPoolsForThreadExit();
    if (arena) |*arena_| {
        arena_.deinit();
    }
}

/// process.exit() inside the worker. Worker-thread only.
pub fn exit(this: *WebWorker) void {
    this.exit_called = true;
    _ = this.setRequestedTerminate();
    // Stop subsequent JS at the next safepoint. `this.vm` is null during
    // `vm.onExit()` (prepareShutdown nulls it first), so a re-entrant process.exit()
    // from an exit handler does not re-arm the trap.
    if (this.vm) |vm| {
        vm.jsc_vm.notifyNeedTermination();
    }
}

// =============================================================================
// Helpers (worker thread)
// =============================================================================

fn setStatus(this: *WebWorker, status: Status) void {
    log("[{d}] status: {s}", .{ this.execution_context_id, @tagName(status) });
    this.status = status;
}

fn flushLogs(this: *WebWorker, vm: *jsc.VirtualMachine) void {
    WorkerErrorEngine.flushLogs(vm, @ptrCast(this.cpp_worker)) catch |err|
        WorkerErrorEngine.reportFailure(vm.global, err);
}

/// Resolve a worker entry-point specifier to a path the module loader can
/// consume. The returned slice is BORROWED — it aliases `str`, the standalone
/// module graph, or the resolver's arena; the caller must NOT free it.
fn resolveEntryPointSpecifier(
    parent: *jsc.VirtualMachine,
    str: []const u8,
    error_message: *bun.String,
    logger: *bun.logger.Log,
) bun.JSError!?[]const u8 {
    if (parent.standalone_module_graph) |graph| {
        if (graph.find(str) != null) {
            return str;
        }

        // Since `bun build --compile` renames files to `.js` by
        // default, we need to do the reverse of our file extension
        // mapping.
        //
        //   new Worker("./foo") -> new Worker("./foo.js")
        //   new Worker("./foo.ts") -> new Worker("./foo.js")
        //   new Worker("./foo.jsx") -> new Worker("./foo.js")
        //   new Worker("./foo.mjs") -> new Worker("./foo.js")
        //   new Worker("./foo.mts") -> new Worker("./foo.js")
        //   new Worker("./foo.cjs") -> new Worker("./foo.js")
        //   new Worker("./foo.cts") -> new Worker("./foo.js")
        //   new Worker("./foo.tsx") -> new Worker("./foo.js")
        //
        if (bun.strings.hasPrefixComptime(str, "./") or bun.strings.hasPrefixComptime(str, "../")) try_from_extension: {
            var pathbuf: bun.PathBuffer = undefined;
            var base = str;

            base = bun.path.joinAbsStringBuf(bun.StandaloneModuleGraph.base_public_path_with_default_suffix, &pathbuf, &.{str}, .auto);
            const extname = std.fs.path.extension(base);

            // ./foo -> ./foo.js
            if (extname.len == 0) {
                pathbuf[base.len..][0..3].* = ".js".*;
                if (graph.find(pathbuf[0 .. base.len + 3])) |js_file| {
                    return js_file.name;
                }

                break :try_from_extension;
            }

            // ./foo.ts -> ./foo.js
            if (bun.strings.eqlComptime(extname, ".ts")) {
                pathbuf[base.len - 3 .. base.len][0..3].* = ".js".*;
                if (graph.find(pathbuf[0..base.len])) |js_file| {
                    return js_file.name;
                }

                break :try_from_extension;
            }

            if (extname.len == 4) {
                inline for (.{ ".tsx", ".jsx", ".mjs", ".mts", ".cts", ".cjs" }) |ext| {
                    if (bun.strings.eqlComptime(extname, ext)) {
                        pathbuf[base.len - ext.len ..][0..".js".len].* = ".js".*;
                        const as_js = pathbuf[0 .. base.len - ext.len + ".js".len];
                        if (graph.find(as_js)) |js_file| {
                            return js_file.name;
                        }
                        break :try_from_extension;
                    }
                }
            }
        }
    }

    if (bun.webcore.ObjectURLRegistry.isBlobURL(str)) {
        if (bun.webcore.ObjectURLRegistry.singleton().has(parent.io, str["blob:".len..])) {
            return str;
        } else {
            error_message.* = bun.String.static("Blob URL is missing");
            return null;
        }
    }

    var resolved_entry_point: bun.resolver.Result = parent.transpiler.resolveEntryPoint(str) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        error_message.* = try WorkerErrorEngine.describeLog(parent.global, logger, "Error resolving Worker entry point");
        return null;
    };

    const entry_path: *bun.fs.Path = resolved_entry_point.path() orelse {
        error_message.* = bun.String.static("Worker entry point is missing");
        return null;
    };
    return entry_path.text;
}

comptime {
    _ = WorkerClassBinding;
    _ = WebWorkerCreateBinding;
    _ = WebWorkerCommitStartupBinding;
    _ = WebWorkerGetParentBinding;
    _ = WebWorkerNotifyNeedTerminationBinding;
    _ = WebWorkerSetRefBinding;
    _ = WebWorkerReleaseParentPollRefBinding;
    _ = WebWorkerDestroyBinding;
    _ = WebWorkerHeapSnapshotTaskResolveBinding;
    _ = WebWorkerHeapSnapshotTaskRejectNotRunningBinding;
}

const std = @import("std");

const bun = @import("bun");
const Async = bun.Async;
const Environment = bun.Environment;
const Output = bun.Output;
const assert = bun.assert;
pub const WorkerErrorEngine = @import("./WorkerErrorEngine.zig");

const jsc = bun.jsc;
const JSCThreadTeardownBindings = bun.bindgen.Module("jsc_thread_teardown");
const WebCoreWorkerBindings = bun.bindgen.Module("WebCoreWorker");
const WebWorkerEngineBindings = bun.bindgen.Module("WebWorkerEngine");
const WorkerClassSchema = WebCoreWorkerBindings.class("Worker");
const WorkerGetHeapSnapshotSchema = WorkerClassSchema.memberKind("getHeapSnapshot", .method);
const WorkerClassBinding = bun.bindgen.EngineClassBackend(WorkerClassSchema, WorkerBinding);
const TeardownThreadJSCVMShim = JSCThreadTeardownBindings.engineShim("teardownThreadJSCVM");
const WebWorkerDispatchExitShim = WebWorkerEngineBindings.engineShim("webWorkerDispatchExit");
const WebWorkerFinishExitShim = WebWorkerEngineBindings.engineShim("webWorkerFinishExit");
const WebWorkerDispatchOnlineShim = WebWorkerEngineBindings.engineShim("webWorkerDispatchOnline");
const WebWorkerFireEarlyMessagesShim = WebWorkerEngineBindings.engineShim("webWorkerFireEarlyMessages");
const WebWorkerGetParentSchema = WebWorkerEngineBindings.nativeExport("webWorkerGetParent");
const WebWorkerGetParentBinding = bun.bindgen.Fn(WebWorkerGetParentSchema, bindWebWorkerGetParent);
const WebWorkerCreateSchema = WebWorkerEngineBindings.nativeExport("webWorkerCreate");
const WebWorkerCreateBinding = bun.bindgen.Fn(WebWorkerCreateSchema, bindWebWorkerCreate);
const WebWorkerCommitStartupSchema = WebWorkerEngineBindings.nativeExport("webWorkerCommitStartup");
const WebWorkerCommitStartupBinding = bun.bindgen.Fn(WebWorkerCommitStartupSchema, bindWebWorkerCommitStartup);
const WebWorkerNotifyNeedTerminationSchema = WebWorkerEngineBindings.nativeExport("webWorkerNotifyNeedTermination");
const WebWorkerSetRefSchema = WebWorkerEngineBindings.nativeExport("webWorkerSetRef");
const WebWorkerReleaseParentPollRefSchema = WebWorkerEngineBindings.nativeExport("webWorkerReleaseParentPollRef");
const WebWorkerDestroySchema = WebWorkerEngineBindings.nativeExport("webWorkerDestroy");
const WebWorkerHeapSnapshotTaskResolveSchema = WebWorkerEngineBindings.nativeExport("webWorkerHeapSnapshotTaskResolve");
const WebWorkerHeapSnapshotTaskRejectNotRunningSchema = WebWorkerEngineBindings.nativeExport("webWorkerHeapSnapshotTaskRejectNotRunning");
const WebWorkerNotifyNeedTerminationBinding = bun.bindgen.Fn(WebWorkerNotifyNeedTerminationSchema, bindWebWorkerNotifyNeedTermination);
const WebWorkerSetRefBinding = bun.bindgen.Fn(WebWorkerSetRefSchema, bindWebWorkerSetRef);
const WebWorkerReleaseParentPollRefBinding = bun.bindgen.Fn(WebWorkerReleaseParentPollRefSchema, bindWebWorkerReleaseParentPollRef);
const WebWorkerDestroyBinding = bun.bindgen.Fn(WebWorkerDestroySchema, bindWebWorkerDestroy);
const WebWorkerHeapSnapshotTaskResolveBinding = bun.bindgen.Fn(WebWorkerHeapSnapshotTaskResolveSchema, bindWebWorkerHeapSnapshotTaskResolve);
const WebWorkerHeapSnapshotTaskRejectNotRunningBinding = bun.bindgen.Fn(WebWorkerHeapSnapshotTaskRejectNotRunningSchema, bindWebWorkerHeapSnapshotTaskRejectNotRunning);
