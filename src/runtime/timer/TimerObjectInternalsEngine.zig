/// Data that TimerObject and ImmediateObject have in common
const TimerObjectInternals = @This();

/// Identifier for this timer that is exposed to JavaScript (by `+timer`)
id: i32 = -1,
interval: u31 = 0,
this_value: bun.bindgen.WrapperReference(.{ TimeoutWrapperSchema, ImmediateWrapperSchema }) = .empty(),
flags: Flags = .{},
/// `bun test --isolate` generation this timer was created in. If it no
/// longer matches `vm.test_isolation_generation` at fire time, the timer
/// is dropped without invoking its callback.
generation: u32 = 0,

/// Used by:
/// - setTimeout
/// - setInterval
/// - setImmediate
/// - AbortSignal.Timeout
pub const Flags = packed struct(u32) {
    /// Whenever a timer is inserted into the heap (which happen on creation or refresh), the global
    /// epoch is incremented and the new epoch is set on the timer. For timers created by
    /// JavaScript, the epoch is used to break ties between timers scheduled for the same
    /// millisecond. This ensures that if you set two timers for the same amount of time, and
    /// refresh the first one, the first one will fire last. This mimics Node.js's behavior where
    /// the refreshed timer will be inserted at the end of a list, which makes it fire later.
    epoch: u25 = 0,

    /// Kind does not include AbortSignal's timeout since it has no corresponding ID callback.
    kind: Kind = .setTimeout,

    // we do not allow the timer to be refreshed after we call clearInterval/clearTimeout
    has_cleared_timer: bool = false,
    is_keeping_event_loop_alive: bool = false,

    // if they never access the timer by integer, don't create a hashmap entry.
    has_accessed_primitive: bool = false,

    has_js_ref: bool = true,

    /// Set to `true` only during execution of the JavaScript function so that `_destroyed` can be
    /// false during the callback, even though the `state` will be `FIRED`.
    in_callback: bool = false,
};

pub fn BindingMethods(comptime Wrapper: type, comptime ClassSchema: type, comptime native_field: []const u8) type {
    return struct {
        const DestroyedSchema = ClassSchema.member("_destroyed");
        const DisposeSchema = ClassSchema.member("dispose");
        const PrimitiveSchema = ClassSchema.member("toPrimitive");
        const RefSchema = ClassSchema.member("ref");
        const UnrefSchema = ClassSchema.member("unref");

        fn internals(this: *Wrapper) *TimerObjectInternals {
            return &@field(this, native_field).get().internals;
        }

        pub fn destroy(this: *Wrapper) void {
            @field(this, native_field).deinit();
            bun.destroy(this);
        }

        pub fn getDestroyed(this: *Wrapper, _: bun.bindgen.CallContext(DestroyedSchema), _: bun.bindgen.Args(DestroyedSchema)) bun.JSError!bool {
            return internals(this).getDestroyed();
        }

        pub fn dispose(this: *Wrapper, _: bun.bindgen.CallContext(DisposeSchema), _: bun.bindgen.Args(DisposeSchema)) bun.JSError!void {
            try internals(this).cancel(VirtualMachine.get());
        }

        pub fn toPrimitive(this: *Wrapper, _: bun.bindgen.CallContext(PrimitiveSchema), _: bun.bindgen.Args(PrimitiveSchema)) bun.JSError!i32 {
            return internals(this).toPrimitive();
        }

        pub fn doRef(this: *Wrapper, _: bun.bindgen.CallContext(RefSchema), args: bun.bindgen.Args(RefSchema)) bun.JSError!bun.bindgen.Return(RefSchema) {
            internals(this).doRef(VirtualMachine.get());
            return args.bindingThis.toOwned();
        }

        pub fn doUnref(this: *Wrapper, _: bun.bindgen.CallContext(UnrefSchema), args: bun.bindgen.Args(UnrefSchema)) bun.JSError!bun.bindgen.Return(UnrefSchema) {
            internals(this).doUnref(VirtualMachine.get());
            return args.bindingThis.toOwned();
        }
    };
}

fn eventLoopTimer(this: *TimerObjectInternals) *EventLoopTimer {
    switch (this.flags.kind) {
        .setImmediate => {
            const parent: *ImmediateObject = @fieldParentPtr("internals", this);
            assert(parent.event_loop_timer.tag == .ImmediateObject);
            return &parent.event_loop_timer;
        },
        .setTimeout, .setInterval => {
            const parent: *TimeoutObject = @fieldParentPtr("internals", this);
            assert(parent.event_loop_timer.tag == .TimeoutObject);
            return &parent.event_loop_timer;
        },
    }
}

