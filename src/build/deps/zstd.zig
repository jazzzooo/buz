//! zstd compile recipe. Hand-maintained; update when bumping the dep.

const m = @import("deps.zig");

pub const dep: m.Dep = .{
    .name = "zstd",
    .groups = &.{
        .{
            .flags = &.{ "-fPIC", "-DZSTD_MULTITHREAD", "-DZSTD_LEGACY_SUPPORT=0", "-DXXH_NAMESPACE=ZSTD_" },
            .includes = &.{ .{ .dep = .{ "zstd", "lib" } }, .{ .dep = .{ "zstd", "lib/common" } } },
            .files = &.{
                "lib/common/debug.c",
                "lib/common/entropy_common.c",
                "lib/common/error_private.c",
                "lib/common/fse_decompress.c",
                "lib/common/pool.c",
                "lib/common/threading.c",
                "lib/common/xxhash.c",
                "lib/common/zstd_common.c",
                "lib/compress/fse_compress.c",
                "lib/compress/hist.c",
                "lib/compress/huf_compress.c",
                "lib/compress/zstd_compress.c",
                "lib/compress/zstd_compress_literals.c",
                "lib/compress/zstd_compress_sequences.c",
                "lib/compress/zstd_compress_superblock.c",
                "lib/compress/zstd_double_fast.c",
                "lib/compress/zstd_fast.c",
                "lib/compress/zstd_lazy.c",
                "lib/compress/zstd_ldm.c",
                "lib/compress/zstd_opt.c",
                "lib/compress/zstd_preSplit.c",
                "lib/compress/zstdmt_compress.c",
                "lib/decompress/huf_decompress.c",
                "lib/decompress/huf_decompress_amd64.S",
                "lib/decompress/zstd_ddict.c",
                "lib/decompress/zstd_decompress.c",
                "lib/decompress/zstd_decompress_block.c",
                "lib/dictBuilder/cover.c",
                "lib/dictBuilder/divsufsort.c",
                "lib/dictBuilder/fastcover.c",
                "lib/dictBuilder/zdict.c",
            },
        },
    },
};
