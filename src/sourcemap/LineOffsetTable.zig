const LineOffsetTable = @This();

/// The source map specification is very loose and does not specify what
/// column numbers actually mean. The popular "source-map" library from Mozilla
/// appears to interpret them as counts of UTF-16 code units, so we generate
/// those too for compatibility.
///
/// We keep mapping tables around to accelerate conversion from byte offsets
/// to UTF-16 code unit counts. Since most JavaScript is ASCII and the mapping
/// for ASCII is 1:1, we avoid creating a table for ASCII-only lines.
///
columns_for_non_ascii: BabyList(i32) = .{},
byte_offset_to_first_non_ascii: u32 = 0,
byte_offset_to_start_of_line: u32 = 0,

pub const List = std.MultiArrayList(LineOffsetTable);

pub fn deinitList(list: *List, allocator: std.mem.Allocator) void {
    for (list.items(.columns_for_non_ascii)) |*columns| columns.deinit(allocator);
    list.deinit(allocator);
    list.* = .empty;
}

fn appendLine(list: *List, allocator: std.mem.Allocator, byte_offset: u32, non_ascii_offset: u32, columns: []const i32) bun.OOM!void {
    const owned = try allocator.dupe(i32, columns);
    errdefer allocator.free(owned);
    try list.append(allocator, .{
        .byte_offset_to_start_of_line = byte_offset,
        .byte_offset_to_first_non_ascii = non_ascii_offset,
        .columns_for_non_ascii = BabyList(i32).fromOwnedSlice(owned),
    });
}

pub fn findLine(byte_offsets_to_start_of_line: []const u32, loc: Logger.Loc) i32 {
    assert(loc.start > -1); // checked by caller
    var original_line: usize = 0;
    const loc_start = @as(usize, @intCast(loc.start));

    {
        var count = byte_offsets_to_start_of_line.len;
        var i: usize = 0;
        while (count > 0) {
            const step = count / 2;
            i = original_line + step;
            if (byte_offsets_to_start_of_line[i] <= loc_start) {
                original_line = i + 1;
                count = count - step - 1;
            } else {
                count = step;
            }
        }
    }

    return if (original_line == 0) -1 else @intCast(original_line - 1);
}

pub fn findIndex(byte_offsets_to_start_of_line: []const u32, loc: Logger.Loc) ?usize {
    assert(loc.start > -1); // checked by caller
    var original_line: usize = 0;
    const loc_start = @as(usize, @intCast(loc.start));

    var count = byte_offsets_to_start_of_line.len;
    var i: usize = 0;
    while (count > 0) {
        const step = count / 2;
        i = original_line + step;
        const byte_offset = byte_offsets_to_start_of_line[i];
        if (byte_offset == loc_start) {
            return i;
        }
        if (i + 1 < byte_offsets_to_start_of_line.len) {
            const next_byte_offset = byte_offsets_to_start_of_line[i + 1];
            if (byte_offset < loc_start and loc_start < next_byte_offset) {
                return i;
            }
        }

        if (byte_offset < loc_start) {
            original_line = i + 1;
            count = count - step - 1;
        } else {
            count = step;
        }
    }

    return null;
}

