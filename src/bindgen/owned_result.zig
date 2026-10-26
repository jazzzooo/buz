pub fn Owner(comptime T: type, comptime destroy: fn (*T) void) type {
    return struct {
        value: T,

        pub const Value = T;
        const Self = @This();

        pub fn deinit(self: *Self) void {
            destroy(&self.value);
        }

        pub fn replace(self: *Self, replacement: *Self) void {
            bun.assert(self != replacement);
            std.mem.swap(Self, self, replacement);
            replacement.deinit();
        }
    };
}

pub fn ResultList(comptime Type: type) type {
    const T = bun.bindgen.ResultType(Type);
    return struct {
        buffer: std.ArrayList(T) = .empty,

        pub const Element = T;
        pub const ElementOwner = Owner(T, destroy);
        pub const empty: @This() = .{};
        const Self = @This();

        fn destroy(value: *T) void {
            bun.bindgen.deinitResult(Type, value);
        }

        pub fn initCapacity(capacity: usize) bun.OOM!Self {
            return .{ .buffer = try .initCapacity(bun.default_allocator, capacity) };
        }

        pub fn takeSequence(source: anytype) bun.OOM!Self {
            if (@TypeOf(source.*).SemanticType.kind != .sequence or @TypeOf(source.*).SemanticType.child != Type)
                @compileError("result list requires a sequence of its declared semantic type");
            defer source.deinit();
            var result = try initCapacity(source.len());
            var iterator = source.iterator();
            while (iterator.next()) |item| result.appendAssumeCapacity(item.value);
            return result;
        }

        pub fn len(self: *const Self) usize {
            return self.buffer.items.len;
        }

        pub fn slice(self: *const Self) []const T {
            return self.buffer.items;
        }

        pub fn sliceMut(self: *Self) []T {
            return self.buffer.items;
        }

        pub fn appendAssumeCapacity(self: *Self, value: T) void {
            self.buffer.appendAssumeCapacity(value);
        }

        pub fn retain(self: *Self, context: anytype, comptime keep: anytype) void {
            var kept: usize = 0;
            for (self.buffer.items, 0..) |*value, i| {
                if (keep(context, value)) {
                    if (kept != i) self.buffer.items[kept] = value.*;
                    kept += 1;
                } else {
                    destroy(value);
                }
            }
            self.buffer.items.len = kept;
        }

        pub fn clear(self: *Self) void {
            for (self.buffer.items) |*value| destroy(value);
            self.buffer.clearRetainingCapacity();
        }

        pub fn deinit(self: *Self) void {
            self.clear();
            self.buffer.deinit(bun.default_allocator);
            self.* = .empty;
        }

        pub fn replace(self: *Self, replacement: *Self) void {
            bun.assert(self != replacement);
            std.mem.swap(Self, self, replacement);
            replacement.deinit();
        }
    };
}

const std = @import("std");
const bun = @import("bun");
