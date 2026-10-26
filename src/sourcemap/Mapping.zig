const Mapping = @This();

const debug = bun.Output.scoped(.SourceMap, .visible);

generated: LineColumnOffset,
original: LineColumnOffset,
source_index: i32,
name_index: i32 = -1,

/// Optimization: if we don't care about the "names" column, then don't store the names.
pub const MappingWithoutName = struct {
    generated: LineColumnOffset,
    original: LineColumnOffset,
    source_index: i32,

    pub fn toNamed(this: *const MappingWithoutName) Mapping {
        return .{
            .generated = this.generated,
            .original = this.original,
            .source_index = this.source_index,
            .name_index = -1,
        };
    }
};

pub const List = struct {
    impl: Value = .{ .without_names = .empty },
    names: []const bun.Semver.String = &[_]bun.Semver.String{},
    names_buffer: bun.ByteList = .{},

    pub const Value = union(enum) {
        without_names: std.MultiArrayList(MappingWithoutName),
        with_names: std.MultiArrayList(Mapping),

        pub fn memoryCost(this: *const Value) usize {
            return switch (this.*) {
                inline else => |list| @TypeOf(list).capacityInBytes(list.capacity),
            };
        }

        pub fn ensureTotalCapacity(this: *Value, allocator: std.mem.Allocator, count: usize) !void {
            switch (this.*) {
                inline else => |*list| try list.ensureTotalCapacity(allocator, count),
            }
        }
    };

    fn ensureWithNames(this: *List, allocator: std.mem.Allocator) !void {
        if (this.impl == .with_names) return;

        var without_names = this.impl.without_names;
        var with_names: std.MultiArrayList(Mapping) = .empty;
        try with_names.ensureTotalCapacity(allocator, without_names.len);
        defer without_names.deinit(allocator);

        with_names.len = without_names.len;
        const old_slices = without_names.slice();
        const new_slices = with_names.slice();

        @memcpy(new_slices.items(.generated), old_slices.items(.generated));
        @memcpy(new_slices.items(.original), old_slices.items(.original));
        @memcpy(new_slices.items(.source_index), old_slices.items(.source_index));
        @memset(new_slices.items(.name_index), -1);

        this.impl = .{ .with_names = with_names };
    }

    fn findIndexFromGenerated(line_column_offsets: []const LineColumnOffset, line: bun.Ordinal, column: bun.Ordinal) ?usize {
        var count = line_column_offsets.len;
        var index: usize = 0;
        while (count > 0) {
            const step = count / 2;
            const i: usize = index + step;
            const mapping = line_column_offsets[i];
            if (mapping.lines.zeroBased() < line.zeroBased() or (mapping.lines.zeroBased() == line.zeroBased() and mapping.columns.zeroBased() <= column.zeroBased())) {
                index = i + 1;
                count -|= step + 1;
            } else {
                count = step;
            }
        }

        if (index > 0) {
            if (line_column_offsets[index - 1].lines.zeroBased() == line.zeroBased()) {
                return index - 1;
            }
        }

        return null;
    }

    pub fn findIndex(this: *const List, line: bun.Ordinal, column: bun.Ordinal) ?usize {
        switch (this.impl) {
            inline else => |*list| {
                if (findIndexFromGenerated(list.items(.generated), line, column)) |i| {
                    return i;
                }
            },
        }

        return null;
    }

    const SortContext = struct {
        generated: []const LineColumnOffset,
        pub fn lessThan(ctx: SortContext, a_index: usize, b_index: usize) bool {
            const a = ctx.generated[a_index];
            const b = ctx.generated[b_index];

            if (a.lines.zeroBased() != b.lines.zeroBased()) {
                return a.lines.zeroBased() < b.lines.zeroBased();
            }
            if (a.columns.zeroBased() != b.columns.zeroBased()) {
                return a.columns.zeroBased() < b.columns.zeroBased();
            }
            return a_index < b_index;
        }
    };

    pub fn sort(this: *List) void {
        switch (this.impl) {
            .without_names => |*list| list.sort(SortContext{ .generated = list.items(.generated) }),
            .with_names => |*list| list.sort(SortContext{ .generated = list.items(.generated) }),
        }
    }

    pub fn append(this: *List, allocator: std.mem.Allocator, mapping: *const Mapping) !void {
        switch (this.impl) {
            .without_names => |*list| {
                try list.append(allocator, .{
                    .generated = mapping.generated,
                    .original = mapping.original,
                    .source_index = mapping.source_index,
                });
            },
            .with_names => |*list| {
                try list.append(allocator, mapping.*);
            },
        }
    }

    pub fn find(this: *const List, line: bun.Ordinal, column: bun.Ordinal) ?Mapping {
        switch (this.impl) {
            inline else => |*list, tag| {
                if (findIndexFromGenerated(list.items(.generated), line, column)) |i| {
                    if (tag == .without_names) {
                        return list.get(i).toNamed();
                    } else {
                        return list.get(i);
                    }
                }
            },
        }

        return null;
    }
    pub fn generated(self: *const List) []const LineColumnOffset {
        return switch (self.impl) {
            inline else => |*list| list.items(.generated),
        };
    }

    pub fn original(self: *const List) []const LineColumnOffset {
        return switch (self.impl) {
            inline else => |*list| list.items(.original),
        };
    }

    pub fn sourceIndex(self: *const List) []const i32 {
        return switch (self.impl) {
            inline else => |*list| list.items(.source_index),
        };
    }

    pub fn nameIndex(self: *const List) []const i32 {
        return switch (self.impl) {
            inline else => |*list| list.items(.name_index),
        };
    }

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        switch (self.impl) {
            inline else => |*list| list.deinit(allocator),
        }

        self.names_buffer.deinit(allocator);
        allocator.free(self.names);
    }

    pub fn getName(this: *List, index: i32) ?[]const u8 {
        if (index < 0) return null;
        const i: usize = @intCast(index);

        if (i >= this.names.len) return null;

        if (this.impl == .with_names) {
            const str: *const bun.Semver.String = &this.names[i];
            return str.slice(this.names_buffer.slice());
        }

        return null;
    }

    pub fn memoryCost(this: *const List) usize {
        return this.impl.memoryCost() + this.names_buffer.memoryCost() +
            (this.names.len * @sizeOf(bun.Semver.String));
    }

    pub fn ensureTotalCapacity(this: *List, allocator: std.mem.Allocator, count: usize) !void {
        try this.impl.ensureTotalCapacity(allocator, count);
    }
};

