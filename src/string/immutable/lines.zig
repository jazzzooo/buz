const std = @import("std");

/// Get up to `output.len` lines ending at `target_line`, ordered from the
/// target line backwards.
pub fn getLinesInText(text: []const u8, target_line: u32, output: [][]const u8) ?[]const []const u8 {
    if (text.len == 0 or output.len == 0) return null;

    var output_len: usize = 0;
    var current_line: u32 = 0;
    var line_start: usize = 0;

    while (true) {
        const line_end = std.mem.indexOfAnyPos(u8, text, line_start, "\r\n") orelse text.len;

        const previous_lines_to_keep = @min(output_len, output.len - 1);
        std.mem.copyBackwards(
            []const u8,
            output[1 .. previous_lines_to_keep + 1],
            output[0..previous_lines_to_keep],
        );
        output[0] = text[line_start..line_end];
        output_len = @min(output_len + 1, output.len);

        if (current_line == target_line) return output[0..output_len];
        if (line_end == text.len) return null;

        line_start = line_end + 1;
        if (text[line_end] == '\r' and line_start < text.len and text[line_start] == '\n') {
            line_start += 1;
        }
        current_line += 1;
    }
}

pub fn getLineInText(text: []const u8, line: u32) ?[]const u8 {
    var output: [1][]const u8 = undefined;
    return (getLinesInText(text, line, &output) orelse return null)[0];
}
