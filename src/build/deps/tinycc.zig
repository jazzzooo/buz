//! tinycc compile recipe. Hand-maintained; update when bumping the dep.

const m = @import("deps.zig");

pub const dep: m.Dep = .{
    .name = "tinycc",
    .groups = &.{
        .{
            .flags = &.{ "-DCONFIG_TCC_PREDEFS", "-DONE_SOURCE=0", "-DTCC_LIBTCC1=\"\"", "-DCONFIG_TCC_BACKTRACE=0", "-DTCC_VERSION=\"12882eee\"", "-DTCC_GITHASH=\"12882eee\"", "-fno-strict-aliasing" },
            .includes = &.{ .{ .dep = .{ "tinycc", "" } }, .{ .dep = .{ "tinycc", "include" } }, .{ .gen = .{ "tinycc", "" } } },
            .files = &.{
                "i386-asm.c",
                "libtcc.c",
                "tccasm.c",
                "tccdbg.c",
                "tccelf.c",
                "tccgen.c",
                "tccpp.c",
                "tccrun.c",
                "x86_64-gen.c",
                "x86_64-link.c",
            },
        },
    },
};
