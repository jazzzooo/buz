pub const S3Stat = struct {
    const log = bun.Output.scoped(.S3Stat, .visible);

    pub const new = bun.TrivialNew(@This());

    bindgen_state: bindgen.ClassState = .{},
    data: Data,

    pub const Data = struct {
        size: u64 = 0,
        etag: bindgen.ThreadSafeDOMString = .empty(),
        content_type: bindgen.ThreadSafeDOMString = .empty(),
        last_modified: bindgen.ThreadSafeDOMString = .empty(),

        pub fn init(size: u64, etag: []const u8, content_type: []const u8, last_modified: []const u8) bun.OOM!Data {
            var result: Data = .{ .size = size };
            errdefer result.deinit();
            result.etag = try .fromUTF8(etag);
            result.content_type = try .fromUTF8(content_type);
            result.last_modified = try .fromUTF8(last_modified);
            return result;
        }

        pub fn deinit(this: *Data) void {
            this.etag.deinit();
            this.content_type.deinit();
            this.last_modified.deinit();
        }

        pub fn toBindingRef(this: *Data, context: anytype) bun.JSError!bindgen.ClassRef(S3StatSchema) {
            const data = this.*;
            this.* = .{};
            return S3Stat.new(.{ .data = data }).toBindingRef(context);
        }
    };

    pub fn toBindingRef(this: *S3Stat, context: anytype) bun.JSError!bindgen.ClassRef(S3StatSchema) {
        return S3StatClass.adoptResult(this, context);
    }

    pub fn getSize(
        this: *S3Stat,
        _: bindgen.CallContext(S3StatSizeSchema),
        _: bindgen.Args(S3StatSizeSchema),
    ) bun.JSError!f64 {
        return @floatFromInt(this.data.size);
    }

    pub fn getEtag(
        this: *S3Stat,
        _: bindgen.CallContext(S3StatEtagSchema),
        _: bindgen.Args(S3StatEtagSchema),
    ) bun.JSError!bindgen.ThreadSafeDOMString {
        return this.data.etag.clone();
    }

    pub fn getContentType(
        this: *S3Stat,
        _: bindgen.CallContext(S3StatContentTypeSchema),
        _: bindgen.Args(S3StatContentTypeSchema),
    ) bun.JSError!bindgen.ThreadSafeDOMString {
        return this.data.content_type.clone();
    }

    pub fn getLastModifiedText(
        this: *S3Stat,
        _: bindgen.CallContext(S3StatLastModifiedTextSchema),
        _: bindgen.Args(S3StatLastModifiedTextSchema),
    ) bun.JSError!bindgen.ThreadSafeDOMString {
        return this.data.last_modified.clone();
    }

    fn deinit(this: *S3Stat) void {
        this.data.deinit();
        bun.destroy(this);
    }

    pub fn destroy(this: *S3Stat) void {
        this.deinit();
    }
};

const bun = @import("bun");
const bindgen = bun.bindgen;

const BindingModule = bindgen.Module("S3Stat");
const S3StatSchema = BindingModule.class("S3Stat");
const S3StatEtagSchema = S3StatSchema.member("etag");
const S3StatLastModifiedTextSchema = S3StatSchema.member("lastModifiedText");
const S3StatSizeSchema = S3StatSchema.member("size");
const S3StatContentTypeSchema = S3StatSchema.member("type");
const S3StatClass = bindgen.Class(S3StatSchema, S3Stat);

comptime {
    _ = S3StatClass;
}
