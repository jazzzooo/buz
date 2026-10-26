const TimerDomain = @import("./Timer.zig");

pub const EventLoopTimer = TimerDomain.EventLoopTimer;
pub const TimeoutMap = TimerDomain.TimeoutMap;
pub const Kind = TimerDomain.Kind;
pub const ID = TimerDomain.ID;

pub const TimerHeap = heap.Intrusive(EventLoopTimer, void, EventLoopTimerEngine.less);

pub const All = struct {
    last_id: i32 = 1,
    io: std.Io,
    lock: std.Io.Mutex = .init,
    thread_id: std.Thread.Id,
    timers: TimerHeap = .{ .context = {} },
    active_timer_count: i32 = 0,
    uv_timer: if (Environment.isWindows) uv.Timer else void = if (Environment.isWindows) std.mem.zeroes(uv.Timer),
    /// Whether we have emitted a warning for passing a negative timeout duration
    warned_negative_number: bool = false,
    /// Whether we have emitted a warning for passing NaN for the timeout duration
    warned_not_number: bool = false,
    /// Incremented when timers are scheduled or rescheduled. See doc comment on
    /// TimerObjectInternals.epoch.
    epoch: u25 = 0,
    immediate_ref_count: i32 = 0,
    uv_idle: if (Environment.isWindows) uv.uv_idle_t else void = if (Environment.isWindows) std.mem.zeroes(uv.uv_idle_t),

    // Event loop delay monitoring (not exposed to JS)
    event_loop_delay: EventLoopDelayMonitor = .{},

    fake_timers: FakeTimers = .{},

    // We split up the map here to avoid storing an extra "repeat" boolean
    maps: struct {
        setTimeout: TimeoutMap = .empty,
        setInterval: TimeoutMap = .empty,
        setImmediate: TimeoutMap = .empty,

        pub inline fn get(this: *@This(), kind: Kind) *TimeoutMap {
            return switch (kind) {
                .setTimeout => &this.setTimeout,
                .setInterval => &this.setInterval,
                .setImmediate => &this.setImmediate,
            };
        }
    } = .{},

    /// Updates the "Date" header.
    date_header_timer: DateHeaderTimer = .{},

    pub fn init(io: std.Io) @This() {
        return .{
            .io = io,
            .thread_id = std.Thread.getCurrentId(),
        };
    }

    pub fn insert(this: *All, timer: *EventLoopTimer) void {
        this.lock.lockUncancelable(this.io);
        defer this.lock.unlock(this.io);
        this.insertLockHeld(timer);
    }

    fn insertLockHeld(this: *All, timer: *EventLoopTimer) void {
        if (Environment.ci_assert) bun.assert(this.lock.tryLock() == false);
        if (this.fake_timers.isActive() and timer.tag.allowFakeTimers()) {
            this.fake_timers.timers.insert(timer);
            timer.state = .ACTIVE;
            timer.in_heap = .fake;
        } else {
            this.timers.insert(timer);
            timer.state = .ACTIVE;
            timer.in_heap = .regular;

            if (Environment.isWindows) {
                this.ensureUVTimer(@alignCast(@fieldParentPtr("timer", this)));
            }
        }
    }

    pub fn remove(this: *All, timer: *EventLoopTimer) void {
        this.lock.lockUncancelable(this.io);
        defer this.lock.unlock(this.io);
        this.removeLockHeld(timer);
    }
    fn removeLockHeld(this: *All, timer: *EventLoopTimer) void {
        if (Environment.ci_assert) bun.assert(this.lock.tryLock() == false);
        switch (timer.in_heap) {
            .none => if (Environment.ci_assert) bun.assert(false), // can't remove a timer that was not inserted
            .regular => this.timers.remove(timer),
            .fake => this.fake_timers.timers.remove(timer),
        }
        timer.in_heap = .none;
        timer.state = .CANCELLED;
    }

    /// Remove the EventLoopTimer if necessary.
    pub fn update(this: *All, timer: *EventLoopTimer, time: *const timespec) void {
        this.lock.lockUncancelable(this.io);
        defer this.lock.unlock(this.io);
        if (timer.state == .ACTIVE) {
            this.removeLockHeld(timer);
        }

        if (Environment.ci_assert) {
            if (&timer.next == time) {
                @panic("timer.next == time. For threadsafety reasons, time and timer.next must always be a different pointer.");
            }
        }

        timer.next = time.*;
        if (EventLoopTimerEngine.jsTimerInternalsFlags(timer)) |flags| {
            this.epoch +%= 1;
            flags.epoch = this.epoch;
        }

        this.insertLockHeld(timer);
    }

    fn ensureUVTimer(this: *All, vm: *VirtualMachine) void {
        if (this.uv_timer.data == null) {
            this.uv_timer.init(vm.uvLoop());
            this.uv_timer.data = vm;
            this.uv_timer.unref();
        }

        if (this.timers.peek()) |timer| {
            uv.uv_update_time(vm.uvLoop());
            const now = timespec.now(.force_real_time);
            const wait = if (timer.next.greater(&now))
                timer.next.duration(&now)
            else
                timespec{ .nsec = 0, .sec = 0 };

            // minimum 1ms
            // https://github.com/nodejs/node/blob/f552c86fecd6c2ba9e832ea129b731dd63abdbe2/src/env.cc#L1512
            const wait_ms = @max(1, wait.msUnsigned());

            this.uv_timer.start(wait_ms, 0, &onUVTimer);

            if (this.active_timer_count > 0) {
                this.uv_timer.ref();
            } else {
                this.uv_timer.unref();
            }
        }
    }

    pub fn onUVTimer(uv_timer_t: *uv.Timer) callconv(.c) void {
        const all: *All = @fieldParentPtr("uv_timer", uv_timer_t);
        const vm: *VirtualMachine = @alignCast(@fieldParentPtr("timer", all));
        all.drainTimers(vm);
        all.ensureUVTimer(vm);
    }

    pub fn incrementImmediateRef(this: *All, delta: i32) void {
        const old = this.immediate_ref_count;
        const new = old + delta;
        this.immediate_ref_count = new;
        const vm: *VirtualMachine = @alignCast(@fieldParentPtr("timer", this));

        if (old <= 0 and new > 0) {
            if (comptime Environment.isWindows) {
                if (this.uv_idle.data == null) {
                    this.uv_idle.init(uv.Loop.get());
                    this.uv_idle.data = vm;
                }

                // Matches Node.js behavior
                this.uv_idle.start(struct {
                    fn cb(_: *uv.uv_idle_t) callconv(.c) void {
                        // prevent libuv from polling forever
                    }
                }.cb);
            } else {
                vm.uwsLoop().ref();
            }
        } else if (old > 0 and new <= 0) {
            if (comptime Environment.isWindows) {
                if (this.uv_idle.data != null) {
                    this.uv_idle.stop();
                }
            } else {
                vm.uwsLoop().unref();
            }
        }
    }

    pub fn incrementTimerRef(this: *All, delta: i32) void {
        const vm: *jsc.VirtualMachine = @alignCast(@fieldParentPtr("timer", this));

        const old = this.active_timer_count;
        const new = old + delta;

        if (comptime Environment.isDebug) {
            assert(new >= 0);
        }

        this.active_timer_count = new;

        if (old <= 0 and new > 0) {
            if (comptime Environment.isWindows) {
                this.uv_timer.ref();
            } else {
                vm.uwsLoop().ref();
            }
        } else if (old > 0 and new <= 0) {
            if (comptime Environment.isWindows) {
                this.uv_timer.unref();
            } else {
                vm.uwsLoop().unref();
            }
        }
    }

    fn isDateTimerActive(this: *const All) bool {
        return this.date_header_timer.event_loop_timer.state == .ACTIVE;
    }

    pub fn updateDateHeaderTimerIfNecessary(this: *All, loop: *const uws.Loop, vm: *VirtualMachine) void {
        if (loop.shouldEnableDateHeaderTimer()) {
            if (!this.isDateTimerActive()) {
                this.date_header_timer.enable(
                    vm,
                    // Be careful to avoid adding extra calls to bun.timespec.now()
                    // when it's not needed.
                    &bun.timespec.now(.allow_mocked_time),
                );
            }
        } else {
            // don't un-schedule it here.
            // it's better to wake up an extra 1 time after a second idle
            // than to have to check a date potentially on every single HTTP request.
        }
    }

    pub fn getTimeout(this: *All, spec: *timespec, vm: *VirtualMachine) bool {
        // On POSIX, if there are pending immediate tasks, use a zero timeout
        // so epoll/kqueue returns immediately without the overhead of writing
        // to the eventfd via wakeup().
        if (comptime Environment.isPosix) {
            if (vm.event_loop.immediate_tasks.items.len > 0) {
                spec.* = .{ .nsec = 0, .sec = 0 };
                return true;
            }
        }

        // lsquic's earliest_adv_tick (set by us_quic_loop_process from
        // loop_post). Folded into the epoll timeout instead of arming a
        // timerfd, so scheduling is free.
        const quic_us: ?i64 = if (comptime Environment.isPosix) us: {
            const loop = vm.event_loop_handle orelse break :us null;
            if (loop.internal_loop_data.quic_head == null) break :us null;
            break :us loop.internal_loop_data.quic_next_tick_us;
        } else null;

        var maybe_now: ?timespec = null;
        while (this.timers.peek()) |min| {
            const now = maybe_now orelse now: {
                const real_now = timespec.now(.force_real_time);
                maybe_now = real_now;
                break :now real_now;
            };

            switch (now.order(&min.next)) {
                .gt, .eq => {
                    // Side-effect: potentially call the StopIfNecessary timer.
                    if (min.tag == .WTFTimer) {
                        _ = this.timers.deleteMin();
                        min.in_heap = .none;
                        EventLoopTimerEngine.fire(min, &now, vm);
                        continue;
                    }

                    spec.* = .{ .nsec = 0, .sec = 0 };
                    return true;
                },
                .lt => {
                    spec.* = min.next.duration(&now);
                    if (quic_us) |us| if (us >= 0) clampToQuic(spec, us);
                    return true;
                },
            }
        }

        if (quic_us) |us| if (us >= 0) {
            spec.* = .{
                .sec = @intCast(@divTrunc(us, std.time.us_per_s)),
                .nsec = @intCast(@mod(us, std.time.us_per_s) * std.time.ns_per_us),
            };
            return true;
        };
        return false;
    }

    fn clampToQuic(spec: *timespec, us: i64) void {
        const cur_us = @as(i64, spec.sec) * std.time.us_per_s + @divTrunc(spec.nsec, std.time.ns_per_us);
        if (us < cur_us) spec.* = .{
            .sec = @intCast(@divTrunc(us, std.time.us_per_s)),
            .nsec = @intCast(@mod(us, std.time.us_per_s) * std.time.ns_per_us),
        };
    }

    // Getting the current time is expensive on certain platforms.
    // We don't want to call it when there are no timers.
    // And when we do call it, we want to be sure we only call it once.
    // and we do NOT want to hold the lock while the timer is running it's code.
    // This function has to be thread-safe.
    fn next(this: *All, has_set_now: *bool, now: *timespec) ?*EventLoopTimer {
        this.lock.lockUncancelable(this.io);
        defer this.lock.unlock(this.io);

        if (this.timers.peek()) |timer| {
            if (!has_set_now.*) {
                now.* = timespec.now(.force_real_time);
                has_set_now.* = true;
            }
            if (timer.next.greater(now)) {
                return null;
            }

            assert(this.timers.deleteMin().? == timer);
            timer.in_heap = .none;

            return timer;
        }
        return null;
    }

    pub fn drainTimers(this: *All, vm: *VirtualMachine) void {
        // Set in next().
        var now: timespec = undefined;
        // Split into a separate variable to avoid increasing the size of the timespec type.
        var has_set_now: bool = false;

        while (this.next(&has_set_now, &now)) |t| {
            EventLoopTimerEngine.fire(t, &now, vm);
        }
    }

    const TimeoutWarning = @FieldType(bun.bindgen.Args(EmitCountdownWarningSchema), "kind");

    fn warnInvalidCountdown(context: anytype, countdown: f64, warning_type: TimeoutWarning) JSError!void {
        try context.engineIn("timers", "emitCountdownWarning").call(.{
            .countdown = countdown,
            .kind = warning_type,
        });
    }

    fn countdownMilliseconds(
        this: *All,
        context: anytype,
        countdown: Countdown,
    ) JSError!u31 {
        const countdown_double = countdown;
        if (!(countdown_double >= 1 and countdown_double <= std.math.maxInt(u31))) {
            if (countdown_double > std.math.maxInt(u31)) {
                try warnInvalidCountdown(context, countdown_double, .overflow);
            } else if (countdown_double < 0 and !this.warned_negative_number) {
                this.warned_negative_number = true;
                try warnInvalidCountdown(context, countdown_double, .negative);
            } else if (std.math.isNan(countdown_double) and !this.warned_not_number) {
                this.warned_not_number = true;
                try warnInvalidCountdown(context, countdown_double, .nan);
            }
            return 1;
        }
        return @intFromFloat(countdown_double);
    }

    pub fn sleepFromBinding(
        context: anytype,
        countdown: SleepCountdown,
        completion: SleepCompletion,
    ) JSError!void {
        const global = context.viewToken().globalObject();
        const vm = global.bunVM();
        const id = vm.timer.last_id;
        vm.timer.last_id +%= 1;

        const milliseconds = switch (countdown) {
            .milliseconds => |delay| delay,
            .deadline => |deadline| delay: {
                const now = context.engineIn("date_time", "currentDateMilliseconds").call(.{});
                const remaining = deadline - now;
                break :delay if (remaining > 0) @ceil(remaining) else 0;
            },
        };
        const countdown_int = std.math.lossyCast(u31, milliseconds);
        var timer = try TimeoutObject.initSleepFromBinding(context, id, countdown_int, completion);
        timer.deinit();
    }

    pub fn createImmediateFromBinding(
        this: *All,
        context: anytype,
        callback: bun.bindgen.CallbackView(TimerCallbackType),
        arguments: bun.bindgen.AnyRestView,
    ) JSError!bun.bindgen.Return(NodeTimersSetImmediateSchema) {
        const global = context.viewToken().globalObject();
        const vm = global.bunVM();
        bun.debugAssert(this == &vm.timer);
        const id = this.last_id;
        this.last_id +%= 1;

        return ImmediateObject.initFromBinding(context, id, callback, arguments);
    }

    pub fn createTimeoutFromBinding(
        this: *All,
        context: anytype,
        callback: bun.bindgen.CallbackView(TimerCallbackType),
        arguments: bun.bindgen.AnyRestView,
        countdown: Countdown,
        repeating: bool,
    ) JSError!bun.bindgen.Return(NodeTimersSetTimeoutSchema) {
        const global = context.viewToken().globalObject();
        const vm = global.bunVM();
        bun.debugAssert(this == &vm.timer);
        const countdown_int = try this.countdownMilliseconds(context, countdown);
        const id = this.last_id;
        this.last_id +%= 1;

        return TimeoutObject.initFromBinding(
            context,
            id,
            if (repeating) .setInterval else .setTimeout,
            countdown_int,
            callback,
            arguments,
        );
    }

    fn findTimerById(this: *All, id: i32) ?*TimeoutObject {
        if (this.maps.setTimeout.get(id)) |timer| {
            bun.assert(timer.tag == .TimeoutObject);
            return @fieldParentPtr("event_loop_timer", timer);
        } else if (this.maps.setInterval.get(id)) |timer| {
            bun.assert(timer.tag == .TimeoutObject);
            return @fieldParentPtr("event_loop_timer", timer);
        } else return null;
    }

    pub fn clearFromBinding(this: *All, value: ClearValue, vm: *VirtualMachine, immediate: bool) JSError!void {
        bun.debugAssert(this == &vm.timer);
        switch (value) {
            .ignored => {},
            .number => |id| if (!immediate) {
                if (this.findTimerById(id)) |timer| try timer.internals.cancel(vm);
            },
            .string => |optional_id| if (!immediate) {
                if (optional_id) |id| {
                    if (this.findTimerById(id)) |timer| try timer.internals.cancel(vm);
                }
            },
            .immediate => |binding| {
                if (!immediate) return;
                try binding.get(ImmediateObject.JSBinding).immediate.get().internals.cancel(vm);
            },
            .timeout => |binding| {
                if (immediate) return;
                try binding.get(TimeoutObject.JSBinding).timeout.get().internals.cancel(vm);
            },
        }
    }

    fn bindSetImmediate(
        context: bun.bindgen.CallContext(NodeTimersSetImmediateSchema),
        args: bun.bindgen.Args(NodeTimersSetImmediateSchema),
    ) JSError!bun.bindgen.Return(NodeTimersSetImmediateSchema) {
        const global = context.viewToken().globalObject();
        return global.bunVM().timer.createImmediateFromBinding(context, args.job, args.arguments);
    }

    fn bindSetTimeout(
        context: bun.bindgen.CallContext(NodeTimersSetTimeoutSchema),
        args: bun.bindgen.Args(NodeTimersSetTimeoutSchema),
    ) JSError!bun.bindgen.Return(NodeTimersSetTimeoutSchema) {
        const global = context.viewToken().globalObject();
        return global.bunVM().timer.createTimeoutFromBinding(context, args.job, args.arguments, args.delay, false);
    }

    fn bindSetInterval(
        context: bun.bindgen.CallContext(NodeTimersSetIntervalSchema),
        args: bun.bindgen.Args(NodeTimersSetIntervalSchema),
    ) JSError!bun.bindgen.Return(NodeTimersSetIntervalSchema) {
        const global = context.viewToken().globalObject();
        return global.bunVM().timer.createTimeoutFromBinding(context, args.job, args.arguments, args.delay, true);
    }

    fn bindClearImmediate(
        _: bun.bindgen.CallContext(NodeTimersClearImmediateSchema),
        args: bun.bindgen.Args(NodeTimersClearImmediateSchema),
    ) JSError!void {
        const vm = VirtualMachine.get();
        try vm.timer.clearFromBinding(args.timer, vm, true);
    }

    fn bindClearTimeout(
        _: bun.bindgen.CallContext(NodeTimersClearTimeoutSchema),
        args: bun.bindgen.Args(NodeTimersClearTimeoutSchema),
    ) JSError!void {
        const vm = VirtualMachine.get();
        try vm.timer.clearFromBinding(args.timer, vm, false);
    }

    fn bindClearInterval(
        _: bun.bindgen.CallContext(NodeTimersClearIntervalSchema),
        args: bun.bindgen.Args(NodeTimersClearIntervalSchema),
    ) JSError!void {
        const vm = VirtualMachine.get();
        try vm.timer.clearFromBinding(args.timer, vm, false);
    }
};