fn ref(this: *TimerObjectInternals) void {
    switch (this.flags.kind) {
        .setImmediate => @as(*ImmediateObject, @fieldParentPtr("internals", this)).ref(),
        .setTimeout, .setInterval => @as(*TimeoutObject, @fieldParentPtr("internals", this)).ref(),
    }
}

fn deref(this: *TimerObjectInternals) void {
    switch (this.flags.kind) {
        .setImmediate => @as(*ImmediateObject, @fieldParentPtr("internals", this)).deref(),
        .setTimeout, .setInterval => @as(*TimeoutObject, @fieldParentPtr("internals", this)).deref(),
    }
}

/// returns true if an exception was thrown
pub fn runImmediateTask(this: *TimerObjectInternals, vm: *VirtualMachine) bool {
    const exception_thrown = dispatch: {
        var timer = (this.this_value.toOwnedClassRef(ImmediateWrapperSchema) catch |err| {
            this.releaseUnavailableTimer(vm);
            vm.global.reportActiveExceptionAsUnhandled(err);
            return true;
        }) orelse {
            this.releaseUnavailableTimer(vm);
            return false;
        };
        defer timer.deinit();

        if (this.flags.has_cleared_timer or
            this.generation != vm.test_isolation_generation or
            // unref'd setImmediate callbacks should only run if there are things keeping the event
            // loop alive other than setImmediates
            (!this.flags.is_keeping_event_loop_alive and !vm.isEventLoopAliveExcludingImmediates()))
        {
            clearCallbackData(ImmediateWrapperSchema, &timer);
            this.releaseUnavailableTimer(vm);
            return false;
        }

        this.this_value.downgrade();
        this.eventLoopTimer().state = .FIRED;
        this.setEnableKeepingEventLoopAlive(vm, false);

        vm.eventLoop().enter();

        this.ref();
        defer {
            if (this.eventLoopTimer().state == .FIRED) {
                this.deref();
            }
            this.deref();
        }
        break :dispatch this.invokeCallback(ImmediateWrapperSchema, &timer, this.asyncID(), vm, false);
    };
    vm.eventLoop().exitMaybeDrainMicrotasks(!exception_thrown) catch return true;

    return exception_thrown;
}

pub fn asyncID(this: *const TimerObjectInternals) u64 {
    return ID.asyncID(.{ .id = this.id, .kind = this.flags.kind });
}

pub fn fire(this: *TimerObjectInternals, _: *const timespec, vm: *jsc.VirtualMachine) void {
    const id = this.id;
    const kind = this.flags.kind;
    const async_id: ID = .{ .id = id, .kind = kind };
    const has_been_cleared = this.eventLoopTimer().state == .CANCELLED or this.flags.has_cleared_timer or vm.scriptExecutionStatus() != .running or this.generation != vm.test_isolation_generation;

    this.eventLoopTimer().state = .FIRED;
    const dispatched = switch (kind == .setImmediate) {
        inline else => |immediate| dispatch: {
            const ClassSchema = if (immediate) ImmediateWrapperSchema else TimeoutWrapperSchema;
            var timer = (this.this_value.toOwnedClassRef(ClassSchema) catch |err| {
                this.releaseUnavailableTimer(vm);
                return vm.global.reportActiveExceptionAsUnhandled(err);
            }) orelse
                return this.releaseUnavailableTimer(vm);
            defer timer.deinit();
            break :dispatch this.fireWithReference(ClassSchema, &timer, kind, has_been_cleared, async_id, vm);
        },
    };
    if (dispatched) vm.eventLoop().exit();
}

const PostDispatchOutcome = struct {
    should_reschedule: bool,
    convert_to_interval: bool,
    repeat_interval: u31,
};

