pub fn legacyCertificate(
    globalObject: *bun.jsc.JSGlobalObject,
    cert: *BoringSSL.X509,
) bun.JSError!X509.CallbackCertificate {
    var data = try bun.bindgen.Engine(ToLegacyObjectSchema).call(globalObject, .{ .certificate = @ptrCast(cert) });
    return X509.CallbackCertificate.fromOwned(try X509.materializeLegacyCertificate(&data));
}

const bun = @import("bun");
const BoringSSL = bun.BoringSSL.c;
const X509 = @import("./x509.zig");

const X509Bindings = bun.bindgen.Module("X509");
const ToLegacyObjectSchema = X509Bindings.engineShim("x509ToLegacyObject");
