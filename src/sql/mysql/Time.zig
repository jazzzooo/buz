const Time = @This();

negative: bool = false,
days: u32 = 0,
hours: u8 = 0,
minutes: u8 = 0,
seconds: u8 = 0,
microseconds: u32 = 0,

pub fn fromMilliseconds(total_ms: f64) Time {
    const magnitude = @abs(total_ms);
    const seconds: u64 = @intFromFloat(@divFloor(magnitude, 1000));
    const milliseconds = magnitude - @as(f64, @floatFromInt(seconds)) * 1000;
    return .{
        .negative = total_ms < 0,
        .days = @intCast(seconds / 86400),
        .hours = @intCast(seconds / 3600 % 24),
        .minutes = @intCast(seconds / 60 % 60),
        .seconds = @intCast(seconds % 60),
        .microseconds = @intFromFloat(milliseconds * 1000),
    };
}

pub fn fromBinary(val: []const u8) Time {
    if (val.len == 0) {
        return Time{};
    }

    var time = Time{};
    if (val.len >= 8) {
        time.negative = val[0] != 0;
        time.days = std.mem.readInt(u32, val[1..5], .little);
        time.hours = val[5];
        time.minutes = val[6];
        time.seconds = val[7];
    }

    if (val.len > 8) {
        time.microseconds = std.mem.readInt(u32, val[8..12], .little);
    }

    return time;
}
pub fn toBinary(this: *const Time, field_type: FieldType, buffer: []u8) u8 {
    switch (field_type) {
        .MYSQL_TYPE_TIME, .MYSQL_TYPE_TIME2 => {
            buffer[1] = if (this.negative) 1 else 0;
            std.mem.writeInt(u32, buffer[2..6], this.days, .little);
            buffer[6] = this.hours;
            buffer[7] = this.minutes;
            buffer[8] = this.seconds;
            if (this.microseconds == 0) {
                buffer[0] = 8; // length
                return 9;
            } else {
                buffer[0] = 12; // length
                std.mem.writeInt(u32, buffer[9..][0..4], this.microseconds, .little);
                return 13;
            }
        },
        else => unreachable,
    }
}

const std = @import("std");
const FieldType = @import("mysql_domain").types.FieldType;
