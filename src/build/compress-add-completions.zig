const std = @import("std");

extern fn ZSTD_compressBound(src_size: usize) usize;
extern fn ZSTD_compress(dst: [*]u8, dst_capacity: usize, src: [*]const u8, src_size: usize, compression_level: c_int) usize;
extern fn ZSTD_isError(code: usize) c_uint;
extern fn ZSTD_getErrorName(code: usize) [*:0]const u8;

const compression_level: c_int = 19;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidArguments;

    const cwd = std.Io.Dir.cwd();
    const input = try cwd.readFileAlloc(init.io, args[1], allocator, .unlimited);
    const compressed = try allocator.alloc(u8, ZSTD_compressBound(input.len));
    const compressed_len = ZSTD_compress(compressed.ptr, compressed.len, input.ptr, input.len, compression_level);
    if (ZSTD_isError(compressed_len) != 0) {
        var stderr = std.Io.File.stderr().writer(init.io, &.{});
        stderr.interface.print("error: zstd compression failed: {s}\n", .{ZSTD_getErrorName(compressed_len)}) catch {};
        return error.CompressionFailed;
    }

    try cwd.writeFile(init.io, .{ .sub_path = args[2], .data = compressed[0..compressed_len] });
}
