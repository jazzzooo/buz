pub const SocketAddress = @import("./SocketAddress.zig");
pub const UpgradedDuplex = @import("./UpgradedDuplexEngine.zig");

fn selectALPNCallback(ssl: ?*BoringSSL.SSL, out: [*c][*c]const u8, outlen: [*c]u8, in: [*c]const u8, inlen: c_uint, _: ?*anyopaque) callconv(.c) c_int {
    // SSL_CTX_set_alpn_select_cb registers on the listener-level SSL_CTX, so its
    // `arg` is shared across every accepted connection — using it for a
    // per-connection *TLSSocket is a UAF when handshakes overlap. Read the
    // socket back from the per-SSL ex_data slot set in onOpen instead.
    const this = bun.cast(*TLSSocket, BoringSSL.SSL_get_ex_data(ssl, 0) orelse return BoringSSL.SSL_TLSEXT_ERR_NOACK);
    if (this.protos) |protos| {
        if (protos.len == 0) {
            return BoringSSL.SSL_TLSEXT_ERR_NOACK;
        }
        const status = BoringSSL.SSL_select_next_proto(bun.cast([*c][*c]u8, out), outlen, protos.ptr, @as(c_uint, @intCast(protos.len)), in, inlen);
        // Previous versions of Node.js returned SSL_TLSEXT_ERR_NOACK if no protocol
        // match was found. This would neither cause a fatal alert nor would it result
        // in a useful ALPN response as part of the Server Hello message.
        // We now return SSL_TLSEXT_ERR_ALERT_FATAL in that case as per Section 3.2
        // of RFC 7301, which causes a fatal no_application_protocol alert.
        return if (status == BoringSSL.OPENSSL_NPN_NEGOTIATED) BoringSSL.SSL_TLSEXT_ERR_OK else BoringSSL.SSL_TLSEXT_ERR_ALERT_FATAL;
    } else {
        return BoringSSL.SSL_TLSEXT_ERR_NOACK;
    }
}

pub const Handlers = @import("./HandlersEngine.zig");
pub const SocketConfig = Handlers.SocketConfig;
const SocketWriteInput = @import("./SocketWriteInput.zig");

pub const Listener = @import("./Listener.zig");
pub const WindowsNamedPipeContext = if (Environment.isWindows) @import("./WindowsNamedPipeContextEngine.zig") else void;

fn SocketJSBinding(comptime Socket: type, comptime ClassSchema: type) type {
    return struct {
        const Self = @This();

        bindgen_state: bindgen.ClassState = .{},
        socket: bindgen.RefNative(Socket, .vm),

        fn Member(comptime name: []const u8) type {
            return ClassSchema.member(name);
        }

        fn Getter(comptime name: []const u8) type {
            return ClassSchema.memberKind(name, .getter);
        }

        pub const destroy = deinit;

        fn deinit(this: *Self) void {
            if (this.socket.getOptional()) |socket| {
                socket.finalizing = true;
                socket.wrapper_has_pending_activity = false;
                if (!socket.core.socket.isClosed()) socket.closeAndDetach(.failure);
            }
            this.socket.deinit();
            bun.destroy(this);
        }

        pub fn memoryUsage(this: *const Self, _: bindgen.MemoryUsageContext(.vm)) usize {
            const socket = this.socket.getOptional() orelse return 0;
            return socket.memoryCost();
        }

        pub fn hasPendingActivity(this: *const Self) bool {
            const socket = this.socket.getOptional() orelse return false;
            return socket.wrapper_has_pending_activity;
        }

        fn NativeMethod(comptime Schema: type, comptime implementation: anytype) type {
            return struct {
                pub fn call(this: *Self, _: bindgen.CallContext(Schema), _: bindgen.Args(Schema)) bun.JSError!bindgen.Return(Schema) {
                    return @call(.auto, implementation, .{this.socket.get()});
                }

                pub fn forward(this: *Self, context: bindgen.CallContext(Schema), args: bindgen.Args(Schema)) bindgen.CallError(Schema)!bindgen.Return(Schema) {
                    return @call(.auto, implementation, .{ this.socket.get(), context, args });
                }

                pub fn withVM(this: *Self, context: bindgen.CallContext(Schema), _: bindgen.Args(Schema)) bun.JSError!bindgen.Return(Schema) {
                    return @call(.auto, implementation, .{ this.socket.get(), context.viewToken().globalObject().bunVM() });
                }
            };
        }

        pub fn bindGetALPNProtocol(
            this: *Self,
            _: bindgen.CallContext(Getter("alpnProtocol")),
            _: bindgen.Args(Getter("alpnProtocol")),
        ) bun.JSError!bindgen.Return(Getter("alpnProtocol")) {
            const protocol = try this.socket.get().getALPNProtocol();
            return if (protocol) |value| .{ .string = value } else .{ .boolean = false };
        }

        pub const bindGetAuthorized = NativeMethod(Getter("authorized"), Socket.getAuthorized).call;

        pub const bindGetBytesWritten = NativeMethod(Getter("bytesWritten"), Socket.getBytesWritten).call;

        pub const bindClose = NativeMethod(Member("close"), Socket.close).withVM;

        pub fn bindGetData(
            _: *Self,
            context: bindgen.CallContext(Getter("data")),
            _: bindgen.Args(Getter("data")),
        ) bun.JSError!bindgen.Return(Getter("data")) {
            return bindgen.Return(Getter("data")).initUndefined(context);
        }

        pub const bindDisableRenegotiation = NativeMethod(Member("disableRenegotiation"), Socket.disableRenegotiation).call;

        pub const bindDispose = NativeMethod(Member("dispose"), Socket.dispose).call;

        pub const bindEnd = NativeMethod(Member("end"), Socket.endFromBindgen).forward;

        pub const bindEndBuffered = NativeMethod(Member("endBuffered"), Socket.endBufferedFromBindgen).forward;

        pub const bindExportKeyingMaterial = NativeMethod(Member("exportKeyingMaterial"), Socket.exportKeyingMaterial).forward;

        pub const bindGetFD = NativeMethod(Getter("fd"), Socket.getFD).call;

        pub const bindFlush = NativeMethod(Member("flush"), Socket.flush).call;

        pub fn bindGetAuthorizationError(
            this: *Self,
            context: bindgen.CallContext(Member("getAuthorizationError")),
            _: bindgen.Args(Member("getAuthorizationError")),
        ) bun.JSError!bindgen.Return(Member("getAuthorizationError")) {
            const auth_error = this.socket.get().getAuthorizationError() orelse return null;
            return try bindgen.SystemError.createErrorInstance(context, .{
                .errno = 0,
                .code = auth_error.code,
                .message = auth_error.reason,
            });
        }

        pub fn bindGetCertificate(
            this: *Self,
            context: bindgen.CallContext(Member("getCertificate")),
            _: bindgen.Args(Member("getCertificate")),
        ) bun.JSError!bindgen.Return(Member("getCertificate")) {
            const certificate = this.socket.get().getCertificate() orelse return null;
            return try X509.legacyCertificateFromContext(context, certificate);
        }

        pub fn bindGetCipher(
            this: *Self,
            _: bindgen.CallContext(Member("getCipher")),
            _: bindgen.Args(Member("getCipher")),
        ) bun.JSError!bindgen.Return(Member("getCipher")) {
            const cipher = this.socket.get().getCipher() orelse return null;
            var result: bindgen.Return(Member("getCipher")) = .{ .name = null, .standardName = null, .version = null };
            errdefer bindgen.deinitReturn(Member("getCipher"), &result);
            const payload = &result.?;
            payload.name = try bindgen.DOMString.fromOptionalUTF8(cipher.name);
            payload.standardName = try bindgen.DOMString.fromOptionalUTF8(cipher.standard_name);
            payload.version = try bindgen.DOMString.fromOptionalUTF8(cipher.version);
            return result;
        }

        pub fn bindGetEphemeralKeyInfo(
            this: *Self,
            _: bindgen.CallContext(Member("getEphemeralKeyInfo")),
            _: bindgen.Args(Member("getEphemeralKeyInfo")),
        ) bun.JSError!bindgen.Return(Member("getEphemeralKeyInfo")) {
            const info = this.socket.get().getEphemeralKeyInfo() orelse return null;
            var result: bindgen.Return(Member("getEphemeralKeyInfo")) = .{ .type = null, .name = null, .size = null };
            errdefer bindgen.deinitReturn(Member("getEphemeralKeyInfo"), &result);
            const payload = &result.?;
            switch (info) {
                .empty => {},
                .dh => |size| {
                    payload.type = try bindgen.DOMString.fromUTF8("DH");
                    payload.size = size;
                },
                .ecdh => |value| {
                    payload.type = try bindgen.DOMString.fromUTF8("ECDH");
                    payload.name = try bindgen.DOMString.fromUTF8(value.name);
                    payload.size = value.size;
                },
            }
            return result;
        }

        pub fn bindGetPeerCertificate(
            this: *Self,
            context: bindgen.CallContext(Member("getPeerCertificate")),
            args: bindgen.Args(Member("getPeerCertificate")),
        ) bun.JSError!bindgen.Return(Member("getPeerCertificate")) {
            var certificate = this.socket.get().getPeerCertificate(args.abbreviated) orelse return null;
            defer certificate.deinit();
            return try X509.legacyCertificateFromContext(context, certificate.value);
        }

        pub fn bindGetPeerX509Certificate(
            this: *Self,
            context: bindgen.CallContext(Member("getPeerX509Certificate")),
            _: bindgen.Args(Member("getPeerX509Certificate")),
        ) bun.JSError!bindgen.Return(Member("getPeerX509Certificate")) {
            var certificate = this.socket.get().getPeerX509Certificate() orelse return null;
            defer certificate.free();
            const operation = context.engineIn("X509", "x509CreateCertificateObject");
            const CertificateHandle = @FieldType(@TypeOf(operation).Args, "certificate");
            return @as(bindgen.Return(Member("getPeerX509Certificate")), try operation.call(.{
                .certificate = @as(CertificateHandle, @ptrCast(certificate)),
            }));
        }

        pub const bindGetServername = NativeMethod(Member("getServername"), Socket.getServername).call;

        pub const bindGetSession = NativeMethod(Member("getSession"), Socket.getSession).call;

        pub fn bindGetSharedSigalgs(
            this: *Self,
            _: bindgen.CallContext(Member("getSharedSigalgs")),
            _: bindgen.Args(Member("getSharedSigalgs")),
        ) bun.JSError!bindgen.Return(Member("getSharedSigalgs")) {
            return this.socket.get().getSharedSigalgs(bindgen.Return(Member("getSharedSigalgs")));
        }

        pub const bindGetTLSFinishedMessage = NativeMethod(Member("getTLSFinishedMessage"), Socket.getTLSFinishedMessage).call;

        pub const bindGetTLSPeerFinishedMessage = NativeMethod(Member("getTLSPeerFinishedMessage"), Socket.getTLSPeerFinishedMessage).call;

        pub const bindGetTLSTicket = NativeMethod(Member("getTLSTicket"), Socket.getTLSTicket).call;

        pub const bindGetTLSVersion = NativeMethod(Member("getTLSVersion"), Socket.getTLSVersion).call;

        pub fn bindGetX509Certificate(
            this: *Self,
            context: bindgen.CallContext(Member("getX509Certificate")),
            _: bindgen.Args(Member("getX509Certificate")),
        ) bun.JSError!bindgen.Return(Member("getX509Certificate")) {
            const certificate = this.socket.get().getX509Certificate() orelse return null;
            const operation = context.engineIn("X509", "x509CreateCertificateObject");
            const CertificateHandle = @FieldType(@TypeOf(operation).Args, "certificate");
            return @as(bindgen.Return(Member("getX509Certificate")), try operation.call(.{
                .certificate = @as(CertificateHandle, @ptrCast(certificate)),
            }));
        }

        pub const bindIsSessionReused = NativeMethod(Member("isSessionReused"), Socket.isSessionReused).call;

        pub const bindGetListener = NativeMethod(Getter("listener"), Socket.getListener).call;

        pub const bindGetLocalAddress = NativeMethod(Getter("localAddress"), Socket.getLocalAddress).call;

        pub const bindGetLocalFamily = NativeMethod(Getter("localFamily"), Socket.getLocalFamily).call;

        pub const bindGetLocalPort = NativeMethod(Getter("localPort"), Socket.getLocalPort).call;

        pub const bindPause = NativeMethod(Member("pause"), Socket.pause).call;

        pub const bindGetReadyState = NativeMethod(Getter("readyState"), Socket.getReadyState).call;

        pub const bindRef = NativeMethod(Member("ref"), Socket.jsRef).withVM;

        pub const bindReload = NativeMethod(Member("reload"), Socket.reloadFromBindgen).forward;

        pub const bindGetRemoteAddress = NativeMethod(Getter("remoteAddress"), Socket.getRemoteAddress).call;

        pub const bindGetRemoteFamily = NativeMethod(Getter("remoteFamily"), Socket.getRemoteFamily).call;

        pub const bindGetRemotePort = NativeMethod(Getter("remotePort"), Socket.getRemotePort).call;

        pub fn bindRenegotiate(
            this: *Self,
            context: bindgen.CallContext(Member("renegotiate")),
            _: bindgen.Args(Member("renegotiate")),
        ) bindgen.CallError(Member("renegotiate"))!void {
            return this.socket.get().renegotiate(context);
        }

        pub const bindResume = NativeMethod(Member("resume"), Socket.@"resume").call;

        pub fn bindSetKeepAlive(
            this: *Self,
            _: bindgen.CallContext(Member("setKeepAlive")),
            args: bindgen.Args(Member("setKeepAlive")),
        ) bun.JSError!bool {
            return this.socket.get().setKeepAlive(args.enabled, args.initialDelay);
        }

        pub fn bindSetMaxSendFragment(
            this: *Self,
            _: bindgen.CallContext(Member("setMaxSendFragment")),
            args: bindgen.Args(Member("setMaxSendFragment")),
        ) bun.JSError!bool {
            return this.socket.get().setMaxSendFragment(args.size);
        }

        pub fn bindSetNoDelay(
            this: *Self,
            _: bindgen.CallContext(Member("setNoDelay")),
            args: bindgen.Args(Member("setNoDelay")),
        ) bun.JSError!bool {
            return this.socket.get().setNoDelay(args.enabled);
        }

        pub fn bindSetServername(
            this: *Self,
            context: bindgen.CallContext(Member("setServername")),
            args: bindgen.Args(Member("setServername")),
        ) bindgen.CallError(Member("setServername"))!void {
            return this.socket.get().setServername(context, args.server_name);
        }

        pub fn bindSetSession(
            this: *Self,
            context: bindgen.CallContext(Member("setSession")),
            args: bindgen.Args(Member("setSession")),
        ) bindgen.CallError(Member("setSession"))!void {
            return this.socket.get().setSession(context, args.session);
        }

        pub fn bindSetVerifyMode(
            this: *Self,
            _: bindgen.CallContext(Member("setVerifyMode")),
            args: bindgen.Args(Member("setVerifyMode")),
        ) bun.JSError!void {
            this.socket.get().setVerifyMode(args.request_cert, args.reject_unauthorized);
        }

        pub fn bindShutdown(
            this: *Self,
            _: bindgen.CallContext(Member("shutdown")),
            args: bindgen.Args(Member("shutdown")),
        ) bun.JSError!void {
            this.socket.get().shutdown(args.read);
        }

        pub const bindTerminate = NativeMethod(Member("terminate"), Socket.terminate).call;

        pub fn bindTimeout(
            this: *Self,
            context: bindgen.CallContext(Member("timeout")),
            args: bindgen.Args(Member("timeout")),
        ) bindgen.CallError(Member("timeout"))!void {
            if (args.seconds < 0) return context.fail(.timeout_out_of_range, {});
            this.socket.get().timeout(args.seconds);
        }

        pub const bindUnref = NativeMethod(Member("unref"), Socket.jsUnref).withVM;

        pub fn bindUpgradeTLS(
            this: *Self,
            context: bindgen.CallContext(Member("upgradeTLS")),
            args: bindgen.Args(Member("upgradeTLS")),
        ) bindgen.CallError(Member("upgradeTLS"))!bindgen.Return(Member("upgradeTLS")) {
            if (comptime Socket == TLSSocket) return null;
            return this.socket.get().upgradeTLSFromBinding(context, args);
        }

        pub const bindWrite = NativeMethod(Member("write"), Socket.writeFromBindgen).forward;

        pub const bindWriteBuffered = NativeMethod(Member("writeBuffered"), Socket.writeBufferedFromBindgen).forward;
    };
}

