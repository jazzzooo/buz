pub const S3Client = struct {
    pub const Handle = S3ClientClass.Handle;

    pub fn inspectCustom(_: *S3Client, context: bindgen.CallContext(S3ClientInspectSchema), args: bindgen.Args(S3ClientInspectSchema)) bun.JSError!bindgen.DOMString {
        return Engine.inspect(context, args);
    }

    pub fn create(options: *const bun.S3.S3CredentialsWithOptions) bun.OOM!*S3Client {
        const client = try bun.default_allocator.create(S3Client);
        errdefer bun.default_allocator.destroy(client);
        client.* = .{
            .credentials = .adopt(try options.credentials.dupe()),
            .options = options.options,
            .acl = options.acl,
            .storage_class = options.storage_class,
            .request_payer = options.request_payer,
        };
        return client;
    }

    pub fn default(context: anytype) bun.JSError!bindgen.ClassRef(S3ClientClassSchema) {
        return Engine.default(context);
    }

    bindgen_state: bindgen.ClassState = .{},
    credentials: bindgen.RefNative(S3Credentials, .vm),
    options: bun.S3.MultiPartUploadOptions = .{},
    acl: ?bun.S3.ACL = null,
    storage_class: ?bun.S3.StorageClass = null,
    request_payer: bool = false,

    pub fn construct(
        context: bindgen.CallContext(S3ClientConstructorSchema),
        args: bindgen.Args(S3ClientConstructorSchema),
    ) bindgen.CallError(S3ClientConstructorSchema)!*S3Client {
        return Engine.construct(context, args);
    }

    fn deinit(this: *@This()) void {
        this.credentials.deinit();
        bun.destroy(this);
    }

    pub fn destroy(this: *@This()) void {
        this.deinit();
    }

    pub fn toBindingRef(this: *@This(), context: anytype) bun.JSError!bindgen.ClassRef(S3ClientClassSchema) {
        return S3ClientClass.adoptResult(this, context);
    }

    pub fn bindDelete(
        this: *S3Client,
        context: bindgen.CallContext(S3ClientDeleteSchema),
        args: bindgen.Args(S3ClientDeleteSchema),
    ) bindgen.CallError(S3ClientDeleteSchema)!void {
        return Engine.call(.instance, .delete, this, context, args);
    }

    pub fn bindExists(
        this: *S3Client,
        context: bindgen.CallContext(S3ClientExistsSchema),
        args: bindgen.Args(S3ClientExistsSchema),
    ) bindgen.CallError(S3ClientExistsSchema)!void {
        return Engine.call(.instance, .exists, this, context, args);
    }

    pub fn bindFile(
        this: *S3Client,
        context: bindgen.CallContext(S3ClientFileSchema),
        args: bindgen.Args(S3ClientFileSchema),
    ) bindgen.CallError(S3ClientFileSchema)!bindgen.Return(S3ClientFileSchema) {
        return Engine.call(.instance, .file, this, context, args);
    }

    pub fn bindListObjects(
        this: *S3Client,
        context: bindgen.CallContext(S3ClientListSchema),
        args: bindgen.Args(S3ClientListSchema),
    ) bindgen.CallError(S3ClientListSchema)!void {
        return Engine.call(.instance, .list, this, context, args);
    }

    pub fn bindPresign(
        this: *S3Client,
        context: bindgen.CallContext(S3ClientPresignSchema),
        args: bindgen.Args(S3ClientPresignSchema),
    ) bindgen.CallError(S3ClientPresignSchema)!bindgen.DOMString {
        return Engine.call(.instance, .presign, this, context, args);
    }

    pub fn bindSize(
        this: *S3Client,
        context: bindgen.CallContext(S3ClientSizeSchema),
        args: bindgen.Args(S3ClientSizeSchema),
    ) bindgen.CallError(S3ClientSizeSchema)!void {
        return Engine.call(.instance, .size, this, context, args);
    }

    pub fn bindStat(
        this: *S3Client,
        context: bindgen.CallContext(S3ClientStatSchema),
        args: bindgen.Args(S3ClientStatSchema),
    ) bindgen.CallError(S3ClientStatSchema)!void {
        return Engine.call(.instance, .stat, this, context, args);
    }

    pub fn bindUnlink(
        this: *S3Client,
        context: bindgen.CallContext(S3ClientUnlinkSchema),
        args: bindgen.Args(S3ClientUnlinkSchema),
    ) bindgen.CallError(S3ClientUnlinkSchema)!void {
        return Engine.call(.instance, .delete, this, context, args);
    }

    pub fn bindWrite(
        this: *S3Client,
        context: bindgen.CallContext(S3ClientWriteSchema),
        args: bindgen.Args(S3ClientWriteSchema),
    ) bindgen.CallError(S3ClientWriteSchema)!void {
        return Engine.call(.instance, .write, this, context, args);
    }

    pub fn bindStaticDelete(
        context: bindgen.CallContext(S3ClientStaticDeleteSchema),
        args: bindgen.Args(S3ClientStaticDeleteSchema),
    ) bindgen.CallError(S3ClientStaticDeleteSchema)!void {
        return Engine.call(.static, .delete, null, context, args);
    }

    pub fn bindStaticExists(
        context: bindgen.CallContext(S3ClientStaticExistsSchema),
        args: bindgen.Args(S3ClientStaticExistsSchema),
    ) bindgen.CallError(S3ClientStaticExistsSchema)!void {
        return Engine.call(.static, .exists, null, context, args);
    }

    pub fn bindStaticFile(
        context: bindgen.CallContext(S3ClientStaticFileSchema),
        args: bindgen.Args(S3ClientStaticFileSchema),
    ) bindgen.CallError(S3ClientStaticFileSchema)!bindgen.Return(S3ClientStaticFileSchema) {
        return Engine.call(.static, .file, null, context, args);
    }

    pub fn bindStaticListObjects(
        context: bindgen.CallContext(S3ClientStaticListSchema),
        args: bindgen.Args(S3ClientStaticListSchema),
    ) bindgen.CallError(S3ClientStaticListSchema)!void {
        return Engine.call(.static, .list, null, context, args);
    }

    pub fn bindStaticPresign(
        context: bindgen.CallContext(S3ClientStaticPresignSchema),
        args: bindgen.Args(S3ClientStaticPresignSchema),
    ) bindgen.CallError(S3ClientStaticPresignSchema)!bindgen.DOMString {
        return Engine.call(.static, .presign, null, context, args);
    }

    pub fn bindStaticSize(
        context: bindgen.CallContext(S3ClientStaticSizeSchema),
        args: bindgen.Args(S3ClientStaticSizeSchema),
    ) bindgen.CallError(S3ClientStaticSizeSchema)!void {
        return Engine.call(.static, .size, null, context, args);
    }

    pub fn bindStaticStat(
        context: bindgen.CallContext(S3ClientStaticStatSchema),
        args: bindgen.Args(S3ClientStaticStatSchema),
    ) bindgen.CallError(S3ClientStaticStatSchema)!void {
        return Engine.call(.static, .stat, null, context, args);
    }

    pub fn bindStaticUnlink(
        context: bindgen.CallContext(S3ClientStaticUnlinkSchema),
        args: bindgen.Args(S3ClientStaticUnlinkSchema),
    ) bindgen.CallError(S3ClientStaticUnlinkSchema)!void {
        return Engine.call(.static, .delete, null, context, args);
    }

    pub fn bindStaticWrite(
        context: bindgen.CallContext(S3ClientStaticWriteSchema),
        args: bindgen.Args(S3ClientStaticWriteSchema),
    ) bindgen.CallError(S3ClientStaticWriteSchema)!void {
        return Engine.call(.static, .write, null, context, args);
    }
};

