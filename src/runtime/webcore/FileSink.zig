const FileSink = @This();

ref_count: RefCount,
writer: IOWriter = .{},
event_loop_handle: jsc.EventLoopHandle,
written: usize = 0,
pending_start: ?usize = null,
pending: streams.Result.Writable.Pending = .{
    .result = .{ .done = {} },
},
signal: streams.Signal = .{},
done: bool = false,
started: bool = false,
must_be_kept_alive_until_eof: bool = false,

auto_flusher: webcore.AutoFlusher = .{},
run_pending_later: CancellableTask = .{},

/// Currently, only used when `stdin` in `Bun.spawn` is a ReadableStream.
readable_stream: jsc.WebCore.ReadableStream.Strong = .{},
process_lifecycle: ?bun.bindgen.RefNative(bun.api.Subprocess, .vm) = null,

const log = Output.scoped(.FileSink, .visible);

pub const RefCount = bun.ptr.RefCount(FileSink, "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

pub fn releasePromiseReactionRef(this: *FileSink) void {
    this.deref();
}

pub fn attachProcessLifecycle(this: *FileSink, owner: bun.bindgen.RefNative(bun.api.Subprocess, .vm)) void {
    bun.assert(this.process_lifecycle == null);
    this.process_lifecycle = owner;
}

pub fn takeProcessLifecycle(this: *FileSink) ?bun.bindgen.RefNative(bun.api.Subprocess, .vm) {
    const owner = this.process_lifecycle;
    this.process_lifecycle = null;
    return owner;
}

/// Count of live native FileSink instances. Incremented at allocation,
/// decremented in `deinit`. Exposed to tests via `bun:internal-for-testing`
/// so leak tests can detect native FileSink leaks that are invisible to
/// `heapStats()` (which only counts JS wrapper objects).
pub var live_count = std.atomic.Value(i32).init(0);

pub const TestingAPIs = struct {
    pub fn fileSinkLiveCount(
        _: bun.bindgen.CallContext(FileSinkLiveCountSchema),
        _: bun.bindgen.Args(FileSinkLiveCountSchema),
    ) bun.JSError!i32 {
        return live_count.load(.monotonic);
    }
};

pub const IOWriter = bun.io.StreamingWriter(@This(), opaque {
    pub const onClose = FileSink.onClose;
    pub const onWritable = FileSink.onReady;
    pub const onError = FileSink.onError;
    pub const onWriteError = FileSink.onWriteError;
    pub const onWrite = FileSink.onWrite;
});
pub const Poll = IOWriter;

pub const Options = struct {
    chunk_size: Blob.SizeType = 1024,
    input_path: webcore.PathOrFileDescriptor,
    truncate: bool = true,
    close: bool = false,
    mode: bun.Mode = 0o664,

    pub fn flags(this: *const Options) i32 {
        _ = this;

        return bun.O.NONBLOCK | bun.O.CLOEXEC | bun.O.CREAT | bun.O.WRONLY;
    }
};

pub fn memoryCost(this: *const FileSink) usize {
    // Since this is a JSSink, the NewJSSink function does @sizeOf(JSSink) which includes @sizeOf(FileSink).
    return this.writer.memoryCost();
}

fn bindForceSynchronous(
    _: bun.bindgen.CallContext(ForceSynchronousSchema),
    args: bun.bindgen.Args(ForceSynchronousSchema),
) bun.JSError!bun.bindgen.Return(ForceSynchronousSchema) {
    const adapter = (args.value orelse return).get(JSSink.Main);
    const this = JSSink.nativeFromMain(adapter) orelse return;
    this.writer.makeSynchronous();
}

comptime {
    _ = ForceSynchronousBinding;
}

pub fn onAttachedProcessExit(this: *FileSink, status: *const bun.spawn.Status) void {
    log("onAttachedProcessExit()", .{});

    // `writer.close()` below re-enters `onClose` which releases the
    // keep-alive ref, and `stream.cancel`/`runPending` drain microtasks
    // which may drop the JS wrapper's ref. Hold a local ref so `this`
    // stays valid for the rest of this function (same pattern as `onWrite`).
    this.ref();
    defer this.deref();

    this.done = true;
    var readable_stream = this.readable_stream;
    this.readable_stream = .{};
    if (readable_stream.has()) {
        if (this.event_loop_handle.globalObject()) |global| {
            if (!status.isOK()) {
                const event_loop = global.bunVM().eventLoop();
                event_loop.enter();
                defer event_loop.exit();
                readable_stream.cancel(global);
            } else {
                readable_stream.done(global);
            }
        }
        // Clean up the readable stream reference
        readable_stream.deinit();
    }

    this.writer.close();

    this.pending.result = .{ .err = .fromCode(.PIPE, .write) };
    this.runPending();

    // `writer.close()` → `onClose` already released this above; kept for
    // paths where `onClose` isn't reached (e.g. writer already closed).
    this.clearKeepAliveRef();
}

fn runPending(this: *FileSink) void {
    this.ref();
    defer this.deref();

    this.run_pending_later.cancel();
    const l = this.eventLoop();

    l.enter();
    defer l.exit();
    if (this.pending.state == .pending) this.pending_start = null;
    this.pending.run();
}

pub fn onWrite(this: *FileSink, amount: usize, status: bun.io.WriteStatus) void {
    log("onWrite({d}, {any})", .{ amount, status });

    // `runPending()` below drains microtasks and may drop the JS wrapper's
    // ref, and `writer.end()`/`writer.close()` re-enter `onClose` which
    // releases the keep-alive ref. Hold a local ref so `this` stays valid
    // for the rest of this function (same pattern as `runPending`/`onAutoFlush`).
    this.ref();
    defer this.deref();

    if (status != .buffered) this.written += amount;

    // TODO: on windows done means ended (no pending data on the buffer) on unix we can still have pending data on the buffer
    // we should unify the behaviors to simplify this
    const has_pending_data = this.writer.hasPendingData();
    // Only keep the event loop ref'd while there's a pending write in progress.
    // If there's no pending write, no need to keep the event loop ref'd.
    this.writer.updateRef(this.eventLoop(), has_pending_data);

    if (has_pending_data) {
        if (this.event_loop_handle.bunVM()) |vm| {
            if (!vm.is_inside_deferred_task_queue) {
                webcore.AutoFlusherEngine.register(@This(), this, &this.auto_flusher, vm);
            }
        }
    }

    if (status == .buffered) return;

    // if we are not done yet and has pending data we just wait so we do not runPending twice
    if (status == .pending and has_pending_data) {
        return;
    }

    if (this.pending.state == .pending) {
        const count = this.written - (this.pending_start orelse @panic("pending file write has no starting offset"));

        // when "done" is true, we will never receive more data.
        if (this.done or status == .end_of_file) {
            this.pending.result = .{ .owned_and_done = count };
        } else {
            this.pending.result = .{ .owned = count };
        }

        this.runPending();
    }

    if (this.done and status == .drained and !this.writer.hasPendingData()) {
        this.writer.end();
    } else if (this.done and status == .end_of_file and !this.writer.hasPendingData()) {
        this.writer.close();
    }

    if (status == .end_of_file) {
        this.signal.close(null);
        this.clearKeepAliveRef();
    }
    _ = FileSinkLiveCountBinding;
}

pub fn onWriteError(this: *FileSink, err: bun.sys.Error, written: usize) void {
    this.ref();
    defer this.deref();
    this.written += written;
    this.onError(err);
}

pub fn onError(this: *FileSink, err: bun.sys.Error) void {
    this.ref();
    defer this.deref();
    log("onError({f})", .{err});
    this.done = true;
    if (this.event_loop_handle.bunVM()) |vm| {
        webcore.AutoFlusherEngine.unregister(@This(), this, &this.auto_flusher, vm);
    }
    if (this.pending.state == .pending) {
        this.pending.result = if (err.getErrno() == .NOMEM) .out_of_memory else .{ .err = err };
        if (this.eventLoop().bunVM()) |vm| {
            if (vm.is_inside_deferred_task_queue) {
                this.runPendingLater();
                if (comptime Environment.isWindows) this.clearKeepAliveRef();
                return;
            }
        }

        this.runPending();
    }

    // On POSIX, the streaming writer always calls `close()` → `onClose`
    // after `onError`, so `onClose` releases the keep-alive ref. Releasing
    // it here could drop the last ref and free `this` before the writer's
    // subsequent `close()` touches its (embedded) fields.
    //
    // On Windows, the pipe error paths call `closeWithoutReporting()` which
    // skips `onClose`, so release here. This is safe because those paths
    // always hold another ref (the in-flight write's ref via `defer
    // parent.deref()` in `onWriteComplete`, or the JS caller's ref when
    // reached synchronously from `write()`) through `closeWithoutReporting`.
    if (comptime Environment.isWindows) this.clearKeepAliveRef();
}

pub fn onReady(this: *FileSink) void {
    log("onReady()", .{});

    this.signal.ready(null, null);
}

pub fn onClose(this: *FileSink) void {
    this.ref();
    defer this.deref();
    log("onClose()", .{});
    if (this.readable_stream.has()) {
        if (this.event_loop_handle.globalObject()) |global| {
            this.readable_stream.done(global);
        }
    }

    this.signal.close(null);

    // The writer is fully closed; no further callbacks will arrive. Release
    // the ref taken when a write returned `.pending`. This must be the last
    // thing we do as it may free `this`.
    this.clearKeepAliveRef();
}

/// Release the ref taken while a pending write keeps the sink alive until EOF.
/// Idempotent via the flag check. May free `this`.
fn clearKeepAliveRef(this: *FileSink) void {
    if (this.must_be_kept_alive_until_eof) {
        this.must_be_kept_alive_until_eof = false;
        this.deref();
    }
}

pub fn createWithPipe(
    event_loop_: anytype,
    pipe: *uv.Pipe,
) bun.OOM!*FileSink {
    if (Environment.isPosix) {
        @compileError("FileSink.createWithPipe is only available on Windows");
    }

    const this = try create(event_loop_);
    this.writer.setPipe(pipe);
    return this;
}

pub fn create(
    event_loop_: anytype,
) bun.OOM!*FileSink {
    const evtloop = switch (@TypeOf(event_loop_)) {
        jsc.EventLoopHandle => event_loop_,
        else => jsc.EventLoopHandle.init(event_loop_),
    };
    const this = try bun.default_allocator.create(FileSink);
    this.initialize(evtloop);
    return this;
}

fn initialize(this: *FileSink, event_loop: jsc.EventLoopHandle) void {
    this.* = .{
        .ref_count = .init(),
        .event_loop_handle = event_loop,
    };
    _ = live_count.fetchAdd(1, .monotonic);
    this.writer.setParent(this);
}

pub fn setup(this: *FileSink, options: *const FileSink.Options) bun.sys.Maybe(void) {
    if (this.readable_stream.has()) {
        // Already started.
        return .success;
    }

    const result = bun.io.openForWriting(
        bun.FD.cwd(),
        options.input_path,
        options.flags(),
        options.mode,
    );

    const fd = switch (result) {
        .err => |err| {
            return .{ .err = err };
        },
        .result => |fd| switch (fd.makeLibUVOwnedForSyscall(.open, .close_on_fail)) {
            .result => |owned_fd| owned_fd,
            .err => |err| return .{ .err = err },
        },
    };
    const ofd_ownership: bun.io.WriterStartOptions.Ownership = switch (options.input_path) {
        .path => .exclusive,
        .fd => .shared,
    };

    switch (this.writer.start(
        fd,
        .{
            .tty_mode = .synchronous,
            .ofd_ownership = ofd_ownership,
        },
    )) {
        .err => |err| {
            _ = fd.closeAllowingStandardIo(null);
            return .{ .err = err };
        },
        .result => {
            // Only keep the event loop ref'd while there's a pending write in progress.
            // If there's no pending write, no need to keep the event loop ref'd.
            this.writer.updateRef(this.eventLoop(), false);
        },
    }

    return .success;
}

pub fn loop(this: *FileSink) *bun.Async.Loop {
    if (comptime bun.Environment.isWindows) {
        return this.event_loop_handle.loop().uv_loop;
    } else {
        return this.event_loop_handle.loop();
    }
}

pub fn eventLoop(this: *FileSink) jsc.EventLoopHandle {
    return this.event_loop_handle;
}

pub fn connect(this: *FileSink, signal: streams.Signal) void {
    this.signal = signal;
}

pub fn start(this: *FileSink, stream_start: streams.Start) bun.sys.Maybe(void) {
    switch (stream_start) {
        .err => |err| return .{ .err = err },
        .FileSink => |*file| {
            switch (this.setup(file)) {
                .err => |err| {
                    return .{ .err = err };
                },
                .result => {},
            }
        },
        else => {},
    }

    this.done = false;
    this.started = true;
    this.signal.start();
    return .success;
}

pub fn runPendingLater(this: *FileSink) void {
    if (this.pending.state != .pending) return;
    if (this.run_pending_later.isScheduled()) return;
    const event_loop = this.eventLoop();
    if (event_loop == .js) {
        this.ref();
        if (!this.run_pending_later.scheduleWithCancel(event_loop.js, this, runDeferredPending, cancelDeferredPending)) {
            this.deref();
        }
    } else {
        this.runPending();
    }
}

pub fn onAutoFlush(this: *FileSink) bool {
    if (this.done or !this.writer.hasPendingData()) {
        this.updateRef(false);
        return false;
    }

    this.ref();
    defer this.deref();

    const amount_buffered = this.writer.outgoing.size();

    switch (this.writer.flush()) {
        .err, .done => {
            this.updateRef(false);
            this.runPendingLater();
        },
        .wrote => |amount_drained| {
            if (amount_drained == amount_buffered) {
                this.updateRef(false);
                this.runPendingLater();
            }
        },
        else => {
            return true;
        },
    }

    return !this.done and this.writer.hasPendingData();
}

pub fn flush(_: *FileSink) bun.sys.Maybe(void) {
    return .success;
}

pub fn flushFromBinding(this: *FileSink, wait: bool) bun.sys.Maybe(Sink.BindingOperation) {
    this.ref();
    defer this.deref();
    _ = wait;

    if (this.pending.state == .pending) {
        return .{ .result = .{ .writable = .{ .pending = &this.pending } } };
    }

    if (this.done) {
        return .{ .result = .undefined };
    }

    const started_at = this.written;
    const rc = this.writer.flush();
    switch (rc) {
        .done, .pending, .wrote => {},
        .err => |err| {
            return .{ .err = err };
        },
    }
    return .{ .result = .{ .writable = this.toResult(rc, started_at) } };
}

pub fn finalize(this: *FileSink) void {
    this.deref();
}
pub const releaseBindingRef = finalize;

pub fn hasPendingActivity(this: *const FileSink) bool {
    return this.pending.state == .pending;
}

pub fn construct(this: *FileSink, _: std.mem.Allocator) void {
    this.initialize(jsc.EventLoopHandle.init(jsc.VirtualMachine.get().eventLoop()));
}

pub fn write(this: *@This(), data: streams.Result) streams.Result.Writable {
    this.ref();
    defer this.deref();
    if (this.done) {
        return .{ .done = {} };
    }

    const started_at = this.written;
    return this.toResult(this.writer.write(data.slice()), started_at);
}
pub const writeBytes = write;
pub fn writeLatin1(this: *@This(), data: streams.Result) streams.Result.Writable {
    this.ref();
    defer this.deref();
    if (this.done) {
        return .{ .done = {} };
    }

    const started_at = this.written;
    return this.toResult(this.writer.writeLatin1(data.slice()), started_at);
}
pub fn writeUTF16(this: *@This(), data: streams.Result) streams.Result.Writable {
    this.ref();
    defer this.deref();
    if (this.done) {
        return .{ .done = {} };
    }

    const started_at = this.written;
    return this.toResult(this.writer.writeUTF16(data.slice16()), started_at);
}

pub fn end(this: *FileSink, _: ?bun.sys.Error) bun.sys.Maybe(void) {
    this.ref();
    defer this.deref();
    if (this.done) {
        return .success;
    }
    this.done = true;

    switch (this.writer.flush()) {
        .done => {
            this.writer.end();
            return .success;
        },
        .err => |e| {
            this.writer.close();
            return .{ .err = e };
        },
        .pending => {
            if (!this.must_be_kept_alive_until_eof) {
                this.must_be_kept_alive_until_eof = true;
                this.ref();
            }
            this.done = true;
            return .success;
        },
        .wrote => {
            this.writer.end();
            return .success;
        },
    }
}

fn deinit(this: *FileSink) void {
    bun.assert(!this.run_pending_later.isScheduled());
    var process = this.takeProcessLifecycle();
    defer if (process) |*owner| owner.deinit();
    if (process) |*owner| owner.get().onStdinSinkDestroyed();
    _ = live_count.fetchSub(1, .monotonic);
    this.pending.deinit();
    this.writer.deinit();
    this.readable_stream.deinit();
    if (this.event_loop_handle.globalObject()) |global| {
        webcore.AutoFlusherEngine.unregister(@This(), this, &this.auto_flusher, global.bunVM());
    }
    bun.destroy(this);
}

pub fn endFromBinding(this: *FileSink) bun.sys.Maybe(Sink.BindingOperation) {
    this.ref();
    defer this.deref();
    if (this.done) {
        if (this.pending.state == .pending) {
            return .{ .result = .{ .writable = .{ .pending = &this.pending } } };
        }

        return .{ .result = .{ .count = this.written } };
    }

    var existing_promise: ?Sink.PendingCountPromise = if (this.pending.state == .pending) switch (this.pending.future) {
        .promise => |*promise| promise.existingPromiseOwned(),
        else => null,
    } else null;
    defer if (existing_promise) |*promise| promise.deinit();
    this.done = true;
    const started_at = this.written;
    const flush_result = this.writer.flush();

    switch (flush_result) {
        .done => |written| {
            this.updateRef(false);
            this.writer.end();
            if (existing_promise) |*promise| return .{ .result = .{ .count_promise = promise.take() } };
            return .{ .result = .{ .count = written } };
        },
        .err => |err| {
            this.onError(err);
            this.writer.close();
            if (existing_promise) |*promise| return .{ .result = .{ .count_promise = promise.take() } };
            return .{ .err = err };
        },
        .pending => |pending_written| {
            if (!this.must_be_kept_alive_until_eof) {
                this.must_be_kept_alive_until_eof = true;
                this.ref();
            }
            this.done = true;
            if (this.pending.state != .pending) this.pending_start = started_at;
            this.pending.result = .{ .owned = pending_written };
            if (existing_promise) |*promise| return .{ .result = .{ .count_promise = promise.take() } };
            return .{ .result = .{ .writable = .{ .pending = &this.pending } } };
        },
        .wrote => |written| {
            this.writer.end();
            if (existing_promise) |*promise| return .{ .result = .{ .count_promise = promise.take() } };
            return .{ .result = .{ .count = written } };
        },
    }
}

pub fn sink(this: *FileSink) Sink {
    return Sink.init(this);
}

pub fn updateRef(this: *FileSink, value: bool) void {
    if (value) {
        this.writer.enableKeepingProcessAlive(this.event_loop_handle);
    } else {
        this.writer.disableKeepingProcessAlive(this.event_loop_handle);
    }
}

pub const JSSink = Sink.JSSink(@This(), "FileSink", 2);

fn getFd(this: *const @This()) i32 {
    const fd = this.writer.getFd();
    if (Environment.isWindows) {
        return switch (fd.decodeWindows()) {
            .windows => -1, // TODO:
            .uv => |num| num,
        };
    }
    return fd.cast();
}

fn toResult(this: *FileSink, write_result: bun.OOM!bun.io.WriteResult, started_at: usize) streams.Result.Writable {
    switch (write_result catch return .out_of_memory) {
        .done => |amt| {
            if (amt > 0)
                return .{ .owned_and_done = amt };

            return .{ .done = {} };
        },
        .wrote => |amt| {
            if (amt > 0)
                return .{ .owned = amt };

            return .{ .temporary = amt };
        },
        .err => |err| {
            return if (err.getErrno() == .NOMEM) .out_of_memory else .{ .err = err };
        },
        .pending => |pending_written| {
            if (!this.must_be_kept_alive_until_eof) {
                this.must_be_kept_alive_until_eof = true;
                this.ref();
            }
            if (this.pending.state != .pending) this.pending_start = started_at;
            this.pending.result = .{ .owned = pending_written };
            return .{ .pending = &this.pending };
        },
    }
}

fn runDeferredPending(this: *FileSink) void {
    defer this.deref();
    this.runPending();
}

fn cancelDeferredPending(this: *FileSink) void {
    this.deref();
}

/// Does not ref or unref.
fn handleResolveStream(this: *FileSink) void {
    this.readable_stream.doneInStoredRealm();

    if (!this.done) {
        this.writer.close();
    }
}

/// Does not ref or unref.
fn handleRejectStream(this: *FileSink) void {
    this.readable_stream.abortInStoredRealm();
    this.readable_stream.deinit();

    if (!this.done) {
        this.writer.close();
    }
}

fn bindOnResolveStream(
    context: bun.bindgen.CallContext(OnResolveStreamSchema),
    args: bun.bindgen.Args(OnResolveStreamSchema),
) bun.JSError!bun.bindgen.Return(OnResolveStreamSchema) {
    log("onResolveStream", .{});
    const this = PromiseReaction.take(args.context) orelse return;
    defer this.deref();
    _ = context;
    this.handleResolveStream();
}

fn bindOnRejectStream(
    context: bun.bindgen.CallContext(OnRejectStreamSchema),
    args: bun.bindgen.Args(OnRejectStreamSchema),
) bun.JSError!bun.bindgen.Return(OnRejectStreamSchema) {
    log("onRejectStream", .{});
    const this = PromiseReaction.take(args.context) orelse return;
    defer this.deref();
    _ = context;
    this.handleRejectStream();
}

pub fn assignToStream(this: *FileSink, stream: *const jsc.WebCore.ReadableStream.Strong, globalThis: *JSGlobalObject) bun.JSError!void {
    var signal = &this.signal;
    this.ref();
    defer this.deref();

    signal.clear();

    this.readable_stream = stream.clone();
    errdefer {
        jsc.WebCore.FileSink.JSSink.detach(this);
        this.readable_stream.deinit();
        this.readable_stream = .{};
    }

    var owned_stream = stream.cloneOwned() orelse return;
    defer owned_stream.deinit();
    var promise_result = try jsc.WebCore.FileSink.JSSink.assignToStream(
        globalThis,
        &owned_stream,
        this,
    ) orelse return;
    defer promise_result.deinit();

    var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
    engine_scope.init(globalThis);
    defer engine_scope.deinit();
    switch (engine_scope.engine(PromiseStatusSchema).call(.{ .promise = promise_result.operand(&engine_scope) })) {
        .pending => {
            this.writer.enableKeepingProcessAlive(this.event_loop_handle);
            this.ref();
            try PromiseReaction.attach(
                &engine_scope,
                promise_result.operand(&engine_scope).asPromise(),
                this,
                OnResolveStreamBinding,
                OnRejectStreamBinding,
            );
        },
        .fulfilled => this.handleResolveStream(),
        .rejected => {
            // Native consumption does not install a promise reaction in this branch.
            engine_scope.engine(PromiseSetHandledSchema).call(.{ .promise = promise_result.operand(&engine_scope) });
            this.handleRejectStream();
        },
    }
}

const std = @import("std");
const CancellableTask = @import("../../event_loop/CancellableTask.zig");

const bun = @import("bun");
const Environment = bun.Environment;
const Output = bun.Output;
const uv = bun.windows.libuv;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;

const webcore = bun.webcore;
const Blob = webcore.Blob;
const Sink = webcore.Sink;
const streams = webcore.streams;

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const FileSinkLiveCountSchema = InternalTestingBindings.function("fileSinkLiveCount");
const FileSinkLiveCountBinding = bun.bindgen.Fn(FileSinkLiveCountSchema, TestingAPIs.fileSinkLiveCount);
const PromiseBindings = bun.bindgen.Module("promises");
const PromiseStatusSchema = PromiseBindings.engineShim("promiseStatus");
const PromiseSetHandledSchema = PromiseBindings.engineShim("promiseSetHandled");
const JSSinkBindings = bun.bindgen.Module("JSSink");
const ForceSynchronousSchema = JSSinkBindings.nativeExport("fileSinkForceSynchronous");
const ForceSynchronousBinding = bun.bindgen.Fn(ForceSynchronousSchema, bindForceSynchronous);
const FileSinkCallbackBindings = bun.bindgen.Module("FileSink");
const OnResolveStreamSchema = FileSinkCallbackBindings.function("onResolveStream");
const OnRejectStreamSchema = FileSinkCallbackBindings.function("onRejectStream");
const PromiseReaction = bun.bindgen.PromiseReaction(OnResolveStreamSchema.args[1].ArgumentType, FileSink);
const OnResolveStreamBinding = bun.bindgen.Fn(OnResolveStreamSchema, bindOnResolveStream);
const OnRejectStreamBinding = bun.bindgen.Fn(OnRejectStreamSchema, bindOnRejectStream);

comptime {
    _ = FileSinkLiveCountBinding;
    _ = OnResolveStreamBinding;
    _ = OnRejectStreamBinding;
}
