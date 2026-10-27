//! The Subprocess object is returned by `Bun.spawn`. This file also holds the
//! code for `Bun.spawnSync`

const Subprocess = @This();

pub const JSBinding = struct {
    bindgen_state: bindgen.ClassState = .{},
    subprocess: bindgen.RefNative(Subprocess, .vm),

    pub fn destroy(this: *JSBinding) void {
        if (this.subprocess.getOptional()) |subprocess| {
            if (subprocess.globalThis.bunVM().isShuttingDown()) subprocess.shutdown();
        }
        this.subprocess.deinit();
        bun.destroy(this);
    }

    pub fn memoryUsage(this: *const JSBinding, _: bindgen.MemoryUsageContext(.vm)) usize {
        const subprocess = this.subprocess.getOptional() orelse return @sizeOf(JSBinding);
        return @sizeOf(JSBinding) + subprocess.memoryCost();
    }

    pub fn hasPendingActivity(this: *const JSBinding) bool {
        const subprocess = this.subprocess.getOptional() orelse return false;
        return subprocess.computeHasPendingActivity();
    }

    fn NativeMethod(comptime Schema: type, comptime implementation: anytype) type {
        return struct {
            fn call(
                this: *JSBinding,
                _: bindgen.CallContext(Schema),
                _: bindgen.Args(Schema),
            ) bun.JSError!bindgen.Return(Schema) {
                return @call(.auto, implementation, .{this.subprocess.get()});
            }

            fn withContext(
                this: *JSBinding,
                context: bindgen.CallContext(Schema),
                _: bindgen.Args(Schema),
            ) bindgen.CallError(Schema)!bindgen.Return(Schema) {
                return @call(.auto, implementation, .{ this.subprocess.get(), context });
            }
        };
    }

    pub fn bindAsyncDisposeNative(
        this: *JSBinding,
        context: bindgen.CallContext(SubprocessAsyncDisposeNativeSchema),
        _: bindgen.Args(SubprocessAsyncDisposeNativeSchema),
    ) bindgen.CallError(SubprocessAsyncDisposeNativeSchema)!void {
        const subprocess = this.subprocess.get();
        if (subprocess.process.hasExited()) return;

        subprocess.stdin.unref();
        subprocess.stdout.unref();
        subprocess.stderr.unref();

        switch (subprocess.tryKill(subprocess.killSignal)) {
            .result => {},
            .err => |err| return context.fail(.system, try bindgen.SystemError.fromSysError(err)),
        }
    }

    pub fn bindGetConnected(
        this: *JSBinding,
        _: bindgen.CallContext(SubprocessConnectedSchema),
        _: bindgen.Args(SubprocessConnectedSchema),
    ) bun.JSError!bool {
        const ipc_data = this.subprocess.get().ipc();
        return ipc_data != null and ipc_data.?.isConnected();
    }

    pub fn bindDisconnect(
        this: *JSBinding,
        _: bindgen.CallContext(SubprocessDisconnectSchema),
        _: bindgen.Args(SubprocessDisconnectSchema),
    ) bun.JSError!void {
        this.subprocess.get().disconnectIPC(true);
    }

    pub const bindGetExitCode = NativeMethod(SubprocessExitCodeSchema, exitCodeResult).call;

    pub fn bindGetExited(
        this: *JSBinding,
        context: bindgen.CallContext(SubprocessExitedSchema),
        _: bindgen.Args(SubprocessExitedSchema),
    ) bindgen.CallError(SubprocessExitedSchema)!void {
        var completion = context.completion();
        const subprocess = this.subprocess.get();
        switch (subprocess.process.status) {
            .exited => |exit| completion.resolve(@intCast(exit.code)),
            .signaled => |signal| completion.resolve(@intCast(signal.toExitCode() orelse 254)),
            .err => |err| {
                const system_error = bindgen.SystemError.fromSysError(err) catch {
                    completion.outOfMemory();
                    return;
                };
                completion.fail(.system, system_error);
            },
            else => {
                if (subprocess.exited_completion != null) {
                    @panic("subprocess exited completion was created twice");
                }
                subprocess.exited_completion = completion.take();
            },
        }
    }

    pub fn bindKill(
        this: *JSBinding,
        context: bindgen.CallContext(SubprocessKillSchema),
        args: bindgen.Args(SubprocessKillSchema),
    ) bindgen.CallError(SubprocessKillSchema)!void {
        const signal: SignalCode = if (args.signal) |input| switch (input) {
            .defaulted => .default,
            .number => |number| @fromBackingInt(number),
            .named => |name| named: {
                comptime {
                    if (@typeInfo(@TypeOf(name)).@"enum".field_names.len != @typeInfo(SignalCode).@"enum".field_names.len)
                        @compileError("Subprocess signal names must cover SignalCode");
                }
                break :named switch (name) {
                    inline else => |tag| code: {
                        const name_bytes = comptime upper: {
                            var bytes: [@tagName(tag).len]u8 = undefined;
                            _ = std.ascii.upperString(&bytes, @tagName(tag));
                            break :upper bytes;
                        };
                        break :code @field(SignalCode, &name_bytes);
                    },
                };
            },
        } else .default;
        switch (this.subprocess.get().tryKill(signal)) {
            .result => {},
            .err => |err| return context.fail(.system, try bindgen.SystemError.fromSysError(err)),
        }
    }

    pub const bindGetKilled = NativeMethod(SubprocessKilledSchema, hasKilled).call;

    pub const bindGetPid = NativeMethod(SubprocessPidSchema, pid).call;

    pub const bindGetReadable = NativeMethod(SubprocessReadableSchema, getStdoutFromBinding).withContext;

    pub const bindRef = NativeMethod(SubprocessRefSchema, jsRef).call;

    pub const bindResourceUsage = NativeMethod(SubprocessResourceUsageSchema, createResourceUsageObject).withContext;

    pub fn bindSend(
        this: *JSBinding,
        context: bindgen.CallContext(SubprocessSendSchema),
        args: bindgen.Args(SubprocessSendSchema),
    ) bindgen.CallError(SubprocessSendSchema)!bool {
        return jsc.IPC.subprocessSend(context, this.subprocess.get(), args);
    }

    pub fn bindGetSignalCode(
        this: *JSBinding,
        _: bindgen.CallContext(SubprocessSignalCodeSchema),
        _: bindgen.Args(SubprocessSignalCodeSchema),
    ) bun.JSError!bindgen.Return(SubprocessSignalCodeSchema) {
        return this.subprocess.get().signalCodeResult(bindgen.Return(SubprocessSignalCodeSchema));
    }

    pub const bindGetStderr = NativeMethod(SubprocessStderrSchema, getStderrFromBinding).withContext;

    pub const bindGetStdin = NativeMethod(SubprocessStdinSchema, getStdin).withContext;

    pub const bindGetStdio = NativeMethod(SubprocessStdioSchema, getStdio).call;

    pub const bindGetStdout = NativeMethod(SubprocessStdoutSchema, getStdoutFromBinding).withContext;

    pub const bindGetTerminal = NativeMethod(SubprocessTerminalSchema, getTerminal).call;

    pub const bindUnref = NativeMethod(SubprocessUnrefSchema, jsUnref).call;

    pub const bindGetWritable = NativeMethod(SubprocessWritableSchema, getStdin).withContext;
};

