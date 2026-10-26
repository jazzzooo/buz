const log = Output.scoped(.@"fs.watch", .hidden);
const PathWatcher = if (Environment.isWindows) @import("./win_watcher.zig") else @import("./path_watcher.zig");

pub const FSWatcher = struct {
    pub const JSBinding = struct {
        bindgen_state: bindgen.ClassState = .{},
        watcher: bindgen.OwnedNative(FSWatcher, .vm),

        pub fn construct(
            context: bindgen.CallContext(FSWatcherConstructorSchema),
            method_args: bindgen.Args(FSWatcherConstructorSchema),
        ) bindgen.CallError(FSWatcherConstructorSchema)!*JSBinding {
            const args = try argumentsFromBindgen(method_args);
            defer args.deinit();
            const result = try FSWatcher.init(args, context.viewToken().globalObject());
            return switch (result) {
                .err => |err| context.fail(.system, try bindgen.SystemError.fromSysError(err)),
                .result => |binding| binding,
            };
        }

        pub const destroy = @This().deinit;

        fn deinit(this: *JSBinding) void {
            this.watcher.deinit();
            bun.destroy(this);
        }

        pub fn hasPendingActivity(this: *const JSBinding) bool {
            return this.watcher.get().hasPendingActivity();
        }

        pub fn doClose(
            this: *JSBinding,
            _: bindgen.CallContext(FSWatcherCloseSchema),
            _: bindgen.Args(FSWatcherCloseSchema),
        ) bun.JSError!void {
            this.watcher.get().close();
        }

        pub fn doRef(
            this: *JSBinding,
            _: bindgen.CallContext(FSWatcherRefSchema),
            _: bindgen.Args(FSWatcherRefSchema),
        ) bun.JSError!void {
            this.watcher.get().refFromJS();
        }

        pub fn doUnref(
            this: *JSBinding,
            _: bindgen.CallContext(FSWatcherUnrefSchema),
            _: bindgen.Args(FSWatcherUnrefSchema),
        ) bun.JSError!void {
            this.watcher.get().unrefFromJS();
        }

        pub fn hasRef(
            this: *JSBinding,
            _: bindgen.CallContext(FSWatcherHasRefSchema),
            _: bindgen.Args(FSWatcherHasRefSchema),
        ) bun.JSError!bool {
            return this.watcher.get().persistent;
        }
    };

    ctx: *VirtualMachine,
    verbose: bool = false,

    mutex: std.Io.Mutex,
    signal: ?*webcore.AbortSignal,
    abort_listener: webcore.AbortSignal.Listener = undefined,
    abort_listener_registered: bool = false,
    persistent: bool,
    path_watcher: ?*PathWatcher.PathWatcher,
    poll_ref: Async.KeepAlive = .{},
    globalThis: *jsc.JSGlobalObject,
    encoding: NodeEncoding,
    listener: FSWatcherListener,

    /// User can call close and pre-detach so we need to track this
    closed: bool,

    /// While it's not closed, the pending activity
    pending_activity_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    current_task: FSWatchTask = undefined,
    ref_count: RefCount = .init(),

    const RefCount = bun.ptr.ThreadSafeRefCount(FSWatcher, "ref_count", deinit, .{});
    const ref = RefCount.ref;
    const deref = RefCount.deref;

    pub fn eventLoop(this: FSWatcher) *EventLoop {
        return this.ctx.eventLoop();
    }

    pub fn enqueueTaskConcurrent(this: FSWatcher, task: *jsc.ConcurrentTask) void {
        this.eventLoop().enqueueTaskConcurrent(task);
    }

    fn callbackContext(this: *FSWatcher) *WatcherCore.CallbackContext {
        return @ptrCast(this);
    }

    fn fromCallbackContext(context: *WatcherCore.CallbackContext) *FSWatcher {
        return @ptrCast(@alignCast(context));
    }

    pub fn destroy(this: *FSWatcher) void {
        this.closeWithoutEmit();
        this.deref();
    }

    fn deinit(this: *FSWatcher) void {
        this.current_task.cleanEntries();
        this.listener.deinit();
        bun.destroy(this);
    }

    pub const FSWatchTask = struct {
        pub const new = bun.TrivialNew(@This());

        ctx: *FSWatcher,
        count: u8 = 0,
        entries: [8]TaskEvent = undefined,
        concurrent_task: jsc.ConcurrentTask = .{},

        pub fn deinit(this: *FSWatchTask) void {
            const ctx = this.ctx;
            this.cleanEntries();
            if (comptime Environment.allow_assert) {
                bun.assert(&this.ctx.current_task != this);
            }
            bun.destroy(this);
            ctx.unrefTask();
            ctx.deref();
        }

        pub fn append(this: *FSWatchTask, event: TaskEvent) void {
            if (this.count == 8) {
                this.enqueue();
                const ctx = this.ctx;
                this.* = .{
                    .ctx = ctx,
                    .count = 0,
                };
            }

            this.entries[this.count] = event;
            this.count += 1;
        }

        pub fn run(this: *FSWatchTask) void {
            for (this.entries[0..this.count]) |event| {
                if (this.ctx.closed) break;
                switch (event) {
                    .watch => |watch_event| switch (watch_event) {
                        inline .rename, .change => |file_path, tag| {
                            this.ctx.emit(file_path, @field(EventType, @tagName(tag)));
                        },
                        .@"error" => |err| {
                            this.ctx.emitError(err);
                        },
                    },
                    .abort => {
                        this.ctx.emitIfAborted();
                    },
                }
            }
        }

        pub fn appendAbort(this: *FSWatchTask) void {
            this.append(.abort);
            this.enqueue();
        }

        pub fn enqueue(this: *FSWatchTask) void {
            if (this.count == 0)
                return;

            if (this.ctx.refTask()) {
                var that = FSWatchTask.new(this.*);
                this.count = 0;
                this.ctx.enqueueTaskConcurrent(that.concurrent_task.from(that, .manual_deinit));
                return;
            }
            this.cleanEntries();
        }

        pub fn cleanEntries(this: *FSWatchTask) void {
            for (this.entries[0..this.count]) |*entry| entry.deinit();
            this.count = 0;
        }
    };

    const TaskEvent = union(enum) {
        watch: WatcherCore.OwnedEvent,
        abort: void,

        fn deinit(this: *TaskEvent) void {
            switch (this.*) {
                .watch => |*event| event.deinit(),
                .abort => {},
            }
            this.* = .abort;
        }
    };

    pub const EventType = FSWatcherTypes.ListenerEvent;

    pub fn onPathUpdate(context: *WatcherCore.CallbackContext, event: WatcherCore.Event, is_file: bool) void {
        const this = fromCallbackContext(context);

        if (this.verbose) {
            switch (event) {
                .rename, .change => |value| {
                    if (is_file) {
                        Output.prettyErrorln("<r> <d>File changed: {s}<r>", .{value});
                    } else {
                        Output.prettyErrorln("<r> <d>Dir changed: {s}<r>", .{value});
                    }
                },
                else => {},
            }
        }

        this.current_task.append(.{ .watch = bun.handleOom(event.toOwned()) });
    }

    pub fn onUpdateEnd(context: *WatcherCore.CallbackContext) void {
        const this = fromCallbackContext(context);
        if (this.verbose) {
            Output.flush();
        }
        this.current_task.enqueue();
    }

    pub const Arguments = FSWatcherTypes.Arguments;

    fn activate(this: *FSWatcher) bun.JSError!void {
        if (this.persistent) {
            this.poll_ref.ref(this.ctx);
        }

        if (this.signal) |s| {
            if (s.aborted()) {
                this.current_task = .{
                    .ctx = this,
                };
                this.current_task.appendAbort();
            } else {
                const signal = try s.listen(this.globalThis, &this.abort_listener, this, FSWatcher.abortListener);
                if (this.signal != null) {
                    bun.debugAssert(signal == s);
                    this.signal = signal;
                    this.abort_listener_registered = true;
                }
            }
        }
    }

    pub fn emitIfAborted(this: *FSWatcher) void {
        if (this.signal) |s| {
            if (s.aborted()) this.emitAbort(null);
        }
    }

    pub fn abortListener(this: *FSWatcher, reason: bindgen.EngineValueView) void {
        this.emitAbort(reason);
    }

    fn emitAbort(this: *FSWatcher, reason: ?bindgen.EngineValueView) void {
        if (this.closed) return;
        _ = this.pending_activity_count.fetchAdd(1, .monotonic);
        defer this.close();
        defer this.unrefTask();
        var engine_reason = (if (reason) |value| value.toRoot() else this.signal.?.abortReasonRoot(this.globalThis)) catch |err|
            return this.globalThis.reportActiveExceptionAsUnhandled(err);
        defer engine_reason.deinit();
        var rooted_reason = engine_reason.takeAnyRoot();
        defer rooted_reason.deinit();
        this.emitOpaqueRoot(&rooted_reason, .abort);
    }

    pub fn emitError(this: *FSWatcher, err: bun.sys.Error) void {
        if (this.closed) return;
        defer this.close();

        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        var error_value = bindgen.SystemError.createSysErrorInstance(&scope, err) catch |js_err|
            return this.globalThis.reportActiveExceptionAsUnhandled(js_err);
        defer error_value.deinit();
        var rooted_error = error_value.toRoot() catch |js_err|
            return this.globalThis.reportActiveExceptionAsUnhandled(js_err);
        defer rooted_error.deinit();
        this.emitOpaqueRoot(&rooted_error, .@"error");
    }

    pub fn emit(this: *FSWatcher, file_name: string, comptime event_type: EventType) void {
        bun.assert(event_type != .@"error");
        if (file_name.len == 0) {
            this.emitValue(.{ .undefined_value = false }, event_type);
            return;
        }

        if (this.encoding == .buffer) {
            var filename = bindgen.OwnedBytes.fromSlice(file_name) catch return this.reportOutOfMemory();
            defer filename.deinit();
            this.emitValue(.{ .buffer = filename.operand() }, event_type);
            return;
        }

        var filename = bindgen.DOMString.fromBunString(Encoder.toBunString(file_name, this.encoding)) catch return this.reportOutOfMemory();
        defer filename.deinit();
        this.emitValue(.{ .string = filename.operand() }, event_type);
    }

    fn emitOpaqueRoot(
        this: *FSWatcher,
        value: *const bindgen.Root,
        comptime event_type: EventType,
    ) void {
        var invocation: FSWatcherListener.Invocation = undefined;
        this.listener.beginInvocation(&invocation);
        defer invocation.deinit();
        emitValueInInvocation(&invocation, .{ .@"opaque" = value.operand(&invocation) }, event_type);
    }

    fn emitValue(this: *FSWatcher, value: FSWatcherListenerValue, comptime event_type: EventType) void {
        var invocation: FSWatcherListener.Invocation = undefined;
        this.listener.beginInvocation(&invocation);
        defer invocation.deinit();
        emitValueInInvocation(&invocation, value, event_type);
    }

    fn emitValueInInvocation(
        invocation: *FSWatcherListener.Invocation,
        value: FSWatcherListenerValue,
        comptime event_type: EventType,
    ) void {
        invocation.call(.{
            .eventType = event_type,
            .value = value,
        }) catch |err| invocation.reportActiveException(err);
    }

    fn reportOutOfMemory(this: *FSWatcher) void {
        this.globalThis.reportActiveExceptionAsUnhandled(this.globalThis.throwOutOfMemory());
    }

    fn refFromJS(this: *FSWatcher) void {
        if (!this.closed and !this.persistent) {
            this.persistent = true;
            this.poll_ref.ref(this.ctx);
        }
    }

    fn unrefFromJS(this: *FSWatcher) void {
        if (this.persistent) {
            this.persistent = false;
            this.poll_ref.unref(this.ctx);
        }
    }

    // this can be called from Watcher Thread or JS Context Thread
    pub fn refTask(this: *FSWatcher) bool {
        this.mutex.lockUncancelable(this.ctx.io);
        defer this.mutex.unlock(this.ctx.io);
        if (this.closed) return false;
        this.ref();
        _ = this.pending_activity_count.fetchAdd(1, .monotonic);

        return true;
    }

    pub fn hasPendingActivity(this: *const FSWatcher) bool {
        return this.pending_activity_count.load(.acquire) > 0;
    }

    pub fn unrefTask(this: *FSWatcher) void {
        this.mutex.lockUncancelable(this.ctx.io);
        defer this.mutex.unlock(this.ctx.io);
        // JSC eventually will free it
        const prev = this.pending_activity_count.fetchSub(1, .monotonic);
        bun.debugAssert(prev > 0);
    }

    pub fn close(this: *FSWatcher) void {
        this.mutex.lockUncancelable(this.ctx.io);
        if (!this.closed) {
            this.closed = true;
            this.mutex.unlock(this.ctx.io);
            this.detach();

            // `closed` is already true so `refTask()` would return false without
            // incrementing; bump the counter directly so the `unrefTask()` below is
            // balanced and the count stays > 0 while the close event is emitted.
            _ = this.pending_activity_count.fetchAdd(1, .monotonic);
            log("emit('close')", .{});
            this.emitValue(.{ .undefined_value = false }, .close);
            this.listener.deinit();
            this.unrefTask();

            this.unrefTask();
        } else {
            this.mutex.unlock(this.ctx.io);
        }
    }

    pub fn closeWithoutEmit(this: *FSWatcher) void {
        this.mutex.lockUncancelable(this.ctx.io);
        if (!this.closed) {
            this.closed = true;
            this.mutex.unlock(this.ctx.io);
            this.detach();
            this.listener.deinit();
            this.unrefTask();
        } else {
            this.mutex.unlock(this.ctx.io);
        }
    }

    // this can be called multiple times
    pub fn detach(this: *FSWatcher) void {
        if (this.ctx.rare_data) |rare| rare.removeFSWatcherForIsolation(this);

        if (this.path_watcher) |path_watcher| {
            this.path_watcher = null;
            path_watcher.detach(this.callbackContext());
        }

        if (this.persistent) {
            this.persistent = false;
            this.poll_ref.unref(this.ctx);
        }

        if (this.signal) |signal| {
            this.signal = null;
            if (this.abort_listener_registered) {
                this.abort_listener_registered = false;
                signal.detach(&this.abort_listener);
            } else {
                signal.unref();
            }
        }
    }

    pub fn init(args: Arguments, global_this: *jsc.JSGlobalObject) bun.JSError!bun.sys.Maybe(*JSBinding) {
        const joined_buf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(joined_buf);
        const file_path: [:0]const u8 = brk: {
            var slice = args.path.slice();
            if (bun.strings.startsWith(slice, "file://")) {
                slice = slice["file://".len..];
            }

            const cwd = bun.fs.FileSystem.instance.top_level_dir;

            break :brk Path.joinAbsStringBufZ(
                cwd,
                joined_buf,
                &.{slice},
                .auto,
            );
        };

        const vm = global_this.bunVM();

        const ctx = try bun.default_allocator.create(FSWatcher);
        ctx.* = .{
            .ctx = vm,
            .current_task = .{
                .ctx = undefined,
                .count = 0,
            },
            .mutex = .init,
            .signal = if (args.signal) |s| s.ref() else null,
            .persistent = args.persistent,
            .path_watcher = null,
            .globalThis = global_this,
            .encoding = args.encoding,
            .listener = args.listener.clone(),
            .closed = false,
            .verbose = args.verbose,
        };
        ctx.current_task.ctx = ctx;
        var owns_ctx = true;
        defer if (owns_ctx) ctx.destroy();
        const binding = try bun.default_allocator.create(JSBinding);
        var owns_binding = true;
        defer if (owns_binding) bun.destroy(binding);
        binding.* = .{ .watcher = .init(ctx) };
        if (vm.test_isolation_enabled) {
            const rare = try vm.tryRareData();
            try rare.addFSWatcherForIsolation(ctx);
        }

        const watcher_runtime: PathWatcher.Runtime = if (comptime Environment.isWindows)
            .{ .loop = vm.uvLoop() }
        else
            .{ .io = vm.io };
        ctx.path_watcher = if (args.signal == null or !args.signal.?.aborted())
            switch (PathWatcher.watch(watcher_runtime, file_path, args.recursive, onPathUpdate, onUpdateEnd, ctx.callbackContext())) {
                .result => |r| r,
                .err => |err| {
                    ctx.closeWithoutEmit();
                    return .{ .err = .{
                        .errno = err.errno,
                        .syscall = .watch,
                        .path = args.path.slice(),
                    } };
                },
            }
        else
            null;
        ctx.activate() catch |err| {
            ctx.closeWithoutEmit();
            return err;
        };
        owns_binding = false;
        owns_ctx = false;
        return .{ .result = binding };
    }
};

