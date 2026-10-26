const Self = @This();

const ReleaseFn = *const fn (*Self) void;

release_fn: ReleaseFn,

pub fn init(release_fn: ReleaseFn) Self {
    return .{ .release_fn = release_fn };
}

pub fn allocator(self: *Self) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn release(self: *Self) void {
    self.release_fn(self);
}

pub fn isInstance(allocator_: std.mem.Allocator) bool {
    return allocator_.vtable == &vtable;
}

fn alloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    return null;
}

fn free(context: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.release();
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = &alloc,
    .resize = &std.mem.Allocator.noResize,
    .remap = &std.mem.Allocator.noRemap,
    .free = &free,
};

const std = @import("std");
