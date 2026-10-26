const DateTime = @This();

year: u16 = 0,
month: u8 = 0,
day: u8 = 0,
hour: u8 = 0,
minute: u8 = 0,
second: u8 = 0,
microsecond: u32 = 0,

pub fn fromBinary(val: []const u8) DateTime {
    switch (val.len) {
        4 => {
            // Byte 1: [year LSB]     (8 bits of year)
            // Byte 2: [year MSB]     (8 bits of year)
            // Byte 3: [month]        (8-bit unsigned integer, 1-12)
            // Byte 4: [day]          (8-bit unsigned integer, 1-31)
            return .{
                .year = std.mem.readInt(u16, val[0..2], .little),
                .month = val[2],
                .day = val[3],
            };
        },
        7 => {
            //                     Byte 1: [year LSB]     (8 bits of year)
            // Byte 2: [year MSB]     (8 bits of year)
            // Byte 3: [month]        (8-bit unsigned integer, 1-12)
            // Byte 4: [day]          (8-bit unsigned integer, 1-31)
            // Byte 5: [hour]         (8-bit unsigned integer, 0-23)
            // Byte 6: [minute]       (8-bit unsigned integer, 0-59)
            // Byte 7: [second]       (8-bit unsigned integer, 0-59)
            return .{
                .year = std.mem.readInt(u16, val[0..2], .little),
                .month = val[2],
                .day = val[3],
                .hour = val[4],
                .minute = val[5],
                .second = val[6],
            };
        },
        11 => {
            //                     Byte 1:    [year LSB]      (8 bits of year)
            // Byte 2:    [year MSB]      (8 bits of year)
            // Byte 3:    [month]         (8-bit unsigned integer, 1-12)
            // Byte 4:    [day]           (8-bit unsigned integer, 1-31)
            // Byte 5:    [hour]          (8-bit unsigned integer, 0-23)
            // Byte 6:    [minute]        (8-bit unsigned integer, 0-59)
            // Byte 7:    [second]        (8-bit unsigned integer, 0-59)
            // Byte 8-11: [microseconds]  (32-bit little-endian unsigned integer
            return .{
                .year = std.mem.readInt(u16, val[0..2], .little),
                .month = val[2],
                .day = val[3],
                .hour = val[4],
                .minute = val[5],
                .second = val[6],
                .microsecond = std.mem.readInt(u32, val[7..11], .little),
            };
        },
        else => std.debug.panic("Invalid datetime length: {d}", .{val.len}),
    }
}

pub fn toBinary(this: *const DateTime, field_type: FieldType, buffer: []u8) u8 {
    switch (field_type) {
        .MYSQL_TYPE_YEAR => {
            buffer[0] = 2;
            std.mem.writeInt(u16, buffer[1..3], this.year, .little);
            return 3;
        },
        .MYSQL_TYPE_DATE => {
            buffer[0] = 4;
            std.mem.writeInt(u16, buffer[1..3], this.year, .little);
            buffer[3] = this.month;
            buffer[4] = this.day;
            return 5;
        },
        .MYSQL_TYPE_DATETIME => {
            buffer[0] = if (this.microsecond == 0) 7 else 11;
            std.mem.writeInt(u16, buffer[1..3], this.year, .little);
            buffer[3] = this.month;
            buffer[4] = this.day;
            buffer[5] = this.hour;
            buffer[6] = this.minute;
            buffer[7] = this.second;
            if (this.microsecond == 0) {
                return 8;
            } else {
                std.mem.writeInt(u32, buffer[8..12], this.microsecond, .little);
                return 12;
            }
        },
        else => return 0,
    }
}

pub fn fromUnixTimestamp(timestamp: i64, microseconds: u32) DateTime {
    var ts = timestamp;
    const days = @divFloor(ts, 86400);
    ts = @mod(ts, 86400);

    const hour = @divFloor(ts, 3600);
    ts = @mod(ts, 3600);

    const minute = @divFloor(ts, 60);
    const second = @mod(ts, 60);

    const date = gregorianDate(@intCast(days));
    return .{
        .year = date.year,
        .month = date.month,
        .day = date.day,
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
        .microsecond = microseconds,
    };
}

pub fn fromMilliseconds(total_ms: f64) DateTime {
    const ts: i64 = @intFromFloat(@divFloor(total_ms, 1000));
    const ms: u32 = @intFromFloat(total_ms - (@as(f64, @floatFromInt(ts)) * 1000));
    return DateTime.fromUnixTimestamp(ts, ms * 1000);
}

fn gregorianDate(days: i32) Date {
    const date = GregorianDate.fromDaysSinceUnixEpoch(days);
    return .{ .year = @intCast(date.year), .month = date.month, .day = date.day };
}

const Date = struct { year: u16, month: u8, day: u8 };

const GregorianDate = @import("../../bun_core/GregorianDate.zig");
const std = @import("std");
const FieldType = @import("mysql_domain").types.FieldType;
