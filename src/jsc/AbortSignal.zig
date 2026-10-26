pub const AbortSignal = opaque {
    pub const Listener = struct {
        const Context = bun.bindgen.NativeCallbackContext(.vm);

        context: Context,
        callback: *const fn (Context, bun.bindgen.EngineValueView) void,

        fn init(ctx: anytype, comptime callback: *const fn (@TypeOf(ctx), bun.bindgen.EngineValueView) void) Listener {
            const Wrapper = struct {
                fn run(context: Context, reason: bun.bindgen.EngineValueView) void {
                    callback(context.get(@TypeOf(ctx)), reason);
                }
            };
            return .{
                .context = .init(ctx),
                .callback = Wrapper.run,
            };
        }

        fn run(this: *Listener, reason: bun.bindgen.EngineValueView) void {
            this.callback(this.context, reason);
        }
    };

    pub fn listen(
        this: *AbortSignal,
        globalObject: *jsc.JSGlobalObject,
        listener: *Listener,
        ctx: anytype,
        comptime callback: *const fn (@TypeOf(ctx), bun.bindgen.EngineValueView) void,
    ) bun.JSError!*AbortSignal {
        listener.* = Listener.init(ctx, callback);
        const registered_signal = bun.bindgen.Engine(AbortSignalAddListenerSchema).call(globalObject, .{
            .signal = @ptrCast(this),
            .listener = @ptrCast(listener),
        }) catch |err| {
            this.removeListener(listener);
            return err;
        };
        return @ptrCast(registered_signal);
    }

    pub fn removeListener(this: *AbortSignal, listener: *Listener) void {
        bun.bindgen.Engine(AbortSignalRemoveListenerSchema).call(.{
            .signal = @ptrCast(this),
            .listener = @ptrCast(listener),
        });
    }

    pub fn signal(
        this: *AbortSignal,
        globalObject: *jsc.JSGlobalObject,
        reason: CommonAbortReason,
    ) void {
        bun.analytics.Features.abort_signal += 1;
        bun.bindgen.Engine(AbortSignalSignalSchema).call(globalObject, .{
            .signal = @ptrCast(this),
            .reason = @backingInt(reason),
        }) catch return;
    }

    pub fn pendingActivityRef(this: *AbortSignal) void {
        bun.bindgen.Engine(AbortSignalIncrementPendingActivitySchema).call(.{ .signal = @ptrCast(this) });
    }

    pub fn pendingActivityUnref(this: *AbortSignal) void {
        bun.bindgen.Engine(AbortSignalDecrementPendingActivitySchema).call(.{ .signal = @ptrCast(this) });
    }

    /// This function is not threadsafe. aborted is a boolean, not an atomic!
    pub fn aborted(this: *AbortSignal) bool {
        return bun.bindgen.Engine(AbortSignalIsAbortedSchema).call(.{ .signal = @ptrCast(this) });
    }

    pub fn abortReasonRoot(this: *AbortSignal, global: *jsc.JSGlobalObject) bun.JSError!bun.bindgen.EngineRoot {
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(global);
        defer scope.deinit();
        var result = try scope.engineIn("abort_signals", "abortSignalReason").call(.{
            .signal = @as(AbortSignalHandle, @ptrCast(this)),
        });
        defer result.deinit();
        return result.toRoot();
    }

    pub fn reasonIfAbortedRoot(this: *AbortSignal, global: *jsc.JSGlobalObject) bun.JSError!?bun.bindgen.EngineRoot {
        if (!this.aborted()) return null;
        return try this.abortReasonRoot(global);
    }

    /// Node's AbortError shape: an `Error` named "AbortError" with code
    /// "ABORT_ERR" whose `cause` is the signal's abort reason. Node-profile
    /// APIs reject with this, never with the raw DOMException in `reason`.
    pub fn wrapAbortErrorRoot(global: *jsc.JSGlobalObject, cause: *const bun.bindgen.EngineRoot) bun.JSError!bun.bindgen.Root {
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(global);
        defer scope.deinit();
        var result = try scope.engineIn("errors", "wrapAbortError").call(.{ .cause = cause.operand(&scope).asEngine() });
        defer result.deinit();
        return result.toRoot();
    }

    pub fn ref(this: *AbortSignal) *AbortSignal {
        return @ptrCast(bun.bindgen.Engine(AbortSignalRefSchema).call(.{ .signal = @ptrCast(this) }));
    }

    pub fn unref(this: *AbortSignal) void {
        bun.bindgen.Engine(AbortSignalUnrefSchema).call(.{ .signal = @ptrCast(this) });
    }

    pub fn deref(this: *AbortSignal) void {
        this.unref();
    }

    pub fn detach(this: *AbortSignal, listener: *Listener) void {
        this.removeListener(listener);
        this.unref();
    }

    pub fn new(global: *JSGlobalObject) *AbortSignal {
        return @ptrCast(bun.bindgen.Engine(AbortSignalNewSchema).call(global, .{}) catch unreachable);
    }

    pub fn timeoutDeadline(this: *AbortSignal) ?bun.timespec {
        const handle = bun.bindgen.Engine(AbortSignalTimeoutSchema).call(.{ .signal = @ptrCast(this) }) orelse return null;
        const timeout: *const Timeout = @ptrCast(@alignCast(handle));
        if (timeout.event_loop_timer.state != .ACTIVE) return null;
        return timeout.event_loop_timer.next;
    }

    pub const Timeout = struct {
        event_loop_timer: jsc.API.Timer.EventLoopTimer,

        // Released by timer teardown, including cancellation without dispatch.
        signal: *AbortSignal,

        /// "epoch" is reused.
        flags: jsc.API.Timer.TimerObjectInternals.Flags = .{},

        /// See `swapGlobalForTestIsolation`: timers from a prior isolated test
        /// file must not fire abort handlers in the new global.
        generation: u32 = 0,

        const new = bun.TrivialNew(Timeout);

        fn init(vm: *jsc.VirtualMachine, signal_: *AbortSignal, milliseconds: u64) *Timeout {
            const this: *Timeout = .new(.{
                .signal = signal_,
                .generation = vm.test_isolation_generation,
                .event_loop_timer = .{
                    .next = bun.timespec.now(.allow_mocked_time).addMs(@intCast(milliseconds)),
                    .tag = .AbortSignalTimeout,
                    .state = .CANCELLED,
                },
            });

            if (comptime bun.Environment.ci_assert) {
                if (signal_.aborted()) {
                    @panic("unreachable: signal is already aborted");
                }
            }

            // We default to not keeping the event loop alive with this timeout.
            vm.timer.insert(&this.event_loop_timer);

            return this;
        }

        fn cancel(this: *Timeout, vm: *jsc.VirtualMachine) void {
            if (this.event_loop_timer.state == .ACTIVE) {
                vm.timer.remove(&this.event_loop_timer);
            }
        }

        pub fn run(this: *Timeout, vm: *jsc.VirtualMachine) void {
            this.event_loop_timer.state = .FIRED;
            const signal_ptr = this.signal.ref();
            defer signal_ptr.unref();
            defer bun.bindgen.Engine(AbortSignalCancelTimeoutSchema).call(.{ .signal = @ptrCast(signal_ptr) });
            const belongs_to_current_global = this.generation == vm.test_isolation_generation;
            if (belongs_to_current_global)
                dispatch(vm, signal_ptr);
        }

        fn dispatch(vm: *jsc.VirtualMachine, signal_ptr: *AbortSignal) void {
            const loop = vm.eventLoop();
            loop.enter();
            defer loop.exit();
            signal_ptr.signal(vm.global, .Timeout);
        }

        // This may run inside the "signal" call.
        fn deinit(this: *Timeout, vm: *jsc.VirtualMachine) void {
            const signal_ptr = this.signal;
            this.cancel(vm);
            bun.destroy(this);
            signal_ptr.unref();
        }

        /// Caller is expected to have already ref'd the AbortSignal.
        fn bindCreate(
            args: bun.bindgen.Args(AbortSignalTimeoutCreateSchema),
        ) bun.bindgen.Return(AbortSignalTimeoutCreateSchema) {
            const vm: *jsc.VirtualMachine = @ptrCast(@alignCast(args.vm));
            const signal_ptr: *AbortSignal = @ptrCast(@alignCast(args.signal));
            return @ptrCast(Timeout.init(vm, signal_ptr, args.milliseconds));
        }

        fn bindDestroy(
            args: bun.bindgen.Args(AbortSignalTimeoutDestroySchema),
        ) bun.bindgen.Return(AbortSignalTimeoutDestroySchema) {
            const this: *Timeout = @ptrCast(@alignCast(args.timeout));
            // Called from cancelTimer(). The AbortSignal's
            // ScriptExecutionContext may be a dead global under --isolate, so
            // we resolve the VM via the threadlocal instead of taking it as a
            // parameter (which the caller would have to dereference the dead
            // context to obtain).
            this.deinit(jsc.VirtualMachine.get());
        }
    };

    fn bindRunListener(
        _: bun.bindgen.CallContext(AbortSignalRunListenerSchema),
        args: bun.bindgen.Args(AbortSignalRunListenerSchema),
    ) bun.bindgen.Return(AbortSignalRunListenerSchema) {
        const listener: *Listener = @ptrCast(@alignCast(args.listener));
        listener.run(args.reason);
    }
};

