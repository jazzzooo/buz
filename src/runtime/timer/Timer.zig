pub const EventLoopTimer = @import("../../event_loop/EventLoopTimer.zig");

pub const TimeoutMap = std.array_hash_map.Auto(i32, *EventLoopTimer);

pub const Kind = enum(u2) {
    setTimeout = 0,
    setInterval = 1,
    setImmediate = 2,
};

pub const ID = struct {
    id: i32,
    kind: Kind = .setTimeout,

    pub inline fn asyncID(this: ID) u64 {
        return @as(u64, @as(u32, @bitCast(this.id))) |
            (@as(u64, @backingInt(this.kind)) << 32);
    }
};

const std = @import("std");