pub const SleepCompletion = bun.bindgen.OwnedCompletion(BunSleepSchema);

const EventLoopTimerEngine = @import("../../event_loop/EventLoopTimerEngine.zig");

pub const TimeoutObject = @import("./TimeoutObjectEngine.zig");
pub const ImmediateObject = @import("./ImmediateObjectEngine.zig");
pub const TimerObjectInternals = @import("./TimerObjectInternalsEngine.zig");

/// A timer created by WTF code and invoked by Bun's event loop
pub const WTFTimer = @import("./WTFTimerEngine.zig");

pub const DateHeaderTimer = @import("./DateHeaderTimerEngine.zig");

pub const EventLoopDelayMonitor = @import("./EventLoopDelayMonitorEngine.zig");

pub const internal_bindings = struct {
    /// Node.js has some tests that check whether timers fire at the right time. They check this
    /// with the internal binding `getLibuvNow()`, which returns an integer in milliseconds. This
    /// works because `getLibuvNow()` is also the clock that their timers implementation uses to
    /// choose when to schedule timers.
    ///
    /// I've tried changing those tests to use `performance.now()` or `Date.now()`. But that always
    /// introduces spurious failures, because neither of those functions use the same clock that the
    /// timers implementation uses (for Bun this is `bun.timespec.now()`), so the tests end up
    /// thinking that the timing is wrong (this also happens when I run the modified test in
    /// Node.js). So the best course of action is for Bun to also expose a function that reveals the
    /// clock that is used to schedule timers.
    pub fn timerClockMs(
        _: bun.bindgen.CallContext(TimerClockMsSchema),
        _: bun.bindgen.Args(TimerClockMsSchema),
    ) bun.JSError!f64 {
        const now = timespec.now(.allow_mocked_time).ms();
        return @floatFromInt(now);
    }
};

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const JSError = bun.JSError;
const assert = bun.assert;
const timespec = bun.timespec;
const uws = bun.uws;
const heap = bun.io.heap;
const uv = bun.windows.libuv;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const VirtualMachine = jsc.VirtualMachine;

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const TimerClockMsSchema = InternalTestingBindings.function("timerClockMs");
const TimerClockMsBinding = bun.bindgen.Fn(TimerClockMsSchema, internal_bindings.timerClockMs);

