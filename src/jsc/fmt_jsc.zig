pub fn fmtString(
    _: bun.bindgen.CallContext(FmtStringSchema),
    args: bun.bindgen.Args(FmtStringSchema),
) bun.JSError!bun.bindgen.DOMString {
    const code = try args.code.toUTF8(bun.default_allocator);
    defer code.deinit();

    var buffer = bun.MutableString.initEmpty(bun.default_allocator);
    defer buffer.deinit();
    var writer = buffer.bufferedWriter();

    switch (args.formatter) {
        .highlight_javascript, .highlight_javascript_redacted => {
            const formatter = bun.fmt.fmtJavaScript(code.slice(), .{
                .enable_colors = true,
                .max_highlight_bytes = null,
                .redact_sensitive_information = args.formatter == .highlight_javascript_redacted,
            });
            writer.writer().print("{f}", .{formatter}) catch return error.OutOfMemory;
        },
        .escape_powershell => {
            writer.writer().print("{f}", .{bun.fmt.escapePowershell(code.slice())}) catch return error.OutOfMemory;
        },
    }

    try writer.flush();

    return bun.bindgen.DOMString.fromUTF8(buffer.list.items);
}

const bun = @import("bun");
const FmtBindings = bun.bindgen.Module("fmt_jsc");
const FmtStringSchema = FmtBindings.function("fmtString");
const FmtStringBinding = bun.bindgen.Fn(FmtStringSchema, fmtString);

comptime {
    _ = FmtStringBinding;
}
