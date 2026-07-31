// Represents data that can be either owned or temporary
pub const Data = union(enum) {
    owned: bun.ByteList,
    temporary: []const u8,
    inline_storage: InlineStorage,
    empty: void,

    pub const InlineStorage = struct {
        pub const capacity = 15;

        bytes: [capacity]u8 = undefined,
        len: u8 = 0,

        pub fn init(bytes: []const u8) InlineStorage {
            bun.assert(bytes.len <= capacity);
            var storage: InlineStorage = .{ .len = @intCast(bytes.len) };
            @memcpy(storage.bytes[0..bytes.len], bytes);
            return storage;
        }

        pub fn slice(storage: *const InlineStorage) []const u8 {
            return storage.bytes[0..storage.len];
        }
    };

    pub const Empty: Data = .{ .empty = {} };

    pub fn create(bytes: []const u8) !Data {
        if (bytes.len == 0) return Empty;

        if (bytes.len <= InlineStorage.capacity) {
            return .{ .inline_storage = .init(bytes) };
        }
        return .{
            .owned = bun.ByteList.fromOwnedSlice(try bun.default_allocator.dupe(u8, bytes)),
        };
    }

    pub fn toOwned(this: @This()) !bun.ByteList {
        return switch (this) {
            .owned => this.owned,
            .temporary => bun.ByteList.fromOwnedSlice(
                try bun.default_allocator.dupe(u8, this.temporary),
            ),
            .empty => bun.ByteList.empty,
            .inline_storage => bun.ByteList.fromOwnedSlice(
                try bun.default_allocator.dupe(u8, this.inline_storage.slice()),
            ),
        };
    }

    pub fn deinit(this: *@This()) void {
        switch (this.*) {
            .owned => |*owned| owned.clearAndFree(bun.default_allocator),
            .temporary => {},
            .empty => {},
            .inline_storage => {},
        }
    }

    /// Zero bytes before deinit
    /// Generally, for security reasons.
    pub fn zdeinit(this: *@This()) void {
        switch (this.*) {
            .owned => |*owned| {
                bun.freeSensitive(bun.default_allocator, owned.slice());
                owned.deinit(bun.default_allocator);
            },
            .temporary => {},
            .empty => {},
            .inline_storage => |*storage| @memset(&storage.bytes, 0),
        }
    }

    pub fn slice(this: *const @This()) []const u8 {
        return switch (this.*) {
            .owned => this.owned.slice(),
            .temporary => this.temporary,
            .empty => "",
            .inline_storage => this.inline_storage.slice(),
        };
    }

    pub fn substring(this: *const @This(), start_index: usize, end_index: usize) Data {
        return switch (this.*) {
            .owned => .{ .temporary = this.owned.slice()[start_index..end_index] },
            .temporary => .{ .temporary = this.temporary[start_index..end_index] },
            .empty => .{ .empty = {} },
            .inline_storage => .{ .temporary = this.inline_storage.slice()[start_index..end_index] },
        };
    }
};

const bun = @import("bun");