const NodeTimersBindings = bun.bindgen.Module("NodeTimers");
const NodeTimersSetImmediateSchema = NodeTimersBindings.function("setImmediate");
const NodeTimersSetTimeoutSchema = NodeTimersBindings.function("setTimeout");
const NodeTimersSetIntervalSchema = NodeTimersBindings.function("setInterval");
const NodeTimersClearImmediateSchema = NodeTimersBindings.function("clearImmediate");
const NodeTimersClearIntervalSchema = NodeTimersBindings.function("clearInterval");
const NodeTimersClearTimeoutSchema = NodeTimersBindings.function("clearTimeout");
pub const TimerCallbackType = @FieldType(bun.bindgen.Args(NodeTimersSetImmediateSchema), "job").SemanticType;
const Countdown = @FieldType(bun.bindgen.Args(NodeTimersSetTimeoutSchema), "delay");
const ClearValue = @FieldType(bun.bindgen.Args(NodeTimersClearTimeoutSchema), "timer");

const BunObjectBindings = bun.bindgen.Module("BunObject");
const BunSleepSchema = BunObjectBindings.function("sleep");
const SleepCountdown = @FieldType(bun.bindgen.Args(BunSleepSchema), "milliseconds");
const EmitCountdownWarningSchema = bun.bindgen.Module("timers").engineShim("emitCountdownWarning");

