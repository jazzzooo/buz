const std = @import("std");

const secret = [3]u64{
    0x2d358dccaa6c78a5,
    0x8bb84b93962eacc9,
    0x4b33a62ed433d4a3,
};

pub fn hash(seed: u64, input: []const u8) u64 {
    const len = input.len;
    const len64: u64 = @intCast(len);
    var a: u64 = 0;
    var b: u64 = 0;
    var remaining_input = input;
    var state = [3]u64{ seed, 0, 0 };

    state[0] ^= mix(seed ^ secret[0], secret[1]) ^ len64;

    if (len <= 16) {
        if (len >= 4) {
            const offset = (len & 24) >> @intCast(len >> 3);
            const end = len - 4;
            a = (read32(remaining_input) << 32) | read32(remaining_input[end..]);
            b = (read32(remaining_input[offset..]) << 32) | read32(remaining_input[end - offset ..]);
        } else if (len > 0) {
            a = (@as(u64, remaining_input[0]) << 56) |
                (@as(u64, remaining_input[len >> 1]) << 32) |
                remaining_input[len - 1];
        }
    } else {
        var remaining = len;
        if (len > 48) {
            state[1] = state[0];
            state[2] = state[0];
            while (remaining >= 96) {
                inline for (0..6) |i| {
                    const lhs = read64(remaining_input[16 * i ..]);
                    const rhs = read64(remaining_input[16 * i + 8 ..]);
                    state[i % 3] = mix(lhs ^ secret[i % 3], rhs ^ state[i % 3]);
                }
                remaining_input = remaining_input[96..];
                remaining -= 96;
            }
            if (remaining >= 48) {
                inline for (0..3) |i| {
                    const lhs = read64(remaining_input[16 * i ..]);
                    const rhs = read64(remaining_input[16 * i + 8 ..]);
                    state[i] = mix(lhs ^ secret[i], rhs ^ state[i]);
                }
                remaining_input = remaining_input[48..];
                remaining -= 48;
            }

            state[0] ^= state[1] ^ state[2];
        }

        if (remaining > 16) {
            state[0] = mix(read64(remaining_input) ^ secret[2], read64(remaining_input[8..]) ^ state[0] ^ secret[1]);
            if (remaining > 32) {
                state[0] = mix(read64(remaining_input[16..]) ^ secret[2], read64(remaining_input[24..]) ^ state[0]);
            }
        }

        a = read64(input[len - 16 ..]);
        b = read64(input[len - 8 ..]);
    }

    a ^= secret[1];
    b ^= state[0];
    mum(&a, &b);
    return mix(a ^ secret[0] ^ len64, b ^ secret[1]);
}

inline fn mum(a: *u64, b: *u64) void {
    const product = @as(u128, a.*) * b.*;
    a.* = @truncate(product);
    b.* = @truncate(product >> 64);
}

inline fn mix(a: u64, b: u64) u64 {
    var lhs = a;
    var rhs = b;
    mum(&lhs, &rhs);
    return lhs ^ rhs;
}

inline fn read64(input: []const u8) u64 {
    return std.mem.readInt(u64, input[0..8], .little);
}

inline fn read32(input: []const u8) u64 {
    return std.mem.readInt(u32, input[0..4], .little);
}
