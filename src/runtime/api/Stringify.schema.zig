const b = @import("bindgen_schema");

pub const schema = b.module("Stringify", .{
    b.function("createError", .{b.argument("message", b.dom_string, .{})}, b.js_error_instance, .{
        .profile = .exact,
    }),
});
