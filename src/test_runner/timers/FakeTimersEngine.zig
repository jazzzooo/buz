const FakeTimers = @This();

active: bool = false,
/// The sorted fake timers. TimerHeap is not optimal here because we need these operations:
/// - peek/takeFirst (provided by TimerHeap)
/// - peekLast (cannot be implemented efficiently with TimerHeap)
/// - count (cannot be implemented efficiently with TimerHeap)
timers: TimerHeap = .{ .context = {} },

pub var current_time: FakeTimerClock.Clock(bun.timespec) = .{};

fn setCurrentTime(globalObject: *jsc.JSGlobalObject, value: struct {
    offset: *const bun.timespec,
    js: ?f64 = null,
}) void {
    const vm = globalObject.bunVM();
    current_time.store(vm.io, value.offset.*);
    const timespec_ms: f64 = @floatFromInt(value.offset.ms());
    if (value.js) |js| current_time.date_now_offset = @floor(js) - timespec_ms;
    bun.bindgen.Engine(SetOverriddenDateNowShim).call(globalObject, .{
        .milliseconds = current_time.date_now_offset + timespec_ms,
    }) catch unreachable;
    vm.overridden_performance_now = @bitCast(value.offset.ns());
}

fn clearCurrentTime(globalObject: *jsc.JSGlobalObject) void {
    const vm = globalObject.bunVM();
    current_time.clear(vm.io);
    bun.bindgen.Engine(SetOverriddenDateNowShim).call(globalObject, .{
        .milliseconds = std.math.nan(f64),
    }) catch unreachable;
    vm.overridden_performance_now = null;
}

fn assertValid(this: *FakeTimers, mode: enum { locked, unlocked }) void {
    if (!bun.Environment.ci_assert) return;
    const owner: *bun.api.Timer.All = @fieldParentPtr("fake_timers", this);
    switch (mode) {
        .locked => bun.assert(owner.lock.tryLock() == false),
        .unlocked => {}, // can't assert unlocked because another thread could be holding the lock
    }
}

pub fn isActive(this: *FakeTimers) bool {
    this.assertValid(.locked);
    defer this.assertValid(.locked);

    return this.active;
}
fn activate(this: *FakeTimers, js_now: f64, globalObject: *jsc.JSGlobalObject) void {
    this.assertValid(.locked);
    defer this.assertValid(.locked);

    this.active = true;
    setCurrentTime(globalObject, .{ .offset = &.epoch, .js = js_now });
}
fn deactivate(this: *FakeTimers, globalObject: *jsc.JSGlobalObject) void {
    this.assertValid(.locked);
    defer this.assertValid(.locked);

    this.clear();
    clearCurrentTime(globalObject);
    this.active = false;
}
fn clear(this: *FakeTimers) void {
    this.assertValid(.locked);
    defer this.assertValid(.locked);

    while (this.timers.deleteMin()) |timer| {
        timer.state = .CANCELLED;
        timer.in_heap = .none;
    }
}
fn executeNext(this: *FakeTimers, globalObject: *jsc.JSGlobalObject) bool {
    this.assertValid(.unlocked);
    defer this.assertValid(.unlocked);
    const vm = globalObject.bunVM();
    const timers = &vm.timer;

    const next = blk: {
        timers.lock.lockUncancelable(timers.io);
        defer timers.lock.unlock(timers.io);
        const timer = this.timers.deleteMin() orelse return false;
        timer.in_heap = .none;
        break :blk timer;
    };

    this.fire(globalObject, next);
    return true;
}
fn fire(this: *FakeTimers, globalObject: *jsc.JSGlobalObject, next: *bun.api.Timer.EventLoopTimer) void {
    this.assertValid(.unlocked);
    defer this.assertValid(.unlocked);
    const vm = globalObject.bunVM();

    if (bun.Environment.ci_assert) {
        const prev = current_time.get();
        bun.assert(prev != null);
        bun.assert(next.next.eql(&prev.?) or next.next.greater(&prev.?));
    }
    const now = next.next;
    setCurrentTime(globalObject, .{ .offset = &now });
    EventLoopTimerEngine.fire(next, &now, vm);
}
fn executeUntil(this: *FakeTimers, globalObject: *jsc.JSGlobalObject, until: bun.timespec) void {
    this.assertValid(.unlocked);
    defer this.assertValid(.unlocked);
    const vm = globalObject.bunVM();
    const timers = &vm.timer;

    while (true) {
        const next = blk: {
            timers.lock.lockUncancelable(timers.io);
            defer timers.lock.unlock(timers.io);

            const peek = this.timers.peek() orelse break;
            if (peek.next.greater(&until)) break;
            bun.assert(this.timers.deleteMin() == peek);
            peek.in_heap = .none;
            break :blk peek;
        };
        this.fire(globalObject, next);
    }
}
fn executeOnlyPendingTimers(this: *FakeTimers, globalObject: *jsc.JSGlobalObject) void {
    this.assertValid(.unlocked);
    defer this.assertValid(.unlocked);
    const vm = globalObject.bunVM();
    const timers = &vm.timer;

    const target = blk: {
        timers.lock.lockUncancelable(timers.io);
        defer timers.lock.unlock(timers.io);
        break :blk this.timers.findMax() orelse return;
    };
    const until = target.next;
    this.executeUntil(globalObject, until);
}
fn executeAllTimers(this: *FakeTimers, globalObject: *jsc.JSGlobalObject) void {
    this.assertValid(.unlocked);
    defer this.assertValid(.unlocked);

    while (this.executeNext(globalObject)) {}
}

