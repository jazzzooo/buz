pub fn writeMatches(allocator: std.mem.Allocator, prefix: []const u8, writer: *std.Io.Writer) !void {
    const data = try zstd.decompressAlloc(allocator, compressed_data);
    defer allocator.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    var wrote_match = false;
    while (lines.next()) |name| {
        if (std.mem.startsWith(u8, name, prefix)) {
            if (wrote_match) try writer.writeByte('\n');
            try writer.writeAll(name);
            wrote_match = true;
        } else if (std.mem.order(u8, name, prefix) == .gt) {
            break;
        }
    }
}

const compressed_data = @embedFile("add-completions.txt.zst");

const std = @import("std");
const zstd = @import("bun").zstd;
