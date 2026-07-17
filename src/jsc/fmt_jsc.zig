//! Bindgen target for `fmt_jsc.bind.ts`. The formatters live in `bun_core`;
//! only the JS-facing wrapper that takes a `*JSGlobalObject` lives here.

pub const js_bindings = struct {
    const gen = bun.gen.fmt_jsc;

    /// Internal function for testing in highlighter.test.ts
    pub fn fmtString(global: *bun.jsc.JSGlobalObject, code: []const u8, formatter_id: gen.Formatter) bun.JSError!bun.String {
        var buffer = bun.MutableString.initEmpty(bun.default_allocator);
        defer buffer.deinit();
        var writer = buffer.bufferedWriter();

        switch (formatter_id) {
            .highlight_javascript, .highlight_javascript_redacted => {
                const formatter = bun.fmt.fmtJavaScript(code, .{
                    .enable_colors = true,
                    .max_highlight_bytes = null,
                    .redact_sensitive_information = formatter_id == .highlight_javascript_redacted,
                });
                writer.writer().print("{f}", .{formatter}) catch |err| {
                    return global.throwError(err, "while formatting");
                };
            },
            .escape_powershell => {
                writer.writer().print("{f}", .{bun.fmt.escapePowershell(code)}) catch |err| {
                    return global.throwError(err, "while formatting");
                };
            },
        }

        writer.flush() catch |err| {
            return global.throwError(err, "while formatting");
        };

        return bun.String.cloneUTF8(buffer.list.items);
    }
};

const bun = @import("bun");