pub const Ref = bindgen.ClassRef(SubprocessSchema);

pub fn toRef(this: *Subprocess, global: *jsc.JSGlobalObject) bun.JSError!Ref {
    const binding = try bun.default_allocator.create(JSBinding);
    binding.* = .{ .subprocess = .empty };
    const reference = try SubprocessClass.adoptNativeRef(binding, global);
    binding.subprocess = .init(this);
    return reference;
}

const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

ref_count: RefCount,
process: *Process,
stdin: Writable,
stdout: Readable,
stderr: Readable,
stdio_pipes: std.ArrayList(StdioResult) = .empty,
pid_rusage: ?Rusage = null,

/// Terminal attached to this subprocess (if spawned with terminal option)
terminal: ?*Terminal = null,

globalThis: *jsc.JSGlobalObject,
observable_getters: std.enums.EnumSet(enum {
    stdin,
    stdout,
    stderr,
}) = .{},
closed: std.enums.EnumSet(StdioKind) = .{},
wrapper: bindgen.ClassWrapperHandle(SubprocessSchema, .weak) = .empty,
activity_ref_held: bool = true,
exited_completion: ?bindgen.OwnedCompletion(SubprocessExitedSchema) = null,
stdin_sink: ?bindgen.ClassRef(FileSinkClassSchema) = null,
stdin_sink_native: bindgen.RefNative(jsc.WebCore.FileSink, .vm) = .empty,

/// `null` indicates all of the IPC data is uninitialized.
ipc_data: ?IPC.SendQueue,
flags: Flags = .{},

weak_file_sink_stdin_ptr: ?*jsc.WebCore.FileSink = null,
stdin_lifecycle_ref: ?bindgen.RefNative(Subprocess, .vm) = null,
abort_signal: ?*webcore.AbortSignal = null,
abort_listener: webcore.AbortSignal.Listener = undefined,

event_loop_timer_refd: bool = false,
event_loop_timer: bun.api.Timer.EventLoopTimer = .{
    .tag = .SubprocessTimeout,
    .next = .epoch,
},
killSignal: SignalCode,

stdout_maxbuf: ?*MaxBuf = null,
stderr_maxbuf: ?*MaxBuf = null,
exited_due_to_maxbuf: ?MaxBuf.Kind = null,

pub const Flags = packed struct(u8) {
    is_sync: bool = false,
    killed: bool = false,
    has_stdin_destructor_called: bool = false,
    finalized: bool = false,
    is_stdin_a_readable_stream: bool = false,
    /// Terminal was created inline by spawn (vs. an existing Terminal passed
    /// by the caller). Owned terminals are closed when the subprocess exits
    /// so the exit callback fires; borrowed terminals are left open for reuse.
    owns_terminal: bool = false,
    _: u2 = 0,
};

pub const SignalCode = bun.SignalCode;

pub const Poll = union(enum) {
    poll_ref: ?*Async.FilePoll,
    wait_thread: WaitThreadPoll,
};

pub const WaitThreadPoll = struct {
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    poll_ref: Async.KeepAlive = .{},
};

pub inline fn assertStdioResult(result: StdioResult) void {
    if (comptime Environment.allow_assert) {
        if (Environment.isPosix) {
            if (result != .unavailable) bun.assert(result.fd() != bun.invalid_fd);
        }
    }
}

pub const ResourceUsage = @import("./subprocess/ResourceUsage.zig");

const log = Output.scoped(.Subprocess, .visible);
pub const StdioKind = @import("./StdioKind.zig").StdioKind;

pub fn onAbortSignal(this: *Subprocess, _: bindgen.EngineValueView) void {
    this.clearAbortSignal();
    _ = this.tryKill(this.killSignal);
}

pub fn createResourceUsageObject(
    this: *Subprocess,
    context: anytype,
) bun.JSError!bindgen.Return(SubprocessResourceUsageSchema) {
    const usage = try ResourceUsage.create(
        brk: {
            if (this.pid_rusage != null) {
                break :brk &this.pid_rusage.?;
            }

            if (Environment.isWindows) {
                if (this.process.poller == .uv) {
                    this.pid_rusage = PosixSpawn.process.uv_getrusage(&this.process.poller.uv);
                    break :brk &this.pid_rusage.?;
                }
            }

            return null;
        },
        context,
    );
    return usage;
}

pub fn hasExited(this: *const Subprocess) bool {
    return this.process.hasExited();
}

pub fn computeHasPendingActivity(this: *const Subprocess) bool {
    if (this.flags.finalized) return false;

    // `ipc_data` is never set back to `null` after init, so checking only
    // for `!= null` would keep the Subprocess wrapper strongly referenced for the
    // lifetime of the VM. The IPC side contributes pending activity until
    // `_onAfterIPCClosed` has actually run: gating on `close_event_sent`
    // (rather than `socket != .closed`) keeps the wrapper Strong across the
    // window where the socket is already `.closed` but the task holding a
    // raw `*SendQueue` into `ipc_data` is still queued.
    if (this.ipc_data != null and !this.ipc_data.?.close_event_sent) {
        return true;
    }

    if (this.hasPendingActivityStdio()) {
        return true;
    }

    if (!this.process.hasExited()) {
        return true;
    }

    return false;
}

pub fn updateHasPendingActivity(this: *Subprocess) void {
    const has_pending = this.computeHasPendingActivity();
    if (comptime Environment.isDebug) {
        log("updateHasPendingActivity() -> {}", .{has_pending});
    }
    if (!has_pending and this.activity_ref_held) this.releaseActivityRef();
}

pub fn releaseActivityRef(this: *Subprocess) void {
    bun.assert(this.activity_ref_held);
    this.activity_ref_held = false;
    this.deref();
}

