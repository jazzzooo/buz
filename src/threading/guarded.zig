pub fn Guarded(comptime Value: type) type {
    return struct {
        const Self = @This();

        unsynchronized_value: Value,
        mutex: std.Io.Mutex = .init,

        pub fn init(value: Value) Self {
            return .{ .unsynchronized_value = value };
        }

        pub fn lock(self: *Self, io: std.Io) *Value {
            self.mutex.lockUncancelable(io);
            return &self.unsynchronized_value;
        }

        pub fn unlock(self: *Self, io: std.Io) void {
            self.mutex.unlock(io);
        }

        pub fn intoUnprotected(self: *Self) Value {
            defer self.* = undefined;
            return self.unsynchronized_value;
        }

        pub fn deinit(self: *Self) void {
            bun.memory.deinit(&self.unsynchronized_value);
            self.* = undefined;
        }
    };
}

const std = @import("std");
const bun = @import("bun");
