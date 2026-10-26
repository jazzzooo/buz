const b = @import("bindgen_schema");

pub const options = b.dictionaryWithOptions("TextDecoderOptions", .{
    b.dictionaryField("fatal", b.boolean, .{ .default_value = .{ .boolean = false } }),
    b.dictionaryField("ignore_bom", b.boolean, .{
        .default_value = .{ .boolean = false },
        .js_name = "ignoreBOM",
    }),
}, .{ .object_error_profile = .node });

pub const schema = b.module("TextDecoderTypes", .{});
