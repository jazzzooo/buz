test "Unicode grapheme break conformance" {
    var lines = std.mem.splitScalar(u8, grapheme_break_test, '\n');
    while (lines.next()) |line| {
        const data = std.mem.trim(
            u8,
            line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len],
            " \t\r",
        );
        if (data.len == 0) continue;

        var tokens = std.mem.tokenizeAny(u8, data, " \t");
        if (!std.mem.eql(u8, tokens.next() orelse return error.InvalidTestData, "÷"))
            return error.InvalidTestData;
        var previous = try parseCodePoint(tokens.next() orelse return error.InvalidTestData);
        var state: grapheme.BreakState = .default;

        while (true) {
            const boundary = tokens.next() orelse return error.InvalidTestData;
            const code_point_text = tokens.next() orelse {
                if (!std.mem.eql(u8, boundary, "÷")) return error.InvalidTestData;
                break;
            };
            const current = try parseCodePoint(code_point_text);
            const expected = if (std.mem.eql(u8, boundary, "÷"))
                true
            else if (std.mem.eql(u8, boundary, "×"))
                false
            else
                return error.InvalidTestData;
            try std.testing.expectEqual(expected, grapheme.graphemeBreak(previous, current, &state));
            previous = current;
        }
    }
}

fn parseCodePoint(text: []const u8) !u32 {
    return std.fmt.parseInt(u32, text, 16);
}

const grapheme = @import("grapheme");
const std = @import("std");
const grapheme_break_test = @embedFile("grapheme_break_test");
