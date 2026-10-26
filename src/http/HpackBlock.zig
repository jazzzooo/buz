pub const PendingCapacity = struct {
    smallest: u32,
    final: u32,

    pub fn record(pending: *?PendingCapacity, capacity: u32) void {
        if (pending.*) |*existing| {
            existing.smallest = @min(existing.smallest, capacity);
            existing.final = capacity;
        } else {
            pending.* = .{ .smallest = capacity, .final = capacity };
        }
    }
};

pub const EncodedSizeUpdate = struct {
    bytes: [6]u8 = undefined,
    len: u8,

    pub fn slice(update: *const EncodedSizeUpdate) []const u8 {
        return update.bytes[0..update.len];
    }
};

pub fn encodeSizeUpdate(capacity: u32) EncodedSizeUpdate {
    var result: EncodedSizeUpdate = .{ .len = 1 };
    if (capacity < 31) {
        result.bytes[0] = 0x20 | @as(u8, @intCast(capacity));
        return result;
    }

    result.bytes[0] = 0x3f;
    var remaining = capacity - 31;
    while (remaining >= 128) : (remaining >>= 7) {
        result.bytes[result.len] = @as(u8, @truncate(remaining)) | 0x80;
        result.len += 1;
    }
    result.bytes[result.len] = @intCast(remaining);
    result.len += 1;
    return result;
}

test "capacity changes retain the smallest and final values" {
    var pending: ?PendingCapacity = null;
    PendingCapacity.record(&pending, 2048);
    PendingCapacity.record(&pending, 4096);
    PendingCapacity.record(&pending, 3072);
    try std.testing.expectEqual(@as(u32, 2048), pending.?.smallest);
    try std.testing.expectEqual(@as(u32, 3072), pending.?.final);
}

test "dynamic table size updates use the HPACK five-bit prefix" {
    try std.testing.expectEqualSlices(u8, &.{0x20}, encodeSizeUpdate(0).slice());
    try std.testing.expectEqualSlices(u8, &.{0x3e}, encodeSizeUpdate(30).slice());
    try std.testing.expectEqualSlices(u8, &.{ 0x3f, 0x00 }, encodeSizeUpdate(31).slice());
    try std.testing.expectEqualSlices(u8, &.{ 0x3f, 0x01 }, encodeSizeUpdate(32).slice());
    try std.testing.expectEqualSlices(u8, &.{ 0x3f, 0xe1, 0x1f }, encodeSizeUpdate(4096).slice());
}

const std = @import("std");
