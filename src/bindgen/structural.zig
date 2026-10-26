//! Structural hashing and equality over plain data, following pointers and
//! slices: two values are equal exactly when their complete structure is.
const std = @import("std");

const NoReferences = struct {
    pub fn isReference(comptime _: type) bool {
        return false;
    }
};

pub fn hash(value: anytype) u64 {
    return hashWith(NoReferences{}, value);
}

pub fn hashWith(references: anytype, value: anytype) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    updateWith(references, &hasher, value);
    return hasher.final();
}

pub fn update(hasher: *std.hash.Wyhash, value: anytype) void {
    updateWith(NoReferences{}, hasher, value);
}

fn updateWith(references: anytype, hasher: *std.hash.Wyhash, value: anytype) void {
    const T = @TypeOf(value);
    if (comptime @TypeOf(references).isReference(T)) {
        update(hasher, references.label(value));
        return;
    }
    switch (@typeInfo(T)) {
        .void, .null => {},
        .bool => hasher.update(&.{@intFromBool(value)}),
        .int => updateInteger(hasher, value),
        .float => {
            const bits: @Int(.unsigned, @bitSizeOf(T)) = @bitCast(value);
            updateInteger(hasher, bits);
        },
        .@"enum" => {
            const tag = @backingInt(value);
            updateInteger(hasher, tag);
        },
        .optional => if (value) |payload| {
            hasher.update(&.{1});
            updateWith(references, hasher, payload);
        } else hasher.update(&.{0}),
        .pointer => |pointer| switch (pointer.size) {
            .one => updateWith(references, hasher, value.*),
            .slice => {
                updateInteger(hasher, @as(u64, value.len));
                if (pointer.child == u8) {
                    hasher.update(value);
                } else for (value) |element| updateWith(references, hasher, element);
            },
            .many, .c => @compileError("structural hashing requires bounded pointers: " ++ @typeName(T)),
        },
        .array => for (value) |element| updateWith(references, hasher, element),
        .@"struct" => |info| inline for (info.field_names) |name| updateWith(references, hasher, @field(value, name)),
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("structural hashing requires tagged unions: " ++ @typeName(T));
            const tag = @backingInt(std.meta.activeTag(value));
            updateInteger(hasher, tag);
            switch (value) {
                inline else => |payload| updateWith(references, hasher, payload),
            }
        },
        else => @compileError("structural hashing does not support " ++ @typeName(T)),
    }
}

fn updateInteger(hasher: *std.hash.Wyhash, value: anytype) void {
    const bits = @bitSizeOf(@TypeOf(value));
    const Unsigned = @Int(.unsigned, bits);
    const bytes = (bits + 7) / 8;
    var buffer: [bytes]u8 = undefined;
    std.mem.writeInt(@Int(.unsigned, bytes * 8), &buffer, @as(Unsigned, @bitCast(value)), .little);
    hasher.update(&buffer);
}

pub fn eql(a: anytype, b: @TypeOf(a)) bool {
    return eqlWith(NoReferences{}, a, b);
}

pub fn eqlWith(references: anytype, a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    if (comptime @TypeOf(references).isReference(T)) return references.label(a) == references.label(b);
    switch (@typeInfo(T)) {
        .void, .null => return true,
        .bool, .int, .@"enum" => return a == b,
        .float => {
            const Bits = @Int(.unsigned, @bitSizeOf(T));
            return @as(Bits, @bitCast(a)) == @as(Bits, @bitCast(b));
        },
        .optional => {
            const left = a orelse return b == null;
            const right = b orelse return false;
            return eqlWith(references, left, right);
        },
        .pointer => |pointer| switch (pointer.size) {
            .one => return a == b or eqlWith(references, a.*, b.*),
            .slice => {
                if (a.len != b.len) return false;
                if (a.ptr == b.ptr) return true;
                if (pointer.child == u8) return std.mem.eql(u8, a, b);
                for (a, b) |left, right| if (!eqlWith(references, left, right)) return false;
                return true;
            },
            .many, .c => @compileError("structural equality requires bounded pointers: " ++ @typeName(T)),
        },
        .array => {
            for (a, b) |left, right| if (!eqlWith(references, left, right)) return false;
            return true;
        },
        .@"struct" => |info| {
            inline for (info.field_names) |name| if (!eqlWith(references, @field(a, name), @field(b, name))) return false;
            return true;
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("structural equality requires tagged unions: " ++ @typeName(T));
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            switch (a) {
                inline else => |payload, tag| return eqlWith(references, payload, @field(b, @tagName(tag))),
            }
        },
        else => @compileError("structural equality does not support " ++ @typeName(T)),
    }
}