pub fn hasPendingActivityStdio(this: *const Subprocess) bool {
    if (this.stdin.hasPendingActivity()) {
        return true;
    }

    inline for (.{ StdioKind.stdout, StdioKind.stderr }) |kind| {
        if (@field(this, @tagName(kind)).hasPendingActivity()) {
            return true;
        }
    }

    return false;
}

pub fn onCloseIO(this: *Subprocess, kind: StdioKind) void {
    this.ref();
    defer this.deref();
    switch (kind) {
        .stdin => {
            const input = this.stdin;
            this.stdin = .{ .ignore = {} };
            switch (input) {
                .pipe => |pipe| {
                    pipe.signal.clear();
                    pipe.deref();
                },
                .buffer => |writer| {
                    writer.deref();
                },
                else => {},
            }
        },
        inline .stdout, .stderr => |tag| {
            const out: *Readable = &@field(this, @tagName(tag));
            switch (out.*) {
                .pipe => |pipe| {
                    if (pipe.state == .done) {
                        out.* = .{ .buffer = CowString.initOwned(pipe.state.done, bun.default_allocator) };
                        pipe.state = .{ .done = &.{} };
                    } else {
                        out.* = .{ .ignore = {} };
                    }
                    pipe.deref();
                },
                else => {},
            }
        },
    }

    // A pipe may be the final asynchronous owner after the process exits.
    this.updateHasPendingActivity();
}

pub fn jsRef(this: *Subprocess) void {
    this.process.enableKeepingEventLoopAlive();

    if (!this.hasCalledGetter(.stdin)) {
        this.stdin.ref();
    }

    if (!this.hasCalledGetter(.stdout)) {
        this.stdout.ref();
    }

    if (!this.hasCalledGetter(.stderr)) {
        this.stderr.ref();
    }

    this.updateHasPendingActivity();
}

/// This disables the keeping process alive flag on the poll and also in the stdin, stdout, and stderr
pub fn jsUnref(this: *Subprocess) void {
    this.process.disableKeepingEventLoopAlive();

    if (!this.hasCalledGetter(.stdin)) {
        this.stdin.unref();
    }

    if (!this.hasCalledGetter(.stdout)) {
        this.stdout.unref();
    }

    if (!this.hasCalledGetter(.stderr)) {
        this.stderr.unref();
    }

    this.updateHasPendingActivity();
}

fn stdioFDToBindingInt32(fd: bun.FD) bun.sys.Maybe(i32) {
    if (!fd.isValid()) return .{ .result = -1 };
    return switch (fd.makeLibUVOwnedForSyscall(.uv_open_osfhandle, .close_on_fail)) {
        .result => |owned| .{ .result = @intCast(owned.uv()) },
        .err => |err| .{ .err = err },
    };
}

fn subprocessStreamFromOwnedSlice(
    context: anytype,
    bytes: []u8,
) bindgen.CallError(@TypeOf(context))!jsc.WebCore.ReadableStream.Result {
    return jsc.WebCore.ReadableStream.fromOwnedSliceResultFromBinding(context, bytes, 0);
}

fn emptySubprocessStream(
    context: anytype,
    canceled: bool,
) bindgen.CallError(@TypeOf(context))!jsc.WebCore.ReadableStream.Result {
    return jsc.WebCore.ReadableStream.emptyResultFromBinding(context, canceled);
}

const PipeReaderIntegration = struct {
    pub const ProcessHandle = *Subprocess;
    pub const LoopHandle = *jsc.EventLoop;
    pub const GlobalHandle = *jsc.JSGlobalObject;
    pub const ReaderEventLoop = jsc.EventLoopHandle;
    pub const StreamResult = jsc.WebCore.ReadableStream.Result;

    pub fn readerClosed(process: ProcessHandle, reader: *PipeReader) void {
        const kind: StdioKind = if (process.stdout == .pipe and process.stdout.pipe == reader)
            .stdout
        else if (process.stderr == .pipe and process.stderr.pipe == reader)
            .stderr
        else
            @panic("subprocess pipe reader is not attached to stdout or stderr");
        process.onCloseIO(kind);
    }

    pub fn streamFromPipe(
        context: anytype,
        parent: *PipeReader,
        reader: *PipeReader.IOReader,
    ) bindgen.CallError(@TypeOf(context))!StreamResult {
        return jsc.WebCore.ReadableStream.fromPipeResultFromBinding(context, parent, reader);
    }

    pub const streamFromOwnedSlice = subprocessStreamFromOwnedSlice;
    pub const emptyStream = emptySubprocessStream;

    pub fn readerEventLoop(event_loop: LoopHandle) ReaderEventLoop {
        return .init(event_loop);
    }

    pub fn platformLoop(event_loop: LoopHandle) *bun.Async.Loop {
        return if (comptime Environment.isWindows)
            event_loop.virtual_machine.uwsLoop().uv_loop
        else
            event_loop.virtual_machine.uwsLoop();
    }
};

pub const PipeReader = @import("./subprocess/SubprocessPipeReader.zig").WithIntegration(PipeReaderIntegration);

const ReadableIntegration = struct {
    pub const ProcessHandle = *Subprocess;
    pub const LoopHandle = *jsc.EventLoop;
    pub const GlobalHandle = *jsc.JSGlobalObject;
    pub const Stdio = bun.api.SpawnStdio;

    pub const assertStdioResult = Subprocess.assertStdioResult;

    pub const fdToBindingInt32 = stdioFDToBindingInt32;
    pub const streamFromOwnedSlice = subprocessStreamFromOwnedSlice;
    pub const emptyStream = emptySubprocessStream;
};

pub const Readable = @import("./subprocess/Readable.zig").WithIntegration(ReadableIntegration, PipeReader);

fn getStderrFromBinding(this: *Subprocess, context: anytype) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    // When terminal is used, stderr goes through the terminal
    if (this.terminal != null) {
        return .{ .nulled = true };
    }
    this.observable_getters.insert(.stderr);
    return this.stderr.toBindingResult(context);
}

pub fn getStdin(this: *Subprocess, context: anytype) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    // When terminal is used, stdin goes through the terminal
    if (this.terminal != null) {
        return .{ .nulled = true };
    }
    this.observable_getters.insert(.stdin);
    return this.stdin.toBindingResult(context, this);
}

fn getStdoutFromBinding(this: *Subprocess, context: anytype) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    // When terminal is used, stdout goes through the terminal
    if (this.terminal != null) {
        return .{ .nulled = true };
    }
    this.observable_getters.insert(.stdout);
    return this.stdout.toBindingResult(context);
}

