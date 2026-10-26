pub fn toAnyBlob(comptime Blob: type, store: *Store) ?Blob.Any {
    if (!store.hasOneRef() or store.data != .bytes) return null;
    const blob = takeInternalBlob(Blob, &store.data.bytes) orelse return null;
    return .{ .InternalBlob = blob };
}

fn takeInternalBlob(comptime Blob: type, bytes: *Store.Bytes) ?Blob.Internal {
    const managed = bytes.takeManaged() orelse return null;
    return .{ .bytes = .fromManaged(managed) };
}

pub fn getCredentialsWithDefaults(s3: *const Store.S3, globalObject: *JSGlobalObject) bun.S3.S3CredentialsWithOptions {
    return S3CredentialsJSC.getCredentialsWithDefaults(s3.getCredentials().*, s3.options, s3.acl, s3.storage_class, s3.request_payer, globalObject);
}

pub fn getCredentialsWithBindingOptions(s3: *const Store.S3, options: anytype, globalObject: *JSGlobalObject) bun.JSError!bun.S3.S3CredentialsWithOptions {
    return S3CredentialsJSC.getCredentialsWithBindingOptions(s3.getCredentials().*, s3.options, options, s3.acl, s3.storage_class, s3.request_payer, globalObject);
}

pub fn unlinkResolved(
    s3: *Store.S3,
    store: *Store,
    globalThis: *JSGlobalObject,
    options: *const bun.S3.S3CredentialsWithOptions,
    acceptor: *bun.S3.S3VoidAcceptor,
) bun.OOM!void {
    bun.assert(s3 == &store.data.s3);
    return @import("../s3/Operations.zig").delete(.{
        .store = store,
        .credentials = &options.credentials,
        .proxy = if (globalThis.bunVM().transpiler.env.getHttpProxy(true, null, null)) |proxy| proxy.href else null,
        .request_payer = options.request_payer,
    }, acceptor);
}

const bun = @import("bun");
const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const Store = @import("./Store.zig");
const S3CredentialsJSC = @import("../s3/CredentialsEngine.zig");
