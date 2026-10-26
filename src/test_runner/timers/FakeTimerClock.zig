pub fn Clock(comptime TimeSpec: type) type {
    return struct {
        const min_time = TimeSpec{ .sec = std.math.minInt(i64), .nsec = std.math.minInt(i64) };

        offset_sec: std.atomic.Value(i64) = .init(min_time.sec),
        offset_nsec: std.atomic.Value(i64) = .init(min_time.nsec),
        sequence: std.atomic.Value(u32) = .init(0),
        lock: std.Io.Mutex = .init,
        date_now_offset: f64 = 0,

        pub fn get(clock: *@This()) ?TimeSpec {
            while (true) {
                const sequence = clock.sequence.load(.acquire);
                if (sequence & 1 != 0) continue;
                const value = TimeSpec{
                    .sec = clock.offset_sec.load(.acquire),
                    .nsec = clock.offset_nsec.load(.acquire),
                };
                if (clock.sequence.load(.acquire) != sequence) continue;
                if (value.eql(&min_time)) return null;
                return value;
            }
        }

        pub fn store(clock: *@This(), io: std.Io, value: TimeSpec) void {
            clock.lock.lockUncancelable(io);
            defer clock.lock.unlock(io);
            _ = clock.sequence.fetchAdd(1, .acq_rel);
            clock.offset_sec.store(value.sec, .monotonic);
            clock.offset_nsec.store(value.nsec, .monotonic);
            _ = clock.sequence.fetchAdd(1, .release);
        }

        pub fn clear(clock: *@This(), io: std.Io) void {
            clock.store(io, min_time);
        }
    };
}

const std = @import("std");

test Clock {
    const Time = struct {
        sec: i64,
        nsec: i64,

        fn eql(left: *const @This(), right: *const @This()) bool {
            return left.sec == right.sec and left.nsec == right.nsec;
        }
    };
    var clock: Clock(Time) = .{};
    try std.testing.expect(clock.get() == null);
}