fn invokeCallback(
    this: *TimerObjectInternals,
    comptime ClassSchema: type,
    timer: *const bun.bindgen.ClassRef(ClassSchema),
    async_id: u64,
    vm: *VirtualMachine,
    is_sleep: bool,
) bool {
    const global = vm.global;
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(vm.global);
    defer scope.deinit();

    defer if (comptime ClassSchema == ImmediateWrapperSchema) {
        this.flags.has_cleared_timer = true;
        this.setEnableKeepingEventLoopAlive(vm, false);
    };
    if (vm.isInspectorEnabled()) Debugger.willDispatchAsyncCall(global, .DOMTimer, async_id);
    defer if (vm.isInspectorEnabled()) Debugger.didDispatchAsyncCall(global, .DOMTimer, async_id);

    this.flags.in_callback = true;
    defer this.flags.in_callback = false;
    if (comptime ClassSchema == ImmediateWrapperSchema) {
        defer clearCallbackData(ClassSchema, timer);
        return scope.engine(TimerInvokeImmediateCallbackSchema).call(.{
            .timer = timer.operand(&scope),
        }) catch true;
    }
    if (is_sleep) {
        const timeout: *TimeoutObject = @fieldParentPtr("internals", this);
        var completion = timeout.takeSleepCompletion() orelse @panic("sleep timer lost its completion");
        completion.resolve({});
        return false;
    }
    return scope.engine(TimerInvokeTimeoutCallbackSchema).call(.{
        .timer = timer.operand(&scope),
    }) catch true;
}

fn timeoutPostDispatch(
    timer: *const bun.bindgen.ClassRef(TimeoutWrapperSchema),
    is_interval: bool,
    vm: *VirtualMachine,
) PostDispatchOutcome {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(vm.global);
    defer scope.deinit();

    const result = scope.engine(TimerTimeoutPostDispatchSchema).call(.{
        .timer = timer.operand(&scope),
        .isInterval = is_interval,
    });
    return .{
        .should_reschedule = result.shouldReschedule,
        .convert_to_interval = result.convertToInterval,
        .repeat_interval = @intCast(result.repeatInterval),
    };
}

fn callbackPresent(
    comptime ClassSchema: type,
    timer: *const bun.bindgen.ClassRef(ClassSchema),
    vm: *VirtualMachine,
) bool {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(vm.global);
    defer scope.deinit();

    if (comptime ClassSchema == ImmediateWrapperSchema) {
        return scope.engine(TimerImmediateCallbackPresentSchema).call(.{ .timer = timer.operand(&scope) });
    }
    return scope.engine(TimerTimeoutCallbackPresentSchema).call(.{ .timer = timer.operand(&scope) });
}

/// The caller releases its dispatch root before exiting the entered event loop.
fn fireWithReference(
    this: *TimerObjectInternals,
    comptime ClassSchema: type,
    timer: *const bun.bindgen.ClassRef(ClassSchema),
    kind: Kind,
    has_been_cleared: bool,
    async_id: ID,
    vm: *VirtualMachine,
) bool {
    const global = vm.global;
    const is_sleep = if (comptime ClassSchema == TimeoutWrapperSchema)
        @as(*TimeoutObject, @fieldParentPtr("internals", this)).hasSleepCompletion()
    else
        false;
    if (has_been_cleared or (!is_sleep and !callbackPresent(ClassSchema, timer, vm))) {
        if (vm.isInspectorEnabled()) Debugger.didCancelAsyncCall(global, .DOMTimer, ID.asyncID(async_id));
        clearCallbackData(ClassSchema, timer);
        this.releaseUnavailableTimer(vm);
        return false;
    }

    var time_before_call: timespec = undefined;
    if (kind == .setInterval) {
        time_before_call = timespec.msFromNow(.allow_mocked_time, this.interval);
    } else {
        this.this_value.downgrade();
    }

    vm.eventLoop().enter();

    this.ref();
    defer this.deref();

    _ = this.invokeCallback(ClassSchema, timer, ID.asyncID(async_id), vm, is_sleep);
    const default_outcome = PostDispatchOutcome{
        .should_reschedule = false,
        .convert_to_interval = false,
        .repeat_interval = 1,
    };
    const outcome = if (comptime ClassSchema == TimeoutWrapperSchema)
        if (is_sleep or this.flags.has_cleared_timer) default_outcome else timeoutPostDispatch(timer, kind == .setInterval, vm)
    else
        default_outcome;

    const is_timer_done = done: {
        if (kind == .setInterval) {
            if (!outcome.should_reschedule) break :done true;
            switch (this.eventLoopTimer().state) {
                .FIRED => {
                    vm.timer.update(this.eventLoopTimer(), &time_before_call);
                    if (this.flags.has_js_ref) this.setEnableKeepingEventLoopAlive(vm, true);
                },
                .ACTIVE => {
                    vm.timer.update(this.eventLoopTimer(), &time_before_call);
                    this.deref();
                },
                else => break :done true,
            }
        } else {
            if (kind == .setTimeout and outcome.convert_to_interval) {
                this.convertToInterval(timer, outcome.repeat_interval, outcome.should_reschedule, vm);
            }
            switch (this.eventLoopTimer().state) {
                .FIRED => break :done true,
                .ACTIVE => this.deref(),
                else => break :done true,
            }
        }
        break :done false;
    };

    if (is_timer_done) {
        this.this_value.downgrade();
        this.setEnableKeepingEventLoopAlive(vm, false);
        this.deref();
    }
    return true;
}

