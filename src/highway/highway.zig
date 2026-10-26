pub fn xxHash3(seed: u64, input: string) u64 {
    return c.highway_xxhash3_64(input.ptr, input.len, seed);
}

pub fn indexOfChar(haystack: string, needle: u8) ?usize {
    if (haystack.len == 0) {
        return null;
    }

    const result = if (comptime Environment.isNative)
        c.highway_index_of_char(haystack.ptr, haystack.len, needle)
    else for (haystack, 0..) |char, index| {
        if (char == needle) break index;
    } else haystack.len;

    if (result == haystack.len) {
        return null;
    }

    bun.debugAssert(haystack[result] == needle);

    return result;
}

pub fn indexOfInterestingCharacterInStringLiteral(slice: string, quote_type: u8) ?usize {
    if (slice.len == 0) {
        return null;
    }

    const result = if (comptime Environment.isNative)
        c.highway_index_of_interesting_character_in_string_literal(slice.ptr, slice.len, quote_type)
    else for (slice, 0..) |char, index| {
        if (char == quote_type or char == '\\' or char < 0x20 or char > 0x7e) break index;
    } else slice.len;

    if (result == slice.len) {
        return null;
    }

    return result;
}

pub fn indexOfNewlineOrNonASCII(haystack: string) ?usize {
    if (haystack.len == 0) return null;

    const result = if (comptime Environment.isNative)
        c.highway_index_of_newline_or_non_ascii(haystack.ptr, haystack.len)
    else for (haystack, 0..) |char, index| {
        if (char > 127 or char < 0x20) break index;
    } else haystack.len;

    if (result == haystack.len) {
        return null;
    }
    if (comptime Environment.isDebug) {
        const haystack_char = haystack[result];
        if (!(haystack_char > 127 or haystack_char < 0x20 or haystack_char == '\r' or haystack_char == '\n')) {
            @panic("Invalid character found in indexOfNewlineOrNonASCII");
        }
    }

    return result;
}

/// Checks if the string contains any newlines, non-ASCII characters, or quotes
pub fn containsNewlineOrNonASCIIOrQuote(text: string) bool {
    if (text.len == 0) {
        return false;
    }

    if (comptime !Environment.isNative) {
        for (text) |char| if (char > 127 or char < 0x20 or char == '"') return true;
        return false;
    }

    return c.highway_contains_newline_or_non_ascii_or_quote(text.ptr, text.len) != 0;
}

/// Finds the first character that needs escaping in a JavaScript string
/// Looks for characters above ASCII (> 127), control characters (< 0x20),
/// backslash characters (`\`), the quote character itself, and for backtick
/// strings also the dollar sign (`$`)
pub fn indexOfNeedsEscapeForJavaScriptString(slice: string, quote_char: u8) ?usize {
    if (slice.len == 0) {
        return null;
    }

    const result = if (comptime Environment.isNative)
        c.highway_index_of_needs_escape_for_javascript_string(slice.ptr, slice.len, quote_char)
    else for (slice, 0..) |char, index| {
        if (char >= 127 or char < 0x20 or char == '\\' or char == quote_char or (quote_char == '`' and char == '$')) break index;
    } else slice.len;

    if (result == slice.len) {
        return null;
    }

    if (comptime Environment.isDebug) {
        const haystack_char = slice[result];
        if (!(haystack_char >= 127 or haystack_char < 0x20 or haystack_char == '\\' or haystack_char == quote_char or haystack_char == '$' or haystack_char == '\r' or haystack_char == '\n')) {
            std.debug.panic("Invalid character found in indexOfNeedsEscapeForJavaScriptString: U+{x}. Full string: \"{f}\"", .{ haystack_char, std.zig.fmtString(slice) });
        }
    }

    return result;
}