const BindingControlHandle = opaque {};

const BindingControl = struct {
    handle: *BindingControlHandle,

    fn init(global_object: *jsc.JSGlobalObject) BindingControl {
        return .{ .handle = @ptrCast(global_object) };
    }

    fn globalObject(control: BindingControl) *jsc.JSGlobalObject {
        return @ptrCast(@alignCast(control.handle));
    }

    fn timerState(control: BindingControl) *bun.api.Timer.All {
        return &control.globalObject().bunVM().timer;
    }

    fn isActive(control: BindingControl) bool {
        const timers = control.timerState();
        timers.lock.lockUncancelable(timers.io);
        defer timers.lock.unlock(timers.io);
        return timers.fake_timers.isActive();
    }

    fn activate(control: BindingControl, requested_now: ?f64) void {
        const timers = control.timerState();
        const js_now = requested_now orelse bun.bindgen.Engine(CurrentUnixTimeMillisecondsShim).call(.{});
        timers.lock.lockUncancelable(timers.io);
        defer timers.lock.unlock(timers.io);
        timers.fake_timers.activate(js_now, control.globalObject());
    }

    fn deactivate(control: BindingControl) void {
        const timers = control.timerState();
        timers.lock.lockUncancelable(timers.io);
        defer timers.lock.unlock(timers.io);
        timers.fake_timers.deactivate(control.globalObject());
    }

    fn advanceToNext(control: BindingControl) void {
        _ = control.timerState().fake_timers.executeNext(control.globalObject());
    }

    fn advanceBy(control: BindingControl, current: bun.timespec, milliseconds: f64) void {
        const target = current.addMsFloat(if (milliseconds == 0) 1 else milliseconds);
        control.timerState().fake_timers.executeUntil(control.globalObject(), target);
        setCurrentTime(control.globalObject(), .{ .offset = &target });
    }

    fn runOnlyPending(control: BindingControl) void {
        control.timerState().fake_timers.executeOnlyPendingTimers(control.globalObject());
    }

    fn runAll(control: BindingControl) void {
        control.timerState().fake_timers.executeAllTimers(control.globalObject());
    }

    fn count(control: BindingControl) usize {
        const timers = control.timerState();
        timers.lock.lockUncancelable(timers.io);
        defer timers.lock.unlock(timers.io);
        return timers.fake_timers.timers.count();
    }

    fn clear(control: BindingControl) void {
        const timers = control.timerState();
        timers.lock.lockUncancelable(timers.io);
        defer timers.lock.unlock(timers.io);
        timers.fake_timers.clear();
    }
};

fn useFakeTimers(
    context: bun.bindgen.CallContext(UseFakeTimersSchema),
    args: bun.bindgen.Args(UseFakeTimersSchema),
) bun.JSError!void {
    const globalThis = context.viewToken().globalObject();
    BindingControl.init(globalThis).activate(if (args.options) |options| options.now else null);
}

fn useRealTimers(
    context: bun.bindgen.CallContext(UseRealTimersSchema),
    _: bun.bindgen.Args(UseRealTimersSchema),
) bun.JSError!void {
    const globalThis = context.viewToken().globalObject();
    BindingControl.init(globalThis).deactivate();
}

fn advanceTimersToNextTimer(
    context: bun.bindgen.CallContext(AdvanceTimersToNextTimerSchema),
    _: bun.bindgen.Args(AdvanceTimersToNextTimerSchema),
) bun.bindgen.CallError(AdvanceTimersToNextTimerSchema)!void {
    const globalThis = context.viewToken().globalObject();
    const timers = BindingControl.init(globalThis);
    if (!timers.isActive()) return context.fail(.inactive, {});
    timers.advanceToNext();
}

fn advanceTimersByTime(
    context: bun.bindgen.CallContext(AdvanceTimersByTimeSchema),
    args: bun.bindgen.Args(AdvanceTimersByTimeSchema),
) bun.bindgen.CallError(AdvanceTimersByTimeSchema)!void {
    const globalThis = context.viewToken().globalObject();
    const timers = BindingControl.init(globalThis);
    if (!timers.isActive()) return context.fail(.inactive, {});

    const milliseconds = args.milliseconds orelse {
        return context.fail(.missing_milliseconds, {});
    };
    const current = current_time.get() orelse return context.fail(.not_initialized, {});
    const converted_milliseconds = try milliseconds.convert(context);
    timers.advanceBy(current, converted_milliseconds.value);
}

