const CPUFeatures = @This();

flags: Flags,

pub const Flags = switch (@import("builtin").cpu.arch) {
    .x86_64 => packed struct(u8) {
        none: bool,

        sse42: bool,
        popcnt: bool,
        avx: bool,
        avx2: bool,
        avx512: bool,

        padding: u2 = 0,
    },
    .aarch64 => packed struct(u8) {
        none: bool,

        neon: bool,
        fp: bool,
        aes: bool,
        crc32: bool,
        atomics: bool,
        sve: bool,

        padding: u1 = 0,
    },
    else => unreachable,
};

pub fn format(features: @This(), writer: *std.Io.Writer) !void {
    var is_first = true;
    inline for (@typeInfo(Flags).@"struct".field_names) |field_name| brk: {
        if (comptime (bun.strings.eql(field_name, "padding") or
            bun.strings.eql(field_name, "none")))
            break :brk;

        if (@field(features.flags, field_name)) {
            if (!is_first)
                try writer.writeAll(" ");
            is_first = false;
            try writer.writeAll(field_name);
        }
    }
}

pub fn isEmpty(features: CPUFeatures) bool {
    return @as(u8, @bitCast(features.flags)) == 0;
}

pub fn hasAnyAVX(features: CPUFeatures) bool {
    return features.flags.avx or features.flags.avx2 or features.flags.avx512;
}

pub fn detect() Flags {
    const flags: Flags = @bitCast(bun.bindgen.Engine(DetectSchema).call(.{}));
    bun.debugAssert(!flags.none and flags.padding == 0);
    return flags;
}

pub fn get() CPUFeatures {
    const flags = detect();
    if (bun.Environment.isX64) {
        bun.analytics.Features.no_avx += @as(usize, @intFromBool(!flags.avx));
        bun.analytics.Features.no_avx2 += @as(usize, @intFromBool(!flags.avx2));
    }

    return .{ .flags = flags };
}

const bun = @import("bun");
const std = @import("std");
const DetectSchema = bun.bindgen.Module("CPUFeatures").engineShim("detect");
