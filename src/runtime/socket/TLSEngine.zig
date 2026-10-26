pub fn WithSocket(comptime This: type) type {
    return struct {
        fn native(this: *This) NativeTLS {
            return .{ .ssl = this.core.socket.ssl(), .is_server = this.isServer(), .detached = this.core.socket.isDetached() };
        }

        pub fn getServername(this: *This) bun.OOM!?bun.bindgen.DOMString {
            const value = native(this).getServername() orelse return null;
            return try bun.bindgen.DOMString.fromUTF8(value);
        }

        pub fn setServername(this: *This, context: anytype, server_name: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
            const connection = native(this);
            connection.checkServername() catch |err| return switch (err) {
                error.ServerNameOnServer => context.fail(.tls_server_sni, {}),
                error.HandshakeStarted => context.fail(.tls_already_started, {}),
            };
            const hostname = try server_name.toOwnedSliceZ(bun.default_allocator);
            errdefer bun.default_allocator.free(hostname);
            const code = connection.setServername(hostname) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidServerName => context.fail(.tls_boringssl, try bun.bindgen.ThreadSafeDOMString.fromUTF8("TLS server name must not contain null bytes")),
            };
            if (code) |value| return @import("./TLSFailure.zig").fromCode(context, value);
            if (this.server_name) |old| bun.default_allocator.free(old);
            this.server_name = hostname;
        }

        pub fn getPeerX509Certificate(this: *This) ?*BoringSSL.X509 {
            return native(this).getPeerX509Certificate();
        }

        pub fn getX509Certificate(this: *This) ?*BoringSSL.X509 {
            return native(this).getX509Certificate();
        }

        pub fn getTLSVersion(this: *This) bun.OOM!?bun.bindgen.DOMString {
            const value = native(this).getTLSVersion() orelse return null;
            return try bun.bindgen.DOMString.fromUTF8(value);
        }

        pub fn setMaxSendFragment(this: *This, size: f64) bool {
            return native(this).setMaxSendFragment(size);
        }

        pub const Certificate = NativeTLS.Certificate;

        pub fn getPeerCertificate(this: *This, abbreviated: ?bool) ?Certificate {
            return native(this).getPeerCertificate(abbreviated);
        }

        pub fn getCertificate(this: *This) ?*BoringSSL.X509 {
            return native(this).getCertificate();
        }

        pub fn getTLSFinishedMessage(this: *This) bun.OOM!?bun.bindgen.OwnedBytes {
            const bytes = try native(this).getTLSFinishedMessage(bun.default_allocator) orelse return null;
            return bun.bindgen.OwnedBytes.fromDefaultAllocatedSlice(bytes);
        }

        pub fn getSharedSigalgs(this: *This, comptime OptionalSequence: type) bun.OOM!OptionalSequence {
            const connection = native(this);
            if (connection.ssl == null) return null;
            const Sequence = @typeInfo(OptionalSequence).optional.child;
            const count = connection.signatureCount();
            var values = try Sequence.Builder.init(count);
            errdefer values.deinit();
            for (0..count) |i| {
                const signature = connection.signature(i);
                const text = try std.fmt.allocPrint(bun.default_allocator, "{s}+{s}", .{ signature.name, signature.hash });
                defer bun.default_allocator.free(text);
                values.appendOwned(try bun.bindgen.DOMString.fromUTF8(text));
            }
            return values.finish();
        }

        pub const CipherInfo = NativeTLS.CipherInfo;

        pub fn getCipher(this: *This) ?CipherInfo {
            return native(this).getCipher();
        }

        pub fn getTLSPeerFinishedMessage(this: *This) bun.OOM!?bun.bindgen.OwnedBytes {
            const bytes = try native(this).getTLSPeerFinishedMessage(bun.default_allocator) orelse return null;
            return bun.bindgen.OwnedBytes.fromDefaultAllocatedSlice(bytes);
        }

        pub fn exportKeyingMaterial(this: *This, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!?bun.bindgen.OwnedBytes {
            if (this.core.socket.isDetached()) {
                return null;
            }

            const label = try args.label.toUTF8(bun.default_allocator);
            defer label.deinit();
            const label_slice = label.slice();
            const connection = native(this);
            if (connection.ssl == null) return null;
            const buffer_size: usize = @intCast(args.length);

            var context_buffer: ?NodeTypes.StringOrBuffer = null;
            defer if (context_buffer) |*value| value.deinit();
            if (args.context) |context_value| {
                context_buffer = try NodeTypes.StringOrBuffer.fromBindgen(context_value, .utf8);
            }

            const context_slice: []const u8 = if (context_buffer) |*value| value.slice() else &.{};
            var output = try bun.bindgen.OwnedBytes.initUninitialized(buffer_size);
            errdefer output.deinit();
            if (!connection.exportKeyingMaterial(label_slice, if (context_buffer != null) context_slice else null, output.mutableSlice())) {
                var error_buffer: [4096 + "OpenSSL ".len]u8 = undefined;
                return context.fail(
                    .export_keying_material_failed,
                    try bun.bindgen.DOMString.fromUTF8(NativeTLS.sslErrorMessage("Failed to export keying material", &error_buffer)),
                );
            }
            return output;
        }

        pub const EphemeralKeyInfo = NativeTLS.EphemeralKeyInfo;

        pub fn getEphemeralKeyInfo(this: *This) ?EphemeralKeyInfo {
            return native(this).getEphemeralKeyInfo();
        }

        pub fn getALPNProtocol(this: *This) bun.OOM!?bun.bindgen.DOMString {
            const value = native(this).getALPNProtocol() orelse return null;
            return try bun.bindgen.DOMString.fromUTF8(value);
        }

        pub fn getSession(this: *This) bun.OOM!?bun.bindgen.OwnedBytes {
            const bytes = try native(this).getSession(bun.default_allocator) orelse return null;
            return bun.bindgen.OwnedBytes.fromDefaultAllocatedSlice(bytes);
        }

        pub fn setSession(this: *This, context: anytype, value: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
            if (this.core.socket.isDetached()) return;
            var input = try NodeTypes.StringOrBuffer.fromBindgen(value, .utf8);
            defer input.deinit();
            if (!native(this).setSession(input.slice())) return failTLSError(context, "SSL_set_session error");
        }

        pub fn getTLSTicket(this: *This) bun.OOM!?bun.bindgen.OwnedBytes {
            const bytes = try native(this).getTLSTicket(bun.default_allocator) orelse return null;
            return bun.bindgen.OwnedBytes.fromDefaultAllocatedSlice(bytes);
        }

        pub fn renegotiate(this: *This, context: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
            if (!native(this).renegotiate()) return failTLSError(context, "SSL_renegotiate error");
        }

        pub fn disableRenegotiation(this: *This) void {
            return native(this).disableRenegotiation();
        }

        pub fn isSessionReused(this: *This) bool {
            return native(this).isSessionReused();
        }

        pub fn setVerifyMode(this: *This, request_cert: bool, reject_unauthorized: bool) void {
            return native(this).setVerifyMode(request_cert, reject_unauthorized);
        }

        noinline fn failTLSError(context: anytype, default_message: []const u8) bun.bindgen.CallError(@TypeOf(context)) {
            var message_buffer: [4096 + "OpenSSL ".len]u8 = undefined;
            const message = NativeTLS.sslErrorMessage(default_message, &message_buffer);
            return context.fail(.tls_operation_failed, try bun.bindgen.DOMString.fromUTF8(message));
        }
    };
}

const std = @import("std");

const bun = @import("bun");
const NodeTypes = @import("../node/types.zig");
const BoringSSL = bun.BoringSSL.c;

const NativeTLS = @import("network_core").tls.TLS(BoringSSL);