pub fn getTerminal(this: *Subprocess) bun.JSError!?Terminal.Ref {
    if (this.terminal) |terminal| {
        return terminal.wrapperRef();
    }
    return null;
}

pub fn setEventLoopTimerRefd(this: *Subprocess, refd: bool) void {
    if (this.event_loop_timer_refd == refd) return;
    this.event_loop_timer_refd = refd;
    if (refd) {
        this.globalThis.bunVM().timer.incrementTimerRef(1);
    } else {
        this.globalThis.bunVM().timer.incrementTimerRef(-1);
    }
}

pub fn timeoutCallback(this: *Subprocess) void {
    this.setEventLoopTimerRefd(false);
    if (this.event_loop_timer.state == .CANCELLED) return;
    if (this.hasExited()) {
        this.event_loop_timer.state = .CANCELLED;
        return;
    }
    this.event_loop_timer.state = .FIRED;
    _ = this.tryKill(this.killSignal);
}

pub fn onMaxBuffer(this: *Subprocess, kind: MaxBuf.Kind) void {
    this.exited_due_to_maxbuf = kind;
    _ = this.tryKill(this.killSignal);
}

pub fn createMaxBuffer(this: *Subprocess, kind: MaxBuf.Kind, slot: *?*MaxBuf, limit: ?i64) bun.OOM!void {
    try MaxBuf.createForOwner(@ptrCast(this), maxBufferExceeded, kind, slot, limit);
}

fn maxBufferExceeded(owner: *MaxBuf.Owner, kind: MaxBuf.Kind) void {
    const this: *Subprocess = @ptrCast(@alignCast(owner));
    MaxBuf.removeFromOwner(switch (kind) {
        .stdout => &this.stdout_maxbuf,
        .stderr => &this.stderr_maxbuf,
    });
    this.onMaxBuffer(kind);
}

pub fn hasKilled(this: *const Subprocess) bool {
    return this.process.hasKilled();
}

pub fn tryKill(this: *Subprocess, sig: SignalCode) bun.sys.Maybe(void) {
    if (this.hasExited()) {
        return .success;
    }
    return this.process.kill(@backingInt(sig));
}

fn hasCalledGetter(this: *Subprocess, comptime getter: @EnumLiteral()) bool {
    return this.observable_getters.contains(getter);
}

fn closeProcess(this: *Subprocess) void {
    if (comptime !Environment.isLinux) {
        return;
    }
    this.process.close();
}

pub fn onStdinDestroyed(this: *Subprocess) void {
    var owner = this.takeStdinLifecycleRef();
    defer if (owner) |*reference| reference.deinit();

    this.markStdinDestroyed();
}

pub fn onStdinSinkDestroyed(this: *Subprocess) void {
    if (this.stdin_lifecycle_ref != null) {
        @panic("subprocess stdin lifecycle reference has two owners");
    }
    this.markStdinDestroyed();
}

pub fn retainStdinLifecycleRef(this: *Subprocess) void {
    if (this.stdin_lifecycle_ref != null) {
        @panic("subprocess stdin lifecycle reference was retained twice");
    }
    this.stdin_lifecycle_ref = bindgen.RefNative(Subprocess, .vm).init(this);
}

pub fn takeStdinLifecycleRef(this: *Subprocess) ?bindgen.RefNative(Subprocess, .vm) {
    const owner = this.stdin_lifecycle_ref;
    this.stdin_lifecycle_ref = null;
    return owner;
}

pub fn restoreStdinLifecycleRef(this: *Subprocess, owner: bindgen.RefNative(Subprocess, .vm)) void {
    if (this.stdin_lifecycle_ref != null) {
        @panic("subprocess stdin lifecycle reference has two owners");
    }
    this.stdin_lifecycle_ref = owner;
}

pub fn releaseStdinLifecycleRef(this: *Subprocess) void {
    var owner = this.takeStdinLifecycleRef();
    if (owner) |*reference| reference.deinit();
}

fn markStdinDestroyed(this: *Subprocess) void {
    this.flags.has_stdin_destructor_called = true;
    this.weak_file_sink_stdin_ptr = null;

    if (!this.flags.finalized) {
        // otherwise update the pending activity flag
        this.updateHasPendingActivity();
    }
}

pub fn disconnectIPC(this: *Subprocess, nextTick: bool) void {
    const ipc_data = this.ipc() orelse return;
    ipc_data.closeSocketNextTick(nextTick);
}

pub fn pid(this: *const Subprocess) i32 {
    return @intCast(this.process.pid);
}

pub fn getStdio(this: *Subprocess) bun.OOM!bindgen.Return(SubprocessStdioSchema) {
    const Result = bindgen.Return(SubprocessStdioSchema);
    var builder = try Result.Builder.init(3 + this.stdio_pipes.items.len);
    for (0..3) |_| builder.appendOwned(null);
    for (this.stdio_pipes.items) |item| {
        const value: ?f64 = if (Environment.isWindows) blk: {
            if (item != .buffer) break :blk null;
            const fdno: usize = @intFromPtr(item.buffer.fd().cast());
            break :blk @floatFromInt(fdno);
        } else switch (item) {
            .owned_fd, .unowned_fd => |fd| @floatFromInt(fd.cast()),
            .unavailable => null,
        };
        builder.appendOwned(value);
    }
    return builder.finish();
}

pub const Source = union(enum) {
    blob: jsc.WebCore.Blob.Any,
    retained_bytes: bun.bindgen.OwnedLease(u8),
    detached: void,

    pub fn memoryCost(this: *const Source) usize {
        // Memory cost of Source and each of the particular fields is covered by @sizeOf(Subprocess).
        return switch (this.*) {
            .blob => this.blob.memoryCost(),
            .retained_bytes, .detached => 0,
        };
    }

    pub fn slice(this: *const Source) []const u8 {
        return switch (this.*) {
            .blob => this.blob.slice(),
            .retained_bytes => this.retained_bytes.unsafePtr("StaticPipeWriter owns Source's input lease until releaseInput clears its buffer after I/O finishes, then detaches Source"),
            else => @panic("Invalid source"),
        };
    }

    pub fn detach(this: *@This()) void {
        switch (this.*) {
            .blob => {
                this.blob.detach();
            },
            .retained_bytes => {
                this.retained_bytes.deinit();
            },
            else => {},
        }
        this.* = .detached;
    }
};

pub const StaticPipeWriter = @import("../../../io/StaticPipeWriter.zig").New(
    Subprocess,
    @import("./subprocess/StaticPipeWriterEngine.zig"),
    Source,
    StdioResult,
);

