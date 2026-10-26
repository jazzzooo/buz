const b = @import("bindgen_schema");

pub const formatter = b.enumeration("Formatter", .{
    b.enumerationValue("highlight_javascript", "highlight-javascript"),
    b.enumerationValue("highlight_javascript_redacted", "highlight-javascript-redacted"),
    b.enumerationValue("escape_powershell", "escape-powershell"),
});

const functions = .{
    b.function(
        "fmtString",
        .{
            b.argument("code", b.dom_string, .{}),
            b.argument("formatter", formatter, .{}),
        },
        b.dom_string,
        .{ .backend = .zig, .profile = .webidl },
    ),
};

pub const schema = b.module("fmt_jsc", functions);
pub const fmt_string = schema.function("fmtString");
