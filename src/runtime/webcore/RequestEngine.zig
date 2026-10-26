pub const inspect = bun.jsc.ConsoleObject.formatClassRefForBinding;

pub fn writeFormat(reference: *const Request.Ref, comptime Formatter: type, formatter: *Formatter, writer: anytype, comptime enable_ansi_colors: bool) !void {
    const request = reference.get(Request);
    const Writer = @TypeOf(writer);
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(formatter.globalThis);
    defer scope.deinit();
    const is_bun_request = scope.engine(Request.JSValueIsBunRequestSchema).call(.{ .value = reference.operand(&scope) });
    const class_label = if (is_bun_request) "BunRequest" else "Request";
    try writer.print("{s} ({f}) {{\n", .{ class_label, bun.fmt.size(request.body.get().value.size(), .{}) });
    {
        formatter.indent += 1;
        defer formatter.indent -|= 1;

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime bun.Output.prettyFmt("<r>method<d>:<r> \"", enable_ansi_colors));
        try writer.writeAll(bun.asByteSlice(@tagName(request.method)));
        try writer.writeAll("\"");
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime bun.Output.prettyFmt("<r>url<d>:<r> ", enable_ansi_colors));
        try request.ensureURL();
        try writer.print(comptime bun.Output.prettyFmt("\"<b>{f}<r>\"", enable_ansi_colors), .{request.url});
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");

        if (is_bun_request) {
            if (try scope.engine(Request.BunRequestParamsSchema).call(.{ .value = reference.operand(&scope) })) |params_value| {
                var params = params_value;
                defer params.deinit();
                var params_object = try params.toOwned();
                defer params_object.deinit();
                try formatter.writeIndent(Writer, writer);
                try writer.writeAll(comptime bun.Output.prettyFmt("<r>params<d>:<r> ", enable_ansi_colors));
                try formatter.printOwnedObject(writer, &params_object, enable_ansi_colors);
                try formatter.printComma(Writer, writer, enable_ansi_colors);
                try writer.writeAll("\n");
            }
        }

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime bun.Output.prettyFmt("<r>headers<d>:<r> ", enable_ansi_colors));
        var headers_ref = (try HeadersSlot.getOwned(reference)) orelse headers: {
            const resource = try request.ensureFetchHeaders(formatter.globalThis);
            const created = try Headers.Binding.adoptNativeRef(try Headers.create(resource.retain()), formatter.globalThis);
            HeadersSlot.setOnOwned(reference, &created);
            break :headers created;
        };
        defer headers_ref.deinit();
        try formatter.printClassRef(writer, &headers_ref, enable_ansi_colors);

        if (request.body.get().value == .Blob) {
            try writer.writeAll("\n");
            try formatter.writeIndent(Writer, writer);
            try request.body.get().value.Blob.writeFormat(Formatter, formatter, writer, enable_ansi_colors);
        } else if (request.body.get().value == .InternalBlob or request.body.get().value == .WTFStringImpl) {
            try writer.writeAll("\n");
            try formatter.writeIndent(Writer, writer);
            const size = request.body.get().value.size();
            if (size == 0) {
                var empty = Blob.initEmpty();
                try empty.writeFormat(Formatter, formatter, writer, enable_ansi_colors);
            } else {
                try Blob.writeFormatForSize(false, size, writer, enable_ansi_colors);
            }
        } else if (request.body.get().value == .Locked) {
            if (try request.getBodyReadableStream(formatter.globalThis)) |stream| {
                var owned_stream = stream;
                defer owned_stream.deinit();
                try writer.writeAll("\n");
                try formatter.writeIndent(Writer, writer);
                var formatted = try owned_stream.format(formatter.globalThis, .{
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
    }
    try writer.writeAll("\n");
    try formatter.writeIndent(Writer, writer);
    try writer.writeAll("}");
}

const bun = @import("bun");
const Blob = @import("./Blob.zig");
const Request = @import("./Request.zig");
const Headers = @import("./Headers.zig");
const HeadersSlot = Request.Binding.CachedClassRefSlot("headers");
