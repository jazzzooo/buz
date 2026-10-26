//! Isolated VM event loop for synchronous subprocess execution.

const SpawnSyncEventLoop = @This();

event_loop: jsc.EventLoop,

uws_loop: *uws.Loop,

original_event_loop_handle: @FieldType(jsc.VirtualMachine, "event_loop_handle") = undefined,

uv_timer: if (bun.Environment.isWindows) ?*bun.windows.libuv.Timer else void = if (bun.Environment.isWindows) null else {},
did_timeout: bool = false,

const Handler = struct {
    pub fn wakeup(loop: *uws.Loop) callconv(.c) void {
        _ = loop;
    }

    pub fn pre(loop: *uws.Loop) callconv(.c) void {
        _ = loop;
    }

    pub fn post(loop: *uws.Loop) callconv(.c) void {
        _ = loop;
    }
};

pub fn init(self: *SpawnSyncEventLoop, vm: *jsc.VirtualMachine) ?uws.PollFailure {
    const loop = switch (uws.Loop.create(Handler)) {
        .loop => |loop| loop,
        .failed => |failure| return failure,
    };

    self.* = .{
        .event_loop = undefined,
        .uws_loop = loop,
    };

    self.event_loop = .{
        .global = vm.global,
        .virtual_machine = vm,
        .uws_loop = if (bun.Environment.isWindows) self.uws_loop else {},
    };

    jsc.EventLoopHandle.init(&self.event_loop).attach(self.uws_loop);
    jsc.setLoopVM(self.uws_loop, null);
    return null;
}

fn onCloseUVTimer(timer: *bun.windows.libuv.Timer) callconv(.c) void {
    bun.default_allocator.destroy(timer);
}

pub fn deinit(this: *SpawnSyncEventLoop) void {
    if (comptime bun.Environment.isWindows) {
        if (this.uv_timer) |timer| {
            timer.stop();
            timer.unref();
            this.uv_timer = null;
            libuv.uv_close(@ptrCast(@alignCast(timer)), @ptrCast(&onCloseUVTimer));
        }
    }

    this.event_loop.deinit();
    this.uws_loop.deinit();
}

pub fn prepare(this: *SpawnSyncEventLoop, vm: *jsc.VirtualMachine) void {
    this.event_loop.global = vm.global;
    this.did_timeout = false;
    this.event_loop.virtual_machine = vm;

    this.original_event_loop_handle = vm.event_loop_handle;
    vm.event_loop_handle = if (bun.Environment.isPosix) this.uws_loop else this.uws_loop.uv_loop;
}

pub fn cleanup(this: *SpawnSyncEventLoop, vm: *jsc.VirtualMachine, prev_event_loop: *jsc.EventLoop) void {
    vm.event_loop_handle = this.original_event_loop_handle;
    vm.event_loop = prev_event_loop;

    if (bun.Environment.isWindows) {
        if (this.uv_timer) |timer| {
            timer.stop();
            timer.unref();
        }
    }
}

pub fn handle(this: *SpawnSyncEventLoop) jsc.EventLoopHandle {
    return jsc.EventLoopHandle.init(&this.event_loop);
}

fn onUVTimer(timer_: *bun.windows.libuv.Timer) callconv(.c) void {
    const this: *SpawnSyncEventLoop = @ptrCast(@alignCast(timer_.data));
    this.did_timeout = true;
    this.uws_loop.uv_loop.stop();
}

const TickState = enum { timeout, completed };

fn prepareTimerOnWindows(this: *SpawnSyncEventLoop, ts: *const bun.timespec) void {
    const timer: *bun.windows.libuv.Timer = this.uv_timer orelse brk: {
        const uv_timer: *bun.windows.libuv.Timer = bun.default_allocator.create(bun.windows.libuv.Timer) catch |e| bun.handleOom(e);
        uv_timer.* = std.mem.zeroes(bun.windows.libuv.Timer);
        uv_timer.init(this.uws_loop.uv_loop);
        break :brk uv_timer;
    };

    timer.start(ts.msUnsigned(), 0, &onUVTimer);
    timer.ref();
    this.uv_timer = timer;
    timer.data = this;
}

pub fn tickWithTimeout(this: *SpawnSyncEventLoop, timeout: ?*const bun.timespec) TickState {
    const duration: ?*const bun.timespec = if (timeout) |ts| &ts.duration(&.now(.allow_mocked_time)) else null;
    if (bun.Environment.isWindows) {
        if (duration) |ts| {
            prepareTimerOnWindows(this, ts);
        }
    }

    // libuv can dispatch process and pipe callbacks inside the poll, so suppress
    // microtasks before entering either platform loop.
    const vm = this.event_loop.virtual_machine;
    const prev_suppress = vm.suppress_microtask_drain;
    vm.suppress_microtask_drain = true;
    defer vm.suppress_microtask_drain = prev_suppress;

    this.uws_loop.tickWithTimeout(duration);

    if (timeout) |ts| {
        if (bun.Environment.isWindows) {
            this.uv_timer.?.unref();
            this.uv_timer.?.stop();
        } else {
            this.did_timeout = bun.timespec.now(.allow_mocked_time).order(ts) != .lt;
        }
    }

    this.event_loop.tickTasksOnly();

    const did_timeout = this.did_timeout;
    this.did_timeout = false;

    if (did_timeout) {
        return .timeout;
    }

    return .completed;
}

pub fn isActive(this: *const SpawnSyncEventLoop) bool {
    return this.uws_loop.isActive();
}

const std = @import("std");

const bun = @import("bun");
const jsc = bun.jsc;
const uws = bun.uws;
const libuv = bun.windows.libuv;
