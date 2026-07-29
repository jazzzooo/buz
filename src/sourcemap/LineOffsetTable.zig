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

pub fn findLine(byte_offsets_to_start_of_line: []const u32, loc: Logger.Loc) i32 {
    assert(loc.start > -1); // checked by caller
    var original_line: usize = 0;
    const loc_start = @as(usize, @intCast(loc.start));

    {
        var count = @as(usize, @truncate(byte_offsets_to_start_of_line.len));
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

    return @as(i32, @intCast(original_line)) - 1;
}

pub fn findIndex(byte_offsets_to_start_of_line: []const u32, loc: Logger.Loc) ?usize {
    assert(loc.start > -1); // checked by caller
    var original_line: usize = 0;
    const loc_start = @as(usize, @intCast(loc.start));

    var count = @as(usize, @truncate(byte_offsets_to_start_of_line.len));
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

pub fn generate(allocator: std.mem.Allocator, contents: std.unicode.Wtf8View, approximate_line_count: i32) List {
    const bytes = contents.bytes;
    var list: List = .empty;
    // Preallocate the top-level table using the approximate line count from the lexer
    list.ensureUnusedCapacity(allocator, @as(usize, @intCast(@max(approximate_line_count, 1)))) catch unreachable;
    var column: i32 = 0;
    var byte_offset_to_first_non_ascii: u32 = 0;
    var line_byte_offset: u32 = 0;

    // the idea here is:
    // we want to avoid re-allocating this array _most_ of the time
    // when lines _do_ have unicode characters, they probably still won't be longer than 255 much
    var stack_fallback_buffer: [256]i32 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(@ptrCast(&stack_fallback_buffer), allocator);
    var columns_for_non_ascii = std.array_list.Managed(i32).initCapacity(stack_fallback.allocator(), 120) catch unreachable;
    const reset_end_index = stack_fallback.fixed_buffer_allocator.end_index;
    const initial_columns_for_non_ascii = columns_for_non_ascii;

    var iterator = contents.iterator();
    while (iterator.i < bytes.len) {
        const codepoint_byte_offset = iterator.i;
        const c = iterator.nextCodepoint().?;
        const cp_len = iterator.i - codepoint_byte_offset;

        if (column == 0) {
            line_byte_offset = @truncate(codepoint_byte_offset);
        }

        if (c > 0x7F and columns_for_non_ascii.items.len == 0) {
            // we have a non-ASCII character, so we need to keep track of the
            // mapping from byte offsets to UTF-16 code unit counts
            byte_offset_to_first_non_ascii = @intCast(codepoint_byte_offset - line_byte_offset);
        }

        // Update the per-byte column offsets
        if (columns_for_non_ascii.items.len > 0 or c > 0x7F) {
            columns_for_non_ascii.appendNTimes(column, cp_len) catch unreachable;
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

                // We don't call .toOwnedSlice() because it is expensive to
                // reallocate the array AND when inside an Arena, it's
                // hideously expensive
                var owned = columns_for_non_ascii.items;
                if (stack_fallback.fixed_buffer_allocator.ownsSlice(std.mem.sliceAsBytes(owned))) {
                    owned = allocator.dupe(i32, owned) catch unreachable;
                }

                list.append(allocator, .{
                    .byte_offset_to_start_of_line = line_byte_offset,
                    .byte_offset_to_first_non_ascii = byte_offset_to_first_non_ascii,
                    .columns_for_non_ascii = BabyList(i32).fromOwnedSlice(owned),
                }) catch unreachable;

                column = 0;
                byte_offset_to_first_non_ascii = 0;
                line_byte_offset = 0;

                // reset the list to use the stack-allocated memory
                stack_fallback.fixed_buffer_allocator.reset();
                stack_fallback.fixed_buffer_allocator.end_index = reset_end_index;
                columns_for_non_ascii = initial_columns_for_non_ascii;
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
        columns_for_non_ascii.append(column) catch unreachable;
    }
    {
        var owned = columns_for_non_ascii.toOwnedSlice() catch unreachable;
        if (stack_fallback.fixed_buffer_allocator.ownsSlice(std.mem.sliceAsBytes(owned))) {
            owned = allocator.dupe(i32, owned) catch unreachable;
        }
        list.append(allocator, .{
            .byte_offset_to_start_of_line = line_byte_offset,
            .byte_offset_to_first_non_ascii = byte_offset_to_first_non_ascii,
            .columns_for_non_ascii = BabyList(i32).fromOwnedSlice(owned),
        }) catch unreachable;
    }

    if (list.capacity > list.len) {
        list.shrinkAndFree(allocator, list.len);
    }
    return list;
}

const std = @import("std");

const bun = @import("bun");
const BabyList = bun.BabyList;
const Logger = bun.logger;
const assert = bun.assert;
const strings = bun.strings;