pub const Lookup = struct {
    mapping: Mapping,
    source_map: ?*ParsedSourceMap = null,
    /// Owned by default_allocator always
    /// use `getSourceCode` to access this as a Slice
    prefetched_source_code: ?[]const u8,

    name: ?[]const u8 = null,

    /// Borrows the source map's name, or owns a resolved path when the source
    /// differs from the executed file:
    ///
    /// - `bun build --sourcemap`, it is another file on disk
    /// - `bun build --compile --sourcemap`, it is an embedded file.
    pub fn displaySourceURLIfNeeded(lookup: Lookup, base_filename: []const u8) bun.OOM!?bun.String.Slice {
        const source_map = lookup.source_map orelse return null;
        // See doc comment on `external_source_names`
        if (source_map.external_source_names.len == 0)
            return null;
        if (lookup.mapping.source_index >= source_map.external_source_names.len)
            return null;

        const name = source_map.external_source_names[@intCast(lookup.mapping.source_index)];

        if (source_map.source_content == .standalone_module_graph) {
            return .fromUTF8NeverFree(name);
        }

        if (std.fs.path.isAbsolute(base_filename)) {
            const dir = std.fs.path.dirname(base_filename) orelse base_filename;
            return .init(bun.default_allocator, try std.fs.path.resolve(bun.default_allocator, &.{ dir, name }));
        }

        return .fromUTF8NeverFree(name);
    }
};

