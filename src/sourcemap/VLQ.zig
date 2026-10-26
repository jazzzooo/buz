//! Variable-length quantity encoding, limited to i32 as per source map spec.
//! https://en.wikipedia.org/wiki/Variable-length_quantity
//! https://sourcemaps.info/spec.html

const VLQ = @This();

/// The maximum encoding length is seven bytes, making `VLQ` eight bytes.
bytes: [vlq_max_in_bytes]u8,
/// This is a u8 and not a u4 because non^2 integers are really slow in Zig.
len: u8 = 0,

pub inline fn slice(self: *const VLQ) []const u8 {
    return self.bytes[0..self.len];
}

pub fn writeTo(self: VLQ, writer: anytype) !void {
    try writer.writeAll(self.bytes[0..self.len]);
}

pub const zero = vlq_lookup_table[0];

const vlq_lookup_table: [256]VLQ = brk: {
    @setEvalBranchQuota(10_000);
    var entries: [256]VLQ = undefined;
    var i: usize = 0;
    var j: i32 = 0;
    while (i < 256) : (i += 1) {
        entries[i] = encodeSlowPath(j);
        j += 1;
    }
    break :brk entries;
};

const vlq_max_in_bytes = 7;

pub fn encode(value: i32) VLQ {
    return if (value >= 0 and value <= 255)
        vlq_lookup_table[@as(usize, @intCast(value))]
    else
        encodeSlowPath(value);
}

// A single base 64 digit can contain 6 bits of data. For the base 64 variable
// length quantities we use in the source map spec, the first bit is the sign,
// the next four bits are the actual value, and the 6th bit is the continuation
// bit. The continuation bit tells us whether there are more digits in this
// value following this digit.
//
//   Continuation
//   |    Sign
//   |    |
//   V    V
//   101011
//
fn encodeSlowPath(value: i32) VLQ {
    var len: u8 = 0;
    var bytes: [vlq_max_in_bytes]u8 = undefined;

    // ECMA-426 uses the zero-magnitude negative encoding for i32::MIN.
    var vlq: u32 = if (value == std.math.minInt(i32))
        1
    else if (value >= 0)
        @as(u32, @bitCast(value << 1))
    else
        @as(u32, @bitCast((-value << 1) | 1));

    // source mappings are limited to i32
    inline for (0..vlq_max_in_bytes) |_| {
        var digit = vlq & 31;
        vlq >>= 5;

        // If there are still more digits in this value, we must make sure the
        // continuation bit is marked
        if (vlq != 0) {
            digit |= 32;
        }

        bytes[len] = base64[digit];
        len += 1;

        if (vlq == 0) {
            return .{ .bytes = bytes, .len = len };
        }
    }

    return .{ .bytes = bytes, .len = 0 };
}

pub const VLQResult = struct {
    value: i32 = 0,
    start: usize = 0,
};

const base64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// base64 stores values up to 7 bits
const base64_lut: [128]u8 = brk: {
    @setEvalBranchQuota(9999);
    var bytes: [128]u8 = @splat(std.math.maxInt(u7));

    for (base64, 0..) |c, i| {
        bytes[c] = i;
    }

    break :brk bytes;
};

pub fn decode(encoded: []const u8, start: usize) VLQResult {
    if (start >= encoded.len) return .{};
    var shift: u6 = 0;
    var vlq: u32 = 0;
    for (encoded[start..], start..) |byte, position| {
        if (byte >= base64_lut.len) return .{};
        const digit = base64_lut[byte];
        if (digit == std.math.maxInt(u7)) return .{};
        const payload: u32 = digit & 31;
        if (shift > 30) {
            if (payload != 0) return .{};
        } else {
            if (shift == 30 and payload > 3) return .{};
            vlq |= payload << @as(u5, @intCast(shift));
        }
        if (digit & 32 == 0) {
            return VLQResult{
                .start = position + 1,
                .value = if (vlq == 1)
                    std.math.minInt(i32)
                else if ((vlq & 1) == 0)
                    @as(i32, @intCast(vlq >> 1))
                else
                    -@as(i32, @intCast((vlq >> 1))),
            };
        }
        shift = @min(shift + 5, 35);
    }
    return .{};
}

pub fn decodeAssumeValid(encoded: []const u8, start: usize) VLQResult {
    const result = decode(encoded, start);
    bun.assert(result.start > start);
    return result;
}

test "VLQ covers signed boundaries and rejects malformed input" {
    for ([_]i32{ std.math.minInt(i32), -2147483647, -256, -1, 0, 1, 255, 256, std.math.maxInt(i32) }) |value| {
        const encoded = encode(value);
        const decoded = decode(encoded.slice(), 0);
        try std.testing.expectEqual(value, decoded.value);
        try std.testing.expectEqual(@as(usize, encoded.len), decoded.start);
        try std.testing.expectEqual(value, decodeAssumeValid(encoded.slice(), 0).value);
    }
    const minimum = encode(std.math.minInt(i32));
    try std.testing.expectEqualStrings("B", minimum.slice());
    for ([_][]const u8{ "", "?", "\x7f", "\xc1", "g", "gggggg", "//////E", "gggggggB" }) |invalid| {
        try std.testing.expectEqual(@as(usize, 0), decode(invalid, 0).start);
    }
    try std.testing.expectEqual(@as(usize, 0), decode("A", 2).start);
    try std.testing.expectEqual(@as(i32, 1), decode("!C?", 1).value);
    try std.testing.expectEqual(@as(usize, 2), decode("!C?", 1).start);
    try std.testing.expectEqual(@as(usize, 9), decode("ggggggggA", 0).start);
}

const bun = @import("bun");
const std = @import("std");
