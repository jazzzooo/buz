pub fn writeFormatWithValues(
    filename: []const u8,
    max_filename_length: usize,
    vals: Fraction,
    failing: Fraction,
    failed: bool,
    writer: *std.Io.Writer,
    indent_name: bool,
    comptime enable_colors: bool,
) !void {
    if (comptime enable_colors) {
        try writer.writeAll(if (failed)
            comptime prettyFmt("<r><b><red>", true)
        else
            comptime prettyFmt("<r><b><green>", true));
    }

    if (indent_name) try writer.writeAll(" ");

    try writer.writeAll(filename);
    try writer.splatByteAll(' ', max_filename_length - filename.len + @as(usize, @intFromBool(!indent_name)));
    try writer.writeAll(comptime prettyFmt("<r><d> | <r>", enable_colors));

    if (comptime enable_colors) {
        try writer.writeAll(if (vals.functions < failing.functions)
            comptime prettyFmt("<b><red>", true)
        else
            comptime prettyFmt("<b><green>", true));
    }

    try writer.print("{d: >7.2}", .{vals.functions * 100.0});
    try writer.writeAll(comptime prettyFmt("<r><d> | <r>", enable_colors));

    if (comptime enable_colors) {
        try writer.writeAll(if (vals.lines < failing.lines)
            comptime prettyFmt("<b><red>", true)
        else
            comptime prettyFmt("<b><green>", true));
    }

    try writer.print("{d: >7.2}", .{vals.lines * 100.0});
}

const std = @import("std");
const bun = @import("bun");
const Fraction = @import("./CoverageFraction.zig").Fraction;
const prettyFmt = bun.Output.prettyFmt;
