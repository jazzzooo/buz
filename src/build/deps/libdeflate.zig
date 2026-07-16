//! libdeflate compile recipe. Hand-maintained; update when bumping the dep.

const m = @import("deps.zig");

pub const dep: m.Dep = .{
    .name = "libdeflate",
    .groups = &.{
        .{
            .flags = &.{},
            .includes = &.{.{ .dep = .{ "libdeflate", "" } }},
            .files = &.{
                "lib/adler32.c",
                "lib/arm/cpu_features.c",
                "lib/crc32.c",
                "lib/deflate_compress.c",
                "lib/deflate_decompress.c",
                "lib/gzip_compress.c",
                "lib/gzip_decompress.c",
                "lib/utils.c",
                "lib/x86/cpu_features.c",
                "lib/zlib_compress.c",
                "lib/zlib_decompress.c",
            },
        },
    },
};