pub fn memoryCost(this: *const Subprocess) usize {
    return @sizeOf(@This()) +
        this.process.memoryCost() +
        this.stdin.memoryCost() +
        this.stdout.memoryCost() +
        this.stderr.memoryCost();
}

pub fn onProcessExit(this: *Subprocess, process: *Process, status: bun.spawn.Status, rusage: *const Rusage) void {
    log("onProcessExit()", .{});
    var receiver = this.wrapper.toOwned() catch |err| failed: {
        this.globalThis.reportActiveExceptionAsUnhandled(err);
        break :failed null;
    };
    defer if (receiver) |*reference| reference.deinit();
    const globalThis = this.globalThis;
    const jsc_vm = globalThis.bunVM();
    this.pid_rusage = rusage.*;
    const is_sync = this.flags.is_sync;
    this.clearAbortSignal();

    defer this.updateHasPendingActivity();
    defer this.disconnectIPC(true);

    if (this.event_loop_timer.state == .ACTIVE) {
        jsc_vm.timer.remove(&this.event_loop_timer);
    }
    this.setEventLoopTimerRefd(false);

    jsc_vm.onSubprocessExit(process);

    if (Environment.isWindows and this.flags.owns_terminal) {
        // POSIX gets EOF on the master when the child (last slave_fd holder)
        // exits. ConPTY's conhost stays alive after the child exits, so close
        // the pseudoconsole now to deliver EOF and fire the terminal's exit
        // callback. Leaves the Terminal itself open to match POSIX.
        if (this.terminal) |terminal| terminal.closePseudoconsole();
    }

    var stdin_owner: ?bindgen.RefNative(Subprocess, .vm) = null;
    defer if (stdin_owner) |*owner| owner.deinit();

    var stdin: ?*jsc.WebCore.FileSink = if (this.stdin == .pipe and this.flags.is_stdin_a_readable_stream) this.stdin.pipe else this.weak_file_sink_stdin_ptr;
    if (this.stdin_sink_native.getOptional()) |sink| {
        if (stdin == null) stdin = sink;
        if (!this.flags.is_stdin_a_readable_stream) stdin_owner = sink.takeProcessLifecycle();
    }

    // We won't be sending any more data.
    if (this.stdin == .buffer) {
        this.stdin.buffer.close();
    }

    if (this.flags.is_sync) {
        // This doesn't match Node.js' behavior, but for synchronous
        // subprocesses the streams should not keep the timers going.
        if (this.stdout == .pipe) {
            this.stdout.close();
        }

        if (this.stderr == .pipe) {
            this.stderr.close();
        }
    } else {
        // This matches Node.js behavior. Node calls resume() on the streams.
        if (this.stdout == .pipe and !this.stdout.pipe.reader.isDone()) {
            this.stdout.pipe.reader.read();
        }

        if (this.stderr == .pipe and !this.stderr.pipe.reader.isDone()) {
            this.stderr.pipe.reader.read();
        }
    }

    if (stdin) |pipe| {
        this.weak_file_sink_stdin_ptr = null;
        this.flags.has_stdin_destructor_called = true;

        // `onAttachedProcessExit()` → `writer.close()` → `FileSink.onClose`
        // fires `pipe.signal` synchronously on POSIX. When the signal still
        // targets `&this.stdin`, that would re-enter
        // `Writable.onClose` → `pipe.deref()` while `onAttachedProcessExit`
        // is still running on `pipe`. Detach the signal first and drive the
        // `onStdinDestroyed()` deref ourselves instead; this also leaves
        // `this.stdin` as `.pipe` so reading `.stdin` after exit still
        // returns the sink.
        if (pipe.signal.matches(&this.stdin)) {
            pipe.signal.clear();
        }
        if (this.takeStdinLifecycleRef()) |owner| {
            if (stdin_owner != null) @panic("subprocess stdin lifecycle reference has two owners");
            stdin_owner = owner;
        }
        this.markStdinDestroyed();

        pipe.onAttachedProcessExit(&status);
    }

    const loop = jsc_vm.eventLoop();

    if (!is_sync) {
        if (this.exited_completion) |completion_| {
            var completion = completion_;
            this.exited_completion = null;
            loop.enter();
            defer loop.exit();

            switch (status) {
                .exited => |exited| completion.resolve(@intCast(exited.code)),
                .err => |err| failure: {
                    const system_error = bindgen.SystemError.fromSysError(err) catch {
                        completion.outOfMemory();
                        break :failure;
                    };
                    completion.fail(.system, system_error);
                },
                .signaled => |signal| completion.resolve(@intCast(signal.toExitCode() orelse 254)),
                else => if (comptime Environment.allow_assert) unreachable,
            }
        }

        if (receiver) |*reference| {
            ExitNotification.enqueue(this, reference, status) catch |err|
                globalThis.reportActiveExceptionAsUnhandled(err);
        }
    }
}

const OnExitCallback = bindgen.Callback(OnExitCallbackSlot.SemanticType);

const ExitNotification = struct {
    registry: *jsc.NativeCompletionRegistry,
    entry: jsc.NativeCompletionRegistry.Entry,
    reference: Ref,
    callback: OnExitCallback,
    status: bun.spawn.Status,

    fn enqueue(subprocess: *Subprocess, reference: *Ref, status: bun.spawn.Status) bun.JSError!void {
        var callback = (try OnExitCallbackSlot.takeOwnedCallback(reference)) orelse return;
        defer callback.deinit();
        const vm = subprocess.globalThis.bunVM();
        // Exit-promise delivery and its microtasks precede the notification.
        const registry = try (try vm.tryRareData()).nativeCompletionRegistry(vm);
        const notification = try bun.default_allocator.create(ExitNotification);
        registry.retain();
        notification.* = .{
            .registry = registry,
            .entry = .{ .context = .init(notification), .deliver = deliver, .detach = detach },
            .reference = reference.take(),
            .callback = callback.take(),
            .status = status,
        };
        if (!registry.register(&notification.entry)) {
            notification.destroy();
            return;
        }
        if (!registry.submit(&notification.entry)) registry.detach(&notification.entry);
    }

    fn deliver(context: jsc.NativeCompletionRegistry.Context) void {
        const notification = context.get(*ExitNotification);
        defer notification.destroy();
        const subprocess = notification.reference.get(JSBinding).subprocess.get();
        subprocess.dispatchExitCallback(&notification.reference, &notification.callback, notification.status) catch |err|
            subprocess.globalThis.reportActiveExceptionAsUnhandled(err);
    }

    fn detach(context: jsc.NativeCompletionRegistry.Context) void {
        context.get(*ExitNotification).destroy();
    }

    fn destroy(notification: *ExitNotification) void {
        notification.callback.deinit();
        notification.reference.deinit();
        notification.registry.release();
        bun.destroy(notification);
    }
};