pub fn NewSocket(comptime ssl: bool) type {
    return struct {
        const This = @This();
        const tls_socket_functions = tls_socket_functions_module.WithSocket(This);
        pub const ClassSchema = bindgen.Module("Socket").class(if (ssl) "TLSSocket" else "TCPSocket");
        pub const JSBinding = SocketJSBinding(This, ClassSchema);
        pub const Binding = bindgen.Class(ClassSchema, JSBinding);
        pub const DataSlot = Binding.CachedSlot("data");
        pub const Ref = bindgen.ClassRef(ClassSchema);

        pub const new = bun.TrivialNew(@This());

        const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
        pub const ref = RefCount.ref;
        pub const deref = RefCount.deref;

        pub const Socket = uws.NewSocketHandler(ssl);
        core: SocketCore.Socket(ssl, Socket),
        /// `SSL_CTX*` this client connection was opened with. One owned ref —
        /// `SSL_CTX_free` on deinit. Server-accepted sockets and plain TCP
        /// leave this null (the Listener / SecureContext owns the ref there).
        owned_ssl_ctx: ?*BoringSSL.SSL_CTX = null,

        finalizing: bool = false,
        owned_protos: bool = true,
        ref_count: RefCount,
        handlers: ?*Handlers,
        wrapper: ?Binding.ActivityWrapper = null,
        wrapper_has_pending_activity: bool = false,
        poll_ref: Async.KeepAlive = Async.KeepAlive.init(),
        ref_pollref_on_connect: bool = true,
        connection: ?Listener.UnixOrHost = null,
        protos: ?[]const u8,
        server_name: ?[:0]const u8 = null,

        native_callback: NativeCallbacks = .none,
        /// `upgradeTLS` produces two `TLSSocket` wrappers over one
        /// `us_socket_t` (the encrypted view + the raw-bytes view node:net
        /// expects at index 0). The encrypted half holds a ref on the raw half
        /// here so a single `onClose` can retire both — no `Handlers.clone()`,
        /// no second context.
        twin: ?*This = null,

        pub fn memoryCost(this: *This) usize {
            // Per-socket SSL state (SSL*, BIO pair, handshake buffers) is ~40 KB
            // off-heap. Reporting it lets the GC apply pressure when JS churns
            // through short-lived TLS connections. The raw `[raw, tls]` upgrade
            // twin shares the same SSL* — only the encrypted half reports it.
            const ssl_cost: usize = if (ssl and !this.core.flags.bypass_tls) 40 * 1024 else 0;
            return @sizeOf(This) + this.core.memoryCost() + ssl_cost;
        }

        pub fn attachNativeCallback(this: *This, callback: NativeCallbacks) bool {
            if (this.native_callback != .none) return false;
            this.native_callback = callback;

            switch (callback) {
                .h2 => |h2| h2.ref(),
                .none => {},
            }
            return true;
        }

        pub fn detachNativeCallback(this: *This) void {
            const native_callback = this.native_callback;
            this.native_callback = .none;

            switch (native_callback) {
                .h2 => |h2| {
                    h2.onNativeClose();
                    h2.deref();
                },
                .none => {},
            }
        }

        pub fn doConnect(this: *This, connection: Listener.UnixOrHost) bun.OOM!?uws.ConnectFailure {
            this.ref();
            defer this.deref();

            const vm = this.getHandlers().vm;
            const group = (try vm.tryRareData()).bunConnectGroup(vm, ssl);
            const kind: uws.SocketKind = if (ssl) .bun_socket_tls else .bun_socket_tcp;
            const flags: i32 = if (this.core.flags.allow_half_open) uws.LIBUS_SOCKET_ALLOW_HALF_OPEN else 0;
            const ssl_ctx: ?*uws.SslCtx = if (ssl) this.owned_ssl_ctx else null;

            switch (connection) {
                .host => |host| {
                    var sf_buffer: [1024]u8 = undefined;
                    var sf: std.heap.BufferFirstAllocator = .init(&sf_buffer, bun.default_allocator);
                    const alloc = sf.allocator();
                    // getaddrinfo doesn't accept bracketed IPv6.
                    const raw = host.host;
                    const clean = if (raw.len > 1 and raw[0] == '[' and raw[raw.len - 1] == ']') raw[1 .. raw.len - 1] else raw;
                    const hostz = try alloc.dupeSentinel(u8, clean, 0);
                    defer alloc.free(hostz);

                    this.core.socket = switch (group.connect(kind, ssl_ctx, hostz, host.port, flags, @sizeOf(*anyopaque))) {
                        .failed => |failure| return failure,
                        .socket => |s| blk: {
                            s.ext(*This).* = this;
                            break :blk Socket.from(s);
                        },
                        .connecting => |c| blk: {
                            c.ext(*This).* = this;
                            break :blk Socket.fromConnecting(c);
                        },
                    };
                },
                .unix => |u| {
                    var sf_buffer: [1024]u8 = undefined;
                    var sf: std.heap.BufferFirstAllocator = .init(&sf_buffer, bun.default_allocator);
                    const alloc = sf.allocator();
                    const pathz = try alloc.dupeSentinel(u8, u, 0);
                    defer alloc.free(pathz);

                    const s = switch (group.connectUnix(kind, ssl_ctx, pathz.ptr, pathz.len, flags, @sizeOf(*anyopaque))) {
                        .socket => |socket| socket,
                        .failed => |failure| return failure,
                    };
                    s.ext(*This).* = this;
                    this.core.socket = Socket.from(s);
                },
                .fd => |f| {
                    const s = switch (group.fromFd(kind, ssl_ctx, @sizeOf(*anyopaque), f.native(), false)) {
                        .socket => |socket| socket,
                        .failed => |failure| return failure,
                    };
                    s.ext(*This).* = this;
                    this.core.socket = Socket.from(s);
                    this.onOpen(this.core.socket);
                },
            }
            return null;
        }

        pub fn @"resume"(this: *This) void {
            return this.core.@"resume"();
        }

        pub fn pause(this: *This) void {
            return this.core.pause();
        }

        pub fn setKeepAlive(this: *This, enabled: bool, initial_delay: u32) bool {
            return this.core.setKeepAlive(enabled, initial_delay);
        }

        pub fn setNoDelay(this: *This, enabled: bool) bool {
            return this.core.setNoDelay(enabled);
        }

        pub fn handleError(this: *This, failure: SocketFailure) void {
            log("handleError", .{});
            const handlers = this.getHandlers();
            var vm = handlers.vm;
            if (vm.isShuttingDown()) {
                return;
            }
            // the handlers must be kept alive for the duration of the function call
            // that way if we need to call the error handler, we can
            var scope = handlers.enter();
            defer if (scope.exit()) {
                this.handlers = null;
            };
            const globalObject = handlers.globalObject;
            var receiver = this.getThisRef(globalObject) catch |err| {
                globalObject.reportActiveExceptionAsUnhandled(err);
                return;
            };
            defer receiver.deinit();
            _ = handlers.callErrorHandler(ClassSchema, &receiver, failure);
        }

        pub fn onWritable(this: *This, _: Socket) void {
            if (this.core.socket.isDetached()) return;
            if (this.native_callback.onWritable()) return;
            const handlers = this.getHandlers();
            const callback = handlers.onWritable orelse return;

            var vm = handlers.vm;
            if (vm.isShuttingDown()) {
                return;
            }
            this.ref();
            defer this.deref();
            this.internalFlush();
            log("onWritable buffered_data_for_node_net {d}", .{this.core.bufferedLength()});
            // is not writable if we have buffered data or if we are already detached
            if (this.core.bufferedLength() > 0 or this.core.socket.isDetached()) return;

            // the handlers must be kept alive for the duration of the function call
            // that way if we need to call the error handler, we can
            var scope = handlers.enter();
            defer if (scope.exit()) {
                this.handlers = null;
            };

            const globalObject = handlers.globalObject;
            var receiver = this.getThisRef(globalObject) catch |err| {
                globalObject.reportActiveExceptionAsUnhandled(err);
                return;
            };
            defer receiver.deinit();
            var invocation: @TypeOf(callback).Invocation = undefined;
            callback.beginInvocation(&invocation);
            defer invocation.deinit();
            _ = invocation.call(.{ .bindingThis = Handlers.socketOperand(ClassSchema, &receiver, &invocation), .socket = Handlers.socketOperand(ClassSchema, &receiver, &invocation) }) catch |err| {
                _ = handlers.callErrorHandlerException(ClassSchema, &receiver, err);
            };
        }

        pub fn onTimeout(this: *This, _: Socket) void {
            if (this.core.socket.isDetached()) return;
            const handlers = this.getHandlers();
            log("onTimeout {s}", .{if (handlers.mode == .server) "S" else "C"});
            const callback = handlers.onTimeout orelse return;
            if (this.finalizing) return;
            if (handlers.vm.isShuttingDown()) {
                return;
            }

            // the handlers must be kept alive for the duration of the function call
            // that way if we need to call the error handler, we can
            var scope = handlers.enter();
            defer if (scope.exit()) {
                this.handlers = null;
            };

            const globalObject = handlers.globalObject;
            var receiver = this.getThisRef(globalObject) catch |err| {
                globalObject.reportActiveExceptionAsUnhandled(err);
                return;
            };
            defer receiver.deinit();
            var invocation: @TypeOf(callback).Invocation = undefined;
            callback.beginInvocation(&invocation);
            defer invocation.deinit();
            _ = invocation.call(.{ .bindingThis = Handlers.socketOperand(ClassSchema, &receiver, &invocation), .socket = Handlers.socketOperand(ClassSchema, &receiver, &invocation) }) catch |err| {
                _ = handlers.callErrorHandlerException(ClassSchema, &receiver, err);
            };
        }

        pub fn getHandlers(this: *const This) *Handlers {
            return this.handlers orelse @panic("No handlers set on Socket");
        }

        pub fn handleConnectError(this: *This, failure: bun.sys.Error) bun.JSError!void {
            return this.handleConnectFailure(.{ .system = failure });
        }

        pub const ConnectFailure = union(enum) { system: bun.sys.Error, native: uws.ConnectFailure, out_of_memory };

        fn systemConnectError(failure: bun.sys.Error) bun.sys.SystemError {
            var message_buffer: [bun.sys.Error.system_error_message_capacity]u8 = undefined;
            const data = failure.toSystemErrorData(&message_buffer);
            return .{
                .errno = data.errno,
                .message = bun.String.static("Failed to connect"),
                .syscall = bun.String.static("connect"),
                .code = if (data.code_tag) |tag| switch (tag) {
                    .node => |code| bun.String.staticTagName(code),
                    .system => |code| bun.String.staticTagName(code),
                } else bun.String.static("UNKNOWN"),
            };
        }

        fn nativeConnectError(failure: uws.ConnectFailure) bun.sys.SystemError {
            if (failure.systemErrno()) |errno| {
                const native_errno: bun.sys.E = if (Environment.isWindows) errno.toE() else @fromBackingInt(@backingInt(errno));
                return systemConnectError(bun.sys.Error.fromCode(native_errno, .connect));
            }
            if (failure.dns_error != 0) {
                const dns_error = bun.c_ares.Error.initEAI(failure.dns_error) orelse .ENOTFOUND;
                return .{
                    .errno = failure.dns_error,
                    .message = dns_error.labelString(),
                    .syscall = bun.String.static("getaddrinfo"),
                    .code = dns_error.shortCodeString(),
                };
            }
            return .{
                .errno = if (failure.poll_error.domain != .none) failure.poll_error.code else failure.system_error,
                .message = bun.String.static("Failed to connect"),
                .syscall = bun.String.static("connect"),
                .code = bun.String.static("UNKNOWN"),
            };
        }

        pub fn handleConnectFailure(this: *This, failure: ConnectFailure) bun.JSError!void {
            const handlers = this.getHandlers();
            log("onConnectError {s} ({s}, {d})", .{ if (handlers.mode == .server) "S" else "C", @tagName(failure), this.ref_count.get() });
            // Ensure the socket is still alive for any defer's we have
            this.ref();
            defer this.deref();
            this.core.clearBuffered();

            const needs_deref = !this.core.socket.isDetached();
            this.core.socket = Socket.detached;
            this.wrapper_has_pending_activity = false;
            defer if (needs_deref) this.deref();

            const vm = handlers.vm;
            this.poll_ref.unrefOnNextTick(vm);
            if (vm.isShuttingDown()) {
                this.markInactive();
                return;
            }

            const globalObject = handlers.globalObject;
            var scope = handlers.enter();
            defer if (scope.exit()) {
                if (this.handlers == handlers) this.handlers = null;
            };
            this.markInactive();
            const system_error_value: ?bun.sys.SystemError = switch (failure) {
                .native => |value| if (value.isOutOfMemory()) null else nativeConnectError(value),
                .system => |value| if (value.getErrno() == .NOMEM) null else systemConnectError(value),
                .out_of_memory => null,
            };
            const err = system_error_value orelse {
                if (!handlers.outOfMemoryConnect()) globalObject.reportActiveExceptionAsUnhandled(error.OutOfMemory);
                return;
            };

            const callback = handlers.onConnectError orelse {
                this.wrapper_has_pending_activity = false;
                _ = handlers.failConnect(&err);
                return;
            };

            var receiver = this.getThisRef(globalObject) catch |allocation_error| {
                if (allocation_error == error.OutOfMemory) {
                    if (!handlers.outOfMemoryConnect()) globalObject.reportActiveExceptionAsUnhandled(allocation_error);
                    return;
                }
                return allocation_error;
            };
            defer receiver.deinit();
            this.wrapper_has_pending_activity = false;

            var system_error = bindgen.SystemError.fromSystemError(&err) catch {
                if (!handlers.outOfMemoryConnect()) globalObject.reportActiveExceptionAsUnhandled(error.OutOfMemory);
                return;
            };
            defer system_error.deinit();

            var invocation: @TypeOf(callback).Invocation = undefined;
            callback.beginInvocation(&invocation);
            defer invocation.deinit();
            var error_result = system_error.toErrorInstance(&invocation) catch |engine_error| {
                if (engine_error == error.OutOfMemory) {
                    if (!handlers.outOfMemoryConnect()) globalObject.reportActiveExceptionAsUnhandled(engine_error);
                    return;
                }
                var thrown_value = try invocation.takeThrownValue(engine_error);
                defer thrown_value.deinit();
                var thrown = handlers.retainConnectError(&thrown_value) orelse return;
                defer thrown.deinit();
                if (!handlers.rejectConnect(&thrown, .{ .attach_async_stack = true })) {
                    _ = handlers.callErrorHandlerRoot(ClassSchema, &receiver, &thrown);
                }
                return;
            };
            defer error_result.deinit();
            var original_error = handlers.retainConnectError(&error_result) orelse return;
            defer original_error.deinit();
            const error_view = try error_result.view(&invocation);
            const result = invocation.call(.{
                .bindingThis = Handlers.socketOperand(ClassSchema, &receiver, &invocation),
                .socket = Handlers.socketOperand(ClassSchema, &receiver, &invocation),
                .@"error" = error_view.operand(&invocation),
            }) catch |callback_error| {
                var thrown_value = try invocation.takeThrownValue(callback_error);
                defer thrown_value.deinit();
                var thrown = handlers.retainConnectError(&thrown_value) orelse return;
                defer thrown.deinit();
                if (!handlers.rejectConnect(&thrown, .{ .attach_async_stack = true })) {
                    _ = handlers.callErrorHandlerRoot(ClassSchema, &receiver, &thrown);
                }
                return;
            };

            switch (result) {
                .@"error" => |returned_error| {
                    var rejection = handlers.retainConnectError(&returned_error) orelse return;
                    defer rejection.deinit();
                    if (!handlers.rejectConnect(&rejection, .{ .attach_async_stack = true })) {
                        _ = handlers.callErrorHandlerRoot(ClassSchema, &receiver, &rejection);
                    }
                },
                .ignored => {
                    _ = handlers.rejectConnect(&original_error, .{
                        .attach_async_stack = true,
                        .handled = true,
                    });
                },
            }
        }

        pub fn onConnectError(this: *This, _: Socket, failure: uws.ConnectFailure) void {
            const global = this.getHandlers().globalObject;
            this.handleConnectFailure(.{ .native = failure }) catch |err| global.reportActiveExceptionAsUnhandled(err);
        }

        pub fn markActive(this: *This) void {
            if (!this.core.flags.is_active) {
                const handlers = this.getHandlers();
                handlers.markActive();
                this.core.flags.is_active = true;
                // Keep the JS wrapper alive while the socket is active.
                // A wrapper may not have been created yet (e.g. server-side
                // sockets without default data), in which case the ref is still
                // empty and there's nothing to upgrade.
                if (this.wrapper != null) this.wrapper_has_pending_activity = true;
            }
        }

        pub fn closeAndDetach(this: *This, code: uws.Socket.CloseCode) void {
            const socket = this.core.socket;
            this.core.clearBuffered();

            this.core.socket.detach();
            this.detachNativeCallback();

            socket.close(code);
        }

        pub fn markInactive(this: *This) void {
            if (this.core.flags.is_active) {
                // we have to close the socket before the socket context is closed
                // otherwise we will get a segfault
                // uSockets will defer freeing the TCP socket until the next tick
                if (!this.core.socket.isClosed()) {
                    this.closeAndDetach(.normal);
                    // onClose will call markInactive again
                    return;
                }

                this.core.flags.is_active = false;
                // Allow the JS wrapper to be GC'd now that the socket is idle.
                // Do this before touching `handlers`: in client mode
                // `handlers.markInactive()` frees the Handlers allocation
                // entirely, and for the last server-side connection on a
                // stopped listener it releases the listener's own strong ref.
                this.wrapper_has_pending_activity = false;
                // During VM shutdown, the Listener (which embeds `handlers`
                // for server sockets) may already have been finalized by the
                // time a deferred `onClose` → `markInactive` reaches here,
                // leaving `this.handlers` dangling. Active-connection
                // bookkeeping is irrelevant once the process is exiting, so
                // just release the event-loop ref and stop.
                const vm = jsc.VirtualMachine.get();
                if (vm.isShuttingDown()) {
                    this.poll_ref.unref(vm);
                    return;
                }
                const handlers = this.getHandlers();
                if (handlers.markInactive()) {
                    // Client-mode handlers are allocated per-connection and
                    // `Handlers.markInactive` just freed them. Null the field
                    // so `connectInner` (net.Socket reconnect path) and
                    // `getListener` don't dereference/destroy freed memory.
                    this.handlers = null;
                }
                this.poll_ref.unref(vm);
            }
        }

        pub fn isServer(this: *const This) bool {
            // `handlers` is null on detached sockets and on closed client
            // sockets (markInactive nulls it once the allocation is freed).
            // JS-callable TLS accessors (`setServername`, `getPeerCertificate`,
            // `getEphemeralKeyInfo`, `setVerifyMode`) consult this on sockets
            // whose connection may already be gone.
            const handlers = this.handlers orelse return false;
            return handlers.mode.isServer();
        }

        fn configureTLS(this: *This) bun.OOM!?u32 {
            if (comptime !ssl) return null;
            const native = this.core.socket.ssl() orelse return null;
            if (native.isInitFinished()) return null;
            BoringSSL.ERR_clear_error();
            if (this.server_name) |hostname| {
                if (BoringSSL.SSL_set_tlsext_host_name(native, if (hostname.len == 0) null else hostname.ptr) != 1)
                    return try TLSFailure.takeCode();
            } else if (this.connection) |connection| {
                if (connection == .host and connection.host.host.len > 0) {
                    const hostname = try default_allocator.dupeSentinel(u8, connection.host.host, 0);
                    defer default_allocator.free(hostname);
                    if (BoringSSL.SSL_set_tlsext_host_name(native, hostname.ptr) != 1)
                        return try TLSFailure.takeCode();
                }
            }
            if (this.protos) |protos| {
                if (this.isServer()) {
                    if (BoringSSL.SSL_set_ex_data(native, 0, this) != 1)
                        return try TLSFailure.takeCode();
                    BoringSSL.SSL_CTX_set_alpn_select_cb(BoringSSL.SSL_get_SSL_CTX(native), selectALPNCallback, null);
                } else {
                    if (BoringSSL.SSL_set_alpn_protos(native, protos.ptr, protos.len) != 0)
                        return try TLSFailure.takeCode();
                }
            }
            return null;
        }

        fn failTLSOpen(this: *This, code: ?u32) void {
            const handlers = this.getHandlers();
            const global = handlers.globalObject;
            var handler_scope = handlers.enter();
            defer if (handler_scope.exit()) {
                if (this.handlers == handlers) this.handlers = null;
            };
            const handled = if (code) |value| handlers.failTLSConnect(value) else handlers.outOfMemoryConnect();
            if (handled) {
                this.closeAndDetach(.failure);
                return;
            }
            var receiver = this.getThisRef(global) catch |err| {
                this.closeAndDetach(.failure);
                global.reportActiveExceptionAsUnhandled(err);
                return;
            };
            defer receiver.deinit();
            this.closeAndDetach(.failure);
            if (code) |value| {
                var scope: bindgen.FocusedEngineScope = undefined;
                scope.init(global);
                defer scope.deinit();
                const native_message = bun.BoringSSL.ErrorMessage.init(value);
                var message = bindgen.DOMString.fromUTF8(native_message.slice()) catch |err| {
                    _ = handlers.callErrorHandlerException(ClassSchema, &receiver, err);
                    return;
                };
                defer message.deinit();
                var exception = scope.engineIn("errors", "createError").call(.{ .message = message.operand() }) catch |err| {
                    _ = handlers.callErrorHandlerException(ClassSchema, &receiver, err);
                    return;
                };
                defer exception.deinit();
                var root = exception.toRoot() catch |err| {
                    _ = handlers.callErrorHandlerException(ClassSchema, &receiver, err);
                    return;
                };
                defer root.deinit();
                _ = handlers.callErrorHandlerRoot(ClassSchema, &receiver, &root);
            } else {
                _ = handlers.callErrorHandlerException(ClassSchema, &receiver, error.OutOfMemory);
            }
        }

        pub fn onOpen(this: *This, socket: Socket) void {
            log("onOpen {s} {*} {} {}", .{ if (this.isServer()) "S" else "C", this, this.core.socket.isDetached(), this.ref_count.get() });
            // Ensure the socket remains alive until this is finished
            this.ref();
            defer this.deref();

            // update the internal socket instance to the one that was just connected
            // This socket must be replaced because the previous one is a connecting socket not a uSockets socket
            this.core.socket = socket;

            if (socket.ext(**anyopaque)) |ctx| {
                ctx.* = bun.cast(**anyopaque, this);
            }
            this.markActive();
            const setup_error = this.configureTLS() catch {
                this.failTLSOpen(null);
                return;
            };
            if (setup_error) |code| {
                this.failTLSOpen(code);
                return;
            }

            const handlers = this.getHandlers();
            const callback = handlers.onOpen;
            const handshake_callback = handlers.onHandshake;

            const globalObject = handlers.globalObject;
            var receiver = this.getThisRef(globalObject) catch |err| {
                if (err != error.OutOfMemory or !handlers.outOfMemoryConnect())
                    globalObject.reportActiveExceptionAsUnhandled(err);
                this.closeAndDetach(.failure);
                return;
            };
            defer receiver.deinit();

            handlers.resolveConnect();

            const open_callback = callback orelse return;
            if (comptime ssl) {
                // only calls open callback if handshake callback is provided
                // If handshake is provided, open is called on connection open
                // If is not provided, open is called after handshake
                if (handshake_callback == null) return;
            }

            // the handlers must be kept alive for the duration of the function call
            // that way if we need to call the error handler, we can
            var scope = handlers.enter();
            defer if (scope.exit()) {
                this.handlers = null;
            };
            var invocation: @TypeOf(open_callback).Invocation = undefined;
            open_callback.beginInvocation(&invocation);
            defer invocation.deinit();
            const result = invocation.call(.{
                .bindingThis = Handlers.socketOperand(ClassSchema, &receiver, &invocation),
                .socket = Handlers.socketOperand(ClassSchema, &receiver, &invocation),
            }) catch |callback_error| {
                var thrown = invocation.takeThrownValue(callback_error) catch return;
                defer thrown.deinit();
                var error_root = thrown.toRoot() catch |err|
                    return invocation.reportActiveException(err);
                defer error_root.deinit();
                _ = handlers.callErrorHandlerRoot(ClassSchema, &receiver, &error_root);
                return;
            };

            switch (result) {
                .@"error" => |error_result| {
                    defer this.markInactive();
                    if (!this.core.socket.isClosed()) {
                        log("Closing due to error", .{});
                    } else {
                        log("Already closed", .{});
                    }
                    var error_root = error_result.toRoot() catch |err|
                        return invocation.reportActiveException(err);
                    defer error_root.deinit();
                    _ = handlers.callErrorHandlerRoot(ClassSchema, &receiver, &error_root);
                },
                .ignored => {},
            }
        }

        const PreparedWrapper = struct {
            reference: Ref,
            activity: ?Binding.ActivityWrapper,

            fn init(reference_: Ref) bun.JSError!PreparedWrapper {
                var reference = reference_;
                errdefer reference.deinit();
                return .{
                    .reference = reference,
                    .activity = try Binding.ActivityWrapper.initRef(&reference),
                };
            }

            fn commit(prepared: *PreparedWrapper, socket: *This) Ref {
                const activity = prepared.activity orelse @panic("socket wrapper was already committed");
                bun.assert(socket.wrapper == null);
                const reference = prepared.reference.take();
                const binding = reference.get(JSBinding);
                bun.assert(binding.socket.getOptional() == null);
                binding.socket = .adopt(socket);
                socket.wrapper = activity;
                socket.wrapper_has_pending_activity = true;
                prepared.activity = null;
                return reference;
            }

            fn deinit(prepared: *PreparedWrapper) void {
                if (prepared.activity) |*activity| activity.deinit();
                prepared.activity = null;
                prepared.reference.deinit();
            }
        };

        fn prepareWrapper(global: *jsc.JSGlobalObject) bun.JSError!PreparedWrapper {
            const binding = try bun.default_allocator.create(JSBinding);
            binding.* = .{ .socket = .empty };
            return PreparedWrapper.init(try Binding.adoptNativeRef(binding, global));
        }

        fn retainedThisRef(this: *This) bun.JSError!?Ref {
            const wrapper = if (this.wrapper) |*value| value else return null;
            return (try wrapper.toOwned()) orelse @panic("live socket lost its generated wrapper");
        }

        pub fn getThisRef(this: *This, globalObject: *jsc.JSGlobalObject) bun.JSError!Ref {
            if (try this.retainedThisRef()) |reference| return reference;
            var prepared = try prepareWrapper(globalObject);
            defer prepared.deinit();
            return prepared.commit(this);
        }

        pub fn getThisRefResult(this: *This, context: anytype) bun.JSError!Ref {
            if (try this.retainedThisRef()) |reference| return reference;
            const binding = try bun.default_allocator.create(JSBinding);
            binding.* = .{ .socket = .empty };
            var prepared = try PreparedWrapper.init(try Binding.adoptResult(binding, context));
            defer prepared.deinit();
            return prepared.commit(this);
        }

        pub fn onEnd(this: *This, _: Socket) void {
            if (this.core.socket.isDetached()) return;
            const handlers = this.getHandlers();
            log("onEnd {s}", .{if (handlers.mode == .server) "S" else "C"});
            // Ensure the socket remains alive until this is finished
            this.ref();
            defer this.deref();

            const callback = if (handlers.vm.isShuttingDown()) null else handlers.onEnd;
            const on_end = callback orelse {
                this.poll_ref.unref(handlers.vm);

                // If you don't handle TCP fin, we assume you're done.
                this.markInactive();
                return;
            };

            // the handlers must be kept alive for the duration of the function call
            // that way if we need to call the error handler, we can
            var scope = handlers.enter();
            defer if (scope.exit()) {
                this.handlers = null;
            };

            const globalObject = handlers.globalObject;
            var receiver = this.getThisRef(globalObject) catch |err| {
                globalObject.reportActiveExceptionAsUnhandled(err);
                return;
            };
            defer receiver.deinit();
            var invocation: @TypeOf(on_end).Invocation = undefined;
            on_end.beginInvocation(&invocation);
            defer invocation.deinit();
            _ = invocation.call(.{ .bindingThis = Handlers.socketOperand(ClassSchema, &receiver, &invocation), .socket = Handlers.socketOperand(ClassSchema, &receiver, &invocation) }) catch |err| {
                _ = handlers.callErrorHandlerException(ClassSchema, &receiver, err);
            };
        }

        pub fn onHandshake(this: *This, s: Socket, success: i32, ssl_error: uws.us_bun_verify_error_t) void {
            const global = this.getHandlers().globalObject;
            this.handleHandshakeEvent(s, success, ssl_error) catch |err| global.reportActiveExceptionAsUnhandled(err);
        }

        fn handleHandshakeEvent(this: *This, s: Socket, success: i32, ssl_error: uws.us_bun_verify_error_t) bun.JSError!void {
            this.core.flags.handshake_complete = true;
            this.core.socket = s;
            if (this.core.socket.isDetached()) return;
            const handlers = this.getHandlers();
            log("onHandshake {s} ({d})", .{ if (handlers.mode == .server) "S" else "C", success });

            const authorized = if (success == 1) true else false;

            this.core.flags.authorized = authorized;

            if (handlers.vm.isShuttingDown()) {
                return;
            }

            const is_open = handlers.onHandshake == null;
            if (is_open and handlers.onOpen == null) return;

            // the handlers must be kept alive for the duration of the function call
            // that way if we need to call the error handler, we can
            var scope = handlers.enter();
            defer if (scope.exit()) {
                this.handlers = null;
            };

            const globalObject = handlers.globalObject;
            var receiver = try this.getThisRef(globalObject);
            defer receiver.deinit();

            var callback_failure: ?bindgen.Root = null;
            defer if (callback_failure) |*failure| failure.deinit();
            // open callback only have 1 parameters and its the socket
            // you should use getAuthorizationError and authorized getter to get those values in this case
            if (is_open) {
                const callback = &handlers.onOpen.?;
                var invocation: @TypeOf(callback.*).Invocation = undefined;
                callback.beginInvocation(&invocation);
                defer invocation.deinit();
                if (invocation.call(.{
                    .bindingThis = Handlers.socketOperand(ClassSchema, &receiver, &invocation),
                    .socket = Handlers.socketOperand(ClassSchema, &receiver, &invocation),
                })) |result| {
                    switch (result) {
                        .@"error" => |error_result| callback_failure = try error_result.toRoot(),
                        .ignored => {},
                    }
                } else |callback_error| {
                    var thrown = try invocation.takeThrownValue(callback_error);
                    defer thrown.deinit();
                    callback_failure = try thrown.toRoot();
                }

                // only call onOpen once for clients
                if (handlers.mode != .server) {
                    // clean onOpen callback so only called in the first handshake and not in every renegotiation
                    // on servers this would require a different approach but it's not needed because our servers will not call handshake multiple times
                    // servers don't support renegotiation
                    if (handlers.onOpen) |*owned| owned.deinit();
                    handlers.onOpen = null;
                }
            } else {
                try handlers.callHandshake(ClassSchema, &receiver, authorized, ssl_error);
            }

            if (callback_failure) |*failure| {
                _ = handlers.callErrorHandlerRoot(ClassSchema, &receiver, failure);
            }
        }

        pub fn onClose(this: *This, socket: Socket, err: c_int, reason: ?*anyopaque) void {
            const global = this.getHandlers().globalObject;
            this.handleCloseEvent(socket, err, reason) catch |failure| global.reportActiveExceptionAsUnhandled(failure);
        }

        fn handleCloseEvent(this: *This, socket: Socket, err: c_int, reason: ?*anyopaque) bun.JSError!void {
            const handlers = this.getHandlers();
            log("onClose {s}", .{if (handlers.mode == .server) "S" else "C"});
            this.detachNativeCallback();
            this.core.socket.detach();
            // The upgradeTLS raw twin shares the same us_socket_t so it never
            // gets its own dispatch — fire its (pre-upgrade) close handler
            // here, then retire it. `raw.twin == null` so this doesn't
            // recurse, and `onClose` derefs the +1 we took at creation.
            if (this.twin) |raw| {
                this.twin = null;
                raw.onClose(socket, err, reason);
            }
            defer this.deref();
            defer this.markInactive();

            if (this.finalizing) {
                return;
            }

            const vm = handlers.vm;
            this.poll_ref.unref(vm);

            if (handlers.onClose == null) return;

            if (vm.isShuttingDown()) {
                return;
            }

            // the handlers must be kept alive for the duration of the function call
            // that way if we need to call the error handler, we can
            var scope = handlers.enter();
            defer if (scope.exit()) {
                this.handlers = null;
            };

            const globalObject = handlers.globalObject;
            var receiver = try this.getThisRef(globalObject);
            defer receiver.deinit();
            try handlers.callClose(ClassSchema, &receiver, err);
        }

        pub fn onData(this: *This, s: Socket, data: []const u8) void {
            this.core.socket = s;
            if (this.core.socket.isDetached()) return;
            const handlers = this.getHandlers();
            log("onData {s} ({d})", .{ if (handlers.mode == .server) "S" else "C", data.len });
            if (this.native_callback.onData(data)) return;

            if (handlers.onData == null) return;
            if (this.finalizing) return;
            if (handlers.vm.isShuttingDown()) {
                return;
            }

            const globalObject = handlers.globalObject;
            var receiver = this.getThisRef(globalObject) catch |err| {
                globalObject.reportActiveExceptionAsUnhandled(err);
                return;
            };
            defer receiver.deinit();
            // the handlers must be kept alive for the duration of the function call
            // that way if we need to call the error handler, we can
            var scope = handlers.enter();
            defer if (scope.exit()) {
                this.handlers = null;
            };

            handlers.callData(ClassSchema, &receiver, data) catch |err| {
                _ = handlers.callErrorHandlerException(ClassSchema, &receiver, err);
            };
        }

        pub fn getListener(this: *This) ?Listener.Ref {
            const handlers = this.handlers orelse return null;

            if (handlers.mode != .server or this.core.socket.isDetached()) {
                return null;
            }

            const l: *Listener = @fieldParentPtr("handlers", handlers);
            return l.strongRef();
        }

        pub fn getReadyState(this: *This) i32 {
            return this.core.getReadyState();
        }

        pub fn getAuthorized(this: *This) bool {
            return this.core.getAuthorized();
        }

        pub fn timeout(this: *This, seconds: i32) void {
            return this.core.timeout(seconds);
        }

        pub const AuthorizationError = struct {
            code: []const u8,
            reason: []const u8,
        };

        pub fn getAuthorizationError(this: *This) ?AuthorizationError {
            if (this.core.socket.isDetached()) return null;

            // this error can change if called in different stages of hanshake
            // is very usefull to have this feature depending on the user workflow
            const ssl_error = this.core.socket.getVerifyError();
            if (ssl_error.error_no == 0) return null;

            const code = if (ssl_error.code == null) "" else ssl_error.code[0..bun.len(ssl_error.code)];

            const reason = if (ssl_error.reason == null) "" else ssl_error.reason[0..bun.len(ssl_error.reason)];

            return .{ .code = code, .reason = reason };
        }

        pub fn writeFromBindgen(this: *This, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!i32 {
            if (this.core.socket.isDetached()) {
                return -1;
            }

            return (try this.writeOrEndFromBindgen(context, args, false, false)).wrote;
        }

        pub fn getLocalFamily(this: *This) bun.OOM!?bindgen.DOMString {
            const address = this.core.address(.local) orelse return null;
            return try bindgen.DOMString.fromUTF8(switch (address) {
                .ipv4 => "IPv4",
                .ipv6 => "IPv6",
            });
        }

        pub fn getLocalAddress(this: *This) bun.OOM!?bindgen.DOMString {
            const address = switch (this.core.address(.local) orelse return null) {
                .ipv4 => |bytes| SocketAddress.initIp4(bytes, 0),
                .ipv6 => |bytes| SocketAddress.initIp6(bytes, 0, 0, 0),
            };
            var buffer: [512]u8 = undefined;
            return try bindgen.DOMString.fromUTF8(address.formatIp(&buffer));
        }

        pub fn getLocalPort(this: *This) ?u16 {
            return this.core.port(.local);
        }

        pub fn getRemoteFamily(this: *This) bun.OOM!?bindgen.DOMString {
            const address = this.core.address(.remote) orelse return null;
            return try bindgen.DOMString.fromUTF8(switch (address) {
                .ipv4 => "IPv4",
                .ipv6 => "IPv6",
            });
        }

        pub fn getRemoteAddress(this: *This) bun.OOM!?bindgen.DOMString {
            const address = switch (this.core.address(.remote) orelse return null) {
                .ipv4 => |bytes| SocketAddress.initIp4(bytes, 0),
                .ipv6 => |bytes| SocketAddress.initIp6(bytes, 0, 0, 0),
            };
            var buffer: [512]u8 = undefined;
            return try bindgen.DOMString.fromUTF8(address.formatIp(&buffer));
        }

        pub fn getRemotePort(this: *This) ?u16 {
            return this.core.port(.remote);
        }

        inline fn doSocketWrite(this: *This, buffer: []const u8) i32 {
            return this.core.doSocketWrite(buffer);
        }

        pub fn writeMaybeCorked(this: *This, buffer: []const u8) i32 {
            this.ref();
            defer this.deref();
            const written = this.core.writeMaybeCorked(buffer);
            if (this.core.flush_after_write) this.internalFlush();
            return written;
        }

        pub fn writeBufferedFromBindgen(this: *This, context: anytype, args: anytype) bun.JSError!bool {
            if (this.core.socket.isDetached()) {
                this.core.clearBuffered();
                return false;
            }

            const result = try this.writeOrEndBufferedFromBindgen(context, args, false);
            return @as(usize, @intCast(@max(result.wrote, 0))) == result.total;
        }

        pub fn endBufferedFromBindgen(this: *This, context: anytype, args: anytype) bun.JSError!bool {
            if (this.core.socket.isDetached()) {
                this.core.clearBuffered();
                return false;
            }

            this.ref();
            defer this.deref();
            const result = try this.writeOrEndBufferedFromBindgen(context, args, true);
            if (result.wrote == result.total) this.internalFlush();
            return @as(usize, @intCast(@max(result.wrote, 0))) == result.total;
        }

        fn writeOrEndBufferedFromBindgen(this: *This, context: anytype, args: anytype, comptime is_end: bool) bun.JSError!WriteResult {
            const data_argument = args.data orelse return if (this.core.bufferedLength() != 0)
                this.writeOrEndBufferedBytes(&.{}, false, is_end)
            else
                this.finishWithoutWrite(is_end);
            const converted_data = try convertWriteArgument(context, data_argument, args.encoding == null);
            const data = converted_data.value orelse return if (this.core.bufferedLength() != 0)
                this.writeOrEndBufferedBytes(&.{}, false, is_end)
            else
                this.finishWithoutWrite(is_end);
            const encoding = try convertWriteEncoding(context, args.encoding, true) orelse .utf8;

            var holder: ?bun.api.node.StringOrBuffer = null;
            defer if (holder) |*value| value.deinit();
            const bytes: []const u8 = switch (data) {
                .buffer => |*lease| lease.unsafePtr("the converted socket-write argument remains alive until the synchronous write or copy completes"),
                .string => |*string_value| blk: {
                    holder = try bun.api.node.StringOrBuffer.fromBindgenString(string_value, encoding);
                    break :blk (&holder.?).slice();
                },
            };
            return if (this.core.bufferedLength() != 0)
                this.writeOrEndBufferedBytes(bytes, true, is_end)
            else
                this.writeBytesOrEnd(bytes, true, is_end);
        }

        fn writeOrEndBufferedBytes(this: *This, bytes: []const u8, data_present: bool, comptime is_end: bool) bun.OOM!WriteResult {
            const result = try this.core.writeOrEndBufferedBytes(bytes, data_present, is_end);
            if (result.finish) this.markInactive();
            return result;
        }

        const WritePosition = union(enum) {
            absent,
            encoding: bun.api.node.Encoding,
            index: i64,
            invalid,
        };

        fn finishWithoutWrite(this: *This, comptime is_end: bool) WriteResult {
            return this.core.finishWithoutWrite(is_end);
        }

        fn convertWriteArgument(context: anytype, argument: anytype, last: bool) @TypeOf(argument.convert(context)) {
            if (!last) return argument.convert(context);
            const forced = try argument.convertLast(context);
            try context.lease(forced.proof);
            return forced.converted;
        }

        fn convertWritePosition(context: anytype, lazy: anytype, last: bool) bun.JSError!WritePosition {
            const value = lazy orelse return .absent;
            const converted = try convertWriteArgument(context, value, last);
            const position = converted.value orelse return .absent;
            return switch (position) {
                .encoding => |encoding| .{ .encoding = switch (encoding) {
                    inline else => |resolved| @field(bun.api.node.Encoding, @tagName(resolved)),
                } },
                .index => |index| .{ .index = index },
                .invalid => .invalid,
            };
        }

        fn convertWriteEncoding(context: anytype, lazy: anytype, last: bool) bun.JSError!?bun.api.node.Encoding {
            const value = lazy orelse return null;
            const converted = try convertWriteArgument(context, value, last);
            return if (converted.value) |encoding| switch (encoding) {
                inline else => |resolved| @field(bun.api.node.Encoding, @tagName(resolved)),
            } else null;
        }

        fn writeOrEndFromBindgen(
            this: *This,
            context: anytype,
            args: anytype,
            buffer_unwritten_data: bool,
            comptime is_end: bool,
        ) bun.bindgen.CallError(@TypeOf(context))!WriteResult {
            const data_argument = args.data orelse return this.finishWithoutWrite(is_end);
            const converted_data = try convertWriteArgument(context, data_argument, args.offsetOrEncoding == null and args.lengthOrEncoding == null and args.encoding == null);
            var data = converted_data.value orelse return this.finishWithoutWrite(is_end);

            const first = try convertWritePosition(context, args.offsetOrEncoding, args.lengthOrEncoding == null and args.encoding == null);
            const second = try convertWritePosition(context, args.lengthOrEncoding, args.encoding == null);
            const trailing_encoding = try convertWriteEncoding(context, args.encoding, true);

            var encoding = trailing_encoding orelse .utf8;
            var encoding_present = trailing_encoding != null;
            var byte_offset_value: ?i64 = null;
            var byte_length_value: ?i64 = null;

            switch (second) {
                .encoding => |value| {
                    encoding = value;
                    encoding_present = true;
                },
                .index => |value| byte_length_value = value,
                .absent, .invalid => {},
            }
            const first_tag = std.meta.activeTag(first);
            const second_tag = std.meta.activeTag(second);
            if (second_tag != .encoding) switch (first) {
                .encoding => |value| {
                    encoding = value;
                    encoding_present = true;
                },
                .index => |value| byte_offset_value = value,
                .absent, .invalid => {},
            };

            const first_present = first_tag != .absent;
            const second_present = second_tag != .absent;
            const encoding_conflicts = switch (second) {
                .encoding => first_present,
                else => switch (first) {
                    .encoding => second_present,
                    else => encoding_present and (first_present or second_present),
                },
            };
            if (encoding_conflicts) {
                return context.fail(.socket_write_encoding_with_range, {});
            }

            const label = if (comptime is_end) "end" else "write";
            if (first_tag == .invalid) {
                return context.fail(
                    .socket_write_invalid_argument,
                    try bindgen.DOMString.fromUTF8(comptime "Expected byteOffset to be a integer for 'Socket." ++ label ++ "'."),
                );
            }
            if (second_tag == .invalid) {
                return context.fail(
                    .socket_write_invalid_argument,
                    try bindgen.DOMString.fromUTF8(comptime "Expected byteLength to be a integer for 'Socket." ++ label ++ "'."),
                );
            }

            const byte_offset: ?usize = if (byte_offset_value) |value| blk: {
                if (value < 0) {
                    return failWriteRange(context, value, "byteOffset", jsc.MAX_SAFE_INTEGER);
                }
                break :blk @intCast(value);
            } else null;
            const byte_length: ?usize = if (byte_length_value) |value| blk: {
                if (value < 0) {
                    return failWriteRange(context, value, "byteLength", jsc.MAX_SAFE_INTEGER);
                }
                break :blk @intCast(value);
            } else null;

            var input = try SocketWriteInput.init(context, &data, encoding);
            defer input.deinit();
            const bytes = try sliceWriteInput(context, input.bytes, byte_offset, byte_length);
            return this.writeBytesOrEnd(bytes, buffer_unwritten_data, is_end);
        }

        fn writeBytesOrEnd(
            this: *This,
            bytes: []const u8,
            buffer_unwritten_data: bool,
            comptime is_end: bool,
        ) bun.OOM!WriteResult {
            const result = try this.core.writeBytesOrEnd(bytes, buffer_unwritten_data, is_end);
            if (result.finish) this.markInactive();
            return result;
        }

        fn sliceWriteInput(
            context: anytype,
            source: []const u8,
            offset: ?usize,
            length: ?usize,
        ) bun.bindgen.CallError(@TypeOf(context))![]const u8 {
            const byte_offset = offset orelse 0;
            if (byte_offset > source.len) {
                return failWriteRange(context, @intCast(byte_offset), "byteOffset", @intCast(source.len));
            }
            const remaining = source[byte_offset..];
            const byte_length = length orelse remaining.len;
            if (byte_length > remaining.len) {
                return failWriteRange(context, @intCast(byte_length), "byteLength", @intCast(remaining.len));
            }
            return remaining[0..byte_length];
        }

        fn failWriteRange(
            context: anytype,
            value: i64,
            comptime field_name: []const u8,
            max: i64,
        ) bun.bindgen.CallError(@TypeOf(context)) {
            var buffer: [256]u8 = undefined;
            const message = std.fmt.bufPrint(
                &buffer,
                "{f}",
                .{bun.fmt.outOfRange(value, .{ .field_name = field_name, .min = 0, .max = max })},
            ) catch unreachable;
            return context.fail(.socket_write_out_of_range, try bindgen.DOMString.fromUTF8(message));
        }

        fn tryWriteEmptyPacket(this: *This) bool {
            return this.core.tryWriteEmptyPacket();
        }

        fn canEndAfterFlush(this: *This) bool {
            return this.core.canEndAfterFlush();
        }

        fn internalFlush(this: *This) void {
            if (this.core.socket.isDetached()) return;
            if (this.core.internalFlush()) this.markInactive();
        }

        pub fn flush(this: *This) void {
            // `end()` → `internalFlush` → `markInactive` → `closeAndDetach(.normal)`
            // detaches `this.core.socket` and, for TLS, defers the raw close until the
            // peer's close_notify arrives — leaving `is_active` set so the eventual
            // `onClose` can run `handlers.markInactive()`. Without this guard a
            // follow-up `flush()` re-enters `markInactive`, sees the detached
            // socket as closed, and frees `*Handlers` early; the deferred `onClose`
            // then derefs freed memory. Every other `internalFlush` caller already
            // has this check.
            if (this.core.socket.isDetached()) return;
            this.internalFlush();
        }

        pub fn terminate(this: *This) void {
            this.closeAndDetach(.failure);
        }

        pub fn shutdown(this: *This, read: bool) void {
            return this.core.shutdown(read);
        }

        fn close(this: *This, vm: *jsc.VirtualMachine) void {
            // `_handle.close()` is the net.Socket `_destroy()` path — Node emits close_notify
            // once and closes the fd without waiting for the peer's reply. `.fast_shutdown`
            // makes `ssl_handle_shutdown` take the fast branch so the raw close runs
            // synchronously (with `.normal` the SSL layer defers waiting for the peer, but we
            // detach + unref immediately below, orphaning the `us_socket_t`). NOT `.failure`:
            // that arms SO_LINGER{1,0} → RST and drops any data still in the kernel send
            // buffer, which `destroy()` after `write()` must not do.
            this.core.socket.close(.fast_shutdown);
            this.core.socket.detach();
            this.poll_ref.unref(vm);
        }

        pub fn endFromBindgen(this: *This, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!i32 {
            if (this.core.socket.isDetached()) {
                return -1;
            }

            this.ref();
            defer this.deref();

            const result = try this.writeOrEndFromBindgen(context, args, false, true);
            if (result.wrote == result.total) this.internalFlush();
            return result.wrote;
        }

        pub fn dispose(this: *This) i32 {
            if (this.core.socket.isDetached()) {
                return -1;
            }

            this.ref();
            defer this.deref();

            const result = this.finishWithoutWrite(true);
            if (result.wrote == result.total) this.internalFlush();
            return result.wrote;
        }

        fn jsRef(this: *This, vm: *jsc.VirtualMachine) void {
            if (this.core.socket.isDetached()) this.ref_pollref_on_connect = true;
            if (this.core.socket.isDetached()) return;
            this.poll_ref.ref(vm);
        }

        fn jsUnref(this: *This, vm: *jsc.VirtualMachine) void {
            if (this.core.socket.isDetached()) this.ref_pollref_on_connect = false;
            this.poll_ref.unref(vm);
        }

        pub fn deinit(this: *This) void {
            this.markInactive();
            this.detachNativeCallback();
            if (this.wrapper) |*wrapper| wrapper.deinit();

            this.core.deinit();

            this.poll_ref.unref(jsc.VirtualMachine.get());
            // need to deinit event without being attached
            if (this.owned_protos) {
                if (this.protos) |protos| {
                    this.protos = null;
                    default_allocator.free(protos);
                }
            }

            if (this.server_name) |server_name| {
                this.server_name = null;
                default_allocator.free(server_name);
            }

            if (this.connection) |connection| {
                this.connection = null;
                connection.deinit();
            }
            if (this.owned_ssl_ctx) |ctx| {
                BoringSSL.SSL_CTX_free(ctx);
                this.owned_ssl_ctx = null;
            }
            bun.destroy(this);
        }

        pub fn reloadFromBindgen(this: *This, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
            const options_argument = args.options orelse {
                return context.fail(.missing_reload_options, {});
            };

            if (this.core.socket.isDetached()) {
                return;
            }

            const converted = try options_argument.convert(context);
            if (this.core.socket.isDetached()) return;
            const this_handlers = this.handlers orelse return;
            var handlers = try Handlers.fromArgument(this_handlers.globalObject, context, &converted.value.handlers, this_handlers.mode == .server);
            defer handlers.deinit();
            this_handlers.replaceCallbacks(&handlers);
        }

        pub fn getFD(this: *This) i64 {
            return this.core.getFD();
        }

        pub fn getBytesWritten(this: *This) usize {
            return this.core.getBytesWritten();
        }

        /// In-place TCP→TLS upgrade. The underlying `us_socket_t` is
        /// `adoptTLS`'d into the per-VM TLS group with a fresh (or
        /// SecureContext-shared) `SSL_CTX*`. Returns `[raw, tls]` — two
        /// `TLSSocket` wrappers over one fd: `tls` is the encrypted view that
        /// owns dispatch; `raw` has `bypass_tls` set so node:net's
        /// `socket._handle` can pipe pre-handshake/tunnelled bytes via
        /// `us_socket_raw_write`. No second context, no `Handlers.clone()`.
        pub fn upgradeTLSFromBinding(
            this: *This,
            context: anytype,
            args: anytype,
        ) bun.bindgen.CallError(@TypeOf(context))!bindgen.Return(ClassSchema.member("upgradeTLS")) {
            const globalObject = context.viewToken().globalObject();
            if (comptime ssl) return null;
            _ = this.core.socket.socket.get() orelse {
                return context.fail(.socket_not_established, {});
            };
            if (this.isServer()) {
                return context.fail(.server_upgrade_unsupported, {});
            }

            const options_argument = args.options orelse {
                return context.fail(.missing_upgrade_options, {});
            };
            const converted = try options_argument.convert(context);
            const opts = &converted.value;

            var handlers = try Handlers.fromArgument(globalObject, context, &opts.handlers, false);
            var handlers_consumed = false;
            errdefer if (!handlers_consumed) handlers.deinit();

            // Resolve the `SSL_CTX*`. Prefer a passed `SecureContext` (the
            // memoised `tls.createSecureContext` path) so 10k upgrades share
            // one `SSL_CTX_new`; otherwise build an owned one from inline
            // `tls:` options. Either way `owned_ctx` holds one ref we drop in
            // deinit; SSL_new() takes its own.
            var owned_ctx: ?*BoringSSL.SSL_CTX = null;
            errdefer if (owned_ctx) |c| BoringSSL.SSL_CTX_free(c);
            var ssl_opts: ?jsc.API.ServerConfig.SSLConfig = null;
            defer if (ssl_opts) |*cfg| cfg.deinit();

            const vm = globalObject.bunVM();
            if (opts.secure_context) |*secure_context| {
                owned_ctx = secure_context.get(SecureContext).borrow();
                if (opts.tls) |*tls_options| {
                    switch (tls_options.*) {
                        .boolean => {},
                        .object => |*object| ssl_opts = try jsc.API.ServerConfig.SSLConfigEngine.parse(context, object),
                    }
                }
            } else if (opts.tls) |*tls_options| {
                switch (tls_options.*) {
                    .boolean => |enabled| if (enabled) {
                        ssl_opts = jsc.API.ServerConfig.SSLConfig.zero;
                    },
                    .object => |*object| ssl_opts = try jsc.API.ServerConfig.SSLConfigEngine.parse(context, object),
                }
                const cfg = &(ssl_opts orelse return context.fail(.tls_required, {}));
                var create_err: uws.TLSContextFailure = .{};
                const rare_data = try vm.tryRareData();
                owned_ctx = rare_data.sslCtxCache().getOrCreate(cfg, &create_err) orelse {
                    return TLSFailure.fromContextCreation(context, create_err);
                };
            } else {
                return context.fail(.tls_required, {});
            }

            var default_data = try opts.data.toRoot();
            defer default_data.deinit();

            const raw_socket = this.core.socket.socket.get() orelse {
                return context.fail(.socket_not_established, {});
            };

            var original_wrapper = try this.getThisRef(globalObject);
            defer original_wrapper.deinit();
            var original_data = (try This.DataSlot.rootFromOwned(&original_wrapper)) orelse
                try bindgen.Root.initUndefined(context);
            defer original_data.deinit();

            const handlers_ptr = try vm.allocator.create(Handlers);
            handlers_ptr.* = handlers.take();
            handlers_consumed = true;
            var owns_handlers = true;
            defer if (owns_handlers) {
                handlers_ptr.deinit();
                vm.allocator.destroy(handlers_ptr);
            };

            const cfg = if (ssl_opts) |*c| c else null;
            var protos = if (cfg) |c| if (c.protos) |p|
                try bun.default_allocator.dupe(u8, p)
            else
                null else null;
            defer if (protos) |value| bun.default_allocator.free(value);
            var server_name = if (cfg) |c| if (c.server_name) |name|
                try bun.default_allocator.dupeSentinel(u8, name, 0)
            else
                null else null;
            defer if (server_name) |value| bun.default_allocator.free(value);
            const tls = try bun.default_allocator.create(TLSSocket);
            tls.* = .{
                .ref_count = .init(),
                .handlers = handlers_ptr,
                .core = .{ .socket = TLSSocket.Socket.detached, .allocator = bun.default_allocator },
                .connection = if (this.connection) |c| c.clone() else null,
                .protos = protos,
                .server_name = server_name,
                .owned_ssl_ctx = owned_ctx,
            };
            protos = null;
            server_name = null;
            owned_ctx = null;
            var owns_tls = true;
            defer if (owns_tls) tls.deref();

            const raw = try bun.default_allocator.create(TLSSocket);
            raw.* = .{
                .ref_count = .init(),
                .handlers = null,
                .core = .{ .socket = TLSSocket.Socket.detached, .allocator = bun.default_allocator },
                .connection = null,
                .protos = null,
            };
            raw.core.flags.bypass_tls = true;
            var owns_raw = true;
            defer if (owns_raw) raw.deref();
            var tls_wrapper = try TLSSocket.prepareWrapper(globalObject);
            defer tls_wrapper.deinit();
            var raw_wrapper = try TLSSocket.prepareWrapper(globalObject);
            defer raw_wrapper.deinit();
            const result = try context.engineIn("Socket", "socketTLSUpgradeResult").call(.{
                .raw = raw_wrapper.reference.operand(context),
                .tls = tls_wrapper.reference.operand(context),
            });

            const sni: ?[*:0]const u8 = if (cfg) |c| if (c.server_name) |name| name.ptr else null else null;
            const group = vm.rareData().bunConnectGroup(vm, true);
            const new_raw = raw_socket.adoptTLS(group, .bun_socket_tls, tls.owned_ssl_ctx.?, sni, @sizeOf(*anyopaque), @sizeOf(*anyopaque)) orelse {
                const err = BoringSSL.ERR_get_error();
                defer if (err != 0) BoringSSL.ERR_clear_error();
                if (err != 0 and !globalObject.hasException()) {
                    return TLSFailure.fromCode(context, err);
                }
                if (!globalObject.hasException()) {
                    return context.fail(.tls_upgrade_failed, {});
                }
                return error.JSError;
            };

            // Retire the original TCP wrapper before any TLS dispatch can run
            // back into JS — it must not see two live owners on one fd. Its
            // *Handlers are TRANSFERRED to the raw twin (the `[raw, tls]`
            // contract is: index 0 keeps the pre-upgrade callbacks and sees
            // ciphertext, index 1 gets the new ones and sees plaintext).
            const raw_handlers = this.handlers;
            this.handlers = null;
            // Preserve `socket.unref()` across the upgrade — node:tls callers
            // that unref the underlying TCP socket before upgrading must not
            // suddenly hold the loop open via the TLS wrapper.
            const was_reffed = this.poll_ref.isActive();
            if (this.core.flags.is_active) {
                this.poll_ref.disable();
                this.core.flags.is_active = false;
                // Do NOT markInactive raw_handlers — ownership of the
                // active_connections=1 it holds is transferring to `raw`.
                this.wrapper_has_pending_activity = false;
            }
            defer this.deref();
            this.detachNativeCallback();
            this.core.socket.detach();

            // Only NOW is it safe for dispatch to fire: ext + kind point at `tls`.
            new_raw.ext(*TLSSocket).* = tls;
            tls.core.socket = TLSSocket.Socket.from(new_raw);

            // The `raw` half — same `us_socket_t*`, ORIGINAL pre-upgrade
            // *Handlers, writes bypass SSL. Dispatch reaches it via the
            // `ssl_raw_tap` ciphertext hook, never via the ext slot.
            raw.handlers = raw_handlers;
            raw.core.socket = TLSSocket.Socket.from(new_raw);
            raw.core.flags.is_active = true;
            var tls_ref = tls_wrapper.commit(tls);
            defer tls_ref.deinit();
            owns_tls = false;
            var raw_ref = raw_wrapper.commit(raw);
            defer raw_ref.deinit();
            owns_raw = false;
            tls.ref();
            raw.ref();
            tls.twin = raw;
            new_raw.setSslRawTap(true);

            TLSSocket.DataSlot.setRootOnOwned(&tls_ref, &default_data);
            // `raw` keeps the pre-upgrade `data` so its callbacks emit on the
            // original net.Socket, not the TLS one.
            TLSSocket.DataSlot.setRootOnOwned(&raw_ref, &original_data);

            tls.markActive();
            owns_handlers = false;
            if (was_reffed) tls.poll_ref.ref(vm);

            // Fire onOpen with the right `this`, then send ClientHello. Doing
            // it before ext was repointed would have ALPN/onOpen land in the
            // dead TCPSocket.
            tls.onOpen(tls.core.socket);
            if (tls.core.socket.socket.get()) |socket| {
                if (socket == new_raw and !tls.core.socket.isClosed()) socket.startTLSHandshake();
            }

            return result;
        }

        pub const disableRenegotiation = if (ssl) tls_socket_functions.disableRenegotiation else tcpNoop;
        pub const isSessionReused = if (ssl) tls_socket_functions.isSessionReused else tcp_socket_is_session_reused;
        pub const setVerifyMode = if (ssl) tls_socket_functions.setVerifyMode else tcpSetVerifyMode;
        pub const renegotiate = if (ssl) tls_socket_functions.renegotiate else tcpRenegotiate;
        pub const getTLSTicket = if (ssl) tls_socket_functions.getTLSTicket else tcpOptionalBytes;
        pub const setSession = if (ssl) tls_socket_functions.setSession else tcpSetSession;
        pub const getSession = if (ssl) tls_socket_functions.getSession else tcpOptionalBytes;
        pub const getALPNProtocol = if (ssl) tls_socket_functions.getALPNProtocol else tcpGetALPNProtocol;
        pub const exportKeyingMaterial = if (ssl) tls_socket_functions.exportKeyingMaterial else tcpExportKeyingMaterial;
        pub const getEphemeralKeyInfo = if (ssl) tls_socket_functions.getEphemeralKeyInfo else tcpGetEphemeralKeyInfo;
        pub const getCipher = if (ssl) tls_socket_functions.getCipher else tcpGetCipher;
        pub const getTLSPeerFinishedMessage = if (ssl) tls_socket_functions.getTLSPeerFinishedMessage else tcpOptionalBytes;
        pub const getTLSFinishedMessage = if (ssl) tls_socket_functions.getTLSFinishedMessage else tcpOptionalBytes;
        pub const getSharedSigalgs = if (ssl) tls_socket_functions.getSharedSigalgs else tcpGetSharedSigalgs;
        pub const getTLSVersion = if (ssl) tls_socket_functions.getTLSVersion else tcpGetTLSVersion;
        pub const setMaxSendFragment = if (ssl) tls_socket_functions.setMaxSendFragment else tcpSetMaxSendFragment;
        pub const getPeerCertificate = if (ssl) tls_socket_functions.getPeerCertificate else tcpGetPeerCertificate;
        pub const getCertificate = if (ssl) tls_socket_functions.getCertificate else tcpGetCertificate;
        pub const getPeerX509Certificate = if (ssl) tls_socket_functions.getPeerX509Certificate else tcpGetCertificate;
        pub const getX509Certificate = if (ssl) tls_socket_functions.getX509Certificate else tcpGetCertificate;
        pub const getServername = if (ssl) tls_socket_functions.getServername else tcpGetServername;
        pub const setServername = if (ssl) tls_socket_functions.setServername else tcpSetServername;

        fn tcpNoop(_: *This) void {}

        fn tcpRenegotiate(_: *This, context: anytype) bun.bindgen.CallError(@TypeOf(context))!void {}

        fn tcpOptionalBytes(_: *This) bun.OOM!?bindgen.OwnedBytes {
            return null;
        }

        fn tcpGetSharedSigalgs(_: *This, comptime OptionalSequence: type) bun.OOM!OptionalSequence {
            return null;
        }

        fn tcpGetEphemeralKeyInfo(_: *This) ?tls_socket_functions.EphemeralKeyInfo {
            return null;
        }

        fn tcpGetCipher(_: *This) ?tls_socket_functions.CipherInfo {
            return null;
        }

        fn tcpGetCertificate(_: *This) ?*BoringSSL.X509 {
            return null;
        }

        fn tcp_socket_is_session_reused(_: *This) bool {
            return false;
        }

        fn tcpGetALPNProtocol(_: *This) bun.OOM!?bindgen.DOMString {
            return null;
        }

        fn tcpGetTLSVersion(_: *This) bun.OOM!?bindgen.DOMString {
            return null;
        }

        fn tcpGetServername(_: *This) bun.OOM!?bindgen.DOMString {
            return null;
        }

        fn tcpSetVerifyMode(_: *This, _: bool, _: bool) void {}

        fn tcpSetSession(_: *This, context: anytype, _: anytype) bun.bindgen.CallError(@TypeOf(context))!void {}

        fn tcpExportKeyingMaterial(_: *This, context: anytype, _: anytype) bun.bindgen.CallError(@TypeOf(context))!?bindgen.OwnedBytes {
            return null;
        }

        fn tcpSetMaxSendFragment(_: *This, _: f64) bool {
            return false;
        }

        fn tcpGetPeerCertificate(_: *This, _: ?bool) ?tls_socket_functions.Certificate {
            return null;
        }

        fn tcpSetServername(_: *This, context: anytype, _: anytype) bun.bindgen.CallError(@TypeOf(context))!void {}
    };
}

pub const TCPSocket = NewSocket(false);
pub const TLSSocket = NewSocket(true);

// We use this direct callbacks on HTTP2 when available
const NativeCallbacks = union(enum) {
    h2: *H2FrameParser,
    none,

    pub fn onData(this: NativeCallbacks, data: []const u8) bool {
        switch (this) {
            .h2 => |h2| {
                h2.onNativeRead(data) catch return false; // TODO: properly propagate exception upwards
                return true;
            },
            .none => return false,
        }
    }
    pub fn onWritable(this: NativeCallbacks) bool {
        switch (this) {
            .h2 => |h2| {
                h2.onNativeWritable();
                return true;
            },
            .none => return false,
        }
    }
};

const log = Output.scoped(.Socket, .visible);

const WriteResult = SocketCore.WriteResult;

/// Unified socket mode replacing the old is_server bool + TLSMode pair.
pub const SocketMode = enum {
    /// Default — TLS client or non-TLS socket
    client,
    /// Listener-owned server. TLS (if any) configured at the listener level.
    server,
    /// Duplex upgraded to TLS server role. Not listener-owned —
    /// markInactive uses client lifecycle path.
    duplex_server,

    /// Returns true for any mode that acts as a TLS server (ALPN, handshake direction).
    /// Both .server and .duplex_server present as server to peers.
    pub fn isServer(this: SocketMode) bool {
        return this == .server or this == .duplex_server;
    }
};

pub const DuplexUpgradeContext = struct {
    ref_count: RefCount = .init(),
    deinit_requested: bool = false,
    upgrade: UpgradedDuplex,
    // We only us a tls and not a raw socket when upgrading a Duplex, Duplex dont support socketpairs
    tls: ?*TLSSocket,
    // task used to deinit the context in the next tick, vm is used to enqueue the task
    vm: *jsc.VirtualMachine,
    task: jsc.AnyTask,
    task_event: EventState = .StartTLS,
    /// Config to build a fresh `SSL_CTX` from (legacy `{ca,cert,key}` callers).
    /// Mutually exclusive with `owned_ctx` — `runEvent` prefers `owned_ctx`.
    ssl_config: ?jsc.API.ServerConfig.SSLConfig,
    /// One ref on a prebuilt `SSL_CTX` (from `opts.tls.secureContext` — the
    /// memoised `tls.createSecureContext` path). Adopted by `startTLSWithCTX`
    /// on success, freed in `deinit` if Close races ahead of StartTLS.
    owned_ctx: ?*BoringSSL.SSL_CTX = null,
    is_open: bool = false,
    mode: SocketMode = .client,

    const RefCount = bun.ptr.RefCount(@This(), "ref_count", destroy, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;

    pub const EventState = enum(u8) {
        StartTLS,
        Close,
    };

    pub const new = bun.TrivialNew(DuplexUpgradeContext);

    pub fn onOpen(this: *DuplexUpgradeContext) void {
        this.is_open = true;
        const socket = TLSSocket.Socket.fromDuplex(&this.upgrade);

        if (this.tls) |tls| {
            tls.onOpen(socket);
        }
    }

    pub fn onData(this: *DuplexUpgradeContext, decoded_data: []const u8) void {
        const socket = TLSSocket.Socket.fromDuplex(&this.upgrade);

        if (this.tls) |tls| {
            tls.onData(socket, decoded_data);
        }
    }

    pub fn onHandshake(this: *DuplexUpgradeContext, success: bool, ssl_error: uws.us_bun_verify_error_t) void {
        const socket = TLSSocket.Socket.fromDuplex(&this.upgrade);

        if (this.tls) |tls| {
            tls.onHandshake(socket, @intFromBool(success), ssl_error);
        }
    }

    pub fn onEnd(this: *DuplexUpgradeContext) void {
        const socket = TLSSocket.Socket.fromDuplex(&this.upgrade);
        if (this.tls) |tls| {
            tls.onEnd(socket);
        }
    }

    pub fn onWritable(this: *DuplexUpgradeContext) void {
        const socket = TLSSocket.Socket.fromDuplex(&this.upgrade);

        if (this.tls) |tls| {
            tls.onWritable(socket);
        }
    }

    pub fn onError(this: *DuplexUpgradeContext, failure: SocketFailure) void {
        if (this.is_open) {
            if (this.tls) |tls| {
                tls.handleError(failure);
            }
        } else {
            if (this.tls) |tls| {
                // Pre-open error (e.g. the duplex emitted non-Buffer data
                // before the queued `.StartTLS` task ran). `handleConnectError`
                // → `markInactive` frees `tls.handlers`; null `tls` so the
                // still-queued `.StartTLS` → `onOpen` — and any further
                // duplex events — skip the TLSSocket instead of calling
                // `getHandlers()` on the freed allocation.
                this.tls = null;
                tls.handleConnectError(bun.sys.Error.fromCode(.CONNREFUSED, .connect)) catch {};
            }
        }
    }

    pub fn onTimeout(this: *DuplexUpgradeContext) void {
        const socket = TLSSocket.Socket.fromDuplex(&this.upgrade);

        if (this.tls) |tls| {
            tls.onTimeout(socket);
        }
    }

    pub fn onClose(this: *DuplexUpgradeContext) void {
        const socket = TLSSocket.Socket.fromDuplex(&this.upgrade);

        if (this.tls) |tls| {
            // `tls.onClose` consumes the +1 we hold (its `defer this.deref()`
            // is the ext-slot/owner pin). Null our pointer first so the
            // `deinitInNextTick` → `deinit` path doesn't deref it a second
            // time — that's the over-deref behind the cross-file
            // `TLSSocket.finalize` use-after-poison. It also means a throw
            // from `duplex.end()` (called right after this returns via
            // `UpgradedDuplex.onClose` → `callWriteOrEnd`) hits the null-check
            // in `onError` instead of reading the Handlers that `tls.onClose`
            // → `markInactive` just freed.
            this.tls = null;
            tls.onClose(socket, 0, null);
        }

        this.deinitInNextTick();
    }

    fn runEvent(this: *DuplexUpgradeContext) void {
        defer this.deref();
        switch (this.task_event) {
            .StartTLS => {
                // A pre-open error (onError's `!is_open` branch) may have
                // already fired the connect-error callback, freed
                // `tls.handlers`, and nulled `tls` while this task was
                // queued. There is nothing to open in that case — and
                // nothing else will reach `deinit()` since the SSLWrapper
                // (whose close callback normally schedules it) is never
                // created — so tear everything down here instead of
                // spinning up a wrapper that would dispatch `onOpen` into
                // the dead socket.
                if (this.tls == null) {
                    this.deinit();
                    return;
                }
                log("DuplexUpgradeContext.startTLS mode={s}", .{@tagName(this.mode)});
                const is_client = this.mode == .client;
                const started: anyerror!void = if (this.owned_ctx) |ctx| blk: {
                    // Transfer the ref into SSLWrapper; null first so the
                    // failure path / deinit don't double-free it.
                    this.owned_ctx = null;
                    break :blk this.upgrade.startTLSWithCTX(ctx, is_client);
                } else if (this.ssl_config) |config|
                    this.upgrade.startTLS(config, is_client)
                else {};
                started catch |err| {
                    if (this.tls) |tls| {
                        const global = tls.getHandlers().globalObject;
                        this.tls = null;
                        const failure: TLSSocket.ConnectFailure = if (err == error.OutOfMemory)
                            .out_of_memory
                        else
                            .{ .system = bun.sys.Error.fromCode(.CONNREFUSED, .connect) };
                        tls.handleConnectFailure(failure) catch |delivery_error| global.reportActiveExceptionAsUnhandled(delivery_error);
                    }
                    this.deinit();
                    return;
                };
                if (this.ssl_config) |*cfg| {
                    cfg.deinit();
                    this.ssl_config = null;
                }
            },
            // Previously this only called `upgrade.close()` and never `deinit`,
            // leaking the SSLWrapper, the strong refs, and this struct itself
            // for every duplex-upgraded TLS socket.
            .Close => this.deinit(),
        }
    }

    fn deinitInNextTick(this: *DuplexUpgradeContext) void {
        if (this.deinit_requested or this.task_event == .Close) return;
        this.task_event = .Close;
        this.ref();
        this.vm.enqueueTask(jsc.Task.init(&this.task));
    }

    fn startTLS(this: *DuplexUpgradeContext) void {
        this.task_event = .StartTLS;
        this.ref();
        this.vm.enqueueTask(jsc.Task.init(&this.task));
    }

    fn deinit(this: *DuplexUpgradeContext) void {
        if (this.deinit_requested) return;
        this.deinit_requested = true;
        this.deref();
    }

    fn destroy(this: *DuplexUpgradeContext) void {
        if (this.tls) |tls| {
            this.tls = null;
            tls.deref();
        }
        if (this.ssl_config) |*cfg| {
            // Close raced ahead of StartTLS — drop the unconsumed config.
            cfg.deinit();
            this.ssl_config = null;
        }
        if (this.owned_ctx) |ctx| {
            this.owned_ctx = null;
            BoringSSL.SSL_CTX_free(ctx);
        }
        this.upgrade.deinit();
        bun.destroy(this);
    }
};

pub fn jsUpgradeDuplexToTLS(
    context: bun.bindgen.CallContext(UpgradeDuplexToTLSSchema),
    args: bun.bindgen.Args(UpgradeDuplexToTLSSchema),
) bun.bindgen.CallError(UpgradeDuplexToTLSSchema)!bindgen.Return(UpgradeDuplexToTLSSchema) {
    const globalObject = context.viewToken().globalObject();
    var duplex = try args.duplex.toOwned();
    defer duplex.deinit();
    const opts = &args.options;
    // is_server=false because these handlers are standalone
    // allocations (not embedded in a Listener). The mode field on Handlers
    // controls lifecycle (markInactive expects a Listener parent when .server).
    // The TLS direction (client vs server) is controlled by DuplexUpgradeContext.mode.
    var handlers = try Handlers.fromArgument(globalObject, context, &opts.handlers, false);
    var handlers_consumed = false;
    errdefer if (!handlers_consumed) handlers.deinit();

    var owned_ctx: ?*BoringSSL.SSL_CTX = null;
    errdefer if (owned_ctx) |c| BoringSSL.SSL_CTX_free(c);
    if (opts.secure_context) |*secure_context| {
        owned_ctx = secure_context.get(SecureContext).borrow();
    }

    var ssl_opts: ?jsc.API.ServerConfig.SSLConfig = null;
    errdefer if (ssl_opts) |*c| c.deinit();
    if (opts.tls) |*tls_options| {
        ssl_opts = switch (tls_options.*) {
            .boolean => |enabled| if (enabled) jsc.API.ServerConfig.SSLConfig.zero else null,
            .object => |*tls_config| try jsc.API.ServerConfig.SSLConfigEngine.parse(context, tls_config),
        };
    }
    if (owned_ctx == null and ssl_opts == null) {
        return context.fail(.tls_required, {});
    }
    const socket_config: ?*jsc.API.ServerConfig.SSLConfig = if (ssl_opts) |*c| c else null;

    var default_data = try opts.data.toRoot();
    defer default_data.deinit();

    const handlers_allocator = handlers.vm.allocator;
    const handlers_ptr = try handlers_allocator.create(Handlers);
    handlers_ptr.* = handlers.take();
    handlers_consumed = true;
    var owns_handlers = true;
    defer if (owns_handlers) {
        handlers_ptr.deinit();
        handlers_allocator.destroy(handlers_ptr);
    };
    // Set mode to duplex_server so TLSSocket.isServer() returns true for ALPN server mode
    // without affecting markInactive lifecycle (which requires a Listener parent).
    handlers_ptr.mode = if (opts.is_server) .duplex_server else .client;
    var protos = if (socket_config) |cfg| if (cfg.protos) |p|
        try bun.default_allocator.dupe(u8, p)
    else
        null else null;
    defer if (protos) |value| bun.default_allocator.free(value);
    var server_name = if (socket_config) |cfg| if (cfg.server_name) |sn|
        try bun.default_allocator.dupeSentinel(u8, sn, 0)
    else
        null else null;
    defer if (server_name) |value| bun.default_allocator.free(value);
    const duplexContext = try bun.default_allocator.create(DuplexUpgradeContext);
    var owns_context_allocation = true;
    defer if (owns_context_allocation) bun.default_allocator.destroy(duplexContext);

    const tls = try bun.default_allocator.create(TLSSocket);
    tls.* = .{
        .ref_count = .init(),
        .handlers = handlers_ptr,
        .core = .{ .socket = TLSSocket.Socket.detached, .allocator = bun.default_allocator },
        .connection = null,
        .protos = protos,
        .server_name = server_name,
        .owned_protos = true,
    };
    protos = null;
    server_name = null;
    var owns_tls = true;
    defer if (owns_tls) tls.deref();
    var tls_ref = try tls.getThisRef(globalObject);
    owns_tls = false;
    defer tls_ref.deinit();
    TLSSocket.DataSlot.setRootOnOwned(&tls_ref, &default_data);

    duplexContext.* = .{
        .upgrade = undefined,
        .tls = tls,
        .vm = globalObject.bunVM(),
        .task = undefined,
        // When `owned_ctx` is set, `runEvent` builds from it and ignores
        // `ssl_config` for SSL_CTX construction; servername/ALPN already
        // copied onto `tls` above so the config's only remaining use is the
        // legacy build path.
        .ssl_config = if (owned_ctx == null) if (socket_config) |c| c.* else null else null,
        .owned_ctx = owned_ctx,
        .mode = if (opts.is_server) .duplex_server else .client,
    };
    owns_context_allocation = false;
    // Ownership of the SSL_CTX ref transferred to DuplexUpgradeContext.
    owned_ctx = null;
    // ssl_opts is moved into duplexContext.ssl_config when owned_ctx == null;
    // otherwise it was only used for protos/server_name and is freed here.
    if (duplexContext.ssl_config == null) {
        if (socket_config) |c| c.deinit();
    }
    // Disarm the errdefer at L2013 — either moved into duplexContext or just
    // freed above; both the move-target and the deinit case must not see it
    // freed again on a later throw.
    ssl_opts = null;
    tls.ref();

    duplexContext.task = jsc.AnyTask.New(DuplexUpgradeContext, DuplexUpgradeContext.runEvent).init(duplexContext);
    duplexContext.upgrade = UpgradedDuplex.fromOwnedDuplex(globalObject, &duplex, duplexContext);

    duplexContext.ref();
    defer duplexContext.deref();
    errdefer {
        tls.wrapper_has_pending_activity = false;
        tls.handlers = null;
        duplexContext.deinit();
    }

    var events = try duplexContext.upgrade.getJSHandlers(context);
    defer events.deinit();
    const result = try context.engineIn("NodeSocket", "socketDuplexUpgradeResult").call(.{
        .socket = tls_ref.operand(context),
        .events = events.operand(context),
    });
    tls.core.socket = TLSSocket.Socket.fromDuplex(&duplexContext.upgrade);
    tls.markActive();
    owns_handlers = false;
    tls.poll_ref.ref(globalObject.bunVM());
    duplexContext.startTLS();
    return result;
}

pub fn jsIsNamedPipeSocket(
    _: bun.bindgen.CallContext(IsNamedPipeSocketSchema),
    args: bun.bindgen.Args(IsNamedPipeSocketSchema),
) bun.JSError!bool {
    return switch (args.socket) {
        .tcp => |socket| socket.get(TCPSocket.JSBinding).socket.get().core.socket.isNamedPipe(),
        .tls => |socket| socket.get(TLSSocket.JSBinding).socket.get().core.socket.isNamedPipe(),
    };
}

pub fn jsGetBufferedAmount(
    _: bun.bindgen.CallContext(GetBufferedAmountSchema),
    args: bun.bindgen.Args(GetBufferedAmountSchema),
) bun.JSError!usize {
    return switch (args.socket) {
        .tcp => |socket| socket.get(TCPSocket.JSBinding).socket.get().core.bufferedLength(),
        .tls => |socket| socket.get(TLSSocket.JSBinding).socket.get().core.bufferedLength(),
    };
}

pub fn jsCreateSocketPair(
    context: bun.bindgen.CallContext(CreateSocketPairSchema),
    _: bun.bindgen.Args(CreateSocketPairSchema),
) bindgen.CallError(CreateSocketPairSchema)!bindgen.Return(CreateSocketPairSchema) {
    if (Environment.isWindows) {
        return context.fail(.unsupported_platform, {});
    }

    var fds_: [2]std.c.fd_t = .{ 0, 0 };
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds_);
    if (rc != 0) {
        const err = bun.sys.Error.fromCode(bun.sys.getErrno(rc), .socketpair);
        return context.fail(.system, try bindgen.SystemError.fromSysError(err));
    }

    _ = bun.FD.fromNative(fds_[0]).updateNonblocking(true);
    _ = bun.FD.fromNative(fds_[1]).updateNonblocking(true);

    const fds: [2]i32 = .{ @intCast(fds_[0]), @intCast(fds_[1]) };
    return try bindgen.Return(CreateSocketPairSchema).fromOwnedSlice(&fds);
}

pub fn jsSetSocketOptions(
    context: bun.bindgen.CallContext(SetSocketOptionsSchema),
    args: bun.bindgen.Args(SetSocketOptionsSchema),
) bindgen.CallError(SetSocketOptionsSchema)!void {
    const socket = args.socket.get(TCPSocket.JSBinding).socket.get();
    const file_descriptor = socket.core.socket.fd();

    if (bun.Environment.isPosix) {
        if (args.kind == 1) {
            const result = bun.sys.setsockopt(file_descriptor, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, args.size);
            if (result.asErr()) |err| {
                return context.fail(.system, try bindgen.SystemError.fromSysError(err));
            }
        } else {
            const result = bun.sys.setsockopt(file_descriptor, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, args.size);
            if (result.asErr()) |err| {
                return context.fail(.system, try bindgen.SystemError.fromSysError(err));
            }
        }
    }
}

const string = []const u8;

const std = @import("std");
const tls_socket_functions_module = @import("./TLSEngine.zig");
const TLSFailure = @import("./TLSFailure.zig");
const H2FrameParser = @import("../api/bun/h2_frame_parser.zig").H2FrameParser;

const bun = @import("bun");
const bindgen = bun.bindgen;
const SocketCore = @import("network_core").socket;
const Async = bun.Async;
const Environment = bun.Environment;
const Output = bun.Output;
const default_allocator = bun.default_allocator;
const uws = bun.uws;
const BoringSSL = bun.BoringSSL.c;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const SocketFailure = @import("./SocketFailure.zig").SocketFailure;
const SecureContext = jsc.API.SecureContext;
const X509 = @import("../api/bun/x509.zig");

const NodeSocketBindings = bun.bindgen.Module("NodeSocket");
const UpgradeDuplexToTLSSchema = NodeSocketBindings.function("upgradeDuplexToTLS");
const IsNamedPipeSocketSchema = NodeSocketBindings.function("isNamedPipeSocket");
const GetBufferedAmountSchema = NodeSocketBindings.function("getBufferedAmount");
const UpgradeDuplexToTLSBinding = bun.bindgen.Fn(UpgradeDuplexToTLSSchema, jsUpgradeDuplexToTLS);
const IsNamedPipeSocketBinding = bun.bindgen.Fn(IsNamedPipeSocketSchema, jsIsNamedPipeSocket);
const GetBufferedAmountBinding = bun.bindgen.Fn(GetBufferedAmountSchema, jsGetBufferedAmount);
const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const CreateSocketPairSchema = InternalTestingBindings.function("createSocketPair");
const SetSocketOptionsSchema = InternalTestingBindings.function("setSocketOptions");
const CreateSocketPairBinding = bun.bindgen.Fn(CreateSocketPairSchema, jsCreateSocketPair);
const SetSocketOptionsBinding = bun.bindgen.Fn(SetSocketOptionsSchema, jsSetSocketOptions);

comptime {
    _ = UpgradeDuplexToTLSBinding;
    _ = IsNamedPipeSocketBinding;
    _ = GetBufferedAmountBinding;
    _ = CreateSocketPairBinding;
    _ = SetSocketOptionsBinding;
}
