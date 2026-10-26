//! Native TLS context construction and the uSockets C-library options ABI.

pub const TLSContextFailure = struct {
    kind: uws.create_bun_socket_error_t = .none,
    boring_ssl_code: u32 = 0,

    fn capture(kind: uws.create_bun_socket_error_t) TLSContextFailure {
        var result: TLSContextFailure = .{ .kind = kind };
        while (true) {
            const code = BoringSSL.ERR_get_error();
            if (code == 0) break;
            if (result.boring_ssl_code == 0) result.boring_ssl_code = code;
            const library = BoringSSL.ERR_GET_LIB(code);
            const reason = BoringSSL.ERR_GET_REASON(code);
            const out_of_memory = if (library == BoringSSL.ERR_LIB_SYS)
                reason == @backingInt(bun.sys.E.NOMEM)
            else
                reason == BoringSSL.ERR_R_MALLOC_FAILURE;
            if (out_of_memory) {
                result.kind = .out_of_memory;
            }
        }
        return result;
    }

    pub fn message(this: TLSContextFailure) ?[]const u8 {
        return this.kind.message();
    }
};

pub const BunSocketContextOptions = extern struct {
    key_file_name: [*c]const u8 = null,
    cert_file_name: [*c]const u8 = null,
    passphrase: [*c]const u8 = null,
    dh_params_file_name: [*c]const u8 = null,
    ca_file_name: [*c]const u8 = null,
    ssl_ciphers: [*c]const u8 = null,
    ssl_prefer_low_memory_usage: i32 = 0,
    key: ?[*]const ?[*:0]const u8 = null,
    key_count: u32 = 0,
    cert: ?[*]const ?[*:0]const u8 = null,
    cert_count: u32 = 0,
    ca: ?[*]const ?[*:0]const u8 = null,
    ca_count: u32 = 0,
    secure_options: u32 = 0,
    reject_unauthorized: i32 = 0,
    request_cert: i32 = 0,
    client_renegotiation_limit: u32 = 3,
    client_renegotiation_window: u32 = 600,

    /// Build a BoringSSL `SSL_CTX*` from these options. Caller owns one ref
    /// and releases with `SSL_CTX_free` — the passphrase is freed inside this
    /// call once private-key load completes, so plain `SSL_CTX_free` is
    /// correct on every path.
    ///
    /// Mode-neutral: the same `SSL_CTX*` may back client connects and server
    /// accepts. CTX-level verify mode comes from `request_cert`/`ca`/
    /// `reject_unauthorized` here; the per-socket client override (always run
    /// chain validation, populate verify_error) is applied in
    /// `us_internal_ssl_attach`, so a server reusing this ctx never sends
    /// CertificateRequest unless these options asked it to.
    pub fn createSSLContext(options: BunSocketContextOptions, failure: *TLSContextFailure) ?*BoringSSL.SSL_CTX {
        var kind: uws.create_bun_socket_error_t = .none;
        const context = c.us_ssl_ctx_from_options(options, &kind) orelse {
            failure.* = TLSContextFailure.capture(kind);
            return null;
        };
        BoringSSL.ERR_clear_error();
        failure.* = .{};
        return context;
    }

    /// SHA-256 over every field this struct carries, dereferencing string
    /// pointers so the digest is content-addressed (not pointer-addressed).
    /// Two option structs that build the same `SSL_CTX*` produce the same
    /// digest. Used as the key for `SSLContextCache`.
    pub fn digest(self: BunSocketContextOptions) [32]u8 {
        var h = bun.sha.Hashers.SHA256.init();
        const feedZ = struct {
            fn f(hp: *bun.sha.Hashers.SHA256, s: [*c]const u8) void {
                // Presence byte so null ≠ "" — both would otherwise feed only
                // the trailing 0. In practice "" usually fails createSSLContext
                // and never caches, but injectivity is cheap to guarantee.
                hp.update(&.{@intFromBool(s != null)});
                if (s) |p| hp.update(std.mem.sliceTo(p, 0));
                hp.update(&.{0}); // terminator so {a:"xy"} ≠ {a:"x",b:"y"}
            }
        }.f;
        const feedArr = struct {
            fn f(hp: *bun.sha.Hashers.SHA256, arr: ?[*]const ?[*:0]const u8, n: u32) void {
                hp.update(&.{@intFromBool(arr != null)});
                hp.update(std.mem.asBytes(&n));
                if (arr) |a| for (a[0..n]) |s| {
                    hp.update(&.{@intFromBool(s != null)});
                    if (s) |p| hp.update(std.mem.sliceTo(p, 0));
                    hp.update(&.{0});
                };
                hp.update(&.{0});
            }
        }.f;
        // File-backed fields: feed path + (mtime, size) so an in-place cert
        // rotation produces a fresh digest. stat() is ~1µs and only runs when
        // the file form is used (Bun-specific; node:tls always passes inline
        // bytes). On stat failure we feed zeros — `createSSLContext` will fail
        // on the same path and the entry never reaches the cache.
        const feedPath = struct {
            fn f(hp: *bun.sha.Hashers.SHA256, s: [*c]const u8) void {
                hp.update(&.{@intFromBool(s != null)});
                if (s) |p| {
                    const path = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
                    hp.update(path);
                    var meta: [3]i64 = @splat(0);
                    if (path.len > 0) switch (bun.sys.stat(path)) {
                        .result => |st| {
                            const mt = st.mtime();
                            meta = .{ @intCast(mt.sec), @intCast(mt.nsec), @intCast(st.size) };
                        },
                        .err => {},
                    };
                    hp.update(std.mem.asBytes(&meta));
                }
                hp.update(&.{0});
            }
        }.f;
        feedPath(&h, self.key_file_name);
        feedPath(&h, self.cert_file_name);
        feedZ(&h, self.passphrase);
        feedPath(&h, self.dh_params_file_name);
        feedPath(&h, self.ca_file_name);
        feedZ(&h, self.ssl_ciphers);
        h.update(std.mem.asBytes(&self.ssl_prefer_low_memory_usage));
        feedArr(&h, self.key, self.key_count);
        feedArr(&h, self.cert, self.cert_count);
        feedArr(&h, self.ca, self.ca_count);
        h.update(std.mem.asBytes(&self.secure_options));
        h.update(std.mem.asBytes(&self.reject_unauthorized));
        h.update(std.mem.asBytes(&self.request_cert));
        h.update(std.mem.asBytes(&self.client_renegotiation_limit));
        h.update(std.mem.asBytes(&self.client_renegotiation_window));
        var out: [32]u8 = undefined;
        h.final(&out);
        return out;
    }

    /// Best-effort byte count of cert/key/CA material — fed into
    /// `SecureContext.memoryCost` so the GC sees the off-heap allocation.
    pub fn approxCertBytes(self: BunSocketContextOptions) usize {
        var n: usize = 0;
        if (self.key) |arr| for (arr[0..self.key_count]) |k| {
            if (k) |s| n += std.mem.sliceTo(s, 0).len;
        };
        if (self.cert) |arr| for (arr[0..self.cert_count]) |k| {
            if (k) |s| n += std.mem.sliceTo(s, 0).len;
        };
        if (self.ca) |arr| for (arr[0..self.ca_count]) |k| {
            if (k) |s| n += std.mem.sliceTo(s, 0).len;
        };
        return n;
    }
};