pub fn generate(allocator: std.mem.Allocator, contents: std.unicode.Wtf8View, approximate_line_count: usize) bun.OOM!List {
    const bytes = contents.bytes;
    if (bytes.len > std.math.maxInt(i32)) return error.OutOfMemory;
    var list: List = .empty;
    errdefer deinitList(&list, allocator);
    try list.ensureUnusedCapacity(allocator, @min(@max(approximate_line_count, 1), bytes.len + 1));
    var column: i32 = 0;
    var byte_offset_to_first_non_ascii: u32 = 0;
    var line_byte_offset: u32 = 0;

    var stack_fallback_buffer: [256]i32 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(@ptrCast(&stack_fallback_buffer), allocator);
    var columns_for_non_ascii = try std.array_list.Managed(i32).initCapacity(stack_fallback.allocator(), 120);
    defer columns_for_non_ascii.deinit();

    var iterator = contents.iterator();
    while (iterator.i < bytes.len) {
        const codepoint_byte_offset = iterator.i;
        const c = iterator.nextCodepoint().?;
        const cp_len = iterator.i - codepoint_byte_offset;

        if (column == 0) {
            line_byte_offset = @intCast(codepoint_byte_offset);
        }

        if (c > 0x7F and columns_for_non_ascii.items.len == 0) {
            // we have a non-ASCII character, so we need to keep track of the
            // mapping from byte offsets to UTF-16 code unit counts
            byte_offset_to_first_non_ascii = @intCast(codepoint_byte_offset - line_byte_offset);
        }

        // Update the per-byte column offsets
        if (columns_for_non_ascii.items.len > 0 or c > 0x7F) {
            try columns_for_non_ascii.appendNTimes(column, cp_len);
        } else {
            switch (c) {
                (@max('\r', '\n') + 1)...127 => {
                    // skip ahead to the next newline or non-ascii character
                    const remaining = bytes[codepoint_byte_offset..];
                    if (strings.indexOfNewlineOrNonASCIICheckStart(remaining, @intCast(cp_len), false)) |j| {
                        column += @as(i32, @intCast(j));
                        iterator.i = codepoint_byte_offset + j;
                    } else {
                        // if there are no more lines, we are done!
                        column += @as(i32, @intCast(remaining.len));
                        iterator.i = bytes.len;
                    }

                    continue;
                },
                else => {},
            }
        }

        switch (c) {
            '\r', '\n', 0x2028, 0x2029 => {
                // windows newline
                if (c == '\r' and iterator.i < bytes.len and bytes[iterator.i] == '\n') {
                    column += 1;
                    continue;
                }

                try appendLine(&list, allocator, line_byte_offset, byte_offset_to_first_non_ascii, columns_for_non_ascii.items);

                column = 0;
                byte_offset_to_first_non_ascii = 0;
                line_byte_offset = 0;

                columns_for_non_ascii.clearRetainingCapacity();
            },
            else => {
                // Mozilla's "source-map" library counts columns using UTF-16 code units
                column += @as(i32, @intFromBool(c > 0xFFFF)) + 1;
            },
        }
    }

    // Mark the start of the next line
    if (column == 0) {
        line_byte_offset = @as(u32, @intCast(bytes.len));
    }

    if (columns_for_non_ascii.items.len > 0) {
        try columns_for_non_ascii.append(column);
    }
    try appendLine(&list, allocator, line_byte_offset, byte_offset_to_first_non_ascii, columns_for_non_ascii.items);

    if (list.capacity > list.len) {
        list.shrinkAndFree(allocator, list.len);
    }
    return list;
}

test "line offset tables own Unicode rows across allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const repeated: [200][2]u8 = @splat("é".*);
            const source = "ascii\nxé😀z\r\n" ++ @as([400]u8, @bitCast(repeated)) ++ "\n終";
            var table = try generate(allocator, try std.unicode.Wtf8View.init(source), 1);
            defer deinitList(&table, allocator);
            try std.testing.expectEqualSlices(u32, &.{ 0, 6, 16, 417 }, table.items(.byte_offset_to_start_of_line));
            try std.testing.expectEqualSlices(u32, &.{ 0, 1, 0, 0 }, table.items(.byte_offset_to_first_non_ascii));
            const columns = table.items(.columns_for_non_ascii);
            try std.testing.expectEqual(@as(usize, 0), columns[0].slice().len);
            try std.testing.expectEqualSlices(i32, &.{ 1, 1, 2, 2, 2, 2, 4, 5, 6 }, columns[1].slice());
            try std.testing.expectEqual(@as(usize, 401), columns[2].slice().len);
            try std.testing.expectEqualSlices(i32, &.{ 0, 0, 0, 1 }, columns[3].slice());
            try std.testing.expectEqual(@as(i32, 3), findLine(table.items(.byte_offset_to_start_of_line), .{ .start = source.len }));
        }
    }.run, .{});
}

const std = @import("std");

const bun = @import("bun");
const BabyList = bun.BabyList;
const Logger = bun.logger;
const assert = bun.assert;
const strings = bun.strings;