fn releaseUnavailableTimer(this: *TimerObjectInternals, vm: *VirtualMachine) void {
    this.setEnableKeepingEventLoopAlive(vm, false);
    this.flags.has_cleared_timer = true;
    this.this_value.downgrade();
    this.deref();
}

fn convertToInterval(
    this: *TimerObjectInternals,
    timer: *const bun.bindgen.ClassRef(TimeoutWrapperSchema),
    repeat_interval: u31,
    should_reschedule: bool,
    vm: *VirtualMachine,
) void {
    bun.debugAssert(this.flags.kind == .setTimeout);
    this.flags.kind = .setInterval;
    this.interval = repeat_interval;
    if (!should_reschedule) return;

    this.this_value.setStrongRef(timer) catch |err| return vm.global.reportActiveExceptionAsUnhandled(err);

    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(vm.global);
    defer scope.deinit();
    const now = timespec.now(.allow_mocked_time);
    const prepared = scope.engine(TimerPrepareRescheduleSchema).call(.{
        .timer = timer.operand(&scope),
        .isInterval = true,
        .idleStart = now.msUnsigned(),
    });
    if (prepared) {
        this.rescheduleAt(vm, now);
    } else {
        this.this_value.downgrade();
    }
}

pub fn init(
    this: *TimerObjectInternals,
    context: anytype,
    comptime ClassSchema: type,
    timer: *const bun.bindgen.ClassRef(ClassSchema),
    global: *JSGlobalObject,
    id: i32,
    kind: Kind,
    interval: u31,
    rest_arguments: ?bun.bindgen.AnyRestView,
) bun.JSError!void {
    const vm = global.bunVM();
    this.* = .{
        .id = id,
        .flags = .{ .kind = kind, .epoch = vm.timer.epoch },
        .interval = interval,
        .generation = vm.test_isolation_generation,
    };

    const argument_count = if (rest_arguments) |rest| rest.length() else 0;
    const operation = if (comptime ClassSchema == ImmediateWrapperSchema)
        context.engineIn("timers", "timerInitializeImmediate")
    else if (comptime ClassSchema == TimeoutWrapperSchema)
        context.engineIn("timers", "timerInitializeTimeout")
    else
        @compileError("timer internals require a Timeout or Immediate class reference");
    const Argument = @typeInfo(@FieldType(@TypeOf(operation).Args, "arguments")).pointer.child;
    var inline_arguments: [8]Argument = undefined;
    const arguments = if (argument_count <= inline_arguments.len)
        inline_arguments[0..argument_count]
    else
        try bun.default_allocator.alloc(Argument, argument_count);
    defer if (arguments.ptr != inline_arguments[0..].ptr) bun.default_allocator.free(arguments);
    for (arguments, 0..) |*argument, index| argument.* = rest_arguments.?.at(index).?.operand(context);

    if (comptime ClassSchema == ImmediateWrapperSchema) {
        try operation.call(.{
            .timer = timer.operand(context),
            .arguments = arguments,
        });
    } else if (comptime ClassSchema == TimeoutWrapperSchema) {
        try operation.call(.{
            .timer = timer.operand(context),
            .interval = interval,
            .repeats = kind == .setInterval,
            .arguments = arguments,
        });
    } else @compileError("timer internals require a Timeout or Immediate class reference");

    this.this_value = try bun.bindgen.WrapperReference(.{ TimeoutWrapperSchema, ImmediateWrapperSchema })
        .initStrongRef(timer);

    if (comptime ClassSchema == ImmediateWrapperSchema) {
        assert(kind == .setImmediate);
        const parent: *ImmediateObject = @fieldParentPtr("internals", this);
        vm.enqueueImmediateTask(parent);
        this.setEnableKeepingEventLoopAlive(vm, true);
        parent.ref();
    } else if (comptime ClassSchema == TimeoutWrapperSchema) {
        assert(kind != .setImmediate);
        const now = timespec.now(.allow_mocked_time);
        if (context.engineIn("timers", "timerPrepareReschedule").call(.{
            .timer = timer.operand(context),
            .isInterval = kind == .setInterval,
            .idleStart = now.msUnsigned(),
        })) {
            this.rescheduleAt(vm, now);
        }
    } else @compileError("timer internals require a Timeout or Immediate class reference");
    if (vm.isInspectorEnabled()) {
        Debugger.didScheduleAsyncCall(global, .DOMTimer, ID.asyncID(.{ .id = id, .kind = kind }), kind != .setInterval);
    }

}

