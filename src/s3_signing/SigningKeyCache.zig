const Self = @This();
const SigningKey = [32]u8;

cache: bun.StringArrayHashMap(SigningKey) = .empty,
date: u64 = 0,
lock: std.Io.Mutex = .init,

pub fn get(io: std.Io, numeric_day: u64, key: []const u8) ?SigningKey {
    global.lock.lockUncancelable(io);
    defer global.lock.unlock(io);
    if (global.date != numeric_day) return null;
    return global.cache.get(key);
}

pub fn set(io: std.Io, numeric_day: u64, key: []const u8, value: SigningKey) bun.OOM!void {
    global.lock.lockUncancelable(io);
    defer global.lock.unlock(io);

    if (global.date != numeric_day) {
        clear();
        global.date = numeric_day;
    }
    if (global.cache.getPtr(key)) |cached| {
        cached.* = value;
        return;
    }
    const owned_key = try bun.default_allocator.dupe(u8, key);
    errdefer bun.default_allocator.free(owned_key);
    try global.cache.put(bun.default_allocator, owned_key, value);
}

fn clear() void {
    for (global.cache.keys()) |key| bun.default_allocator.free(key);
    global.cache.clearRetainingCapacity();
}

var global: Self = .{};

const bun = @import("bun");
const std = @import("std");
