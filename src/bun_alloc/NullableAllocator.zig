const NullableAllocator = @This();

value: ?std.mem.Allocator = null,

pub inline fn init(allocator: ?std.mem.Allocator) NullableAllocator {
    return .{ .value = allocator };
}

pub inline fn isNull(this: NullableAllocator) bool {
    return this.value == null;
}

pub inline fn get(this: NullableAllocator) ?std.mem.Allocator {
    return this.value;
}

pub fn free(this: *const NullableAllocator, bytes: []const u8) void {
    if (this.get()) |allocator| {
        allocator.free(bytes);
    }
}

const std = @import("std");
