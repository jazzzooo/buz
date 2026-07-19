//! picohttpparser compile recipe. Hand-maintained; update when bumping the dep.

const m = @import("deps.zig");

pub const dep: m.Dep = .{
    .name = "picohttpparser",
    .groups = &.{
        .{
            .flags = &.{"-std=gnu17"},
            .includes = &.{.{ .dep = .{ "picohttpparser", "" } }},
            .files = &.{
                "picohttpparser.c",
            },
        },
    },
};
