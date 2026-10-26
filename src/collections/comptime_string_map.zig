/// Comptime string map optimized for small sets of disparate string keys.
/// Works by separating the keys by length at comptime and only checking strings of
/// equal length at runtime.
///
/// `kvs` expects a list literal containing list literals or an array/slice of structs
/// where `.@"0"` is the `[]const u8` key and `.@"1"` is the associated value of type `V`.
pub fn ComptimeStringMap(comptime V: type, comptime kvs_list: anytype) type {
    const KV = struct {
        key: []const u8,
        value: V,
    };

    const precomputed = comptime blk: {
        @setEvalBranchQuota(99999);

        var sorted_kvs: [kvs_list.len]KV = undefined;
        const lenAsc = (struct {
            fn lenAsc(context: void, a: KV, b: KV) bool {
                _ = context;
                if (a.key.len != b.key.len) {
                    return a.key.len < b.key.len;
                }
                @setEvalBranchQuota(999999);
                return std.mem.order(u8, a.key, b.key) == .lt;
            }
        }).lenAsc;
        for (kvs_list, &sorted_kvs) |kv, *sorted| {
            sorted.* = .{ .key = kv.@"0", .value = if (V == void) {} else kv.@"1" };
        }
        std.sort.pdq(KV, &sorted_kvs, {}, lenAsc);
        const min_len = if (sorted_kvs.len == 0) 0 else sorted_kvs[0].key.len;
        const max_len = if (sorted_kvs.len == 0) 0 else sorted_kvs[sorted_kvs.len - 1].key.len;
        var len_indexes: [max_len + 2]usize = undefined;
        var i: usize = 0;

        for (&len_indexes, 0..) |*start, len| {
            @setEvalBranchQuota(99999);
            while (i < sorted_kvs.len and sorted_kvs[i].key.len < len) {
                i += 1;
            }
            start.* = i;
        }
        break :blk .{
            .min_len = min_len,
            .max_len = max_len,
            .sorted_kvs = sorted_kvs,
            .len_indexes = len_indexes,
        };
    };

    return struct {
        const len_indexes = precomputed.len_indexes;
        pub const kvs = precomputed.sorted_kvs;

        const keys_list: []const []const u8 = blk: {
            var k: [kvs.len][]const u8 = undefined;
            for (kvs, 0..) |kv, i| {
                k[i] = kv.key;
            }
            const final = k;
            break :blk &final;
        };

        pub const Value = V;

        pub fn keys() []const []const u8 {
            return keys_list;
        }

        pub fn has(str: []const u8) bool {
            return get(str) != null;
        }

        pub fn getWithLength(str: []const u8, comptime len: usize) ?V {
            const i = indexOfWithLength(str, len) orelse return null;
            return kvs[i].value;
        }

        pub fn getWithLengthAndEql(str: anytype, comptime len: usize, comptime eqls: anytype) ?V {
            inline for (len_indexes[len]..len_indexes[len + 1]) |i| {
                if (eqls(str, kvs[i].key)) {
                    return kvs[i].value;
                }
            }

            return null;
        }

        pub fn getWithLengthAndEqlList(str: anytype, comptime len: usize, comptime eqls: anytype) ?V {
            const start = comptime len_indexes[len];
            const range = comptime keys()[start..len_indexes[len + 1]];
            if (eqls(str, range)) |k| {
                return kvs[start + k].value;
            }

            return null;
        }

        pub fn get(str: []const u8) ?V {
            if (str.len < precomputed.min_len or str.len > precomputed.max_len)
                return null;

            comptime var i: usize = precomputed.min_len;
            inline while (i <= precomputed.max_len) : (i += 1) {
                if (str.len == i) {
                    return getWithLength(str, i);
                }
            }

            return null;
        }

        /// Returns the index of the key in the sorted list of keys.
        pub fn indexOf(str: []const u8) ?usize {
            if (str.len < precomputed.min_len or str.len > precomputed.max_len)
                return null;

            comptime var len: usize = precomputed.min_len;
            inline while (len <= precomputed.max_len) : (len += 1) {
                if (str.len == len) {
                    return indexOfWithLength(str, len);
                }
            }
            return null;
        }

        fn indexOfWithLength(str: []const u8, comptime len: usize) ?usize {
            // An unrolled scan over the length-sorted keys is faster than a switch for both small and large key sets.
            inline for (len_indexes[len]..len_indexes[len + 1]) |i| {
                if (strings.eqlComptimeCheckLenWithType(u8, str, kvs[i].key, false)) return i;
            }
            return null;
        }

        pub fn fromString(str: bun.String) ?V {
            return getWithEql(str, bun.String.eqlComptime);
        }

        /// Looks up `input` with its ASCII letters lowercased, so only lowercase keys can match.
        pub fn getCaseInsensitiveASCII(input: []const u8) ?V {
            if (input.len < precomputed.min_len or input.len > precomputed.max_len)
                return null;

            comptime var len: usize = precomputed.min_len;
            inline while (len <= precomputed.max_len) : (len += 1) {
                if (input.len == len) {
                    var lowercased: [len]u8 = undefined;
                    for (input, &lowercased) |c, *lower| lower.* = std.ascii.toLower(c);
                    return getWithLengthAndEql(&lowercased, len, bun.strings.eqlComptimeIgnoreLen);
                }
            }

            return null;
        }

        pub fn getWithEql(input: anytype, comptime eql: anytype) ?V {
            const Input = @TypeOf(input);
            const length = if (@hasField(Input, "len")) input.len else input.length();
            if (length < precomputed.min_len or length > precomputed.max_len)
                return null;

            comptime var i: usize = precomputed.min_len;
            inline while (i <= precomputed.max_len) : (i += 1) {
                if (length == i) {
                    return getWithLengthAndEql(input, i, eql);
                }
            }

            return null;
        }

        pub fn getWithEqlList(input: anytype, comptime eql: anytype) ?V {
            const Input = @TypeOf(input);
            const length = if (@hasField(Input, "len"))
                input.len
            else if (comptime std.meta.hasFn(Input, "length"))
                input.length()
            else
                input.len();
            if (length < precomputed.min_len or length > precomputed.max_len)
                return null;

            comptime var i: usize = precomputed.min_len;
            inline while (i <= precomputed.max_len) : (i += 1) {
                if (length == i) {
                    return getWithLengthAndEqlList(input, i, eql);
                }
            }

            return null;
        }

        /// Lookup the first-defined string key for a given value.
        ///
        /// Linear search.
        pub fn getKey(value: V) ?[]const u8 {
            inline for (kvs) |kv| {
                if (kv.value == value) return kv.key;
            }

            return null;
        }
    };
}

