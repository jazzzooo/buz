const EventLoopTimer = @import("./EventLoopTimer.zig");

pub fn less(_: void, a: *const EventLoopTimer, b: *const EventLoopTimer) bool {
    const sec_order = std.math.order(a.next.sec, b.next.sec);
    if (sec_order != .eq) return sec_order == .lt;

    const maybe_a_flags = jsTimerInternalsFlags(a);
    const maybe_b_flags = jsTimerInternalsFlags(b);
    var a_ns = a.next.nsec;
    var b_ns = b.next.nsec;
    if (maybe_a_flags != null) a_ns = std.time.ns_per_ms * @divTrunc(a_ns, std.time.ns_per_ms);
    if (maybe_b_flags != null) b_ns = std.time.ns_per_ms * @divTrunc(b_ns, std.time.ns_per_ms);

    const order = std.math.order(a_ns, b_ns);
    if (order == .eq) {
        if (maybe_a_flags) |a_flags| {
            if (maybe_b_flags) |b_flags| {
                return b_flags.epoch -% a_flags.epoch < std.math.maxInt(u25) / 2;
            }
        }
    }
    return order == .lt;
}

pub fn jsTimerInternalsFlags(timer: anytype) switch (@TypeOf(timer)) {
    *EventLoopTimer => ?*TimerObjectInternals.Flags,
    *const EventLoopTimer => ?*const TimerObjectInternals.Flags,
    else => |T| @compileError("wrong type " ++ @typeName(T) ++ " passed to jsTimerInternalsFlags"),
} {
    switch (timer.tag) {
        inline .TimeoutObject, .ImmediateObject, .AbortSignalTimeout => |tag| {
            const Parent = TagType(tag);
            const parent: switch (@TypeOf(timer)) {
                *EventLoopTimer => *Parent,
                *const EventLoopTimer => *const Parent,
                else => unreachable,
            } = @fieldParentPtr("event_loop_timer", timer);
            return if (comptime Parent == jsc.WebCore.AbortSignal.Timeout)
                &parent.flags
            else
                &parent.internals.flags;
        },
        else => return null,
    }
}

pub fn fire(timer: *EventLoopTimer, now: *const timespec, vm: *VirtualMachine) void {
    switch (timer.tag) {
        .PostgresSQLConnectionTimeout => @as(*api.Postgres.PostgresSQLConnection, @alignCast(@fieldParentPtr("timer", timer))).onConnectionTimeout(),
        .PostgresSQLConnectionMaxLifetime => @as(*api.Postgres.PostgresSQLConnection, @alignCast(@fieldParentPtr("max_lifetime_timer", timer))).onMaxLifetimeTimeout(),
        .MySQLConnectionTimeout => @as(*api.MySQL.MySQLConnection, @alignCast(@fieldParentPtr("timer", timer))).onConnectionTimeout(),
        .MySQLConnectionMaxLifetime => @as(*api.MySQL.MySQLConnection, @alignCast(@fieldParentPtr("max_lifetime_timer", timer))).onMaxLifetimeTimeout(),
        .ValkeyConnectionTimeout => @as(*api.Valkey, @alignCast(@fieldParentPtr("timer", timer))).onConnectionTimeout(),
        .ValkeyConnectionReconnect => @as(*api.Valkey, @alignCast(@fieldParentPtr("reconnect_timer", timer))).onReconnectTimer(),
        .DevServerMemoryVisualizerTick => bun.bake.DevServer.emitMemoryVisualizerMessageTimer(timer, now),
        .DevServerSweepSourceMaps => bun.bake.DevServer.SourceMapStore.sweepWeakRefs(timer, now),
        .AbortSignalTimeout => {
            const timeout = @as(*jsc.WebCore.AbortSignal.Timeout, @fieldParentPtr("event_loop_timer", timer));
            timeout.run(vm);
        },
        .DateHeaderTimer => {
            const date_header_timer = @as(*jsc.API.Timer.DateHeaderTimer, @fieldParentPtr("event_loop_timer", timer));
            date_header_timer.run(vm);
        },
        .BunTest => {
            var container_strong = jsc.Jest.bun_test.BunTestPtr.cloneFromRawUnsafe(@fieldParentPtr("timer", timer));
            defer container_strong.deinit();
            jsc.Jest.bun_test.BunTest.bunTestTimeoutCallback(container_strong, now, vm);
        },
        .EventLoopDelayMonitor => {
            const monitor = @as(*jsc.API.Timer.EventLoopDelayMonitor, @fieldParentPtr("event_loop_timer", timer));
            monitor.onFire(vm, now);
        },
        .CronJob => {
            const job = bun.api.cron.CronJob.fromEventLoopTimer(timer);
            job.onTimerFire(vm);
        },
        .GarbageCollection => {
            const controller: *jsc.GarbageCollectionController = @fieldParentPtr("gc_timer", timer);
            controller.onGCTimer();
        },
        .GarbageCollectionRepeat => {
            const controller: *jsc.GarbageCollectionController = @fieldParentPtr("gc_repeating_timer", timer);
            controller.onGCRepeatingTimer();
        },
        inline else => |tag| {
            const Parent = TagType(tag);
            if (@FieldType(Parent, "event_loop_timer") != EventLoopTimer) {
                @compileError(@typeName(Parent) ++ " has wrong type for 'event_loop_timer'");
            }
            var container: *Parent = @alignCast(@fieldParentPtr("event_loop_timer", timer));
            if (comptime Parent == TimeoutObject or Parent == ImmediateObject) {
                container.internals.fire(now, vm);
            } else if (comptime Parent == WTFTimer) {
                container.fire(now, vm);
            } else if (comptime Parent == StatWatcher) {
                container.timerCallback();
            } else if (comptime Parent == UpgradedDuplex) {
                container.onTimeout();
            } else if (Environment.isWindows and Parent == WindowsNamedPipe) {
                container.onTimeout();
            } else if (comptime Parent == DNSResolver) {
                container.checkTimeouts(now, vm);
            } else if (comptime Parent == jsc.Subprocess) {
                container.timeoutCallback();
            } else {
                container.callback(container);
            }
        },
    }
}