const structural_hash = hash;
const structural_eql = eql;

/// A hash map context interning values by complete structure.
pub fn Context(comptime K: type) type {
    return struct {
        pub fn hash(_: @This(), key: K) u64 {
            return structural_hash(key);
        }

        pub fn eql(_: @This(), a: K, b: K) bool {
            return structural_eql(a, b);
        }
    };
}

pub fn Map(comptime K: type, comptime V: type) type {
    return std.HashMapUnmanaged(K, V, Context(K), std.hash_map.default_max_load_percentage);
}

pub fn OrderedMap(comptime K: type, comptime V: type) type {
    const OrderedContext = struct {
        pub fn hash(_: @This(), key: K) u32 {
            return @truncate(structural_hash(key));
        }

        pub fn eql(_: @This(), a: K, b: K, _: usize) bool {
            return structural_eql(a, b);
        }
    };
    return std.array_hash_map.Custom(K, V, OrderedContext, true);
}

test "structure, not identity" {
    const Node = struct { name: []const u8, child: ?*const @This() };
    const leaf_a: Node = .{ .name = "leaf", .child = null };
    const leaf_b: Node = .{ .name = "leaf", .child = null };
    const a: Node = .{ .name = "root", .child = &leaf_a };
    const b: Node = .{ .name = "root", .child = &leaf_b };
    try std.testing.expect(eql(a, b));
    try std.testing.expectEqual(hash(a), hash(b));
    const c: Node = .{ .name = "root", .child = null };
    try std.testing.expect(!eql(a, c));
}