fn dispatchExitCallback(this: *Subprocess, reference: *Ref, callback: *const OnExitCallback, status: bun.spawn.Status) bun.JSError!void {
    var signal_code = try this.signalCodeResult(bindgen.Return(SubprocessSignalCodeSchema));
    defer if (signal_code) |*value| switch (value.*) {
        .string => |*string| string.deinit(),
        .integer => {},
    };

    const event_loop = this.globalThis.bunVM().eventLoop();
    event_loop.enter();
    defer event_loop.exit();

    var invocation: OnExitCallback.Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    const signal_operand: SubprocessOnExitSignalCode = if (signal_code) |*value| switch (value.*) {
        .string => |*string| .{ .string = string.operand() },
        .integer => |number| .{ .integer = number },
    } else null;

    if (status == .err) {
        const error_result = try bindgen.SystemError.createSysErrorInstance(&invocation, status.err);
        try invocation.call(.{
            .bindingThis = reference.operand(&invocation),
            .subprocess = reference.operand(&invocation),
            .exitCode = this.exitCodeResult(),
            .signalCode = signal_operand,
            .@"error" = error_result.operand(&invocation),
        });
    } else {
        try invocation.call(.{
            .bindingThis = reference.operand(&invocation),
            .subprocess = reference.operand(&invocation),
            .exitCode = this.exitCodeResult(),
            .signalCode = signal_operand,
            .@"error" = null,
        });
    }
}

fn closeIO(this: *Subprocess, comptime io: @EnumLiteral()) void {
    if (this.closed.contains(io)) return;
    this.closed.insert(io);

    // If you never referenced stdout/stderr, they won't be garbage collected.
    //
    // That means:
    //   1. We need to stop watching them
    //   2. We need to free the memory
    //   3. We need to halt any pending reads (1)

    if (!this.hasCalledGetter(io)) {
        @field(this, @tagName(io)).finalize();
    } else {
        @field(this, @tagName(io)).close();
    }
}

pub fn onPipeClose(this: *uv.Pipe) callconv(.c) void {
    // safely free the pipes
    bun.default_allocator.destroy(this);
}

// This must only be run once per Subprocess
pub fn finalizeStreams(this: *Subprocess) void {
    log("finalizeStreams", .{});
    this.closeProcess();

    this.closeIO(.stdin);
    this.closeIO(.stdout);
    this.closeIO(.stderr);

    for (this.stdio_pipes.items) |*item| item.deinit();
    this.stdio_pipes.clearAndFree(bun.default_allocator);
}

fn deinit(this: *Subprocess) void {
    log("deinit", .{});
    this.finalizeResources(false);
    bun.destroy(this);
}

fn clearAbortSignal(this: *Subprocess) void {
    if (this.abort_signal) |signal| {
        this.abort_signal = null;
        signal.pendingActivityUnref();
        signal.removeListener(&this.abort_listener);
        signal.unref();
    }
}

fn finalizeResources(this: *Subprocess, consume_stdin_ref: bool) void {
    if (this.flags.finalized) return;
    this.flags.finalized = true;
    this.clearStdinSinkReference();
    if (!consume_stdin_ref and this.stdin_lifecycle_ref != null) {
        @panic("subprocess reached its last reference while stdin still owned one");
    }
    var stdin_owner = if (consume_stdin_ref) this.takeStdinLifecycleRef() else null;
    defer if (stdin_owner) |*owner| owner.deinit();

    this.wrapper.deinit();
    if (this.exited_completion) |completion_| {
        var completion = completion_;
        this.exited_completion = null;
        completion.release();
    }
    this.clearAbortSignal();
    this.finalizeStreams();

    this.process.detach();
    this.process.deref();

    if (this.event_loop_timer.state == .ACTIVE) {
        this.globalThis.bunVM().timer.remove(&this.event_loop_timer);
    }
    this.setEventLoopTimerRefd(false);

    MaxBuf.removeFromOwner(&this.stdout_maxbuf);
    MaxBuf.removeFromOwner(&this.stderr_maxbuf);

    if (this.ipc_data) |*ipc_data| {
        // In normal operation the socket is already `.closed` by the time we
        // get here (that is what allowed `computeHasPendingActivity` to drop
        // to false and let GC collect us). `disconnectIPC` would be a no-op
        // in that state and would leak the SendQueue's buffers; deinit it
        // instead. `SendQueue.deinit` handles the VM-shutdown case where the
        // socket is still open.
        ipc_data.deinit();
        this.ipc_data = null;
    }
}

pub fn shutdown(this: *Subprocess) void {
    this.finalizeResources(true);
    if (this.activity_ref_held) this.releaseActivityRef();
}

pub fn clearStdinSinkReference(this: *Subprocess) void {
    var native = this.stdin_sink_native;
    this.stdin_sink_native = .empty;
    defer native.deinit();
    var wrapper = this.stdin_sink;
    this.stdin_sink = null;
    defer if (wrapper) |*reference| reference.deinit();
    if (native.getOptional()) |sink| {
        if (sink.takeProcessLifecycle()) |owner| this.restoreStdinLifecycleRef(owner);
    }
}

fn exitCodeResult(this: *Subprocess) ?i32 {
    if (this.process.status == .exited) return @intCast(this.process.status.exited.code);
    return null;
}

fn signalCodeResult(this: *Subprocess, comptime Result: type) bun.OOM!Result {
    const signal = this.process.signalCode() orelse return null;
    if (signal.name()) |name| return .{ .string = try bindgen.DOMString.fromUTF8(name) };
    return .{ .integer = @intCast(@backingInt(signal)) };
}

