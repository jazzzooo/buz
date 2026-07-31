// Length-encoded integer encoding/decoding
pub fn encodedLengthIntSize(value: u64) usize {
    if (value < 0xfb) return 1;
    if (value < 0x10000) return 3;
    if (value < 0x1000000) return 4;
    return 9;
}

pub fn encodeLengthInt(value: u64, buffer: *[9]u8) []const u8 {
    const len = encodedLengthIntSize(value);
    switch (len) {
        1 => buffer[0] = @intCast(value),
        3 => {
            buffer[0] = 0xfc;
            std.mem.writeInt(u16, buffer[1..3], @intCast(value), .little);
        },
        4 => {
            buffer[0] = 0xfd;
            std.mem.writeInt(u24, buffer[1..4], @intCast(value), .little);
        },
        9 => {
            buffer[0] = 0xfe;
            std.mem.writeInt(u64, buffer[1..9], value, .little);
        },
        else => unreachable,
    }
    return buffer[0..len];
}

pub fn decodeLengthInt(bytes: []const u8) ?struct { value: u64, bytes_read: usize } {
    if (bytes.len == 0) return null;

    const first_byte = bytes[0];

    switch (first_byte) {
        0xfc => {
            if (bytes.len < 3) return null;
            return .{
                .value = std.mem.readInt(u16, bytes[1..3], .little),
                .bytes_read = 3,
            };
        },
        0xfd => {
            if (bytes.len < 4) return null;
            return .{
                .value = std.mem.readInt(u24, bytes[1..4], .little),
                .bytes_read = 4,
            };
        },
        0xfe => {
            if (bytes.len < 9) return null;
            return .{
                .value = std.mem.readInt(u64, bytes[1..9], .little),
                .bytes_read = 9,
            };
        },
        else => return .{ .value = first_byte, .bytes_read = 1 },
    }
}

const std = @import("std");
