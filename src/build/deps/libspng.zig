//! libspng compile recipe. Hand-maintained; update when bumping the dep.

const m = @import("deps.zig");

pub const dep: m.Dep = .{
    .name = "libspng",
    .groups = &.{
        .{
            .flags = &.{ "-DSPNG_STATIC", "-DSPNG_SSE=1" },
            .includes = &.{ .{ .dep = .{ "libspng", "spng" } }, .{ .gen = .{ "zlib", "" } } },
            .files = &.{
                "spng/spng.c",
            },
        },
    },
};
