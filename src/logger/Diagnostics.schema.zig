const b = @import("bindgen_schema");

pub const level = b.enumeration("DiagnosticLevel", .{
    b.enumerationValue("err", "error"),
    b.enumerationValue("warn", "warn"),
    b.enumerationValue("note", "note"),
    b.enumerationValue("debug", "debug"),
    b.enumerationValue("verbose", "verbose"),
});

pub const position = b.dictionary("DiagnosticPosition", .{
    b.dictionaryField("line_text", b.dom_string, .{ .required = true, .js_name = "lineText" }),
    b.dictionaryField("file", b.dom_string, .{ .required = true }),
    b.dictionaryField("namespace_value", b.dom_string, .{ .required = true, .js_name = "namespace" }),
    b.dictionaryField("line", b.int32, .{ .required = true }),
    b.dictionaryField("column", b.int32, .{ .required = true }),
    b.dictionaryField("length", b.size, .{ .required = true }),
    b.dictionaryField("offset", b.size, .{ .required = true }),
});

pub const nullable_position = b.optionalNullish(position);

const inspect_options = b.dictionary("DiagnosticInspectOptions", .{
    b.dictionaryField("colors", b.boolean, .{ .default_value = .{ .boolean = false } }),
});

pub const inspect_arguments = .{
    b.argument("depth", b.discardAny(.ignored), .{ .presence = .optional }),
    b.argument("options", inspect_options, .{ .presence = .optional }),
};

pub const schema = b.module("Diagnostics", .{});