const TestEnum = enum {
    A,
    B,
    C,
    D,
    E,
};

test "ComptimeStringMap list literal of list literals" {
    const map = ComptimeStringMap(TestEnum, .{
        .{ "these", .D },
        .{ "have", .A },
        .{ "nothing", .B },
        .{ "incommon", .C },
        .{ "samelen", .E },
    });

    try testMap(map);
}

test "ComptimeStringMap array of structs" {
    const KV = struct {
        @"0": []const u8,
        @"1": TestEnum,
    };
    const map = ComptimeStringMap(TestEnum, [_]KV{
        .{ .@"0" = "these", .@"1" = .D },
        .{ .@"0" = "have", .@"1" = .A },
        .{ .@"0" = "nothing", .@"1" = .B },
        .{ .@"0" = "incommon", .@"1" = .C },
        .{ .@"0" = "samelen", .@"1" = .E },
    });

    try testMap(map);
}

test "ComptimeStringMap slice of structs" {
    const KV = struct {
        @"0": []const u8,
        @"1": TestEnum,
    };
    const slice: []const KV = &[_]KV{
        .{ .@"0" = "these", .@"1" = .D },
        .{ .@"0" = "have", .@"1" = .A },
        .{ .@"0" = "nothing", .@"1" = .B },
        .{ .@"0" = "incommon", .@"1" = .C },
        .{ .@"0" = "samelen", .@"1" = .E },
    };
    const map = ComptimeStringMap(TestEnum, slice);

    try testMap(map);
}

fn testMap(comptime map: anytype) !void {
    try std.testing.expectEqual(TestEnum.A, map.get("have").?);
    try std.testing.expectEqual(TestEnum.B, map.get("nothing").?);
    try std.testing.expect(null == map.get("missing"));
    try std.testing.expectEqual(TestEnum.D, map.get("these").?);
    try std.testing.expectEqual(TestEnum.E, map.get("samelen").?);

    try std.testing.expect(!map.has("missing"));
    try std.testing.expect(map.has("these"));
}

test "ComptimeStringMap void value type, slice of structs" {
    const KV = struct {
        @"0": []const u8,
    };
    const slice: []const KV = &[_]KV{
        .{ .@"0" = "these" },
        .{ .@"0" = "have" },
        .{ .@"0" = "nothing" },
        .{ .@"0" = "incommon" },
        .{ .@"0" = "samelen" },
    };
    const map = ComptimeStringMap(void, slice);

    try testSet(map);
}

test "ComptimeStringMap void value type, list literal of list literals" {
    const map = ComptimeStringMap(void, .{
        .{"these"},
        .{"have"},
        .{"nothing"},
        .{"incommon"},
        .{"samelen"},
    });

    try testSet(map);
}

fn testSet(comptime map: anytype) !void {
    try std.testing.expectEqual({}, map.get("have").?);
    try std.testing.expectEqual({}, map.get("nothing").?);
    try std.testing.expect(null == map.get("missing"));
    try std.testing.expectEqual({}, map.get("these").?);
    try std.testing.expectEqual({}, map.get("samelen").?);

    try std.testing.expect(!map.has("missing"));
    try std.testing.expect(map.has("these"));
}

const bun = @import("bun");
const strings = bun.strings;

const std = @import("std");
