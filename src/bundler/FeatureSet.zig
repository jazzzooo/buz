const FeatureSet = @This();

names: OwnedNames = .empty,
count: usize = 0,

pub const Bytes = OwnedNativeSlice(u8, .any);
pub const OwnedNames = OwnedNativeSlice(Bytes, .any);
pub const empty: FeatureSet = .{};

pub const View = struct {
    names: []const Bytes = &.{},

    pub const empty: View = .{};

    pub fn contains(self: View, name: []const u8) bool {
        var start: usize = 0;
        var end = self.names.len;
        while (start < end) {
            const middle = start + (end - start) / 2;
            switch (std.mem.order(u8, self.names[middle].slice(), name)) {
                .lt => start = middle + 1,
                .gt => end = middle,
                .eq => return true,
            }
        }
        return false;
    }

    pub fn hash(self: View, hasher: *std.hash.Wyhash) void {
        if (self.names.len == 0) return;
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, self.names.len, .little);
        hasher.update(&length);
        for (self.names) |*name| {
            const bytes = name.slice();
            std.mem.writeInt(u64, &length, bytes.len, .little);
            hasher.update(&length);
            hasher.update(bytes);
        }
    }
};

pub fn init(input: []const []const u8) bun.OOM!FeatureSet {
    var names = try OwnedNames.Builder.init(input.len);
    errdefer names.deinit();
    for (input) |name| names.appendOwned(.fromOwnedSlice(try bun.default_allocator.dupe(u8, name)));
    return fromOwned(names.finish());
}

/// Takes initialized names allocated with bun.default_allocator.
pub fn fromOwnedNames(names: []Bytes) FeatureSet {
    return fromOwned(.fromOwnedSlice(names));
}

pub fn fromOwned(owned: OwnedNames) FeatureSet {
    const names = owned.values;
    std.mem.sort(Bytes, names, {}, lessThan);
    var count: usize = 0;
    for (0..names.len) |index| {
        if (count > 0 and std.mem.eql(u8, names[count - 1].slice(), names[index].slice())) {
            names[index].deinit();
            continue;
        }
        if (count != index) {
            names[count] = names[index];
            names[index] = .empty;
        }
        count += 1;
    }
    return .{ .names = owned, .count = count };
}

fn lessThan(_: void, a: Bytes, b: Bytes) bool {
    return std.mem.lessThan(u8, a.slice(), b.slice());
}

pub fn view(self: *const FeatureSet) View {
    return .{ .names = self.names.slice()[0..self.count] };
}

pub fn deinit(self: *FeatureSet) void {
    self.names.deinit();
    self.count = 0;
}

test "feature sets own names and hash independently of order and duplicates" {
    var name = "alpha".*;
    var first = try FeatureSet.init(&.{ "beta", &name, "alpha" });
    defer first.deinit();
    @memset(&name, 'x');
    var second = try FeatureSet.init(&.{ "alpha", "beta" });
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 2), first.count);
    try std.testing.expect(first.view().contains("alpha"));
    try std.testing.expect(first.view().contains("beta"));
    try std.testing.expect(!first.view().contains("xxxxx"));
    var first_hash = std.hash.Wyhash.init(0);
    var second_hash = std.hash.Wyhash.init(0);
    first.view().hash(&first_hash);
    second.view().hash(&second_hash);
    const expected_hash = second_hash.final();
    try std.testing.expectEqual(first_hash.final(), expected_hash);

    var combined = try FeatureSet.init(&.{"alpha\x00beta"});
    defer combined.deinit();
    var combined_hash = std.hash.Wyhash.init(0);
    combined.view().hash(&combined_hash);
    try std.testing.expect(combined_hash.final() != expected_hash);
}

const std = @import("std");
const bun = @import("bun");
const OwnedNativeSlice = @import("../bindgen/owned_native_slice.zig").OwnedNativeSlice;