pub fn handleIPCMessage(
    this: *Subprocess,
    message: *const IPC.DecodedIPCMessage,
) void {
    IPClog("Subprocess#handleIPCMessage", .{});
    switch (message.*) {
        .version => |v| {
            IPC.log("Child IPC version is {d}", .{v});
        },
        .data => |*data| {
            IPC.log("Received IPC message from child", .{});
            var receiver = (this.wrapper.toOwned() catch |err| return this.globalThis.reportActiveExceptionAsUnhandled(err)) orelse return;
            defer receiver.deinit();
            var callback = (IPCCallbackSlot.ownedCallback(&receiver) catch |err|
                return this.globalThis.reportActiveExceptionAsUnhandled(err)) orelse return;
            defer callback.deinit();
            const event_loop = this.globalThis.bunVM().eventLoop();
            event_loop.enter();
            defer event_loop.exit();
            var invocation: @TypeOf(callback).Invocation = undefined;
            callback.beginInvocation(&invocation);
            defer invocation.deinit();
            const message_view = data.view(&invocation) catch |err|
                return this.globalThis.reportActiveExceptionAsUnhandled(err);
            invocation.call(.{
                .bindingThis = receiver.operand(&invocation),
                .message = message_view.operand(&invocation),
                .subprocess = receiver.operand(&invocation),
                .handle = false,
            }) catch |err| this.globalThis.reportActiveExceptionAsUnhandled(err);
        },
        .internal => |*data| {
            IPC.log("Received IPC internal message from child", .{});
            var message_root = data.toAnyRoot();
            defer message_root.deinit();
            NodeClusterEngine.handleInternalMessagePrimary(this, &message_root) catch |err|
                this.globalThis.reportActiveExceptionAsUnhandled(err);
        },
    }
}