const NodeTimersSetImmediateBinding = bun.bindgen.Fn(NodeTimersSetImmediateSchema, All.bindSetImmediate);
const NodeTimersSetTimeoutBinding = bun.bindgen.Fn(NodeTimersSetTimeoutSchema, All.bindSetTimeout);
const NodeTimersSetIntervalBinding = bun.bindgen.Fn(NodeTimersSetIntervalSchema, All.bindSetInterval);
const NodeTimersClearImmediateBinding = bun.bindgen.Fn(NodeTimersClearImmediateSchema, All.bindClearImmediate);
const NodeTimersClearIntervalBinding = bun.bindgen.Fn(NodeTimersClearIntervalSchema, All.bindClearInterval);
const NodeTimersClearTimeoutBinding = bun.bindgen.Fn(NodeTimersClearTimeoutSchema, All.bindClearTimeout);

comptime {
    _ = TimerClockMsBinding;
    _ = NodeTimersSetImmediateBinding;
    _ = NodeTimersSetTimeoutBinding;
    _ = NodeTimersSetIntervalBinding;
    _ = NodeTimersClearImmediateBinding;
    _ = NodeTimersClearIntervalBinding;
    _ = NodeTimersClearTimeoutBinding;
}
const FakeTimers = bun.jsc.Jest.bun_test.FakeTimers;