pub fn doRef(this: *TimerObjectInternals, vm: *VirtualMachine) void {
    const did_have_js_ref = this.flags.has_js_ref;
    this.flags.has_js_ref = true;

    const scheduled = switch (this.eventLoopTimer().state) {
        .ACTIVE, .PENDING => !this.flags.has_cleared_timer,
        .FIRED, .CANCELLED => false,
    };
    if (!did_have_js_ref and scheduled) {
        this.setEnableKeepingEventLoopAlive(vm, true);
    }
}

pub fn canRefresh(this: *const TimerObjectInternals) bool {
    assert(this.flags.kind != .setImmediate);
    if (this.id == -1 or this.flags.kind == .setImmediate or this.flags.has_cleared_timer) {
        return false;
    }
    return true;
}

pub fn rescheduleFromRefresh(
    this: *TimerObjectInternals,
    timer: bun.bindgen.ClassRefView(TimeoutWrapperSchema),
    vm: *VirtualMachine,
    now: timespec,
) bun.JSError!void {
    try this.this_value.setStrongClassView(TimeoutWrapperSchema, timer);
    this.rescheduleAt(vm, now);
}

pub fn isInterval(this: *const TimerObjectInternals) bool {
    return this.flags.kind == .setInterval;
}

pub fn doUnref(this: *TimerObjectInternals, vm: *VirtualMachine) void {
    const did_have_js_ref = this.flags.has_js_ref;
    this.flags.has_js_ref = false;

    if (did_have_js_ref) {
        this.setEnableKeepingEventLoopAlive(vm, false);
    }
}

fn clearCallbackData(comptime ClassSchema: type, timer: *const bun.bindgen.ClassRef(ClassSchema)) void {
    const Binding = if (ClassSchema == TimeoutWrapperSchema) TimeoutObject.JSBinding else ImmediateObject.JSBinding;
    const Class = bun.bindgen.Class(ClassSchema, Binding);
    Class.CachedSlotInvalidator("callback").clearOwned(timer);
    Class.CachedSlotInvalidator("arguments").clearOwned(timer);
}

pub fn cancel(this: *TimerObjectInternals, vm: *VirtualMachine) bun.JSError!void {
    this.ref();
    defer this.deref();
    switch (this.flags.kind) {
        .setImmediate => {
            if (try this.this_value.toOwnedClassRef(ImmediateWrapperSchema)) |owned| {
                var timer = owned;
                defer timer.deinit();
                clearCallbackData(ImmediateWrapperSchema, &timer);
            }
        },
        .setTimeout, .setInterval => {
            if (try this.this_value.toOwnedClassRef(TimeoutWrapperSchema)) |owned| {
                var timer = owned;
                defer timer.deinit();
                clearCallbackData(TimeoutWrapperSchema, &timer);
            }
        },
    }
    this.setEnableKeepingEventLoopAlive(vm, false);
    this.flags.has_cleared_timer = true;

    if (this.flags.has_accessed_primitive) {
        _ = vm.timer.maps.get(this.flags.kind).orderedRemove(this.id);
    }

    if (this.flags.kind == .setImmediate) {
        // Release the strong reference so the GC can collect the JS object.
        // The immediate task is still in the event loop queue and will be skipped
        // by runImmediateTask when it sees has_cleared_timer == true.
        this.this_value.downgrade();
        return;
    }

    const was_active = this.eventLoopTimer().state == .ACTIVE;

    this.eventLoopTimer().state = .CANCELLED;
    this.this_value.downgrade();

    if (was_active) {
        vm.timer.remove(this.eventLoopTimer());
        this.deref();
    }
}

pub fn rescheduleAt(this: *TimerObjectInternals, vm: *VirtualMachine, now: timespec) void {
    assert(this.flags.kind != .setImmediate);
    const scheduled_time = now.addMs(this.interval);
    const was_active = this.eventLoopTimer().state == .ACTIVE;
    if (was_active) {
        vm.timer.remove(this.eventLoopTimer());
    } else {
        this.ref();
    }

    vm.timer.update(this.eventLoopTimer(), &scheduled_time);
    this.flags.has_cleared_timer = false;

    if (this.flags.has_js_ref) {
        this.setEnableKeepingEventLoopAlive(vm, true);
    }
}

