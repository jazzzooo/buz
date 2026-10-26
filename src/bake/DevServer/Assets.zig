/// Storage for hashed assets on `/_bun/asset/{hash}.ext`
pub fn WithTypes(comptime DevServer: type, comptime StaticRoute: type) type {
    return struct {
        const Assets = @This();

        /// Owns absolute paths. Values are indexes into `files`.
        path_map: bun.StringArrayHashMap(EntryIndex),
        /// Content-addressable store. Multiple paths can point to the same content
        /// hash, which is tracked by the `refs` array. One reference is held to
        /// contained StaticRoute instances when they are stored.
        files: AutoArrayHashMap(u64, *StaticRoute),
        /// Indexed by the same index of `files`. The value is never `0`.
        refs: ArrayListUnmanaged(u32),

        const EntryIndex = bun.GenericIndex(u30, Assets);

        fn owner(assets: *Assets) *DevServer {
            return @alignCast(@fieldParentPtr("assets", assets));
        }

        pub fn getHash(assets: *Assets, path: []const u8) ?u64 {
            assert(assets.owner().magic == .valid);
            return if (assets.path_map.get(path)) |idx|
                assets.files.keys()[idx.get()]
            else
                null;
        }

        /// Asset keys may be content hashes or stable stylesheet IDs.
        pub fn replacePath(
            assets: *Assets,
            /// not allocated
            abs_path: []const u8,
            /// Ownership is transferred to this function
            contents: *AnyBlob,
            mime_type: *const MimeType,
            /// content hash of the asset
            content_hash: u64,
        ) !void {
            defer contents.detach();
            assert(assets.owner().magic == .valid);
            assets.owner().graph_safety_lock.assertLocked();
            defer assert(assets.files.count() == assets.refs.items.len);
            const alloc = assets.owner().allocator();
            debug.log("replacePath {f} {} - {s}/{s} ({s})", .{
                bun.fmt.quote(abs_path),
                content_hash,
                DevServer.asset_prefix,
                &std.fmt.bytesToHex(std.mem.asBytes(&content_hash), .lower),
                mime_type.value,
            });

            const old_entry = assets.path_map.get(abs_path);
            const existing_target = assets.files.getIndex(content_hash);
            const replaces_target = old_entry != null and existing_target != null and existing_target.? == old_entry.?.get();
            if (old_entry == null) try assets.path_map.ensureUnusedCapacity(alloc, 1);
            const owned_path = if (old_entry == null) try alloc.dupe(u8, abs_path) else null;
            errdefer if (owned_path) |path| alloc.free(path);

            var new_route: ?*StaticRoute = null;
            defer if (new_route) |route| route.deref();
            var next_ref_count: u32 = 1;
            if (existing_target) |target| {
                if (!replaces_target) {
                    next_ref_count = std.math.add(u32, assets.refs.items[target], 1) catch return error.OutOfMemory;
                }
            } else {
                if (assets.files.count() >= std.math.maxInt(u30)) return error.OutOfMemory;
                try assets.files.ensureUnusedCapacity(alloc, 1);
                try assets.refs.ensureUnusedCapacity(alloc, 1);
            }
            if (existing_target == null or replaces_target) {
                new_route = try StaticRoute.initFromAnyBlob(contents, .{
                    .mime_type = mime_type,
                    .server = assets.owner().server orelse unreachable,
                });
            }

            if (old_entry == null) {
                _ = try assets.owner().client_graph.insertEmpty(abs_path, .unknown);
            }

            if (replaces_target) {
                // A stylesheet can have new contents under the same ID.
                const target = existing_target.?;
                const previous = assets.files.values()[target];
                assets.files.values()[target] = new_route.?;
                new_route = null;
                previous.deref();
                return;
            }

            const target: EntryIndex = if (existing_target) |index| target: {
                assets.refs.items[index] = next_ref_count;
                break :target .init(@intCast(index));
            } else target: {
                const index = assets.files.count();
                assets.files.putAssumeCapacityNoClobber(content_hash, new_route.?);
                assets.refs.appendAssumeCapacity(1);
                new_route = null;
                break :target .init(@intCast(index));
            };
            if (old_entry) |old| {
                assets.path_map.getPtr(abs_path).?.* = target;
                assets.unrefByIndex(old, 1);
            } else {
                assets.path_map.putAssumeCapacityNoClobber(owned_path.?, target);
            }
        }

        fn unrefByIndex(assets: *Assets, index: EntryIndex, dec_count: u32) void {
            defer assert(assets.files.count() == assets.refs.items.len);
            assert(dec_count > 0);
            assert(assets.refs.items[index.get()] >= dec_count);
            assets.refs.items[index.get()] -= dec_count;
            if (assets.refs.items[index.get()] == 0) {
                const removed = assets.files.values()[index.get()];
                assets.files.swapRemoveAt(index.get());
                _ = assets.refs.swapRemove(index.get());
                // `swapRemove` moved the entry that was at the old last index into
                // `index`'s slot. Any `path_map` value that still points at the old
                // last index (now equal to `files.count()`) must be patched to point
                // at the new slot, otherwise the next lookup for that path would read
                // past the end of `files`/`refs`, or alias an unrelated asset if a
                // new entry is appended afterwards.
                const moved_from: u30 = @intCast(assets.files.count());
                if (moved_from != index.get()) {
                    for (assets.path_map.values()) |*entry_index| {
                        if (entry_index.get() == moved_from) entry_index.* = index;
                    }
                }
                removed.deref();
            }
        }

        pub fn unrefByPath(assets: *Assets, path: []const u8) void {
            const entry = assets.path_map.fetchSwapRemove(path) orelse return;
            defer assets.owner().allocator().free(entry.key);
            assets.unrefByIndex(entry.value, 1);
        }

        pub fn getByPath(assets: *Assets, path: []const u8) ?*StaticRoute {
            const index = assets.path_map.get(path) orelse return null;
            return assets.files.values()[index.get()];
        }

        pub fn get(assets: *Assets, content_hash: u64) ?*StaticRoute {
            assert(assets.owner().magic == .valid);
            assert(assets.files.count() == assets.refs.items.len);
            return assets.files.get(content_hash);
        }

        pub fn deinit(assets: *Assets, alloc: Allocator) void {
            for (assets.path_map.keys()) |path| alloc.free(path);
            assets.path_map.deinit(alloc);
            for (assets.files.values()) |blob| blob.deref();
            assets.files.deinit(alloc);
            assets.refs.deinit(alloc);
        }

        pub fn memoryCost(assets: *Assets) usize {
            var cost: usize = 0;
            cost += memoryCostArrayHashMap(assets.path_map);
            for (assets.path_map.keys()) |path| cost += path.len;
            for (assets.files.values()) |blob| cost += blob.memoryCost();
            cost += memoryCostArrayHashMap(assets.files);
            cost += memoryCostArrayList(assets.refs);
            return cost;
        }

        const debug = DevServer.debug;
        const memoryCostArrayHashMap = DevServer.memoryCostArrayHashMap;
        const memoryCostArrayList = DevServer.memoryCostArrayList;
    };
}

const bun = @import("bun");
const assert = bun.assert;
const MimeType = bun.http.MimeType;
const AnyBlob = bun.webcore.Blob.Any;

const std = @import("std");
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoArrayHashMap = std.array_hash_map.Auto;
const Allocator = std.mem.Allocator;
