//! Native backing for `node:tls` `SecureContext`. Owns one BoringSSL
//! `SSL_CTX*`; every `tls.connect`/`upgradeTLS`/`addContext` that names this
//! object passes that pointer to listen/connect/adopt, where `SSL_new()`
//! up-refs it for each socket. Policy (verify mode, reneg limits) is encoded
//! on the SSL_CTX itself in `us_ssl_ctx_from_options`, so the SSL_CTX's own
//! refcount is the only refcount and a socket safely outlives a GC'd
//! SecureContext.
//!
//! Public construction owns a fresh context. Internal interning uses a per-global
//! weak wrapper map and a bounded native cache to reuse parsed credentials.
const SecureContext = @This();

bindgen_state: bindgen.ClassState = .{},
ctx: bindgen.OwnedNativeWithDestructor(BoringSSL.SSL_CTX, freeSSLContext, .any),
/// `BunSocketContextOptions.digest()` — exactly the fields that reach
/// `us_ssl_ctx_from_options`. Stored so an `intern()` WeakGCMap hit (keyed by
/// the low 64 bits) can do a full content-equality check before reusing.
digest: [32]u8,
/// Approximate cert/key/CA byte length plus the BoringSSL `SSL_CTX` floor
/// (~50 KB), so the GC can account for the off-heap allocation.
extra_memory: usize,

fn freeSSLContext(ctx: *BoringSSL.SSL_CTX) void {
    BoringSSL.SSL_CTX_free(ctx);
}

pub fn construct(
    context: bindgen.CallContext(SecureContextConstructorSchema),
    args: bindgen.Args(SecureContextConstructorSchema),
) bindgen.CallError(SecureContextConstructorSchema)!*SecureContext {
    return bun.api.SecureContextEngine.construct(context, args);
}

/// Internal context interning reuses a live wrapper or a cached native context.
pub fn internSecureContext(
    context: bindgen.CallContext(InternSecureContextSchema),
    args: bindgen.Args(InternSecureContextSchema),
) bindgen.CallError(InternSecureContextSchema)!bindgen.Return(InternSecureContextSchema) {
    return bun.api.SecureContextEngine.intern(context, args);
}

/// Consumes the caller's BoringSSL reference, including on allocation failure.
pub fn create(ctx: *BoringSSL.SSL_CTX, digest_value: [32]u8, extra_memory: usize) bun.OOM!*SecureContext {
    errdefer BoringSSL.SSL_CTX_free(ctx);
    const this = try bun.default_allocator.create(SecureContext);
    this.* = .{
        .ctx = .init(ctx),
        .digest = digest_value,
        .extra_memory = extra_memory,
    };
    return this;
}

/// `SSL_CTX_up_ref` and return for callers that want to outlive this wrapper's
/// GC.
pub fn borrow(this: *SecureContext) *BoringSSL.SSL_CTX {
    const ctx = this.ctx.get();
    _ = BoringSSL.SSL_CTX_up_ref(ctx);
    return ctx;
}

pub fn destroy(this: *SecureContext) void {
    this.ctx.deinit();
    bun.destroy(this);
}

pub fn memoryUsage(this: *const SecureContext, _: bindgen.MemoryUsageContext(.vm)) usize {
    return @sizeOf(SecureContext) + this.extra_memory;
}

/// Exposed via `bun:internal-for-testing` so churn tests can assert
/// `SSL_CTX_new` was called O(1) times, not O(connections).
pub fn jsLiveCount(
    _: bindgen.CallContext(SecureContextLiveCountSchema),
    _: bindgen.Args(SecureContextLiveCountSchema),
) bun.JSError!i64 {
    return @intCast(c.us_ssl_ctx_live_count());
}

pub const c = uws.SocketContext.c;

const bun = @import("bun");
const bindgen = bun.bindgen;
const uws = bun.uws;
const BoringSSL = bun.BoringSSL.c;

const BindingModule = bindgen.Module("SecureContext");
pub const InternSecureContextSchema = BindingModule.function("internSecureContext");
const SecureContextSchema = BindingModule.class("SecureContext");
pub const SecureContextConstructorSchema = SecureContextSchema.constructor();
pub const Binding = bindgen.Class(SecureContextSchema, SecureContext);
const InternSecureContext = bindgen.Fn(InternSecureContextSchema, internSecureContext);
const SecureContextLiveCountSchema = bindgen.Module("InternalTesting").function("secureContextLiveCount");
const SecureContextLiveCount = bindgen.Fn(SecureContextLiveCountSchema, jsLiveCount);

comptime {
    _ = Binding;
    _ = InternSecureContext;
    _ = SecureContextLiveCount;
}