const string = []const u8;

const Path = @import("../../paths/resolve_path.zig");
const std = @import("std");

const bun = @import("bun");
const Async = bun.Async;
const Environment = bun.Environment;
const Output = bun.Output;
const webcore = bun.webcore;

const jsc = bun.jsc;
const bindgen = bun.bindgen;
const EventLoop = jsc.EventLoop;
const VirtualMachine = jsc.VirtualMachine;
const Encoder = @import("../webcore/encoding.zig");
const NodeEncoding = FSWatcherTypes.NodeEncoding;
const FSWatcherBindingModule = bindgen.Module("FSWatcher");
const FSWatcherSchema = FSWatcherBindingModule.class("FSWatcher");
const FSWatcherClass = bindgen.Class(FSWatcherSchema, FSWatcher.JSBinding);
const FSWatcherConstructorSchema = FSWatcherSchema.constructor();
const FSWatcherCloseSchema = FSWatcherSchema.member("close");
const FSWatcherHasRefSchema = FSWatcherSchema.member("hasRef");
const FSWatcherRefSchema = FSWatcherSchema.member("ref");
const FSWatcherUnrefSchema = FSWatcherSchema.member("unref");
const FSWatcherListener = FSWatcherTypes.Listener;
const FSWatcherListenerValue = FSWatcherTypes.ListenerValue;
const FSWatcherTypes = @import("./FSWatcherTypes.zig");
const PathLike = @import("./PathLike.zig").PathLike;
const WatcherCore = @import("./fs_watcher.zig");

fn argumentsFromBindgen(args: anytype) bun.JSError!FSWatcherTypes.Arguments {
    const path = try PathLike.fromBindingView(args.path);
    errdefer path.deinit();
    return .{
        .path = path,
        .listener = try args.listener.toOwned(),
        .signal = if (args.options.signal) |signal| signal.get() else null,
        .persistent = args.options.persistent,
        .recursive = args.options.recursive,
        .encoding = if (args.options.encoding) |encoding| switch (encoding) {
            .utf8 => .utf8,
            .utf16le => .utf16le,
            .latin1 => .latin1,
            .ascii => .ascii,
            .base64 => .base64,
            .base64url => .base64url,
            .hex => .hex,
            .buffer => .buffer,
        } else .utf8,
        .verbose = args.options.verbose,
    };
}

comptime {
    _ = FSWatcherClass;
}
