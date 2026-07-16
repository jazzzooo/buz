//! lsqpack compile recipe. Hand-maintained; update when bumping the dep.

const m = @import("deps.zig");

pub const dep: m.Dep = .{
    .name = "lsqpack",
    .groups = &.{
        .{
            .flags = &.{ "-DHAVE_BORINGSSL=1", "-DXXH_HEADER_NAME=\"xxhash.h\"", "-DLS_QPACK_USE_LARGE_TABLES=1", "-DLS_HPACK_BSS_LARGE_TABLES=1", "-DLSQPACK_ENC_LOGGER_HEADER=\"lsquic_qpack_enc_logger.h\"", "-DLSQPACK_DEC_LOGGER_HEADER=\"lsquic_qpack_dec_logger.h\"", "-DLSQUIC_DEBUG_NEXT_ADV_TICK=0", "-DLSQUIC_CONN_STATS=0", "-DLSQUIC_QIR=0", "-DLSQUIC_WEBTRANSPORT_SERVER_SUPPORT=0", "-w" },
            .includes = &.{ .{ .dep = .{ "lsquic", "include" } }, .{ .dep = .{ "lsquic", "src/liblsquic" } }, .{ .dep = .{ "boringssl", "include" } }, .{ .dep = .{ "lshpack", "" } }, .{ .dep = .{ "lshpack", "deps/xxhash" } }, .{ .dep = .{ "lsqpack", "" } }, .{ .gen = .{ "zlib", "" } }, .{ .dep = .{ "zlib", "" } } },
            .files = &.{
                "lsqpack.c",
            },
        },
    },
};
