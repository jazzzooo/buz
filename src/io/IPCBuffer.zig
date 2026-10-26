const std = @import("std");

pub const Mode = enum {
    advanced,
    json,

    pub fn fromString(value: []const u8) ?Mode {
        return std.meta.stringToEnum(Mode, value);
    }
};

pub const AdvancedMessageType = enum(u8) {
    Version = 1,
    SerializedMessage = 2,
    SerializedInternalMessage = 3,
    _,
};

pub const advanced_header_length = 5;

pub fn advancedHeader(message_type: AdvancedMessageType, value: u32) [advanced_header_length]u8 {
    var bytes: [advanced_header_length]u8 = undefined;
    bytes[0] = @backingInt(message_type);
    std.mem.writeInt(u32, bytes[1..5], value, .little);
    return bytes;
}

const IPCBuffer = @This();
data: std.ArrayList(u8) = .empty,
head: usize = 0,
scanned: usize = 0,

const compaction_threshold = 16 * 1024 * 1024;

pub const Frame = struct {
    bytes: []const u8,
    newline_pos: ?u32 = null,
};

pub fn deinit(self: *IPCBuffer, allocator: std.mem.Allocator) void {
    self.data.deinit(allocator);
    self.* = .{};
}

pub fn append(self: *IPCBuffer, allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!void {
    const available = try self.reserve(allocator, bytes.len);
    @memcpy(available, bytes);
    self.commit(bytes.len);
}

pub fn reserve(self: *IPCBuffer, allocator: std.mem.Allocator, length: usize) std.mem.Allocator.Error![]u8 {
    if (self.head != 0 and self.data.capacity - self.data.items.len < length) self.compact();
    try self.data.ensureUnusedCapacity(allocator, length);
    return self.data.unusedCapacitySlice()[0..length];
}

pub fn commit(self: *IPCBuffer, length: usize) void {
    std.debug.assert(length <= self.data.capacity - self.data.items.len);
    self.data.items.len += length;
}

pub fn next(self: *IPCBuffer, mode: Mode) error{InvalidFormat}!?Frame {
    const bytes = self.data.items[self.head..];
    switch (mode) {
        .json => {
            if (std.mem.indexOfScalar(u8, bytes[self.scanned..], '\n')) |offset| {
                const position = self.scanned + offset;
                if (position >= std.math.maxInt(u32)) return error.InvalidFormat;
                return .{ .bytes = bytes[0 .. position + 1], .newline_pos = @intCast(position) };
            }
            if (bytes.len >= std.math.maxInt(u32)) return error.InvalidFormat;
            self.scanned = bytes.len;
            return null;
        },
        .advanced => {
            if (bytes.len < advanced_header_length) return null;
            const message_type: AdvancedMessageType = @fromBackingInt(bytes[0]);
            const length: usize = switch (message_type) {
                .Version => advanced_header_length,
                .SerializedMessage, .SerializedInternalMessage => advanced_header_length + @as(usize, std.mem.readInt(u32, bytes[1..5], .little)),
                _ => return error.InvalidFormat,
            };
            if (bytes.len < length) return null;
            return .{ .bytes = bytes[0..length] };
        },
    }
}

pub fn consume(self: *IPCBuffer, allocator: std.mem.Allocator, length: usize) void {
    std.debug.assert(length <= self.data.items.len - self.head);
    self.head += length;
    self.scanned = 0;
    if (self.head == self.data.items.len) {
        if (self.data.capacity >= compaction_threshold) {
            self.data.clearAndFree(allocator);
        } else self.data.clearRetainingCapacity();
        self.head = 0;
    } else if (self.head >= compaction_threshold) self.compact();
}

fn compact(self: *IPCBuffer) void {
    const remaining = self.data.items[self.head..];
    @memmove(self.data.items[0..remaining.len], remaining);
    self.data.items.len = remaining.len;
    self.head = 0;
}