pub inline fn generatedLine(mapping: *const Mapping) i32 {
    return mapping.generated.lines.zeroBased();
}

pub inline fn generatedColumn(mapping: *const Mapping) i32 {
    return mapping.generated.columns.zeroBased();
}

pub inline fn sourceIndex(mapping: *const Mapping) i32 {
    return mapping.source_index;
}

pub inline fn originalLine(mapping: *const Mapping) i32 {
    return mapping.original.lines.zeroBased();
}

pub inline fn originalColumn(mapping: *const Mapping) i32 {
    return mapping.original.columns.zeroBased();
}

pub inline fn nameIndex(mapping: *const Mapping) i32 {
    return mapping.name_index;
}

pub fn parse(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    estimated_mapping_count: ?usize,
    sources_count: i32,
    input_line_count: ?usize,
    options: struct {
        allow_names: bool = false,
        sort: bool = false,
    },
) ParseResult {
    debug("parse mappings ({d} bytes)", .{bytes.len});
    if (bytes.len > std.math.maxInt(i32)) return .{ .fail = .{
        .msg = "Source map is too large",
        .err = error.OutOfMemory,
        .loc = .{},
    } };

    var mapping = Mapping.List{};
    var committed = false;
    defer if (!committed) mapping.deinit(allocator);

    if (estimated_mapping_count) |count| {
        mapping.ensureTotalCapacity(allocator, count) catch {
            return .{
                .fail = .{
                    .msg = "Out of memory",
                    .err = error.OutOfMemory,
                    .loc = .{},
                },
            };
        };
    }

    var generated = LineColumnOffset{ .lines = bun.Ordinal.start, .columns = bun.Ordinal.start };
    var original = LineColumnOffset{ .lines = bun.Ordinal.start, .columns = bun.Ordinal.start };
    var name_index: i32 = 0;
    var source_index: i32 = 0;
    var max_original_line: usize = 0;
    var needs_sort = false;
    var remain = bytes;
    var has_names = false;
    while (remain.len > 0) {
        if (remain[0] == ';') {
            generated.columns = bun.Ordinal.start;

            while (strings.hasPrefixComptime(
                remain,
                comptime @as([@sizeOf(usize) / 2]u8, @splat(';')),
            )) {
                generated.lines = generated.lines.addScalar(@sizeOf(usize) / 2);
                remain = remain[@sizeOf(usize) / 2 ..];
            }

            while (remain.len > 0 and remain[0] == ';') {
                generated.lines = generated.lines.addScalar(1);
                remain = remain[1..];
            }

            if (remain.len == 0) {
                break;
            }
        }

        // Read the generated column
        const generated_column_delta = decodeVLQ(remain, 0);

        if (generated_column_delta.start == 0) {
            return .{
                .fail = .{
                    .msg = "Missing generated column value",
                    .err = error.MissingGeneratedColumnValue,
                    .value = generated.columns.zeroBased(),
                    .loc = .{ .start = @as(i32, @intCast(bytes.len - remain.len)) },
                },
            };
        }

        needs_sort = needs_sort or generated_column_delta.value < 0;

        const generated_column, const generated_column_overflow = @addWithOverflow(generated.columns.zeroBased(), generated_column_delta.value);
        if (generated_column_overflow != 0 or generated_column < 0) {
            return .{
                .fail = .{
                    .msg = "Invalid generated column value",
                    .err = error.InvalidGeneratedColumnValue,
                    .value = generated_column,
                    .loc = .{ .start = @as(i32, @intCast(bytes.len - remain.len)) },
                },
            };
        }
        generated.columns = .fromZeroBased(generated_column);

        remain = remain[generated_column_delta.start..];

        // According to the specification, it's valid for a mapping to have 1,
        // 4, or 5 variable-length fields. Having one field means there's no
        // original location information, which is pretty useless. Just ignore
        // those entries.
        if (remain.len == 0)
            break;

        switch (remain[0]) {
            ',' => {
                remain = remain[1..];
                continue;
            },
            ';' => {
                continue;
            },
            else => {},
        }

        // Read the original source
        const source_index_delta = decodeVLQ(remain, 0);
        if (source_index_delta.start == 0) {
            return .{
                .fail = .{
                    .msg = "Invalid source index delta",
                    .err = error.InvalidSourceIndexDelta,
                    .loc = .{ .start = @as(i32, @intCast(bytes.len - remain.len)) },
                },
            };
        }
        const next_source_index, const source_index_overflow = @addWithOverflow(source_index, source_index_delta.value);
        if (source_index_overflow != 0 or next_source_index < 0 or next_source_index >= sources_count) {
            return .{
                .fail = .{
                    .msg = "Invalid source index value",
                    .err = error.InvalidSourceIndexValue,
                    .value = next_source_index,
                    .loc = .{ .start = @as(i32, @intCast(bytes.len - remain.len)) },
                },
            };
        }
        source_index = next_source_index;
        remain = remain[source_index_delta.start..];

        // Read the original line
        const original_line_delta = decodeVLQ(remain, 0);
        if (original_line_delta.start == 0) {
            return .{
                .fail = .{
                    .msg = "Missing original line",
                    .err = error.MissingOriginalLine,
                    .loc = .{ .start = @as(i32, @intCast(bytes.len - remain.len)) },
                },
            };
        }

        const original_line, const original_line_overflow = @addWithOverflow(original.lines.zeroBased(), original_line_delta.value);
        if (original_line_overflow != 0 or original_line < 0) {
            return .{
                .fail = .{
                    .msg = "Invalid original line value",
                    .err = error.InvalidOriginalLineValue,
                    .value = original_line,
                    .loc = .{ .start = @as(i32, @intCast(bytes.len - remain.len)) },
                },
            };
        }
        original.lines = .fromZeroBased(original_line);
        remain = remain[original_line_delta.start..];

        // Read the original column
        const original_column_delta = decodeVLQ(remain, 0);
        if (original_column_delta.start == 0) {
            return .{
                .fail = .{
                    .msg = "Missing original column value",
                    .err = error.MissingOriginalColumnValue,
                    .value = original.columns.zeroBased(),
                    .loc = .{ .start = @as(i32, @intCast(bytes.len - remain.len)) },
                },
            };
        }

        const original_column, const original_column_overflow = @addWithOverflow(original.columns.zeroBased(), original_column_delta.value);
        if (original_column_overflow != 0 or original_column < 0) {
            return .{
                .fail = .{
                    .msg = "Invalid original column value",
                    .err = error.InvalidOriginalColumnValue,
                    .value = original_column,
                    .loc = .{ .start = @as(i32, @intCast(bytes.len - remain.len)) },
                },
            };
        }
        original.columns = .fromZeroBased(original_column);
        remain = remain[original_column_delta.start..];

        if (remain.len > 0) {
            switch (remain[0]) {
                ',' => {
                    // 4 column, but there's more on this line.
                    remain = remain[1..];
                },
                // 4 column, and there's no more on this line.
                ';' => {},

                // 5th column: the name
                else => |c| {
                    // Read the name index
                    const name_index_delta = decodeVLQ(remain, 0);
                    if (name_index_delta.start == 0) {
                        return .{
                            .fail = .{
                                .msg = "Invalid name index delta",
                                .err = error.InvalidNameIndexDelta,
                                .value = @intCast(c),
                                .loc = .{ .start = @as(i32, @intCast(bytes.len - remain.len)) },
                            },
                        };
                    }
                    remain = remain[name_index_delta.start..];

                    const next_name_index, const name_index_overflow = @addWithOverflow(name_index, name_index_delta.value);
                    if (name_index_overflow != 0 or next_name_index < 0) return .{ .fail = .{
                        .msg = "Invalid name index value",
                        .err = error.InvalidNameIndexValue,
                        .value = next_name_index,
                        .loc = .{ .start = @intCast(bytes.len - remain.len) },
                    } };
                    name_index = next_name_index;

                    if (options.allow_names) {
                        if (!has_names) {
                            mapping.ensureWithNames(allocator) catch {
                                return .{
                                    .fail = .{
                                        .msg = "Out of memory",
                                        .err = error.OutOfMemory,
                                        .loc = .{ .start = @as(i32, @intCast(bytes.len - remain.len)) },
                                    },
                                };
                            };
                        }
                        has_names = true;
                    }

                    if (remain.len > 0) {
                        switch (remain[0]) {
                            // There's more on this line.
                            ',' => {
                                remain = remain[1..];
                            },
                            // That's the end of the line.
                            ';' => {},
                            else => {},
                        }
                    }
                },
            }
        }
        max_original_line = @max(max_original_line, @as(usize, @intCast(original.lines.zeroBased())));
        mapping.append(allocator, &.{
            .generated = generated,
            .original = original,
            .source_index = source_index,
            .name_index = name_index,
        }) catch |err| return .{ .fail = .{
            .msg = "Out of memory",
            .err = err,
            .loc = .{},
        } };
    }

    if (needs_sort and options.sort) {
        mapping.sort();
    }

    committed = true;
    return .{ .success = .{
        .ref_count = .init(),
        .allocator = allocator,
        .mappings = mapping,
        .input_line_count = input_line_count orelse max_original_line,
    } };
}

