const b = @import("bindgen_schema");
const blob_types = @import("binding_schema_BlobTypes");

const s3_stat_class = b.class(
    "S3Stat",
    b.illegalConstructor(),
    .{
        b.getter("etag", b.thread_safe_dom_string, .{ .implementation = "getEtag", .cache = "etag" }),
        b.method("lastModifiedText", .{}, b.thread_safe_dom_string, .{
            .implementation = "getLastModifiedText",
            .length = 0,
            .private_symbol = "lastModifiedText",
        }),
        b.getter("lastModified", b.js_date, .{
            .backend = .builtin,
            .builtin = "s3StatLastModifiedCodeGenerator",
            .cache = "lastModified",
        }),
        b.getter("size", blob_types.size, .{ .implementation = "getSize", .cache = "size" }),
        b.getter("type", b.thread_safe_dom_string, .{ .implementation = "getContentType", .cache = "type" }),
    },
    .{
        b.cachedSlot("etag", b.thread_safe_dom_string, .{}),
        b.cachedSlot("lastModified", b.js_date, .{}),
        b.cachedSlot("size", blob_types.size, .{}),
        b.cachedSlot("type", b.thread_safe_dom_string, .{}),
    },
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
    },
);

pub const schema = b.moduleWithClasses("S3Stat", .{}, .{s3_stat_class});
pub const s3_stat = schema.class("S3Stat");
