const std = @import("std");

pub const number_tag: u64 = 0xfffe000000000000;
pub const double_offset: u64 = 1 << 49;
pub const not_cell_mask: u64 = number_tag | 0x2;
pub const empty_value: i64 = 0;
pub const deleted_value: i64 = 0x4;
pub const undefined_value: i64 = 0xa;
pub const null_value: i64 = 0x2;
pub const false_value: i64 = 0x6;
pub const true_value: i64 = 0x7;

pub fn fromDouble(value: f64) i64 {
    // NaN payloads can overlap the cell and integer tags after encoding.
    const value_bits: u64 = @bitCast(if (std.math.isNan(value)) std.math.nan(f64) else value);
    return @bitCast(value_bits +% double_offset);
}

pub fn fromInt32(value: i32) i64 {
    return @bitCast(number_tag | @as(u32, @bitCast(value)));
}

pub fn isInt32(encoded: i64) bool {
    return (bits(encoded) & number_tag) == number_tag;
}

pub fn isNumber(encoded: i64) bool {
    return (bits(encoded) & number_tag) != 0;
}

pub fn isCell(encoded: i64) bool {
    return encoded != empty_value and encoded != deleted_value and (bits(encoded) & not_cell_mask) == 0;
}

pub fn asDouble(encoded: i64) f64 {
    std.debug.assert(isNumber(encoded) and !isInt32(encoded));
    return @bitCast(bits(encoded) -% double_offset);
}

pub fn asInt32(encoded: i64) i32 {
    std.debug.assert(isInt32(encoded));
    return @bitCast(@as(u32, @truncate(bits(encoded))));
}

pub fn cellPointer(comptime Pointer: type, encoded: i64) Pointer {
    std.debug.assert(isCell(encoded));
    return @ptrFromInt(bits(encoded));
}

pub fn fromCell(pointer: anytype) i64 {
    const encoded: i64 = @bitCast(@as(u64, @intFromPtr(pointer)));
    std.debug.assert(isCell(encoded));
    return encoded;
}

fn bits(encoded: i64) u64 {
    return @bitCast(encoded);
}

test "number encoding preserves signed zero and canonicalizes colliding NaNs" {
    for ([_]u64{ 0x7ff0000000000001, 0x7fffffffffffffff, 0xfff8000000000000, 0xffffffffffffffff }) |payload| {
        const encoded = fromDouble(@bitCast(payload));
        try std.testing.expect(isNumber(encoded));
        try std.testing.expect(!isInt32(encoded));
        try std.testing.expect(!isCell(encoded));
        try std.testing.expect(std.math.isNan(asDouble(encoded)));
    }
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(asDouble(fromDouble(-0.0)))));
}