pub fn indexOfAnyChar(haystack: string, chars: string) ?usize {
    if (haystack.len == 0 or chars.len == 0) {
        return null;
    }

    const result = if (comptime Environment.isNative)
        c.highway_index_of_any_char(haystack.ptr, haystack.len, chars.ptr, chars.len)
    else find: for (haystack, 0..) |haystack_char, index| {
        for (chars) |char| {
            if (haystack_char == char) break :find index;
        }
    } else haystack.len;

    if (result == haystack.len) {
        return null;
    }

    if (comptime Environment.isDebug) {
        const haystack_char = haystack[result];
        var found = false;
        for (chars) |character| {
            if (character == haystack_char) {
                found = true;
                break;
            }
        }
        if (!found) {
            @panic("Invalid character found in indexOfAnyChar");
        }
    }

    return result;
}

pub fn copyU16ToU8(input: []align(1) const u16, output: []u8) void {
    if (input.len > std.math.maxInt(usize) / 2) @panic("uint16 copy input is too long");
    if (input.len > output.len) @panic("uint16 copy destination is too short");
    if (comptime !Environment.isNative) {
        const input_address = @intFromPtr(input.ptr);
        const output_address = @intFromPtr(output.ptr);
        const prefix = if (output_address > input_address and output_address - input_address < input.len * 2)
            @min(output_address - input_address, input.len)
        else
            0;
        var end = prefix;
        while (end > 0) {
            end -= 1;
            output[end] = @truncate(input[end]);
        }
        for (prefix..input.len) |index| output[index] = @truncate(input[index]);
        return;
    }
    c.highway_copy_u16_to_u8(input.ptr, input.len, output.ptr);
}

/// Apply a WebSocket mask to data using SIMD acceleration
/// If skip_mask is true, data is copied without masking
pub fn fillWithSkipMask(mask: [4]u8, output: []u8, input: []const u8, skip_mask: bool) void {
    if (input.len > output.len) @panic("mask destination is too short");
    if (input.len == 0) {
        return;
    }

    if (comptime !Environment.isNative) {
        const input_address = @intFromPtr(input.ptr);
        const output_address = @intFromPtr(output.ptr);
        if (output_address > input_address and output_address - input_address < input.len) {
            var end = input.len;
            while (end > 0) {
                end -= 1;
                output[end] = if (skip_mask) input[end] else input[end] ^ mask[end % mask.len];
            }
            return;
        }
        for (input, output[0..input.len], 0..) |in, *out, index| {
            out.* = if (skip_mask) in else in ^ mask[index % mask.len];
        }
        return;
    }

    c.highway_fill_with_skip_mask(
        &mask,
        output.ptr,
        input.ptr,
        input.len,
        @intFromBool(skip_mask),
    );
}

/// Useful for single-line JavaScript comments.
/// Scans for:
/// - `\n`, `\r`
/// - Non-ASCII characters (which implicitly include `\n`, `\r`)
/// - `#`
/// - `@`
pub fn indexOfNewlineOrNonASCIIOrHashOrAt(haystack: string) ?usize {
    if (haystack.len == 0) {
        return null;
    }

    const result = if (comptime Environment.isNative)
        c.highway_index_of_newline_or_non_ascii_or_hash_or_at(haystack.ptr, haystack.len)
    else for (haystack, 0..) |char, index| {
        if (char == '#' or char == '@' or char < 0x20 or char > 127) break index;
    } else haystack.len;

    if (result == haystack.len) {
        return null;
    }

    return result;
}

/// Scans for:
/// - " "
/// - Non-ASCII characters (which implicitly include `\n`, `\r`, '\t')
pub fn indexOfSpaceOrNewlineOrNonASCII(haystack: string) ?usize {
    if (haystack.len == 0) {
        return null;
    }

    const result = if (comptime Environment.isNative)
        c.highway_index_of_space_or_newline_or_non_ascii(haystack.ptr, haystack.len)
    else for (haystack, 0..) |char, index| {
        if (char <= ' ' or char > 127) break index;
    } else haystack.len;

    if (result == haystack.len) {
        return null;
    }

    return result;
}

const string = []const u8;

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const c = @import("highway-ffi");
