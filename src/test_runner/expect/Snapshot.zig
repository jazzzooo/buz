const std = @import("std");

pub const TrimResult = struct {
    trimmed: []const u8,
    start_indent: ?[]const u8,
    end_indent: ?[]const u8,
};

pub fn trimLeadingWhitespaceForInlineSnapshot(input: []const u8, buffer: []u8) TrimResult {
    std.debug.assert(buffer.len == input.len);
    var src = input;
    var dst = buffer;
    const unchanged: TrimResult = .{ .trimmed = input, .start_indent = null, .end_indent = null };

    const first_newline = std.mem.indexOfScalar(u8, src, '\n') orelse return unchanged;
    for (src[0..first_newline]) |char| if (char != ' ' and char != '\t') return unchanged;
    src = src[first_newline + 1 ..];

    const indent_len = for (src, 0..) |char, i| {
        if (char != ' ' and char != '\t') break i;
    } else src.len;
    const indent = src[0..indent_len];
    const keep_indentation: TrimResult = .{ .trimmed = input, .start_indent = indent, .end_indent = indent };
    if (indent_len == 0) return keep_indentation;

    dst[0] = '\n';
    dst = dst[1..];
    src = src[indent_len..];
    const second_newline = (std.mem.indexOfScalar(u8, src, '\n') orelse return keep_indentation) + 1;
    @memcpy(dst[0..second_newline], src[0..second_newline]);
    src = src[second_newline..];
    dst = dst[second_newline..];

    while (src.len > 0) {
        const max_indent_len = @min(src.len, indent_len);
        const line_indent_len = for (src[0..max_indent_len], 0..) |char, i| {
            if (char != ' ' and char != '\t') break i;
        } else max_indent_len;
        src = src[line_indent_len..];

        if (line_indent_len < max_indent_len) {
            if (src.len == 0) break;
            if (src[0] == '\n') {
                dst[0] = '\n';
                src = src[1..];
                dst = dst[1..];
                continue;
            }
            return keep_indentation;
        }

        const line_newline = (std.mem.indexOfScalar(u8, src, '\n') orelse {
            for (src) |char| {
                if (char != ' ' and char != '\t') return keep_indentation;
            }
            break;
        }) + 1;
        @memcpy(dst[0..line_newline], src[0..line_newline]);
        src = src[line_newline..];
        dst = dst[line_newline..];
    }

    const end_indent_start = if (std.mem.lastIndexOfScalar(u8, input, '\n')) |index| index + 1 else return keep_indentation;
    for (input[end_indent_start..]) |char| if (char != ' ' and char != '\t') return keep_indentation;
    return .{
        .trimmed = buffer[0 .. buffer.len - dst.len],
        .start_indent = indent,
        .end_indent = input[end_indent_start..],
    };
}

fn expectTrimmed(input: []const u8, expected: []const u8) !void {
    const buffer = try std.testing.allocator.alloc(u8, input.len);
    defer std.testing.allocator.free(buffer);

    const result = trimLeadingWhitespaceForInlineSnapshot(input, buffer);
    checkLineSuffixes(input, result);
    try std.testing.expectEqualStrings(expected, result.trimmed);
}

fn checkLineSuffixes(input: []const u8, result: TrimResult) void {
    var input_lines = std.mem.splitScalar(u8, input, '\n');
    var output_lines = std.mem.splitScalar(u8, result.trimmed, '\n');
    while (true) {
        const input_line = input_lines.next();
        const output_line = output_lines.next();
        if (input_line == null) {
            std.debug.assert(output_line == null);
            break;
        }
        std.debug.assert(output_line != null);
        std.debug.assert(std.mem.endsWith(u8, input_line.?, output_line.?));
    }
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var input_buffer: [4096]u8 = undefined;
    const input = input_buffer[0..smith.slice(&input_buffer)];
    const buffer = try std.testing.allocator.alloc(u8, input.len);
    defer std.testing.allocator.free(buffer);
    checkLineSuffixes(input, trimLeadingWhitespaceForInlineSnapshot(input, buffer));
}

test "trim inline snapshot indentation" {
    try expectTrimmed(
        \\
        \\Hello, world!
        \\
    ,
        \\
        \\Hello, world!
        \\
    );
    try expectTrimmed(
        \\
        \\  Hello, world!
        \\
    ,
        \\
        \\Hello, world!
        \\
    );
    try expectTrimmed(
        \\
        \\  Object{
        \\    key: value
        \\  }
        \\
    ,
        \\
        \\Object{
        \\  key: value
        \\}
        \\
    );
    try expectTrimmed(
        \\
        \\  Object{
        \\  key: value
        \\
        \\  }
        \\
    ,
        \\
        \\Object{
        \\key: value
        \\
        \\}
        \\
    );
    try expectTrimmed(
        \\
        \\    Object{
        \\  key: value
        \\  }
        \\
    ,
        \\
        \\    Object{
        \\  key: value
        \\  }
        \\
    );
    try expectTrimmed(
        \\
        \\  "æ™
        \\
        \\  !!!!*5897yhduN"'\`Il"
        \\
    ,
        \\
        \\"æ™
        \\
        \\!!!!*5897yhduN"'\`Il"
        \\
    );
}

test "fuzz inline snapshot indentation" {
    try std.testing.fuzz({}, fuzzOne, .{});
}
