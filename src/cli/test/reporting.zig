pub fn escapeXml(str: []const u8, writer: anytype) !void {
    var last: usize = 0;
    for (str, 0..) |c, i| {
        const escaped = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => "\xef\xbf\xbd",
            else => continue,
        };
        if (i > last) try writer.writeAll(str[last..i]);
        try writer.writeAll(escaped);
        last = i + 1;
    }
    if (str.len > last) try writer.writeAll(str[last..]);
}