fn setEnableKeepingEventLoopAlive(this: *TimerObjectInternals, vm: *VirtualMachine, enable: bool) void {
    if (this.flags.is_keeping_event_loop_alive == enable) {
        return;
    }
    this.flags.is_keeping_event_loop_alive = enable;
    switch (this.flags.kind) {
        .setTimeout, .setInterval => vm.timer.incrementTimerRef(if (enable) 1 else -1),

        // setImmediate has slightly different event loop logic
        .setImmediate => vm.timer.incrementImmediateRef(if (enable) 1 else -1),
    }
}

pub fn toPrimitive(this: *TimerObjectInternals) bun.JSError!i32 {
    if (!this.flags.has_accessed_primitive) {
        this.flags.has_accessed_primitive = true;
        const vm = VirtualMachine.get();
        try vm.timer.maps.get(this.flags.kind).put(bun.default_allocator, this.id, this.eventLoopTimer());
    }
    return this.id;
}

/// This is the getter for `_destroyed` on JS Timeout and Immediate objects
pub fn getDestroyed(this: *TimerObjectInternals) bool {
    if (this.flags.has_cleared_timer) {
        return true;
    }
    if (this.flags.in_callback) {
        return false;
    }
    return switch (this.eventLoopTimer().state) {
        .ACTIVE, .PENDING => false,
        .FIRED, .CANCELLED => true,
    };
}

pub fn finalize(this: *TimerObjectInternals) void {
    this.this_value.finalize();
    this.deref();
}

pub fn deinit(this: *TimerObjectInternals) void {
    this.this_value.deinit();
    const vm = VirtualMachine.get();
    const kind = this.flags.kind;

    if (this.eventLoopTimer().state == .ACTIVE) {
        vm.timer.remove(this.eventLoopTimer());
    }

    if (this.flags.has_accessed_primitive) {
        const map = vm.timer.maps.get(kind);
        if (map.orderedRemove(this.id)) {
            // If this array gets large, let's shrink it down
            // Array keys are i32
            // Values are 1 ptr
            // Therefore, 12 bytes per entry
            // So if you created 21,000 timers and accessed them by ID, you'd be using 252KB
            const allocated_bytes = map.capacity() * @sizeOf(TimeoutMap.Data);
            const used_bytes = map.count() * @sizeOf(TimeoutMap.Data);
            if (allocated_bytes - used_bytes > 256 * 1024) {
                map.shrinkAndFree(bun.default_allocator, map.count() + 8);
            }
        }
    }

    this.setEnableKeepingEventLoopAlive(vm, false);
    switch (kind) {
        .setImmediate => (@as(*ImmediateObject, @fieldParentPtr("internals", this))).ref_count.assertNoRefs(),
        .setTimeout, .setInterval => (@as(*TimeoutObject, @fieldParentPtr("internals", this))).ref_count.assertNoRefs(),
    }
}

const Debugger = @import("../../jsc/Debugger.zig");

const bun = @import("bun");
const assert = bun.assert;
const timespec = bun.timespec;

const Timer = bun.api.Timer;
const EventLoopTimer = Timer.EventLoopTimer;
const ID = Timer.ID;
const ImmediateObject = Timer.ImmediateObject;
const Kind = Timer.Kind;
const TimeoutMap = Timer.TimeoutMap;
const TimeoutObject = Timer.TimeoutObject;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const VirtualMachine = jsc.VirtualMachine;
const TimerBindings = bun.bindgen.Module("timers");
const TimerPrepareRescheduleSchema = TimerBindings.engineShim("timerPrepareReschedule");
const TimerTimeoutCallbackPresentSchema = TimerBindings.engineShim("timerTimeoutCallbackPresent");
const TimerImmediateCallbackPresentSchema = TimerBindings.engineShim("timerImmediateCallbackPresent");
const TimerInvokeTimeoutCallbackSchema = TimerBindings.engineShim("timerInvokeTimeoutCallback");
const TimerTimeoutPostDispatchSchema = TimerBindings.engineShim("timerTimeoutPostDispatch");
const TimerInvokeImmediateCallbackSchema = TimerBindings.engineShim("timerInvokeImmediateCallback");
const TimeoutWrapperSchema = bun.bindgen.Module("Timeout").class("Timeout");
const ImmediateWrapperSchema = bun.bindgen.Module("Immediate").class("Immediate");
