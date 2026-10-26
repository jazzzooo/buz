const postgres_epoch_ms = 946684800000;

pub fn fromBinary(bytes: []const u8) f64 {
    const microseconds = std.mem.readInt(i64, bytes[0..8], .big);
    const value: f64 = @floatFromInt(microseconds);
    return (value / std.time.us_per_ms) + postgres_epoch_ms;
}

const std = @import("std");
