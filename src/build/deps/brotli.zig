//! brotli compile recipe. Hand-maintained; update when bumping the dep.

const m = @import("deps.zig");

pub const dep: m.Dep = .{
    .name = "brotli",
    .groups = &.{
        .{
            .flags = &.{ "-fPIC", "-DBROTLI_HAVE_LOG2=1", "-DOS_LINUX", "-fno-lto" },
            .includes = &.{.{ .dep = .{ "brotli", "c/include" } }},
            .files = &.{
                "c/common/constants.c",
                "c/common/context.c",
                "c/common/dictionary.c",
                "c/common/platform.c",
                "c/common/shared_dictionary.c",
                "c/common/transform.c",
                "c/dec/bit_reader.c",
                "c/dec/decode.c",
                "c/dec/huffman.c",
                "c/dec/state.c",
                "c/enc/backward_references.c",
                "c/enc/backward_references_hq.c",
                "c/enc/bit_cost.c",
                "c/enc/block_splitter.c",
                "c/enc/brotli_bit_stream.c",
                "c/enc/cluster.c",
                "c/enc/command.c",
                "c/enc/compound_dictionary.c",
                "c/enc/compress_fragment.c",
                "c/enc/compress_fragment_two_pass.c",
                "c/enc/dictionary_hash.c",
                "c/enc/encode.c",
                "c/enc/encoder_dict.c",
                "c/enc/entropy_encode.c",
                "c/enc/fast_log.c",
                "c/enc/histogram.c",
                "c/enc/literal_cost.c",
                "c/enc/memory.c",
                "c/enc/metablock.c",
                "c/enc/static_dict.c",
                "c/enc/utf8_util.c",
            },
        },
    },
};
