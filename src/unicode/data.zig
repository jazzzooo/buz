pub const version = types.version;
pub const max_code_point = types.max_code_point;

pub const GraphemeBreak = types.GraphemeBreak;
pub const IndicConjunctBreak = types.IndicConjunctBreak;
pub const Properties = types.Properties;
pub const Width = types.Width;

pub inline fn get(cp: u32) Properties {
    if (cp > max_code_point) return .{};
    const offset = tables.stage1[cp >> 8] + @as(u8, @truncate(cp));
    return @bitCast(tables.stage3[tables.stage2[offset]]);
}

comptime {
    if (!std.mem.eql(u8, version, tables.unicode_version))
        @compileError("generated Unicode table version mismatch");
}

const std = @import("std");
const tables = @import("unicode_tables");
const types = @import("types.zig");