fn TagType(comptime tag: EventLoopTimer.Tag) type {
    return switch (tag) {
        .TimerCallback => TimerCallback,
        .TimeoutObject => TimeoutObject,
        .ImmediateObject => ImmediateObject,
        .StatWatcher => StatWatcher,
        .UpgradedDuplex => UpgradedDuplex,
        .DNSResolver => DNSResolver,
        .WindowsNamedPipe => if (Environment.isWindows) WindowsNamedPipe else UnreachableTimer,
        .WTFTimer => WTFTimer,
        .PostgresSQLConnectionTimeout, .PostgresSQLConnectionMaxLifetime => jsc.Postgres.PostgresSQLConnection,
        .MySQLConnectionTimeout, .MySQLConnectionMaxLifetime => jsc.MySQL.MySQLConnection,
        .SubprocessTimeout => jsc.Subprocess,
        .ValkeyConnectionReconnect, .ValkeyConnectionTimeout => jsc.API.Valkey,
        .DevServerSweepSourceMaps, .DevServerMemoryVisualizerTick => bun.bake.DevServer,
        .AbortSignalTimeout => jsc.WebCore.AbortSignal.Timeout,
        .DateHeaderTimer => jsc.API.Timer.DateHeaderTimer,
        .BunTest => jsc.Jest.bun_test.BunTest,
        .EventLoopDelayMonitor => jsc.API.Timer.EventLoopDelayMonitor,
        .CronJob => bun.api.cron.CronJob,
        .GarbageCollection, .GarbageCollectionRepeat => jsc.GarbageCollectionController,
    };
}

const UnreachableTimer = struct {
    event_loop_timer: EventLoopTimer,
    fn callback(_: *UnreachableTimer, _: *UnreachableTimer) void {
        if (Environment.ci_assert) bun.assert(false);
    }
};

const TimerCallback = struct {
    callback: *const fn (*TimerCallback) void,
    ctx: *anyopaque,
    event_loop_timer: EventLoopTimer,
};

const std = @import("std");
const StatWatcher = @import("../runtime/node/StatWatcherEngine.zig").StatWatcher;

const bun = @import("bun");
const Environment = bun.Environment;
const timespec = bun.timespec;
const DNSResolver = bun.api.dns.Resolver;
const UpgradedDuplex = @import("../runtime/socket/UpgradedDuplexEngine.zig");
const WindowsNamedPipe = @import("../runtime/socket/WindowsNamedPipeContextEngine.zig").WindowsNamedPipe;

const ImmediateObject = bun.api.Timer.ImmediateObject;
const TimeoutObject = bun.api.Timer.TimeoutObject;
const TimerObjectInternals = bun.api.Timer.TimerObjectInternals;
const WTFTimer = bun.api.Timer.WTFTimer;

const jsc = bun.jsc;
const VirtualMachine = jsc.VirtualMachine;
const api = jsc.API;