const bun = @import("bun");
const CommonAbortReason = @import("../http_types/CommonAbortReason.zig").CommonAbortReason;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;

const AbortSignalBindings = bun.bindgen.Module("abort_signals");
const AbortSignalIsAbortedSchema = AbortSignalBindings.engineShim("abortSignalIsAborted");
const AbortSignalAddListenerSchema = AbortSignalBindings.engineShim("abortSignalAddListener");
const AbortSignalReasonSchema = AbortSignalBindings.engineShim("abortSignalReason");
const AbortSignalHandle = bun.bindgen.EngineArgumentType(AbortSignalReasonSchema, "signal");
const AbortSignalTimeoutSchema = AbortSignalBindings.engineShim("abortSignalTimeout");
const AbortSignalCancelTimeoutSchema = AbortSignalBindings.engineShim("abortSignalCancelTimeout");
const AbortSignalRefSchema = AbortSignalBindings.engineShim("abortSignalRef");
const AbortSignalUnrefSchema = AbortSignalBindings.engineShim("abortSignalUnref");
const AbortSignalIncrementPendingActivitySchema = AbortSignalBindings.engineShim("abortSignalIncrementPendingActivity");
const AbortSignalDecrementPendingActivitySchema = AbortSignalBindings.engineShim("abortSignalDecrementPendingActivity");
const AbortSignalNewSchema = AbortSignalBindings.engineShim("abortSignalNew");
const AbortSignalRemoveListenerSchema = AbortSignalBindings.engineShim("abortSignalRemoveListener");
const AbortSignalSignalSchema = AbortSignalBindings.engineShim("abortSignalSignal");
const AbortSignalTimeoutCreateSchema = AbortSignalBindings.nativeExport("abortSignalTimeoutCreate");
const AbortSignalTimeoutDestroySchema = AbortSignalBindings.nativeExport("abortSignalTimeoutDestroy");
const AbortSignalRunListenerSchema = AbortSignalBindings.nativeExport("abortSignalRunListener");
const AbortSignalTimeoutCreateBinding = bun.bindgen.Fn(AbortSignalTimeoutCreateSchema, AbortSignal.Timeout.bindCreate);
const AbortSignalTimeoutDestroyBinding = bun.bindgen.Fn(AbortSignalTimeoutDestroySchema, AbortSignal.Timeout.bindDestroy);
const AbortSignalRunListenerBinding = bun.bindgen.Fn(AbortSignalRunListenerSchema, AbortSignal.bindRunListener);

comptime {
    _ = AbortSignalTimeoutCreateBinding;
    _ = AbortSignalTimeoutDestroyBinding;
    _ = AbortSignalRunListenerBinding;
}
