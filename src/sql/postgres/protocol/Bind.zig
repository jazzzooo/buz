pub fn write(name: []const u8, parameters: anytype, result_fields: []const FieldDescription, writer: anytype) AnyPostgresError!void {
    if (parameters.len() > std.math.maxInt(u16) or result_fields.len > std.math.maxInt(u16)) return error.TooManyParameters;
    try writer.write("B");
    const message_length = try writer.length();
    try writer.string("");
    try writer.string(name);
    try writer.short(parameters.len());
    for (0..parameters.len()) |i| try writer.short(@as(u16, if (parameters.at(i) == .text or parameters.at(i) == .null_value) 0 else 1));
    try writer.short(parameters.len());
    for (0..parameters.len()) |i| {
        const value = parameters.at(i);
        if (value == .null_value) {
            try writer.int4(std.math.maxInt(u32));
            continue;
        }
        const length = try writer.length();
        switch (value) {
            .null_value => unreachable,
            .boolean => |boolean| try writer.write(&.{@intFromBool(boolean)}),
            .int16 => |number| try writer.short(@as(u16, @bitCast(number))),
            .int32 => |number| try writer.int4(@bitCast(number)),
            .int64 => |number| try writer.int8(number),
            .float32 => |number| try writer.f32(number),
            .float64 => |number| try writer.f64(number),
            .date => |milliseconds| {
                if (std.math.isInf(milliseconds)) {
                    try writer.int8(if (milliseconds < 0) std.math.minInt(i64) else std.math.maxInt(i64));
                } else {
                    const timestamp: i64 = @intFromFloat(milliseconds);
                    const epoch = try std.math.sub(i64, timestamp, 946684800000);
                    try writer.int8(try std.math.mul(i64, epoch, std.time.us_per_ms));
                }
            },
            .text, .bytes => |bytes| {
                if (bytes.len > std.math.maxInt(i32)) return error.Overflow;
                try writer.write(bytes);
            },
            .int32_array => |bytes| {
                if (bytes.len % 4 != 0 or bytes.len / 4 > std.math.maxInt(i32)) return error.InvalidQueryBinding;
                try writer.int4(1);
                try writer.int4(0);
                try writer.int4(23);
                try writer.int4(@intCast(bytes.len / 4));
                try writer.int4(1);
                var index: usize = 0;
                while (index < bytes.len) : (index += 4) {
                    try writer.int4(4);
                    try writer.int4(std.mem.readInt(u32, bytes[index..][0..4], @import("builtin").target.cpu.arch.endian()));
                }
            },
            .uint16, .uint32, .uint64, .time => return error.InvalidQueryBinding,
        }
        try length.writeExcludingSelf();
    }
    var any_binary = false;
    for (result_fields) |field| any_binary = any_binary or field.typeTag().isBinaryFormatSupported();
    try writer.short(if (any_binary) result_fields.len else 0);
    if (any_binary) for (result_fields) |field| try writer.short(field.typeTag().formatCode());
    try message_length.write();
}

const std = @import("std");
const FieldDescription = @import("./FieldDescription.zig");
const AnyPostgresError = @import("../AnyPostgresError.zig").AnyPostgresError;