fn runOnlyPendingTimers(
    context: bun.bindgen.CallContext(RunOnlyPendingTimersSchema),
    _: bun.bindgen.Args(RunOnlyPendingTimersSchema),
) bun.bindgen.CallError(RunOnlyPendingTimersSchema)!void {
    const globalThis = context.viewToken().globalObject();
    const timers = BindingControl.init(globalThis);
    if (!timers.isActive()) return context.fail(.inactive, {});
    timers.runOnlyPending();
}

fn runAllTimers(
    context: bun.bindgen.CallContext(RunAllTimersSchema),
    _: bun.bindgen.Args(RunAllTimersSchema),
) bun.bindgen.CallError(RunAllTimersSchema)!void {
    const globalThis = context.viewToken().globalObject();
    const timers = BindingControl.init(globalThis);
    if (!timers.isActive()) return context.fail(.inactive, {});
    timers.runAll();
}

fn getTimerCount(
    context: bun.bindgen.CallContext(GetTimerCountSchema),
    _: bun.bindgen.Args(GetTimerCountSchema),
) bun.bindgen.CallError(GetTimerCountSchema)!bun.bindgen.Return(GetTimerCountSchema) {
    const globalThis = context.viewToken().globalObject();
    const timers = BindingControl.init(globalThis);
    if (!timers.isActive()) return context.fail(.inactive, {});
    return timers.count();
}

fn clearAllTimers(
    context: bun.bindgen.CallContext(ClearAllTimersSchema),
    _: bun.bindgen.Args(ClearAllTimersSchema),
) bun.bindgen.CallError(ClearAllTimersSchema)!void {
    const globalThis = context.viewToken().globalObject();
    const timers = BindingControl.init(globalThis);
    if (!timers.isActive()) return context.fail(.inactive, {});
    timers.clear();
}

fn isFakeTimers(
    context: bun.bindgen.CallContext(IsFakeTimersSchema),
    _: bun.bindgen.Args(IsFakeTimersSchema),
) bun.JSError!bool {
    const globalThis = context.viewToken().globalObject();
    return BindingControl.init(globalThis).isActive();
}

const std = @import("std");

const bun = @import("bun");
const EventLoopTimerEngine = @import("../../event_loop/EventLoopTimerEngine.zig");
const FakeTimerClock = @import("./FakeTimerClock.zig");
const jsc = bun.jsc;
const TimerHeap = bun.api.Timer.TimerHeap;

const FakeTimersBindings = bun.bindgen.Module("fake_timers_config");
const UseFakeTimersSchema = FakeTimersBindings.function("useFakeTimers");
const UseFakeTimersBinding = bun.bindgen.Fn(UseFakeTimersSchema, useFakeTimers);
const UseRealTimersSchema = FakeTimersBindings.function("useRealTimers");
const UseRealTimersBinding = bun.bindgen.Fn(UseRealTimersSchema, useRealTimers);
const AdvanceTimersToNextTimerSchema = FakeTimersBindings.function("advanceTimersToNextTimer");
const AdvanceTimersToNextTimerBinding = bun.bindgen.Fn(AdvanceTimersToNextTimerSchema, advanceTimersToNextTimer);
const AdvanceTimersByTimeSchema = FakeTimersBindings.function("advanceTimersByTime");
const AdvanceTimersByTimeBinding = bun.bindgen.Fn(AdvanceTimersByTimeSchema, advanceTimersByTime);
const RunOnlyPendingTimersSchema = FakeTimersBindings.function("runOnlyPendingTimers");
const RunOnlyPendingTimersBinding = bun.bindgen.Fn(RunOnlyPendingTimersSchema, runOnlyPendingTimers);
const RunAllTimersSchema = FakeTimersBindings.function("runAllTimers");
const RunAllTimersBinding = bun.bindgen.Fn(RunAllTimersSchema, runAllTimers);
const GetTimerCountSchema = FakeTimersBindings.function("getTimerCount");
const GetTimerCountBinding = bun.bindgen.Fn(GetTimerCountSchema, getTimerCount);
const ClearAllTimersSchema = FakeTimersBindings.function("clearAllTimers");
const ClearAllTimersBinding = bun.bindgen.Fn(ClearAllTimersSchema, clearAllTimers);
const IsFakeTimersSchema = FakeTimersBindings.function("isFakeTimers");
const IsFakeTimersBinding = bun.bindgen.Fn(IsFakeTimersSchema, isFakeTimers);

comptime {
    _ = UseFakeTimersBinding;
    _ = UseRealTimersBinding;
    _ = AdvanceTimersToNextTimerBinding;
    _ = AdvanceTimersByTimeBinding;
    _ = RunOnlyPendingTimersBinding;
    _ = RunAllTimersBinding;
    _ = GetTimerCountBinding;
    _ = ClearAllTimersBinding;
    _ = IsFakeTimersBinding;
}

const DateTimeBindings = bun.bindgen.Module("date_time");
const SetOverriddenDateNowShim = DateTimeBindings.engineShim("setOverriddenDateNow");
const CurrentUnixTimeMillisecondsShim = DateTimeBindings.engineShim("currentUnixTimeMilliseconds");