pub const c = struct {
    pub extern fn us_ssl_ctx_from_options(BunSocketContextOptions, *uws.create_bun_socket_error_t) ?*BoringSSL.SSL_CTX;
    pub extern fn us_ssl_ctx_live_count() c_long;
};

test "TLS failures capture nested allocation errors and consume the library queue" {
    BoringSSL.ERR_clear_error();
    defer BoringSSL.ERR_clear_error();
    BoringSSL.ERR_put_error(BoringSSL.ERR_LIB_SSL, 0, BoringSSL.SSL_R_NO_CIPHER_MATCH, @src().file, @src().line);
    const first_code = BoringSSL.ERR_peek_error();
    BoringSSL.ERR_put_error(BoringSSL.ERR_LIB_SSL, 0, BoringSSL.ERR_R_MALLOC_FAILURE, @src().file, @src().line);
    BoringSSL.ERR_put_error(BoringSSL.ERR_LIB_SSL, 0, BoringSSL.SSL_R_NO_CIPHER_MATCH, @src().file, @src().line);
    const failure = TLSContextFailure.capture(.invalid_ciphers);
    try std.testing.expectEqual(uws.create_bun_socket_error_t.out_of_memory, failure.kind);
    try std.testing.expectEqual(first_code, failure.boring_ssl_code);
    try std.testing.expectEqual(@as(u32, 0), BoringSSL.ERR_peek_error());

    BoringSSL.ERR_put_error(BoringSSL.ERR_LIB_SYS, 0, BoringSSL.ERR_R_MALLOC_FAILURE, @src().file, @src().line);
    try std.testing.expectEqual(uws.create_bun_socket_error_t.load_ca_file, TLSContextFailure.capture(.load_ca_file).kind);
    BoringSSL.ERR_put_error(BoringSSL.ERR_LIB_SYS, 0, @backingInt(bun.sys.E.NOMEM), @src().file, @src().line);
    try std.testing.expectEqual(uws.create_bun_socket_error_t.out_of_memory, TLSContextFailure.capture(.load_ca_file).kind);
}

const std = @import("std");

const bun = @import("bun");
const uws = bun.uws;
const BoringSSL = bun.BoringSSL.c;
