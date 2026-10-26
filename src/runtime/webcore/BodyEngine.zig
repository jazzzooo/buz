pub fn writeFormat(body: *Body, comptime Formatter: type, formatter: *Formatter, writer: anytype, comptime enable_ansi_colors: bool) !void {
    const Writer = @TypeOf(writer);
    try formatter.writeIndent(Writer, writer);
    try writer.writeAll(comptime bun.Output.prettyFmt("<r>bodyUsed<d>:<r> ", enable_ansi_colors));
    try formatter.printBoolean(writer, body.value == .Used, enable_ansi_colors);

    if (body.value == .Blob) {
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");
        try formatter.writeIndent(Writer, writer);
        try body.value.Blob.writeFormat(Formatter, formatter, writer, enable_ansi_colors);
    } else if (body.value == .InternalBlob or body.value == .WTFStringImpl) {
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");
        try formatter.writeIndent(Writer, writer);
        try Blob.writeFormatForSize(false, body.value.size(), writer, enable_ansi_colors);
    } else if (body.value == .Locked and body.value.Locked.readable.has()) {
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");
        try formatter.writeIndent(Writer, writer);
        var formatted = try body.value.Locked.readable.format(body.value.Locked.global.get(), .{
            .enable_colors = enable_ansi_colors,
            .add_newline = false,
            .flush = false,
            .max_depth = 2,
        });
        defer formatted.deinit();
        var utf8 = try formatted.toUTF8(bun.default_allocator);
        defer utf8.deinit();
        try writer.writeAll(utf8.slice());
    }
}

const bun = @import("bun");
const Blob = @import("./Blob.zig");
const Body = @import("./Body.zig");
