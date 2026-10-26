const Native = @import("MarkdownObjectNative.zig");

const bun = @import("bun");
const Bindings = bun.bindgen.Module("MarkdownObject");
const HTMLBinding = bun.bindgen.Fn(Bindings.function("html"), Native.renderToHTML);
const AnsiBinding = bun.bindgen.Fn(Bindings.function("ansi"), Native.renderToAnsi);
const ParseSessionSchema = Bindings.class("MarkdownParseSession");
const ParseSessionBinding = bun.bindgen.Class(ParseSessionSchema, Native.MarkdownParseSession);

comptime {
    _ = HTMLBinding;
    _ = AnsiBinding;
    _ = ParseSessionBinding;
}