pub fn handleIPCClose(this: *Subprocess) void {
    IPClog("Subprocess#handleIPCClose", .{});
    defer this.updateHasPendingActivity();

    var receiver = (this.wrapper.toOwned() catch |err| return this.globalThis.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer receiver.deinit();
    IPCCallbackSlot.clearOwned(&receiver);
    var callback = (OnDisconnectCallbackSlot.takeOwnedCallback(&receiver) catch |err|
        return this.globalThis.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer callback.deinit();
    var invocation: @TypeOf(callback).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    invocation.dispatch(.{ .bindingThis = receiver.operand(&invocation), .firstTime = true });
}

pub fn ipc(this: *Subprocess) ?*IPC.SendQueue {
    return &(this.ipc_data orelse return null);
}
pub fn getGlobalThis(this: *Subprocess) ?*jsc.JSGlobalObject {
    return this.globalThis;
}

const IPClog = Output.scoped(.IPC, .visible);

pub const TestingAPIs = struct {
    /// Inject a synthetic read error into a subprocess's stdout/stderr
    /// PipeReader, as if the underlying read() syscall (Posix) or libuv read
    /// callback (Windows) had failed with EBADF. Used by tests to exercise
    /// the onReaderError cleanup path, which is otherwise very hard to
    /// trigger deterministically — on Windows in particular, peer death on
    /// a named pipe maps to UV_EOF rather than an error.
    ///
    /// Returns true if an error was injected, false if the given stdio is
    /// not (or no longer) a buffered pipe reader.
    pub fn injectStdioReadError(
        _: bun.bindgen.CallContext(InjectStdioReadErrorSchema),
        args: bun.bindgen.Args(InjectStdioReadErrorSchema),
    ) bun.JSError!bool {
        const subprocess = args.subprocess.get(JSBinding).subprocess.get();
        const out: *Readable = switch (args.stream) {
            .stdout => &subprocess.stdout,
            .stderr => &subprocess.stderr,
        };

        if (out.* != .pipe) return false;
        const pipe = out.pipe;

        // Mirror what the real error path does (onStreamRead on Windows,
        // read() on Posix) so the teardown exercised is identical.
        const fake_err = bun.sys.Error.fromCode(.BADF, .read);
        if (comptime Environment.isWindows) {
            _ = pipe.reader.stopReading();
        }
        pipe.reader.onError(fake_err);
        return true;
    }
};

pub const StdioResult = bun.spawn.process.SpawnProcessResult.StdioResult;

const WritableIntegration = struct {
    pub const ProcessHandle = *Subprocess;
    pub const LoopHandle = *jsc.EventLoop;
    pub const SinkHandle = *jsc.WebCore.FileSink;
    pub const BufferWriterHandle = *StaticPipeWriter;
    pub const Stdio = bun.api.SpawnStdio;

    pub const assertStdioResult = Subprocess.assertStdioResult;

    pub const fdToBindingInt32 = stdioFDToBindingInt32;

    pub fn owner(writable: *Writable) ProcessHandle {
        return @fieldParentPtr("stdin", writable);
    }

    pub fn sinkMemoryCost(sink: SinkHandle) usize {
        return sink.memoryCost();
    }

    pub fn updateSinkRef(sink: SinkHandle, add: bool) void {
        sink.updateRef(add);
    }

    pub fn releaseSink(sink: SinkHandle) void {
        sink.deref();
    }

    pub fn clearStdinSinkReference(process: ProcessHandle) void {
        process.clearStdinSinkReference();
    }

    pub fn stdinDestroyed(process: ProcessHandle) void {
        process.onStdinDestroyed();
    }

    pub fn stdinIsReadableStream(process: ProcessHandle) bool {
        return process.flags.is_stdin_a_readable_stream;
    }

    pub fn createPipe(
        context: anytype,
        stdio: *Stdio,
        event_loop: LoopHandle,
        process: ProcessHandle,
        result: *StdioResult,
        stdin_is_readable_stream: *bool,
    ) bindgen.CallError(@TypeOf(context))!?SinkHandle {
        if (comptime Environment.isWindows) {
            if (result.* != .buffer) return null;
        }

        const pipe = (if (comptime Environment.isWindows)
            jsc.WebCore.FileSink.createWithPipe(event_loop, result.buffer)
        else
            jsc.WebCore.FileSink.create(event_loop)) catch |err| {
            if (stdio.* == .readable_stream) stdio.readable_stream.cancelInStoredRealm();
            return err;
        };
        if (comptime Environment.isWindows) _ = result.take();

        const start_result = if (comptime Environment.isWindows)
            pipe.writer.startWithCurrentPipe()
        else
            pipe.writer.start(result.owned_fd, .{});
        if (start_result.asErr()) |err| {
            pipe.deref();
            if (stdio.* == .readable_stream) stdio.readable_stream.cancelInStoredRealm();
            return context.fail(.system, try bindgen.SystemError.fromSysError(err));
        }
        if (comptime Environment.isPosix) _ = result.take();
        if (comptime Environment.isWindows) pipe.writer.setParent(pipe);

        process.weak_file_sink_stdin_ptr = pipe;
        process.retainStdinLifecycleRef();
        process.flags.has_stdin_destructor_called = false;

        if (stdio.* == .readable_stream) {
            pipe.assignToStream(&stdio.readable_stream, event_loop.global) catch |err| {
                process.weak_file_sink_stdin_ptr = null;
                pipe.deref();
                process.releaseStdinLifecycleRef();
                return err;
            };
            stdin_is_readable_stream.* = true;
        }

        return pipe;
    }

    pub fn createBufferWriter(
        stdio: *Stdio,
        event_loop: LoopHandle,
        process: ProcessHandle,
        result: *StdioResult,
    ) bun.OOM!?BufferWriterHandle {
        if (comptime Environment.isWindows) {
            if (result.* != .buffer) return null;
        } else if (result.* != .owned_fd) return null;
        const source: Source = switch (stdio.*) {
            .blob => source: {
                const blob = stdio.blob;
                stdio.* = .ignore;
                break :source .{ .blob = blob };
            },
            .retained_bytes => source: {
                const bytes = stdio.retained_bytes.take();
                stdio.* = .ignore;
                break :source .{ .retained_bytes = bytes };
            },
            else => unreachable,
        };
        return StaticPipeWriter.create(StaticPipeWriter.Scheduler.init(event_loop), process, result, source);
    }

    fn SinkResult(comptime Context: type) type {
        return @FieldType(bindgen.Return(Context), "sink");
    }

    pub fn takeSinkResult(
        context: anytype,
        process: ProcessHandle,
        pipe: SinkHandle,
    ) bindgen.CallError(@TypeOf(context))!SinkResult(@TypeOf(context)) {
        if (pipe.signal.matches(&process.stdin)) pipe.signal.clear();
        if (process.process.hasExited()) {
            if (!process.flags.has_stdin_destructor_called) {
                pipe.onAttachedProcessExit(&process.process.status);
                process.onStdinDestroyed();
            }
        } else {
            process.flags.has_stdin_destructor_called = false;
            process.weak_file_sink_stdin_ptr = pipe;
            pipe.attachProcessLifecycle(process.takeStdinLifecycleRef() orelse bindgen.RefNative(Subprocess, .vm).init(process));
        }

        var reference = try jsc.WebCore.FileSink.JSSink.createResult(context, pipe);
        bun.assert(process.stdin_sink == null and process.stdin_sink_native.getOptional() == null);
        process.stdin_sink_native = .init(pipe);
        process.stdin_sink = reference.clone();
        return reference.take();
    }

    pub fn finalizeSink(writable: *Writable, pipe: SinkHandle) void {
        if (pipe.signal.matches(writable)) pipe.signal.clear();
        pipe.deref();
    }

    pub fn endSink(pipe: SinkHandle) void {
        _ = pipe.end(null);
    }
};

pub const Writable = @import("./subprocess/Writable.zig").WithIntegration(WritableIntegration);

pub const MaxBuf = bun.io.MaxBuf;
pub const spawnSync = spawn_bindings.spawnSync;
pub const spawn = spawn_bindings.spawn;
pub const spawnFromBinding = spawn_bindings.spawnFromBinding;
pub const BindgenSpawn = spawn_bindings.BindgenSpawn;
pub const BindgenSpawnSync = spawn_bindings.BindgenSpawnSync;

const IPC = @import("../../../jsc/ipc.zig");
const Terminal = @import("./Terminal.zig");
const spawn_bindings = @import("./SpawnBindingsEngine.zig");
const NodeClusterEngine = @import("../../node/NodeClusterEngine.zig");
const std = @import("std");

const bun = @import("bun");
const Async = bun.Async;
const bindgen = bun.bindgen;
const Environment = bun.Environment;
const Output = bun.Output;
const default_allocator = bun.default_allocator;
const webcore = bun.webcore;
const which = bun.which;
const CowString = bun.ptr.CowString;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;

const PosixSpawn = bun.spawn;
const Process = bun.spawn.Process;
const Rusage = bun.spawn.Rusage;

const windows = bun.windows;
const uv = windows.libuv;

const SubprocessBindingModule = bindgen.Module("Subprocess");
const SubprocessSchema = SubprocessBindingModule.class("Subprocess");
pub const SubprocessClass = bindgen.Class(SubprocessSchema, JSBinding);
const FileSinkClassSchema = bindgen.Module("JSSink").class("FileSink");
const SubprocessAsyncDisposeNativeSchema = SubprocessSchema.member("__asyncDispose");
const SubprocessConnectedSchema = SubprocessSchema.member("connected");
const SubprocessDisconnectSchema = SubprocessSchema.member("disconnect");
const SubprocessExitCodeSchema = SubprocessSchema.member("exitCode");
const SubprocessExitedSchema = SubprocessSchema.member("exited");
const SubprocessKillSchema = SubprocessSchema.member("kill");
const SubprocessKilledSchema = SubprocessSchema.member("killed");
const SubprocessPidSchema = SubprocessSchema.member("pid");
const SubprocessReadableSchema = SubprocessSchema.member("readable");
const SubprocessRefSchema = SubprocessSchema.member("ref");
const SubprocessResourceUsageSchema = SubprocessSchema.member("resourceUsage");
const SubprocessSendSchema = SubprocessSchema.member("send");
const SubprocessSignalCodeSchema = SubprocessSchema.member("signalCode");
const SubprocessStderrSchema = SubprocessSchema.member("stderr");
const SubprocessStdinSchema = SubprocessSchema.member("stdin");
const SubprocessStdioSchema = SubprocessSchema.member("stdio");
const SubprocessStdoutSchema = SubprocessSchema.member("stdout");
const SubprocessTerminalSchema = SubprocessSchema.member("terminal");
const SubprocessUnrefSchema = SubprocessSchema.member("unref");
const SubprocessWritableSchema = SubprocessSchema.member("writable");
const SubprocessOnExitSignalCode = @FieldType(bindgen.Args(bindgen.CallbackSchema("SubprocessOnExitCallback")), "signalCode");
pub const OnExitCallbackSlot = SubprocessClass.CachedSlot("onExitCallback");
pub const OnDisconnectCallbackSlot = SubprocessClass.CachedSlot("onDisconnectCallback");
pub const IPCCallbackSlot = SubprocessClass.CachedSlot("ipcCallback");
pub const StdinSlot = SubprocessClass.CachedUnionSlot("stdin");
pub const TerminalSlot = SubprocessClass.CachedClassRefSlot("terminal");

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const InjectStdioReadErrorSchema = InternalTestingBindings.function("injectStdioReadError");
const InjectStdioReadErrorBinding = bun.bindgen.Fn(InjectStdioReadErrorSchema, TestingAPIs.injectStdioReadError);

comptime {
    _ = SubprocessClass;
    _ = InjectStdioReadErrorBinding;
}
