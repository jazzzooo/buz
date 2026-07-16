//! zlib compile recipe. Hand-maintained; update when bumping the dep.

const m = @import("deps.zig");

pub const dep: m.Dep = .{
    .name = "zlib",
    .groups = &.{
        .{
            .flags = &.{ "-DZLIB_COMPAT", "-DWITH_GZFILEOP", "-DWITH_OPTIM", "-DINFLATE_STRICT", "-DHAVE_ATTRIBUTE_ALIGNED", "-DHAVE_BUILTIN_ASSUME_ALIGNED", "-DHAVE_BUILTIN_CTZ", "-DHAVE_BUILTIN_CTZLL", "-DHAVE_VISIBILITY_HIDDEN", "-DHAVE_VISIBILITY_INTERNAL", "-DHAVE_POSIX_MEMALIGN", "-D_LARGEFILE64_SOURCE=1", "-D__USE_LARGEFILE64", "-DHAVE_SYS_AUXV_H", "-DX86_FEATURES", "-DX86_HAVE_XSAVE_INTRIN", "-DHAVE_CPUID_GNU", "-DX86_SSE2", "-DX86_SSSE3", "-DX86_SSE41", "-DX86_SSE42", "-DX86_PCLMULQDQ_CRC", "-DX86_AVX2", "-DX86_AVX512", "-DX86_AVX512VNNI", "-DX86_VPCLMULQDQ_CRC" },
            .includes = &.{ .{ .dep = .{ "zlib", "" } }, .{ .dep = .{ "zlib", "arch/generic" } }, .{ .dep = .{ "zlib", "arch/x86" } }, .{ .gen = .{ "zlib", "" } } },
            .files = &.{
                "adler32.c",
                "arch/generic/adler32_c.c",
                "arch/generic/adler32_fold_c.c",
                "arch/generic/crc32_braid_c.c",
                "arch/generic/crc32_chorba_c.c",
                "arch/generic/crc32_fold_c.c",
                "compress.c",
                "cpu_features.c",
                "crc32.c",
                "crc32_braid_comb.c",
                "deflate.c",
                "deflate_fast.c",
                "deflate_huff.c",
                "deflate_medium.c",
                "deflate_quick.c",
                "deflate_rle.c",
                "deflate_slow.c",
                "deflate_stored.c",
                "functable.c",
                "gzlib.c",
                "gzread.c",
                "gzwrite.c",
                "infback.c",
                "inflate.c",
                "inftrees.c",
                "insert_string.c",
                "insert_string_roll.c",
                "trees.c",
                "uncompr.c",
                "zutil.c",
            },
        },
        .{
            .flags = &.{ "-DZLIB_COMPAT", "-DWITH_GZFILEOP", "-DWITH_OPTIM", "-DINFLATE_STRICT", "-DHAVE_ATTRIBUTE_ALIGNED", "-DHAVE_BUILTIN_ASSUME_ALIGNED", "-DHAVE_BUILTIN_CTZ", "-DHAVE_BUILTIN_CTZLL", "-DHAVE_VISIBILITY_HIDDEN", "-DHAVE_VISIBILITY_INTERNAL", "-DHAVE_POSIX_MEMALIGN", "-D_LARGEFILE64_SOURCE=1", "-D__USE_LARGEFILE64", "-DHAVE_SYS_AUXV_H", "-DX86_FEATURES", "-DX86_HAVE_XSAVE_INTRIN", "-DHAVE_CPUID_GNU", "-DX86_SSE2", "-DX86_SSSE3", "-DX86_SSE41", "-DX86_SSE42", "-DX86_PCLMULQDQ_CRC", "-DX86_AVX2", "-DX86_AVX512", "-DX86_AVX512VNNI", "-DX86_VPCLMULQDQ_CRC", "-mxsave" },
            .includes = &.{ .{ .dep = .{ "zlib", "" } }, .{ .dep = .{ "zlib", "arch/generic" } }, .{ .dep = .{ "zlib", "arch/x86" } }, .{ .gen = .{ "zlib", "" } } },
            .files = &.{
                "arch/x86/x86_features.c",
            },
        },
        .{
            .flags = &.{ "-DZLIB_COMPAT", "-DWITH_GZFILEOP", "-DWITH_OPTIM", "-DINFLATE_STRICT", "-DHAVE_ATTRIBUTE_ALIGNED", "-DHAVE_BUILTIN_ASSUME_ALIGNED", "-DHAVE_BUILTIN_CTZ", "-DHAVE_BUILTIN_CTZLL", "-DHAVE_VISIBILITY_HIDDEN", "-DHAVE_VISIBILITY_INTERNAL", "-DHAVE_POSIX_MEMALIGN", "-D_LARGEFILE64_SOURCE=1", "-D__USE_LARGEFILE64", "-DHAVE_SYS_AUXV_H", "-DX86_FEATURES", "-DX86_HAVE_XSAVE_INTRIN", "-DHAVE_CPUID_GNU", "-DX86_SSE2", "-DX86_SSSE3", "-DX86_SSE41", "-DX86_SSE42", "-DX86_PCLMULQDQ_CRC", "-DX86_AVX2", "-DX86_AVX512", "-DX86_AVX512VNNI", "-DX86_VPCLMULQDQ_CRC", "-msse2", "-fno-lto" },
            .includes = &.{ .{ .dep = .{ "zlib", "" } }, .{ .dep = .{ "zlib", "arch/generic" } }, .{ .dep = .{ "zlib", "arch/x86" } }, .{ .gen = .{ "zlib", "" } } },
            .files = &.{
                "arch/x86/chorba_sse2.c",
                "arch/x86/chunkset_sse2.c",
                "arch/x86/compare256_sse2.c",
                "arch/x86/slide_hash_sse2.c",
            },
        },
        .{
            .flags = &.{ "-DZLIB_COMPAT", "-DWITH_GZFILEOP", "-DWITH_OPTIM", "-DINFLATE_STRICT", "-DHAVE_ATTRIBUTE_ALIGNED", "-DHAVE_BUILTIN_ASSUME_ALIGNED", "-DHAVE_BUILTIN_CTZ", "-DHAVE_BUILTIN_CTZLL", "-DHAVE_VISIBILITY_HIDDEN", "-DHAVE_VISIBILITY_INTERNAL", "-DHAVE_POSIX_MEMALIGN", "-D_LARGEFILE64_SOURCE=1", "-D__USE_LARGEFILE64", "-DHAVE_SYS_AUXV_H", "-DX86_FEATURES", "-DX86_HAVE_XSAVE_INTRIN", "-DHAVE_CPUID_GNU", "-DX86_SSE2", "-DX86_SSSE3", "-DX86_SSE41", "-DX86_SSE42", "-DX86_PCLMULQDQ_CRC", "-DX86_AVX2", "-DX86_AVX512", "-DX86_AVX512VNNI", "-DX86_VPCLMULQDQ_CRC", "-mssse3", "-fno-lto" },
            .includes = &.{ .{ .dep = .{ "zlib", "" } }, .{ .dep = .{ "zlib", "arch/generic" } }, .{ .dep = .{ "zlib", "arch/x86" } }, .{ .gen = .{ "zlib", "" } } },
            .files = &.{
                "arch/x86/adler32_ssse3.c",
                "arch/x86/chunkset_ssse3.c",
            },
        },
        .{
            .flags = &.{ "-DZLIB_COMPAT", "-DWITH_GZFILEOP", "-DWITH_OPTIM", "-DINFLATE_STRICT", "-DHAVE_ATTRIBUTE_ALIGNED", "-DHAVE_BUILTIN_ASSUME_ALIGNED", "-DHAVE_BUILTIN_CTZ", "-DHAVE_BUILTIN_CTZLL", "-DHAVE_VISIBILITY_HIDDEN", "-DHAVE_VISIBILITY_INTERNAL", "-DHAVE_POSIX_MEMALIGN", "-D_LARGEFILE64_SOURCE=1", "-D__USE_LARGEFILE64", "-DHAVE_SYS_AUXV_H", "-DX86_FEATURES", "-DX86_HAVE_XSAVE_INTRIN", "-DHAVE_CPUID_GNU", "-DX86_SSE2", "-DX86_SSSE3", "-DX86_SSE41", "-DX86_SSE42", "-DX86_PCLMULQDQ_CRC", "-DX86_AVX2", "-DX86_AVX512", "-DX86_AVX512VNNI", "-DX86_VPCLMULQDQ_CRC", "-msse4.1", "-fno-lto" },
            .includes = &.{ .{ .dep = .{ "zlib", "" } }, .{ .dep = .{ "zlib", "arch/generic" } }, .{ .dep = .{ "zlib", "arch/x86" } }, .{ .gen = .{ "zlib", "" } } },
            .files = &.{
                "arch/x86/chorba_sse41.c",
            },
        },
        .{
            .flags = &.{ "-DZLIB_COMPAT", "-DWITH_GZFILEOP", "-DWITH_OPTIM", "-DINFLATE_STRICT", "-DHAVE_ATTRIBUTE_ALIGNED", "-DHAVE_BUILTIN_ASSUME_ALIGNED", "-DHAVE_BUILTIN_CTZ", "-DHAVE_BUILTIN_CTZLL", "-DHAVE_VISIBILITY_HIDDEN", "-DHAVE_VISIBILITY_INTERNAL", "-DHAVE_POSIX_MEMALIGN", "-D_LARGEFILE64_SOURCE=1", "-D__USE_LARGEFILE64", "-DHAVE_SYS_AUXV_H", "-DX86_FEATURES", "-DX86_HAVE_XSAVE_INTRIN", "-DHAVE_CPUID_GNU", "-DX86_SSE2", "-DX86_SSSE3", "-DX86_SSE41", "-DX86_SSE42", "-DX86_PCLMULQDQ_CRC", "-DX86_AVX2", "-DX86_AVX512", "-DX86_AVX512VNNI", "-DX86_VPCLMULQDQ_CRC", "-msse4.2", "-fno-lto" },
            .includes = &.{ .{ .dep = .{ "zlib", "" } }, .{ .dep = .{ "zlib", "arch/generic" } }, .{ .dep = .{ "zlib", "arch/x86" } }, .{ .gen = .{ "zlib", "" } } },
            .files = &.{
                "arch/x86/adler32_sse42.c",
            },
        },
        .{
            .flags = &.{ "-DZLIB_COMPAT", "-DWITH_GZFILEOP", "-DWITH_OPTIM", "-DINFLATE_STRICT", "-DHAVE_ATTRIBUTE_ALIGNED", "-DHAVE_BUILTIN_ASSUME_ALIGNED", "-DHAVE_BUILTIN_CTZ", "-DHAVE_BUILTIN_CTZLL", "-DHAVE_VISIBILITY_HIDDEN", "-DHAVE_VISIBILITY_INTERNAL", "-DHAVE_POSIX_MEMALIGN", "-D_LARGEFILE64_SOURCE=1", "-D__USE_LARGEFILE64", "-DHAVE_SYS_AUXV_H", "-DX86_FEATURES", "-DX86_HAVE_XSAVE_INTRIN", "-DHAVE_CPUID_GNU", "-DX86_SSE2", "-DX86_SSSE3", "-DX86_SSE41", "-DX86_SSE42", "-DX86_PCLMULQDQ_CRC", "-DX86_AVX2", "-DX86_AVX512", "-DX86_AVX512VNNI", "-DX86_VPCLMULQDQ_CRC", "-msse4.2", "-mpclmul", "-fno-lto" },
            .includes = &.{ .{ .dep = .{ "zlib", "" } }, .{ .dep = .{ "zlib", "arch/generic" } }, .{ .dep = .{ "zlib", "arch/x86" } }, .{ .gen = .{ "zlib", "" } } },
            .files = &.{
                "arch/x86/crc32_pclmulqdq.c",
            },
        },
        .{
            .flags = &.{ "-DZLIB_COMPAT", "-DWITH_GZFILEOP", "-DWITH_OPTIM", "-DINFLATE_STRICT", "-DHAVE_ATTRIBUTE_ALIGNED", "-DHAVE_BUILTIN_ASSUME_ALIGNED", "-DHAVE_BUILTIN_CTZ", "-DHAVE_BUILTIN_CTZLL", "-DHAVE_VISIBILITY_HIDDEN", "-DHAVE_VISIBILITY_INTERNAL", "-DHAVE_POSIX_MEMALIGN", "-D_LARGEFILE64_SOURCE=1", "-D__USE_LARGEFILE64", "-DHAVE_SYS_AUXV_H", "-DX86_FEATURES", "-DX86_HAVE_XSAVE_INTRIN", "-DHAVE_CPUID_GNU", "-DX86_SSE2", "-DX86_SSSE3", "-DX86_SSE41", "-DX86_SSE42", "-DX86_PCLMULQDQ_CRC", "-DX86_AVX2", "-DX86_AVX512", "-DX86_AVX512VNNI", "-DX86_VPCLMULQDQ_CRC", "-mavx2", "-mbmi2", "-fno-lto" },
            .includes = &.{ .{ .dep = .{ "zlib", "" } }, .{ .dep = .{ "zlib", "arch/generic" } }, .{ .dep = .{ "zlib", "arch/x86" } }, .{ .gen = .{ "zlib", "" } } },
            .files = &.{
                "arch/x86/adler32_avx2.c",
                "arch/x86/chunkset_avx2.c",
                "arch/x86/compare256_avx2.c",
                "arch/x86/slide_hash_avx2.c",
            },
        },
        .{
            .flags = &.{ "-DZLIB_COMPAT", "-DWITH_GZFILEOP", "-DWITH_OPTIM", "-DINFLATE_STRICT", "-DHAVE_ATTRIBUTE_ALIGNED", "-DHAVE_BUILTIN_ASSUME_ALIGNED", "-DHAVE_BUILTIN_CTZ", "-DHAVE_BUILTIN_CTZLL", "-DHAVE_VISIBILITY_HIDDEN", "-DHAVE_VISIBILITY_INTERNAL", "-DHAVE_POSIX_MEMALIGN", "-D_LARGEFILE64_SOURCE=1", "-D__USE_LARGEFILE64", "-DHAVE_SYS_AUXV_H", "-DX86_FEATURES", "-DX86_HAVE_XSAVE_INTRIN", "-DHAVE_CPUID_GNU", "-DX86_SSE2", "-DX86_SSSE3", "-DX86_SSE41", "-DX86_SSE42", "-DX86_PCLMULQDQ_CRC", "-DX86_AVX2", "-DX86_AVX512", "-DX86_AVX512VNNI", "-DX86_VPCLMULQDQ_CRC", "-mavx512f", "-mavx512dq", "-mavx512bw", "-mavx512vl", "-mbmi2", "-fno-lto" },
            .includes = &.{ .{ .dep = .{ "zlib", "" } }, .{ .dep = .{ "zlib", "arch/generic" } }, .{ .dep = .{ "zlib", "arch/x86" } }, .{ .gen = .{ "zlib", "" } } },
            .files = &.{
                "arch/x86/adler32_avx512.c",
                "arch/x86/chunkset_avx512.c",
                "arch/x86/compare256_avx512.c",
            },
        },
        .{
            .flags = &.{ "-DZLIB_COMPAT", "-DWITH_GZFILEOP", "-DWITH_OPTIM", "-DINFLATE_STRICT", "-DHAVE_ATTRIBUTE_ALIGNED", "-DHAVE_BUILTIN_ASSUME_ALIGNED", "-DHAVE_BUILTIN_CTZ", "-DHAVE_BUILTIN_CTZLL", "-DHAVE_VISIBILITY_HIDDEN", "-DHAVE_VISIBILITY_INTERNAL", "-DHAVE_POSIX_MEMALIGN", "-D_LARGEFILE64_SOURCE=1", "-D__USE_LARGEFILE64", "-DHAVE_SYS_AUXV_H", "-DX86_FEATURES", "-DX86_HAVE_XSAVE_INTRIN", "-DHAVE_CPUID_GNU", "-DX86_SSE2", "-DX86_SSSE3", "-DX86_SSE41", "-DX86_SSE42", "-DX86_PCLMULQDQ_CRC", "-DX86_AVX2", "-DX86_AVX512", "-DX86_AVX512VNNI", "-DX86_VPCLMULQDQ_CRC", "-mavx512f", "-mavx512dq", "-mavx512bw", "-mavx512vl", "-mavx512vnni", "-mbmi2", "-fno-lto" },
            .includes = &.{ .{ .dep = .{ "zlib", "" } }, .{ .dep = .{ "zlib", "arch/generic" } }, .{ .dep = .{ "zlib", "arch/x86" } }, .{ .gen = .{ "zlib", "" } } },
            .files = &.{
                "arch/x86/adler32_avx512_vnni.c",
            },
        },
        .{
            .flags = &.{ "-DZLIB_COMPAT", "-DWITH_GZFILEOP", "-DWITH_OPTIM", "-DINFLATE_STRICT", "-DHAVE_ATTRIBUTE_ALIGNED", "-DHAVE_BUILTIN_ASSUME_ALIGNED", "-DHAVE_BUILTIN_CTZ", "-DHAVE_BUILTIN_CTZLL", "-DHAVE_VISIBILITY_HIDDEN", "-DHAVE_VISIBILITY_INTERNAL", "-DHAVE_POSIX_MEMALIGN", "-D_LARGEFILE64_SOURCE=1", "-D__USE_LARGEFILE64", "-DHAVE_SYS_AUXV_H", "-DX86_FEATURES", "-DX86_HAVE_XSAVE_INTRIN", "-DHAVE_CPUID_GNU", "-DX86_SSE2", "-DX86_SSSE3", "-DX86_SSE41", "-DX86_SSE42", "-DX86_PCLMULQDQ_CRC", "-DX86_AVX2", "-DX86_AVX512", "-DX86_AVX512VNNI", "-DX86_VPCLMULQDQ_CRC", "-mpclmul", "-mvpclmulqdq", "-mavx512f", "-mavx512dq", "-mavx512bw", "-mavx512vl", "-mbmi2", "-fno-lto" },
            .includes = &.{ .{ .dep = .{ "zlib", "" } }, .{ .dep = .{ "zlib", "arch/generic" } }, .{ .dep = .{ "zlib", "arch/x86" } }, .{ .gen = .{ "zlib", "" } } },
            .files = &.{
                "arch/x86/crc32_vpclmulqdq.c",
            },
        },
    },
};
