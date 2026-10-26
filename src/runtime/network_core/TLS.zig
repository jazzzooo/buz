const std = @import("std");

pub fn TLS(comptime BoringSSL: type) type {
    return struct {
        const Connection = @This();
        ssl: ?*BoringSSL.SSL,
        is_server: bool,
        detached: bool,

        pub fn getServername(this: Connection) ?[]const u8 {
            const ssl_ptr = this.ssl orelse return null;

            const servername = BoringSSL.SSL_get_servername(ssl_ptr, BoringSSL.TLSEXT_NAMETYPE_host_name);
            if (servername == null) {
                return null;
            }
            return std.mem.span(servername);
        }

        pub fn getPeerX509Certificate(this: Connection) ?*BoringSSL.X509 {
            const ssl_ptr = this.ssl orelse return null;
            return BoringSSL.SSL_get_peer_certificate(ssl_ptr);
        }

        pub fn getX509Certificate(this: Connection) ?*BoringSSL.X509 {
            const ssl_ptr = this.ssl orelse return null;
            return BoringSSL.SSL_get_certificate(ssl_ptr);
        }

        pub fn getTLSVersion(this: Connection) ?[]const u8 {
            const ssl_ptr = this.ssl orelse return null;
            const version = BoringSSL.SSL_get_version(ssl_ptr);
            if (version == null) return null;
            const version_len = std.mem.len(version);
            if (version_len == 0) return null;
            return version[0..version_len];
        }

        pub fn setMaxSendFragment(this: Connection, size_value: f64) bool {
            if (!std.math.isFinite(size_value) or size_value < 512 or size_value > 16384) return false;
            const size: usize = @intFromFloat(@trunc(size_value));

            const ssl_ptr = this.ssl orelse return false;
            return BoringSSL.SSL_set_max_send_fragment(ssl_ptr, size) == 1;
        }

        pub fn getPeerCertificate(this: Connection, abbreviated_value: ?bool) ?Certificate {
            const abbreviated = abbreviated_value orelse true;

            const ssl_ptr = this.ssl orelse return null;

            if (abbreviated) {
                if (this.is_server) {
                    const cert = BoringSSL.SSL_get_peer_certificate(ssl_ptr) orelse return null;
                    return .{ .value = cert, .owned = true };
                }

                const cert_chain = BoringSSL.SSL_get_peer_cert_chain(ssl_ptr) orelse return null;
                const cert = BoringSSL.sk_X509_value(cert_chain, 0) orelse return null;
                return .{ .value = cert, .owned = false };
            }
            return null;
        }

        pub fn getCertificate(this: Connection) ?*BoringSSL.X509 {
            const ssl_ptr = this.ssl orelse return null;
            return BoringSSL.SSL_get_certificate(ssl_ptr);
        }

        pub fn getTLSFinishedMessage(this: Connection, allocator: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
            const ssl_ptr = this.ssl orelse return null;

            var dummy: [1]u8 = undefined;
            const size = BoringSSL.SSL_get_finished(ssl_ptr, @as(*anyopaque, @ptrCast(&dummy)), @sizeOf(@TypeOf(dummy)));
            if (size == 0) return null;

            const buffer_size = @as(usize, @intCast(size));
            const buffer = try allocator.alloc(u8, buffer_size);
            errdefer allocator.free(buffer);
            const buffer_ptr: *anyopaque = @ptrCast(buffer.ptr);

            const result_size = BoringSSL.SSL_get_finished(ssl_ptr, buffer_ptr, buffer_size);
            std.debug.assert(result_size == size);
            return buffer;
        }

        pub fn getCipher(this: Connection) ?CipherInfo {
            const ssl_ptr = this.ssl orelse return null;
            const cipher = BoringSSL.SSL_get_current_cipher(ssl_ptr);
            if (cipher == null) return .{ .name = null, .standard_name = null, .version = null };

            const name = BoringSSL.SSL_CIPHER_get_name(cipher);
            const standard_name = BoringSSL.SSL_CIPHER_standard_name(cipher);
            const version = BoringSSL.SSL_CIPHER_get_version(cipher);
            return .{
                .name = if (name) |value| value[0..std.mem.len(value)] else null,
                .standard_name = if (standard_name) |value| value[0..std.mem.len(value)] else null,
                .version = if (version) |value| value[0..std.mem.len(value)] else null,
            };
        }

        pub fn getTLSPeerFinishedMessage(this: Connection, allocator: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
            const ssl_ptr = this.ssl orelse return null;

            var dummy: [1]u8 = undefined;
            const size = BoringSSL.SSL_get_peer_finished(ssl_ptr, @as(*anyopaque, @ptrCast(&dummy)), @sizeOf(@TypeOf(dummy)));
            if (size == 0) return null;

            const buffer_size = @as(usize, @intCast(size));
            const buffer = try allocator.alloc(u8, buffer_size);
            errdefer allocator.free(buffer);
            const buffer_ptr: *anyopaque = @ptrCast(buffer.ptr);

            const result_size = BoringSSL.SSL_get_peer_finished(ssl_ptr, buffer_ptr, buffer_size);
            std.debug.assert(result_size == size);
            return buffer;
        }

        pub fn getEphemeralKeyInfo(this: Connection) ?EphemeralKeyInfo {
            if (this.is_server) return null;

            const ssl_ptr = this.ssl orelse return null;

            const raw_key: [*c]BoringSSL.EVP_PKEY = BoringSSL.SSL_get_privatekey(ssl_ptr);
            if (raw_key == null) return .empty;

            const kid = BoringSSL.EVP_PKEY_id(raw_key);
            const bits = BoringSSL.EVP_PKEY_bits(raw_key);

            switch (kid) {
                BoringSSL.EVP_PKEY_DH => return .{ .dh = bits },

                BoringSSL.EVP_PKEY_EC, BoringSSL.EVP_PKEY_X25519, BoringSSL.EVP_PKEY_X448 => {
                    var curve_name: []const u8 = undefined;
                    if (kid == BoringSSL.EVP_PKEY_EC) {
                        const ec = BoringSSL.EVP_PKEY_get1_EC_KEY(raw_key) orelse return .empty;
                        defer BoringSSL.EC_KEY_free(ec);
                        const nid = BoringSSL.EC_GROUP_get_curve_name(BoringSSL.EC_KEY_get0_group(ec));
                        const nid_str = BoringSSL.OBJ_nid2sn(nid);
                        if (nid_str != null) {
                            curve_name = nid_str[0..std.mem.len(nid_str)];
                        } else {
                            curve_name = "";
                        }
                    } else {
                        const kid_str = BoringSSL.OBJ_nid2sn(kid);
                        if (kid_str != null) {
                            curve_name = kid_str[0..std.mem.len(kid_str)];
                        } else {
                            curve_name = "";
                        }
                    }
                    return .{ .ecdh = .{ .name = curve_name, .size = bits } };
                },
                else => return .empty,
            }
        }

        pub fn getALPNProtocol(this: Connection) ?[]const u8 {
            var alpn_proto: [*c]const u8 = null;
            var alpn_proto_len: u32 = 0;

            const ssl_ptr = this.ssl orelse return null;

            BoringSSL.SSL_get0_alpn_selected(ssl_ptr, &alpn_proto, &alpn_proto_len);
            if (alpn_proto == null or alpn_proto_len == 0) {
                return null;
            }

            return alpn_proto[0..alpn_proto_len];
        }

        pub fn getSession(this: Connection, allocator: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
            const ssl_ptr = this.ssl orelse return null;
            const session = BoringSSL.SSL_get_session(ssl_ptr) orelse return null;
            const size = BoringSSL.i2d_SSL_SESSION(session, null);
            if (size <= 0) return null;

            const buffer_size = @as(usize, @intCast(size));
            const buffer = try allocator.alloc(u8, buffer_size);
            errdefer allocator.free(buffer);
            var buffer_ptr: [*c]u8 = @ptrCast(buffer.ptr);

            const result_size = BoringSSL.i2d_SSL_SESSION(session, &buffer_ptr);
            std.debug.assert(result_size == size);
            return buffer;
        }

        pub fn getTLSTicket(this: Connection, allocator: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
            const ssl_ptr = this.ssl orelse return null;
            const session = BoringSSL.SSL_get_session(ssl_ptr) orelse return null;
            var ticket: [*c]const u8 = undefined;
            var length: usize = 0;

            BoringSSL.SSL_SESSION_get0_ticket(session, @as([*c][*c]const u8, @ptrCast(&ticket)), &length);

            if (ticket == null or length == 0) return null;

            return try allocator.dupe(u8, ticket[0..length]);
        }

        pub fn disableRenegotiation(this: Connection) void {
            const ssl_ptr = this.ssl orelse return;
            BoringSSL.SSL_set_renegotiate_mode(ssl_ptr, BoringSSL.ssl_renegotiate_never);
        }

        pub fn isSessionReused(this: Connection) bool {
            const ssl_ptr = this.ssl orelse return false;
            return BoringSSL.SSL_session_reused(ssl_ptr) == 1;
        }

        pub fn setVerifyMode(this: Connection, request_cert: bool, reject_unauthorized: bool) void {
            if (this.detached) {
                return;
            }

            var verify_mode: c_int = BoringSSL.SSL_VERIFY_NONE;
            if (this.is_server) {
                if (request_cert) {
                    verify_mode = BoringSSL.SSL_VERIFY_PEER;
                    if (reject_unauthorized)
                        verify_mode |= BoringSSL.SSL_VERIFY_FAIL_IF_NO_PEER_CERT;
                }
            }
            const ssl_ptr = this.ssl;

            BoringSSL.SSL_set_verify(ssl_ptr, verify_mode, alwaysAllowSSLVerifyCallback);
        }

        fn alwaysAllowSSLVerifyCallback(_: c_int, _: ?*BoringSSL.X509_STORE_CTX) callconv(.c) c_int {
            return 1;
        }

        fn appendSSLMessage(buffer: []u8, written: *usize, part: []const u8) void {
            const available = buffer.len - written.*;
            const length = @min(available, part.len);
            @memcpy(buffer[written.*..][0..length], part[0..length]);
            written.* += length;
        }

        pub fn sslErrorMessage(default_message: []const u8, output_buffer: []u8) []const u8 {
            var written: usize = 0;
            var has_detail = false;
            var ssl_error = BoringSSL.ERR_get_error();
            while (ssl_error != 0) : (ssl_error = BoringSSL.ERR_get_error()) {
                const reason = if (BoringSSL.ERR_reason_error_string(ssl_error)) |pointer| std.mem.span(pointer) else "";
                const function = if (BoringSSL.ERR_func_error_string(ssl_error)) |pointer| std.mem.span(pointer) else "";
                const library = if (BoringSSL.ERR_lib_error_string(ssl_error)) |pointer| std.mem.span(pointer) else "";
                if (reason.len == 0 and function.len == 0 and library.len == 0) continue;

                appendSSLMessage(output_buffer, &written, if (has_detail) "\n" else "OpenSSL ");
                appendSSLMessage(output_buffer, &written, reason);
                if (function.len > 0) {
                    appendSSLMessage(output_buffer, &written, " via ");
                    appendSSLMessage(output_buffer, &written, function);
                }
                if (library.len > 0) {
                    appendSSLMessage(output_buffer, &written, " ");
                    appendSSLMessage(output_buffer, &written, library);
                }
                has_detail = true;
            }

            if (has_detail) {
                BoringSSL.ERR_clear_error();
                return output_buffer[0..written];
            }
            return default_message;
        }

        pub const Certificate = struct {
            value: *BoringSSL.X509,
            owned: bool,

            pub fn deinit(certificate: *Certificate) void {
                if (certificate.owned) certificate.value.free();
            }
        };

        pub const CipherInfo = struct {
            name: ?[]const u8,
            standard_name: ?[]const u8,
            version: ?[]const u8,
        };

        pub const EphemeralKeyInfo = union(enum) {
            empty,
            dh: i32,
            ecdh: struct {
                name: []const u8,
                size: i32,
            },
        };

        pub const Signature = struct { name: []const u8, hash: []const u8 };

        pub fn signatureCount(this: Connection) usize {
            const ssl_ptr = this.ssl orelse return 0;
            return @intCast(@max(BoringSSL.SSL_get_shared_sigalgs(ssl_ptr, 0, null, null, null, null, null), 0));
        }

        pub fn signature(this: Connection, index: usize) Signature {
            const ssl_ptr = this.ssl.?;
            var hash_nid: c_int = 0;
            var sign_nid: c_int = 0;
            var sig_with_md: []const u8 = "";

            _ = BoringSSL.SSL_get_shared_sigalgs(ssl_ptr, @as(c_int, @intCast(index)), &sign_nid, &hash_nid, null, null, null);
            switch (sign_nid) {
                BoringSSL.EVP_PKEY_RSA => {
                    sig_with_md = "RSA";
                },
                BoringSSL.EVP_PKEY_RSA_PSS => {
                    sig_with_md = "RSA-PSS";
                },

                BoringSSL.EVP_PKEY_DSA => {
                    sig_with_md = "DSA";
                },

                BoringSSL.EVP_PKEY_EC => {
                    sig_with_md = "ECDSA";
                },

                BoringSSL.NID_ED25519 => {
                    sig_with_md = "Ed25519";
                },

                BoringSSL.NID_ED448 => {
                    sig_with_md = "Ed448";
                },
                BoringSSL.NID_id_GostR3410_2001 => {
                    sig_with_md = "gost2001";
                },

                BoringSSL.NID_id_GostR3410_2012_256 => {
                    sig_with_md = "gost2012_256";
                },
                BoringSSL.NID_id_GostR3410_2012_512 => {
                    sig_with_md = "gost2012_512";
                },
                else => {
                    const sn_str = BoringSSL.OBJ_nid2sn(sign_nid);
                    if (sn_str != null) {
                        sig_with_md = sn_str[0..std.mem.len(sn_str)];
                    } else {
                        sig_with_md = "UNDEF";
                    }
                },
            }

            const hash_str = BoringSSL.OBJ_nid2sn(hash_nid);
            const hash_slice = if (hash_str) |value| value[0..std.mem.len(value)] else "UNDEF";
            return .{ .name = sig_with_md, .hash = hash_slice };
        }

        pub fn checkServername(this: Connection) error{ ServerNameOnServer, HandshakeStarted }!void {
            if (this.is_server) return error.ServerNameOnServer;
            if (this.ssl) |native| if (native.isInitFinished()) return error.HandshakeStarted;
        }

        pub fn setServername(this: Connection, hostname: [:0]const u8) error{ OutOfMemory, InvalidServerName }!?u32 {
            if (std.mem.indexOfScalar(u8, hostname, 0) != null) return error.InvalidServerName;
            if (this.ssl) |native| {
                BoringSSL.ERR_clear_error();
                if (BoringSSL.SSL_set_tlsext_host_name(native, if (hostname.len == 0) null else hostname.ptr) != 1)
                    return try takeCode();
            }
            return null;
        }

        pub fn setSession(this: Connection, bytes: []const u8) bool {
            var cursor: [*c]const u8 = bytes.ptr;
            const session = BoringSSL.d2i_SSL_SESSION(null, &cursor, @intCast(bytes.len)) orelse return true;
            defer BoringSSL.SSL_SESSION_free(session);
            return BoringSSL.SSL_set_session(this.ssl, session) == 1;
        }

        pub fn renegotiate(this: Connection) bool {
            const ssl_ptr = this.ssl orelse return true;
            BoringSSL.ERR_clear_error();
            return BoringSSL.SSL_renegotiate(ssl_ptr) == 1;
        }

        pub fn exportKeyingMaterial(this: Connection, label: []const u8, context: ?[]const u8, output: []u8) bool {
            const bytes = context orelse &.{};
            return BoringSSL.SSL_export_keying_material(
                this.ssl.?,
                if (output.len == 0) null else output.ptr,
                output.len,
                label.ptr,
                label.len,
                if (bytes.len == 0) null else bytes.ptr,
                bytes.len,
                @intFromBool(context != null),
            ) == 1;
        }

        pub fn takeCode() error{OutOfMemory}!u32 {
            var first: u32 = 0;
            var allocation_failed = false;
            while (true) {
                const code = BoringSSL.ERR_get_error();
                if (code == 0) break;
                if (first == 0) first = code;
                if (BoringSSL.ERR_GET_REASON(code) == BoringSSL.ERR_R_MALLOC_FAILURE) allocation_failed = true;
            }
            if (allocation_failed) return error.OutOfMemory;
            return first;
        }
    };
}
