const SourceMapInput = @This();

const RefCount = bun.ptr.ThreadSafeRefCount(SourceMapInput, "references", destroy, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

references: RefCount = .init(),
inline_url: ?[]const u8,
external_json: ?[]const u8,
allow_external_file: bool,

pub fn capture(source: bun.TextView, external_json: ?[]const u8, allow_external_file: bool) bun.OOM!*SourceMapInput {
    const allocator = bun.default_allocator;
    const inline_url = try bun.SourceMap.findSourceMappingURL(source, allocator);
    errdefer if (inline_url) |bytes| allocator.free(bytes);
    const json_copy = if (external_json) |bytes| try allocator.dupe(u8, bytes) else null;
    errdefer if (json_copy) |bytes| allocator.free(bytes);
    return create(inline_url, json_copy, allow_external_file);
}

/// Adopts the exact-sized byte allocations only on success.
pub fn create(inline_url: ?[]const u8, external_json: ?[]const u8, allow_external_file: bool) bun.OOM!*SourceMapInput {
    const result = try bun.default_allocator.create(SourceMapInput);
    result.* = .{
        .inline_url = inline_url,
        .external_json = external_json,
        .allow_external_file = allow_external_file,
    };
    return result;
}

pub fn memoryCost(this: *const SourceMapInput) usize {
    return @sizeOf(SourceMapInput) +
        (if (this.inline_url) |bytes| bytes.len else @as(usize, 0)) +
        (if (this.external_json) |bytes| bytes.len else @as(usize, 0));
}

fn destroy(this: *SourceMapInput) void {
    if (this.inline_url) |bytes| bun.default_allocator.free(bytes);
    if (this.external_json) |bytes| bun.default_allocator.free(bytes);
    bun.default_allocator.destroy(this);
}

test "source-map input captures independent native storage" {
    var source = "\n//# sourceMappingURL=inline.map".*;
    var json = "{\"mappings\":\"AAAA\"}".*;
    const input = try capture(.{ .utf8 = &source }, &json, false);
    defer input.deref();
    @memset(&source, 0);
    @memset(&json, 0);
    try std.testing.expectEqualStrings("inline.map", input.inline_url.?);
    try std.testing.expectEqualStrings("{\"mappings\":\"AAAA\"}", input.external_json.?);
}

const std = @import("std");
const bun = @import("bun");
