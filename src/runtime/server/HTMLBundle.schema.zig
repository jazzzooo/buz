const b = @import("bindgen_schema");

const html_bundle_class = b.class(
    "HTMLBundle",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.getter("index", b.dom_string, .{ .implementation = "getIndex", .cache = "index" }),
    },
    .{
        b.cachedSlot("index", b.dom_string, .{}),
    },
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .shared,
        .identity = .fresh,
        .fresh_identity_reason = "each bundle result creates one native state and exposes it through one wrapper",
        .reference_thread = .vm,
    },
);

pub const schema = b.moduleWithClasses("HTMLBundle", .{}, .{html_bundle_class});
pub const html_bundle = schema.class("HTMLBundle");
