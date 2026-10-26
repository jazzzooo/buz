pub fn Registry(comptime Blob: type) type {
    return struct {
        lock: std.Io.Mutex = .init,
        map: std.AutoHashMap(UUID, *Entry) = std.AutoHashMap(UUID, *Entry).init(bun.default_allocator),

        const Self = @This();

        pub const Entry = struct {
            blob: Blob,

            fn init(blob: *const Blob) bun.OOM!*Entry {
                const entry = try bun.default_allocator.create(Entry);
                errdefer bun.destroy(entry);
                entry.* = .{ .blob = try blob.dupe() };
                return entry;
            }

            fn deinit(this: *Entry) void {
                this.blob.deinit();
                bun.destroy(this);
            }
        };

        pub fn register(this: *Self, io: std.Io, uuid: UUID, blob: *const Blob) bun.OOM!void {
            const entry = try Entry.init(blob);
            errdefer entry.deinit();

            this.lock.lockUncancelable(io);
            defer this.lock.unlock(io);
            if (try this.map.fetchPut(uuid, entry)) |previous| {
                previous.value.deinit();
            }
        }

        pub fn singleton() *Self {
            const Singleton = struct {
                var registry: Self = .{};
            };
            return &Singleton.registry;
        }

        pub fn resolveAndDupe(this: *Self, io: std.Io, pathname: []const u8) bun.OOM!?Blob {
            const uuid = uuidFromPathname(pathname) orelse return null;
            return this.resolveUUIDAndDupe(io, uuid);
        }

        pub fn resolveUUIDAndDupe(this: *Self, io: std.Io, uuid: UUID) bun.OOM!?Blob {
            this.lock.lockUncancelable(io);
            defer this.lock.unlock(io);
            const entry = this.map.get(uuid) orelse return null;
            return try entry.blob.dupe();
        }

        pub fn revoke(this: *Self, io: std.Io, pathname: []const u8) void {
            const uuid = uuidFromPathname(pathname) orelse return;
            this.revokeUUID(io, uuid);
        }

        pub fn revokeUUID(this: *Self, io: std.Io, uuid: UUID) void {
            this.lock.lockUncancelable(io);
            defer this.lock.unlock(io);
            const entry = this.map.fetchRemove(uuid) orelse return;
            entry.value.deinit();
        }

        pub fn has(this: *Self, io: std.Io, pathname: []const u8) bool {
            const uuid = uuidFromPathname(pathname) orelse return false;
            this.lock.lockUncancelable(io);
            defer this.lock.unlock(io);
            return this.map.contains(uuid);
        }
    };
}

fn uuidFromPathname(pathname: []const u8) ?UUID {
    return UUID.parse(pathname) catch return null;
}

pub const specifier_len = "blob:".len + UUID.stringLength;

pub fn isBlobURL(url: []const u8) bool {
    return url.len >= specifier_len and bun.strings.hasPrefixComptime(url, "blob:");
}

const std = @import("std");

const bun = @import("bun");
const UUID = bun.UUID;
