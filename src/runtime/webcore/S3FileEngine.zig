pub fn writeFormat(s3: *Blob.Store.S3, comptime Formatter: type, formatter: *Formatter, writer: anytype, comptime enable_ansi_colors: bool, content_type: []const u8, offset: usize) !void {
    try writer.writeAll(comptime Output.prettyFmt("<r>S3Ref<r>", enable_ansi_colors));
    const credentials = s3.getCredentials();
    // detect virtual host style bucket name
    const bucket_name = if (credentials.virtual_hosted_style and credentials.endpoint.len > 0) S3.S3Credentials.guessBucket(credentials.endpoint) orelse credentials.bucket else credentials.bucket;

    if (bucket_name.len > 0) {
        try writer.print(
            comptime Output.prettyFmt(" (<green>\"{s}/{s}\"<r>)<r> {{", enable_ansi_colors),
            .{
                bucket_name,
                s3.path(),
            },
        );
    } else {
        try writer.print(
            comptime Output.prettyFmt(" (<green>\"{s}\"<r>)<r> {{", enable_ansi_colors),
            .{
                s3.path(),
            },
        );
    }

    if (content_type.len > 0) {
        try writer.writeAll("\n");
        formatter.indent += 1;
        defer formatter.indent -|= 1;

        try formatter.writeIndent(@TypeOf(writer), writer);
        try writer.print(
            comptime Output.prettyFmt("type<d>:<r> <green>\"{s}\"<r>", enable_ansi_colors),
            .{
                content_type,
            },
        );

        try formatter.printComma(@TypeOf(writer), writer, enable_ansi_colors);
        if (offset > 0) {
            try writer.writeAll("\n");
        }
    }

    if (offset > 0) {
        formatter.indent += 1;
        defer formatter.indent -|= 1;

        try formatter.writeIndent(@TypeOf(writer), writer);

        try writer.print(
            comptime Output.prettyFmt("offset<d>:<r> <yellow>{d}<r>", enable_ansi_colors),
            .{
                offset,
            },
        );

        try formatter.printComma(@TypeOf(writer), writer, enable_ansi_colors);
    }
    try S3ClientEngine.writeFormatCredentials(credentials, s3.options, s3.acl, Formatter, formatter, writer, enable_ansi_colors);
    try formatter.writeIndent(@TypeOf(writer), writer);
    try writer.writeAll("}");
    formatter.resetLine();
}
pub fn constructS3FileWithResolvedOptions(
    globalObject: *jsc.JSGlobalObject,
    path: *bun.api.node.PathLike,
    options: *const S3.S3CredentialsWithOptions,
    default_credentials: ?*S3.S3Credentials,
) bun.JSError!Blob {
    const owned_path = path.*;
    path.* = .{ .string = bun.PathString.empty };

    const store = if (!options.changed_credentials and default_credentials != null)
        try Blob.Store.initS3WithReferencedCredentials(owned_path, null, default_credentials.?, bun.default_allocator)
    else
        try Blob.Store.initS3(owned_path, null, options.credentials, bun.default_allocator);
    store.data.s3.options = options.options;
    store.data.s3.acl = options.acl;
    store.data.s3.storage_class = options.storage_class;
    store.data.s3.request_payer = options.request_payer;

    var blob = try Blob.initWithStore(store);
    errdefer blob.deinit();
    try applyContentType(&blob, options.content_type, globalObject);
    return blob;
}

fn applyContentType(blob: *Blob, content_type: ?[]const u8, globalObject: *jsc.JSGlobalObject) bun.OOM!void {
    const value = content_type orelse return;
    if (!strings.isAllASCII(value)) return;
    if (globalObject.bunVM().mimeType(value)) |entry| {
        try blob.setContentType(entry.value, .explicit);
        return;
    }
    const buffer = try bun.default_allocator.alloc(u8, value.len);
    _ = strings.copyLowercase(value, buffer);
    blob.setContentTypeOwned(buffer, .explicit);
}
pub fn constructInternalWithBindingOptions(
    context: anytype,
    path: *bun.api.node.PathLike,
    options: anytype,
) bun.bindgen.CallError(@TypeOf(context))!*Blob {
    const globalObject = context.viewToken().globalObject();
    const existing_credentials = globalObject.bunVM().transpiler.env.getS3Credentials();
    var resolved = try S3CredentialsJSC.resolveOptions(context, .{ .credentials = existing_credentials }, options, globalObject);
    defer resolved.deinit();
    var blob = try constructS3FileWithResolvedOptions(globalObject, path, &resolved, null);
    defer blob.deinit();
    return Blob.new(&blob);
}

pub fn stat(comptime kind: Operations.StatKind, global: *jsc.JSGlobalObject, blob: *Blob, acceptor: *Operations.StatAcceptor(kind)) bun.OOM!void {
    const store = blob.storePtr().?;
    const s3 = &store.data.s3;
    return Operations.stat(kind, .{
        .store = store,
        .credentials = s3.getCredentials(),
        .proxy = if (global.bunVM().transpiler.env.getHttpProxy(true, null, null)) |proxy| proxy.href else null,
        .request_payer = s3.request_payer,
    }, acceptor);
}

pub fn getBucketName(
    this: *const Blob,
) ?[]const u8 {
    const store = this.storePtr() orelse return null;
    if (store.data != .s3) return null;
    const credentials = store.data.s3.getCredentials();
    return S3FileDomain.bucketName(credentials.bucket, store.data.s3.path());
}

pub fn getBucket(this: *const Blob) bun.OOM!?bun.bindgen.DOMString {
    if (getBucketName(this)) |name| {
        return try bun.bindgen.DOMString.fromUTF8(name);
    }
    return null;
}

const S3ClientEngine = @import("./S3ClientEngine.zig");
const S3FileDomain = @import("./S3File.zig");
const S3CredentialsJSC = @import("./s3/CredentialsEngine.zig");
const Operations = @import("./s3/Operations.zig");
const bun = @import("bun");
const Output = bun.Output;
const S3 = bun.S3;
const strings = bun.strings;

const jsc = bun.jsc;
const Blob = jsc.WebCore.Blob;
