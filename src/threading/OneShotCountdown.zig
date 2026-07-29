const OneShotCountdown = @This();

remaining: std.atomic.Value(usize) = .init(0),
event: std.Io.Event = .is_set,

pub fn init(count: usize) OneShotCountdown {
    return .{
        .remaining = .init(count),
        .event = if (count == 0) .is_set else .unset,
    };
}

pub fn addOne(countdown: *OneShotCountdown) void {
    const previous = countdown.remaining.fetchAdd(1, .monotonic);
    bun.assert(previous > 0);
}

pub fn finish(countdown: *OneShotCountdown, io: std.Io) void {
    const previous = countdown.remaining.fetchSub(1, .acq_rel);
    bun.assert(previous > 0);
    if (previous == 1) countdown.event.set(io);
}

pub fn wait(countdown: *OneShotCountdown, io: std.Io) void {
    countdown.event.waitUncancelable(io);
    bun.assert(countdown.remaining.load(.acquire) == 0);
}

const bun = @import("bun");
const std = @import("std");
