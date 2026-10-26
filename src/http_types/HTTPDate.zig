pub fn write(buffer: *[32]u8, timestamp_ms: u64) []u8 {
    if (timestamp_ms == 0) return buffer[0..0];

    const seconds = timestamp_ms / std.time.ms_per_s;
    if (seconds > std.math.maxInt(i64)) return buffer[0..0];

    const seconds_per_day = 24 * 60 * 60;
    const days: i64 = @intCast(seconds / seconds_per_day);
    const seconds_in_day = seconds % seconds_per_day;
    const date = GregorianDate.fromDaysSinceUnixEpoch(days);
    if (date.year < 0 or date.year > 9999) return buffer[0..0];
    const year: u16 = @intCast(date.year);

    const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const hour = seconds_in_day / (60 * 60);
    const minute = (seconds_in_day / 60) % 60;
    const second = seconds_in_day % 60;

    return std.fmt.bufPrint(
        buffer,
        "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT",
        .{ weekdays[date.weekday], date.day, months[date.month - 1], year, hour, minute, second },
    ) catch unreachable;
}

const std = @import("std");
const GregorianDate = @import("../bun_core/GregorianDate.zig");
