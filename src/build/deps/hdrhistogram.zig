//! hdrhistogram compile recipe. Hand-maintained; update when bumping the dep.

const m = @import("deps.zig");

pub const dep: m.Dep = .{
    .name = "hdrhistogram",
    .groups = &.{
        .{
            .flags = &.{"-D_GNU_SOURCE"},
            .includes = &.{.{ .dep = .{ "hdrhistogram", "include" } }},
            .files = &.{
                "src/hdr_encoding.c",
                "src/hdr_histogram.c",
                "src/hdr_histogram_log_no_op.c",
            },
        },
    },
};
