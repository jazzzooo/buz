pub const inspect = bun.jsc.ConsoleObject.formatClassRefForBinding;

pub fn writeFormat(
    archive: *const Archive,
    comptime Formatter: type,
    formatter: *Formatter,
    writer: anytype,
    comptime enable_ansi_colors: bool,
) !void {
    const Writer = @TypeOf(writer);

    try writer.print(comptime bun.Output.prettyFmt("Archive ({f}) {{\n", enable_ansi_colors), .{bun.fmt.size(archive.byteLength(), .{})});

    {
        formatter.indent += 1;
        defer formatter.indent -|= 1;

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime bun.Output.prettyFmt("<r>files<d>:<r> ", enable_ansi_colors));
        try formatter.printNumber(writer, @floatFromInt(archive.fileCount()), enable_ansi_colors);
    }
    try writer.writeAll("\n");
    try formatter.writeIndent(Writer, writer);
    try writer.writeAll("}");
    formatter.resetLine();
}

const bun = @import("bun");
const Archive = @import("./Archive.zig");