const Engine = @import("./S3ClientEngine.zig");
const bun = @import("bun");
const bindgen = bun.bindgen;
const S3Credentials = bun.S3.S3Credentials;

const S3ClientBindings = bindgen.Module("S3Client");
const S3ClientClassSchema = S3ClientBindings.class("S3Client");
pub const S3ClientClass = bindgen.Class(S3ClientClassSchema, S3Client);
const S3ClientConstructorSchema = S3ClientClassSchema.constructor();
const S3ClientInspectSchema = S3ClientClassSchema.member("inspectCustom");
const S3ClientDeleteSchema = S3ClientClassSchema.memberKind("delete", .method);
const S3ClientExistsSchema = S3ClientClassSchema.memberKind("exists", .method);
const S3ClientFileSchema = S3ClientClassSchema.memberKind("file", .method);
const S3ClientListSchema = S3ClientClassSchema.memberKind("list", .method);
const S3ClientPresignSchema = S3ClientClassSchema.memberKind("presign", .method);
const S3ClientSizeSchema = S3ClientClassSchema.memberKind("size", .method);
const S3ClientStatSchema = S3ClientClassSchema.memberKind("stat", .method);
const S3ClientUnlinkSchema = S3ClientClassSchema.memberKind("unlink", .method);
const S3ClientWriteSchema = S3ClientClassSchema.memberKind("write", .method);
const S3ClientStaticDeleteSchema = S3ClientClassSchema.memberKind("delete", .static_method);
const S3ClientStaticExistsSchema = S3ClientClassSchema.memberKind("exists", .static_method);
const S3ClientStaticFileSchema = S3ClientClassSchema.memberKind("file", .static_method);
const S3ClientStaticListSchema = S3ClientClassSchema.memberKind("list", .static_method);
const S3ClientStaticPresignSchema = S3ClientClassSchema.memberKind("presign", .static_method);
const S3ClientStaticSizeSchema = S3ClientClassSchema.memberKind("size", .static_method);
const S3ClientStaticStatSchema = S3ClientClassSchema.memberKind("stat", .static_method);
const S3ClientStaticUnlinkSchema = S3ClientClassSchema.memberKind("unlink", .static_method);
const S3ClientStaticWriteSchema = S3ClientClassSchema.memberKind("write", .static_method);

comptime {
    _ = S3ClientClass;
}
