const std = @import("std");
const ir = @import("bindgen_ir");
const normalize = @import("../normalize.zig");

pub fn build(n: *normalize.Normalizer, location: []const u8, members: []const ir.ObjectSurfaceMember, value_count: u32) normalize.Error!ir.CppSurfaceHashTable {
    const max_index: usize = @intCast(std.math.maxInt(i16));
    if (value_count > max_index + 1)
        return n.reject(location, "static surface hash tables support at most {d} values", .{max_index + 1});
    const base_size = std.math.ceilPowerOfTwoAssert(usize, @max(1, @as(usize, value_count) * 2));
    const index = try n.arena.alloc(ir.CppSurfaceHashIndex, base_size + value_count);
    @memset(index, .{ .value = -1, .next = -1 });
    var compact_size = base_size;
    const mask = base_size - 1;
    var value_index: u32 = 0;
    for (members) |member| {
        if (!member.exposed or member.installation != .table) continue;
        var slot: usize = @as(usize, propertyHash(member.property_name)) & mask;
        while (index[slot].value != -1) {
            if (index[slot].next != -1) {
                slot = @intCast(index[slot].next);
            } else {
                if (compact_size > max_index)
                    return n.reject(location, "static surface collision indices must fit a signed 16-bit integer", .{});
                index[slot].next = @intCast(compact_size);
                slot = compact_size;
                compact_size += 1;
            }
        }
        index[slot].value = @intCast(value_index);
        value_index += 1;
    }
    return .{ .value_count = value_count, .mask = @intCast(mask), .index = index[0..compact_size] };
}

/// The property-name hash JavaScriptCore's static hash tables use.
fn propertyHash(bytes: []const u8) u32 {
    const hash: u32 = @truncate(@import("rapidhash").hash(0, bytes) & 0x00ff_ffff);
    return if (hash == 0) 0x0080_0000 else hash;
}