test "mapping coordinate accumulation rejects overflow" {
    const Case = struct { input: []const u8, failure: anyerror };
    for ([_]Case{
        .{ .input = "+/////DAAA,CAAA", .failure = error.InvalidGeneratedColumnValue },
        .{ .input = "ACAA,A+/////DAA", .failure = error.InvalidSourceIndexValue },
        .{ .input = "AA+/////DA,AACA", .failure = error.InvalidOriginalLineValue },
        .{ .input = "AAA+/////D,AAAC", .failure = error.InvalidOriginalColumnValue },
        .{ .input = "AAAAC,AAAA+/////D", .failure = error.InvalidNameIndexValue },
        .{ .input = "AAAAD", .failure = error.InvalidNameIndexValue },
    }) |case| {
        switch (parse(std.testing.allocator, case.input, null, std.math.maxInt(i32), null, .{ .allow_names = true })) {
            .fail => |failure| try std.testing.expectEqual(case.failure, failure.err),
            .success => |value| {
                var unexpected = value;
                unexpected.mappings.deinit(std.testing.allocator);
                return error.ExpectedInvalidSourceMap;
            },
        }
    }
}

test "mapping parse failures release partial storage and preserve allocator ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const parsed = owned: {
                var value = switch (parse(allocator, "AAAA,CACC", null, 1, null, .{})) {
                    .success => |result| result,
                    .fail => |failure| return failure.err,
                };
                errdefer value.mappings.deinit(allocator);
                const result = try allocator.create(ParsedSourceMap);
                result.* = value;
                break :owned result;
            };
            defer parsed.deref();
            try std.testing.expect(parsed.findMapping(.fromZeroBased(0), .fromZeroBased(1)) != null);
            try std.testing.expectEqual(@as(usize, 1), parsed.input_line_count);

            switch (parse(allocator, "AAAA,?", null, 1, 1, .{})) {
                .fail => |failure| {
                    if (failure.err == error.OutOfMemory) return error.OutOfMemory;
                    try std.testing.expectEqual(error.MissingGeneratedColumnValue, failure.err);
                },
                .success => |result| {
                    var unexpected = result;
                    unexpected.mappings.deinit(allocator);
                    return error.ExpectedInvalidSourceMap;
                },
            }
        }
    }.run, .{});
}

const std = @import("std");

const SourceMap = @import("./sourcemap.zig");
const LineColumnOffset = SourceMap.LineColumnOffset;
const ParseResult = SourceMap.ParseResult;
const ParsedSourceMap = SourceMap.ParsedSourceMap;
const decodeVLQ = SourceMap.VLQ.decode;

const bun = @import("bun");
const assert = bun.assert;
const strings = bun.strings;