pub fn Graph(comptime ids: anytype) type {
    return struct {
        const Labels = labels: {
            var names: [ids.len][]const u8 = undefined;
            for (ids, &names) |Id, *name| name.* = Id.table;
            break :labels @Struct(.auto, null, &names, &@as([ids.len]type, @splat([]u32)), &@splat(.{}));
        };
        labels: Labels,

        pub fn isReference(comptime T: type) bool {
            inline for (ids) |Id| if (T == Id) return true;
            return false;
        }

        pub fn label(g: @This(), id: anytype) u32 {
            return @field(g.labels, @TypeOf(id).table)[id.index];
        }

        fn References(comptime T: type) type {
            return struct {
                const any = value: {
                    if (isReference(T)) break :value true;
                    break :value switch (@typeInfo(T)) {
                        .pointer => |pointer| References(pointer.child).any,
                        .optional => |optional| References(optional.child).any,
                        .array => |array| References(array.child).any,
                        inline .@"struct", .@"union" => |info| fields: {
                            for (info.field_names) |name| if (References(@FieldType(T, name)).any) break :fields true;
                            break :fields false;
                        },
                        else => false,
                    };
                };
            };
        }

        fn remap(g: @This(), arena: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!@TypeOf(value) {
            const T = @TypeOf(value);
            if (comptime isReference(T)) return .of(g.label(value));
            if (comptime !References(T).any) return value;
            return switch (@typeInfo(T)) {
                .optional => if (value) |payload| try g.remap(arena, payload) else null,
                .pointer => |pointer| switch (pointer.size) {
                    .one => pointer: {
                        const result = try arena.create(pointer.child);
                        result.* = try g.remap(arena, value.*);
                        break :pointer result;
                    },
                    .slice => slice: {
                        const result = try arena.alloc(pointer.child, value.len);
                        for (value, result) |item, *output| output.* = try g.remap(arena, item);
                        break :slice result;
                    },
                    .many, .c => @compileError("IR references require bounded pointers"),
                },
                .@"struct" => |info| object: {
                    var result: T = undefined;
                    inline for (info.field_names) |name| @field(result, name) = try g.remap(arena, @field(value, name));
                    break :object result;
                },
                .array => array: {
                    var result: T = undefined;
                    for (value, &result) |item, *output| output.* = try g.remap(arena, item);
                    break :array result;
                },
                .@"union" => switch (value) {
                    inline else => |payload, tag| @unionInit(T, @tagName(tag), try g.remap(arena, payload)),
                },
                else => @compileError("unsupported IR reference container"),
            };
        }

        fn RowContext(comptime T: type) type {
            return struct {
                graph: Graph(ids),
                rows: []const T,
                previous: []const u32,

                pub fn hash(context: @This(), index: usize) u32 {
                    return @truncate(hashWith(context.graph, .{ context.previous[index], context.rows[index] }));
                }

                pub fn eql(context: @This(), a: usize, b: usize, _: usize) bool {
                    return context.previous[a] == context.previous[b] and eqlWith(context.graph, context.rows[a], context.rows[b]);
                }
            };
        }

        pub fn intern(arena: std.mem.Allocator, source: anytype) std.mem.Allocator.Error!@TypeOf(source) {
            const T = @TypeOf(source);
            var scratch: std.heap.ArenaAllocator = .init(arena);
            defer scratch.deinit();
            const temporary = scratch.allocator();
            var current: Labels = undefined;
            var next: Labels = undefined;
            inline for (ids) |Id| {
                const count = @field(source, Id.table).len;
                @field(current, Id.table) = try temporary.alloc(u32, count);
                @memset(@field(current, Id.table), 0);
                @field(next, Id.table) = try temporary.alloc(u32, count);
            }

            // Refining from one class also merges equal cycles, including a
            // plan's API view or lazy wire declaration pointing back to it.
            while (true) {
                const graph: @This() = .{ .labels = current };
                var changed = false;
                inline for (ids) |Id| {
                    const rows = @field(source, Id.table);
                    const Row = @typeInfo(@TypeOf(rows)).pointer.child;
                    const previous = @field(current, Id.table);
                    const output = @field(next, Id.table);
                    const context: RowContext(Row) = .{ .graph = graph, .rows = rows, .previous = previous };
                    var groups: std.array_hash_map.Custom(usize, void, RowContext(Row), true) = .empty;
                    defer groups.deinit(temporary);
                    for (rows, output, 0..) |_, *group, index| {
                        const entry = try groups.getOrPutContext(temporary, index, context);
                        group.* = @intCast(entry.index);
                    }
                    changed = changed or !std.mem.eql(u32, previous, output);
                }
                std.mem.swap(Labels, &current, &next);
                if (!changed) break;
            }

            const graph: @This() = .{ .labels = current };
            var result: T = undefined;
            inline for (@typeInfo(T).@"struct".field_names) |name| {
                const value = @field(source, name);
                @field(result, name) = if (comptime @hasField(Labels, name)) try graph.table(arena, value, @field(current, name)) else try graph.remap(arena, value);
            }
            return result;
        }

        fn table(g: @This(), arena: std.mem.Allocator, rows: anytype, labels: []const u32) std.mem.Allocator.Error!@TypeOf(rows) {
            const count = if (labels.len == 0) 0 else std.mem.max(u32, labels) + 1;
            const Row = @typeInfo(@TypeOf(rows)).pointer.child;
            const result = try arena.alloc(Row, count);
            var written: usize = 0;
            for (rows, labels) |row, index| {
                if (index != written) continue;
                result[written] = try g.remap(arena, row);
                written += 1;
            }
            return result;
        }
    };
}
