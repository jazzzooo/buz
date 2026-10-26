pub fn bucketName(configured_bucket: []const u8, path: []const u8) ?[]const u8 {
    if (configured_bucket.len != 0) return configured_bucket;
    const relative_path = if (path.len != 0 and path[0] == '/') path[1..] else path;
    const end = std.mem.indexOfScalar(u8, relative_path, '/') orelse return null;
    if (end == 0) return null;
    return relative_path[0..end];
}

const std = @import("std");

test bucketName {
    try std.testing.expectEqualStrings("configured", bucketName("configured", "/path/key").?);
    try std.testing.expectEqualStrings("bucket", bucketName("", "/bucket/key").?);
    try std.testing.expectEqualStrings("bucket", bucketName("", "bucket/key").?);
    try std.testing.expect(bucketName("", "/key") == null);
    try std.testing.expect(bucketName("", "") == null);
}
