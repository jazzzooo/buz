const BytecodeGenerator = @This();

generate_fn: *const fn (bun.options.Format, []const u8, *bun.String) ?Generated,

pub const Generated = struct {
    bytes: []const u8,
    allocator: std.mem.Allocator,
};

pub fn generate(
    this: BytecodeGenerator,
    format: bun.options.Format,
    source: []const u8,
    source_provider_url: *bun.String,
) ?Generated {
    return this.generate_fn(format, source, source_provider_url);
}

const std = @import("std");
const bun = @import("bun");
