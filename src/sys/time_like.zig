pub const TimeLike = if (Environment.isWindows) f64 else std.posix.timespec;

pub fn fromSecondsOrOmit(seconds: f64) TimeLike {
    if (std.math.isNan(seconds)) {
        if (Environment.isWindows) return seconds;
        return std.posix.UTIME.OMIT;
    }
    if (Environment.isWindows) return seconds;
    const whole = @floor(seconds);
    return .{
        .sec = @intFromFloat(whole),
        .nsec = @intFromFloat((seconds - whole) * std.time.ns_per_s),
    };
}

const std = @import("std");
const Environment = @import("../bun_core/env.zig");
