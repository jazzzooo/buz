//! lshpack compile recipe. Hand-maintained; update when bumping the dep.

const m = @import("deps.zig");

pub const dep: m.Dep = .{
    .name = "lshpack",
    .groups = &.{
        .{
            .flags = &.{ "-DXXH_HEADER_NAME=\"xxhash.h\"", "-DLS_HPACK_USE_LARGE_TABLES=1", "-DLS_HPACK_BSS_LARGE_TABLES=1" },
            .includes = &.{ .{ .dep = .{ "lshpack", "" } }, .{ .dep = .{ "lshpack", "deps/xxhash" } } },
            .files = &.{
                "deps/xxhash/xxhash.c",
                "lshpack.c",
            },
        },
    },
};
