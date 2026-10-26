pub const inspect = bun.jsc.ConsoleObject.formatClassRefForBinding;

pub fn writeFormat(reference: *const Response.Ref, comptime Formatter: type, formatter: *Formatter, writer: anytype, comptime enable_ansi_colors: bool) !void {
    const response = reference.get(Response);
    const Writer = @TypeOf(writer);
    try writer.print("Response ({f}) {{\n", .{bun.fmt.size(response.body.len(), .{})});

    {
        formatter.indent += 1;
        defer formatter.indent -|= 1;

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime bun.Output.prettyFmt("<r>ok<d>:<r> ", enable_ansi_colors));
        try formatter.printBoolean(writer, response.isOK(), enable_ansi_colors);
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime bun.Output.prettyFmt("<r>url<d>:<r> \"", enable_ansi_colors));
        try writer.print(comptime bun.Output.prettyFmt("<r><b>{f}<r>", enable_ansi_colors), .{response.url});
        try writer.writeAll("\"");
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime bun.Output.prettyFmt("<r>status<d>:<r> ", enable_ansi_colors));
        try formatter.printNumber(writer, @floatFromInt(response.response_init.status_code), enable_ansi_colors);
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime bun.Output.prettyFmt("<r>statusText<d>:<r> ", enable_ansi_colors));
        try writer.print(comptime bun.Output.prettyFmt("<r>\"<b>{f}<r>\"", enable_ansi_colors), .{response.response_init.status_text});
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime bun.Output.prettyFmt("<r>headers<d>:<r> ", enable_ansi_colors));
        var headers_ref = (try HeadersSlot.getOwned(reference)) orelse headers: {
            const resource = try response.getOrCreateHeaders(formatter.globalThis);
            const created = try Headers.Binding.adoptNativeRef(try Headers.create(resource.retain()), formatter.globalThis);
            HeadersSlot.setOnOwned(reference, &created);
            break :headers created;
        };
        defer headers_ref.deinit();
        try formatter.printClassRef(writer, &headers_ref, enable_ansi_colors);
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime bun.Output.prettyFmt("<r>redirected<d>:<r> ", enable_ansi_colors));
        try formatter.printBoolean(writer, response.redirected, enable_ansi_colors);
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");

        formatter.resetLine();
        try BodyEngine.writeFormat(&response.body, Formatter, formatter, writer, enable_ansi_colors);
    }
    try writer.writeAll("\n");
    try formatter.writeIndent(Writer, writer);
    try writer.writeAll("}");
    formatter.resetLine();
}

const bun = @import("bun");
const BodyEngine = @import("./BodyEngine.zig");
const Response = @import("./Response.zig");
const Headers = @import("./Headers.zig");
const HeadersSlot = Response.Binding.CachedClassRefSlot("headers");
