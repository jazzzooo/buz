/// WebSocketUpgradeClient handles the HTTP upgrade process for WebSocket connections.
///
/// This module implements the client-side of the WebSocket protocol handshake as defined in RFC 6455.
/// It manages the initial HTTP request that upgrades the connection from HTTP to WebSocket protocol.
///
/// The process works as follows:
/// 1. Client sends an HTTP request with special headers indicating a WebSocket upgrade
/// 2. Server responds with HTTP 101 Switching Protocols
/// 3. After successful handshake, the connection is handed off to the WebSocket implementation
///
/// This client handles both secure (TLS) and non-secure connections.
/// It manages connection timeouts, protocol negotiation, and error handling during the upgrade process.
///
/// Note: This implementation is only used during the initial connection phase.
/// Once the WebSocket connection is established, control is passed to the WebSocket client.
///
/// For more information about the WebSocket handshaking process, see:
/// - RFC 6455 (The WebSocket Protocol): https://datatracker.ietf.org/doc/html/rfc6455#section-1.3
/// - MDN WebSocket API: https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API
/// - WebSocket Handshake: https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_servers#the_websocket_handshake
pub fn NewHTTPUpgradeClient(comptime ssl: bool) type {
    return struct {
        pub const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
        pub const ref = RefCount.ref;
        pub const deref = RefCount.deref;
        pub const Socket = uws.NewSocketHandler(ssl);

        pub const DeflateNegotiationResult = struct {
            enabled: bool = false,
            params: WebSocketDeflate.Params = .{},
        };

        ref_count: RefCount,
        tcp: Socket,
        globalThis: *jsc.JSGlobalObject,
        outgoing_websocket: ?*CppWebSocket,
        input_body_buf: []u8 = &[_]u8{},
        to_send: []const u8 = "",
        read_length: usize = 0,
        headers_buf: [128]PicoHTTP.Header = undefined,
        body: std.ArrayList(u8) = .empty,
        hostname: [:0]const u8 = "",
        poll_ref: Async.KeepAlive = Async.KeepAlive.init(),
        state: State = .initializing,
        subprotocols: bun.StringSet,

        /// Proxy state (null when not using proxy)
        proxy: ?WebSocketProxy = null,

        // TLS options (full SSLConfig for complete TLS customization)
        ssl_config: ?*SSLConfig = null,

        /// `us_ssl_ctx_t` built from `ssl_config` when it carries a custom CA.
        /// This client owns one ref; the connected `WebSocket` retains its own
        /// ref before the upgrade client releases this one.
        secure: ?*uws.SslCtx = null,

        // Expected Sec-WebSocket-Accept value for handshake validation per RFC 6455 §4.2.2.
        // This is base64(SHA-1(Sec-WebSocket-Key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")).
        expected_accept: [28]u8 = @splat(0),

        // Whether the upgrade request offered `permessage-deflate`. When this is
        // false (opt-out via `perMessageDeflate: false`) and the server responds
        // with a `Sec-WebSocket-Extensions` header anyway, `processResponse`
        // fails the handshake per RFC 6455 §9.1 — matching upstream `ws`.
        offered_permessage_deflate: bool = true,

        const State = enum {
            initializing,
            reading,
            failed,
            // Proxy states
            proxy_handshake, // Sent CONNECT, waiting for 200
            proxy_tls_handshake, // TLS inside tunnel (for wss:// through proxy)
            done, // WebSocket upgrade complete, forwarding data through tunnel
        };

        const HTTPClient = @This();

        pub const onOpen = handleOpen;
        pub const onClose = handleClose;
        pub const onData = handleData;
        pub const onWritable = handleWritable;
        pub const onTimeout = handleTimeout;
        pub const onLongTimeout = handleTimeout;
        pub const onConnectError = handleConnectError;
        pub const onEnd = handleEnd;
        pub const onHandshake = handleHandshake;

        fn deinit(this: *HTTPClient) void {
            this.clearData();
            bun.debugAssert(this.tcp.isDetached());
            bun.destroy(this);
        }

        fn bindConnect(
            context: bun.bindgen.CallContext(ConnectSchema),
            args: *bun.bindgen.Args(ConnectSchema),
        ) bun.JSError!bun.bindgen.Return(ConnectSchema) {
            return connectFromBinding(context, args);
        }

        fn connectFromBinding(
            context: anytype,
            args: *bun.bindgen.Args(ConnectSchema),
        ) bun.JSError!bun.bindgen.Return(ConnectSchema) {
            const global = context.viewToken().globalObject();
            const vm = global.bunVM();
            const websocket = args.outgoing;
            const port = args.port;
            const proxy_port = args.proxyPort;
            const target_is_secure = args.targetIsSecure;
            const offer_permessage_deflate = args.offerPerMessageDeflate;
            const ssl_config = if (args.sslConfig) |*config| config.get() else null;

            bun.assert(vm.event_loop_handle != null);
            bun.assert(args.headerNames.len() == args.headerValues.len());
            bun.assert(args.proxyHeaderNames.len() == args.proxyHeaderValues.len());

            // Decode the borrowed binding strings before building request buffers.
            const allocator = bun.default_allocator;

            var host_slice = try args.host.toUTF8(allocator);
            defer host_slice.deinit();
            var pathname_slice = try args.path.toUTF8(allocator);
            defer pathname_slice.deinit();
            var client_protocol_slice = try args.protocol.toUTF8(allocator);
            defer client_protocol_slice.deinit();

            const extra_headers = try Headers8Bit.init(allocator, args.headerNames, args.headerValues);
            defer extra_headers.deinit();

            var proxy_host_slice: ?bun.String.Slice = null;
            defer if (proxy_host_slice) |s| s.deinit();
            if (args.proxyHost) |proxy_host| proxy_host_slice = try proxy_host.toUTF8(allocator);

            var target_authorization_slice: ?bun.String.Slice = null;
            defer if (target_authorization_slice) |s| s.deinit();
            if (args.targetAuthorization) |authorization| target_authorization_slice = try authorization.toUTF8(allocator);

            var unix_socket_path_slice: ?bun.String.Slice = null;
            defer if (unix_socket_path_slice) |s| s.deinit();
            if (args.unixSocketPath) |path| unix_socket_path_slice = try path.toUTF8(allocator);

            const using_proxy = args.proxyHost != null;

            // Check if user provided a custom protocol for subprotocols validation
            var protocol_for_subprotocols: []const u8 = client_protocol_slice.slice();
            for (extra_headers.names(), extra_headers.values()) |name, value| {
                if (strings.eqlCaseInsensitiveASCII(name, "sec-websocket-protocol", true)) {
                    protocol_for_subprotocols = value;
                    break;
                }
            }

            var encoded_key: [24]u8 = undefined;
            const request_key = UpgradeRequest.findValidKey(extra_headers.names(), extra_headers.values()) orelse
                std.base64.standard.Encoder.encode(&encoded_key, &vm.rareData().nextUUID().bytes);
            const request_result = try UpgradeRequest.buildRequestBody(
                allocator,
                request_key,
                pathname_slice.slice(),
                target_is_secure,
                host_slice.slice(),
                port,
                client_protocol_slice.slice(),
                extra_headers.names(),
                extra_headers.values(),
                if (target_authorization_slice) |s| s.slice() else null,
                offer_permessage_deflate,
            );
            const body = request_result.body;

            // Build proxy state if using proxy
            // The CONNECT request copies the temporary proxy authorization and headers.
            var proxy_state: ?WebSocketProxy = null;
            var connect_request: []u8 = &[_]u8{};
            var transferred = false;
            defer if (!transferred) {
                if (proxy_state) |*proxy| proxy.deinit() else allocator.free(body);
                allocator.free(connect_request);
            };
            if (using_proxy) {
                // Parse proxy authorization (temporary, freed after building CONNECT request)
                var proxy_auth_slice: ?[]const u8 = null;
                var proxy_auth_decoded: ?bun.String.Slice = null;
                defer if (proxy_auth_decoded) |s| s.deinit();

                if (args.proxyAuthorization) |auth| {
                    proxy_auth_decoded = try auth.toUTF8(allocator);
                    proxy_auth_slice = proxy_auth_decoded.?.slice();
                }

                const proxy_extra_headers = try Headers8Bit.init(allocator, args.proxyHeaderNames, args.proxyHeaderValues);
                defer proxy_extra_headers.deinit();

                connect_request = try UpgradeRequest.buildConnectRequest(
                    allocator,
                    host_slice.slice(),
                    port,
                    proxy_auth_slice,
                    proxy_extra_headers.names(),
                    proxy_extra_headers.values(),
                );

                const target_host_dup = try allocator.dupe(u8, host_slice.slice());

                proxy_state = WebSocketProxy.init(
                    target_host_dup,
                    // Use target_is_secure from C++, not ssl template parameter
                    // (ssl may be true for HTTPS proxy even with ws:// target)
                    target_is_secure,
                    body,
                );
            }

            var subprotocols = bun.StringSet.init(allocator);
            defer if (!transferred) subprotocols.clearAndFree();
            var protocol_iterator = bun.http.HeaderValueIterator.init(protocol_for_subprotocols);
            while (protocol_iterator.next()) |protocol| try subprotocols.insert(protocol);

            const display_host_ = if (using_proxy) proxy_host_slice.?.slice() else host_slice.slice();
            // The outer TLS connection authenticates the proxy when one is used.
            const tls_host = if (unix_socket_path_slice != null) host_slice.slice() else display_host_;
            const hostname: [:0]const u8 = if (ssl and tls_host.len > 0 and !strings.isIPAddress(tls_host))
                try allocator.dupeSentinel(u8, tls_host, 0)
            else
                "";
            defer if (!transferred and hostname.len > 0) allocator.free(hostname);

            const client = try allocator.create(HTTPClient);
            client.* = .{
                .ref_count = .init(),
                .tcp = .{ .socket = .{ .detached = {} } },
                .globalThis = global,
                .outgoing_websocket = websocket,
                .input_body_buf = if (using_proxy) connect_request else body,
                .state = .initializing,
                .proxy = proxy_state,
                .expected_accept = request_result.expected_accept,
                .offered_permessage_deflate = offer_permessage_deflate,
                .subprotocols = subprotocols,
                .hostname = hostname,
            };

            client.ssl_config = if (args.sslConfig) |*config| config.takeNative() else null;
            transferred = true;

            const connect_port = if (using_proxy) proxy_port else port;

            client.poll_ref.ref(vm);
            const display_host = if (bun.FeatureFlags.hardcode_localhost_to_127_0_0_1 and strings.eqlComptime(display_host_, "localhost"))
                "127.0.0.1"
            else
                display_host_;

            log("connect: ssl={}, has_ssl_config={}, using_proxy={}", .{ ssl, ssl_config != null, using_proxy });

            const group = vm.rareData().wsUpgradeGroup(vm, ssl);
            const kind: uws.SocketKind = if (ssl) .ws_client_upgrade_tls else .ws_client_upgrade;
            // Default-TLS shares the VM-wide client SSL_CTX; a custom CA
            // builds a per-connection one that the connected WebSocket
            // inherits so it isn't rebuilt on adopt.
            const secure_ptr: ?*uws.SslCtx = if (comptime ssl) brk: {
                if (ssl_config) |config| if (config.requires_custom_request_ctx) {
                    var err: uws.TLSContextFailure = .{};
                    // Per-VM weak cache: every `new WebSocket(wss://, {tls:{ca}})`
                    // with the same CA shares one CTX with each other and with
                    // any `Bun.connect`/Postgres/etc. that named it.
                    const ctx = vm.rareData().sslCtxCache().getOrCreateOpts(config.asUSocketsForClientVerification(), &err) orelse {
                        // Do NOT fall through to the default trust store — the
                        // user passed an explicit CA/cert and BoringSSL
                        // rejected it. Swapping in system roots would let the
                        // connection succeed against a host the user didn't
                        // trust. The C++ caller emits an `error` event on null.
                        log("createSSLContext failed for WebSocket: {s}", .{@tagName(err.kind)});
                        client.poll_ref.unref(vm);
                        client.deref();
                        if (err.kind == .out_of_memory) return error.OutOfMemory;
                        return null;
                    };
                    // Owned ref; the connected WebSocket retains a separate
                    // ref during upgrade.
                    client.secure = ctx;
                    break :brk ctx;
                };
                var failure: uws.TLSContextFailure = .{};
                break :brk vm.rareData().defaultClientSslCtx(&failure) orelse {
                    client.deref();
                    if (failure.kind == .out_of_memory) return error.OutOfMemory;
                    return null;
                };
            } else null;

            // Unix domain socket path (ws+unix:// / wss+unix://)
            if (unix_socket_path_slice) |usp| {
                if (Socket.connectUnixGroup(
                    group,
                    kind,
                    secure_ptr,
                    usp.slice(),
                    client,
                    false,
                )) |socket| {
                    client.tcp = socket;
                    if (client.state == .failed) {
                        client.deref();
                        return null;
                    }
                    bun.analytics.Features.WebSocket += 1;

                    client.tcp.timeout(120);
                    client.state = .reading;
                    // +1 for cpp_websocket
                    client.ref();
                    return client;
                } else |err| {
                    client.deref();
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                }
                return null;
            }

            if (Socket.connectGroup(
                group,
                kind,
                secure_ptr,
                display_host,
                connect_port,
                client,
                false,
            )) |sock| {
                client.tcp = sock;
                const out = client;
                // I don't think this case gets reached.
                if (out.state == .failed) {
                    client.deref();
                    return null;
                }
                bun.analytics.Features.WebSocket += 1;

                out.tcp.timeout(120);
                out.state = .reading;
                // +1 for cpp_websocket
                out.ref();
                return out;
            } else |err| {
                client.deref();
                if (err == error.OutOfMemory) return error.OutOfMemory;
            }

            return null;
        }

        pub fn clearInput(this: *HTTPClient) void {
            if (this.input_body_buf.len > 0) bun.default_allocator.free(this.input_body_buf);
            this.input_body_buf.len = 0;
        }
        pub fn clearData(this: *HTTPClient) void {
            this.poll_ref.unref(jsc.VirtualMachine.get());

            this.subprotocols.clearAndFree();
            this.clearInput();
            this.body.clearAndFree(bun.default_allocator);

            if (this.hostname.len > 0) {
                bun.default_allocator.free(this.hostname);
                this.hostname = "";
            }

            // Clean up proxy state. Null the field and detach the tunnel's
            // back-reference before deinit so that SSLWrapper shutdown callbacks
            // cannot re-enter clearData() while the proxy is still reachable.
            if (this.proxy != null) {
                var proxy = this.proxy.?;
                this.proxy = null;
                if (proxy.getTunnel()) |tunnel| {
                    tunnel.detachUpgradeClient();
                }
                proxy.deinit();
            }
            if (this.ssl_config) |config| {
                config.deinit();
                bun.default_allocator.destroy(config);
                this.ssl_config = null;
            }
            if (this.secure) |s| {
                bun.BoringSSL.c.SSL_CTX_free(s);
                this.secure = null;
            }
        }
        pub fn cancel(this: *HTTPClient) void {
            this.clearData();

            // Either of the below two operations - closing the TCP socket or clearing the C++ reference could trigger a deref
            // Therefore, we need to make sure the `this` pointer is valid until the end of the function.
            this.ref();
            defer this.deref();

            // The C++ end of the socket is no longer holding a reference to this, so we must clear it.
            if (this.outgoing_websocket != null) {
                this.outgoing_websocket = null;
                this.deref();
            }

            // no need to be .failure we still wanna to send pending SSL buffer + close_notify
            if (comptime ssl) {
                this.tcp.close(.normal);
            } else {
                this.tcp.close(.failure);
            }
        }

        pub fn fail(this: *HTTPClient, code: ErrorCode) void {
            log("onFail: {s}", .{@tagName(code)});
            this.dispatchAbruptClose(code);

            if (comptime ssl) {
                this.tcp.close(.normal);
            } else {
                this.tcp.close(.failure);
            }
        }

        fn dispatchAbruptClose(this: *HTTPClient, code: ErrorCode) void {
            if (this.outgoing_websocket) |ws| {
                this.outgoing_websocket = null;
                CppWebSocketEngine.didAbruptClose(this.globalThis, ws, code);
                this.deref();
            }
        }

        pub fn handleClose(this: *HTTPClient, _: Socket, _: c_int, _: ?*anyopaque) void {
            log("onClose", .{});
            this.clearData();
            this.tcp.detach();
            this.dispatchAbruptClose(ErrorCode.ended);

            this.deref();
        }

        pub fn terminate(this: *HTTPClient, code: ErrorCode) void {
            this.fail(code);

            // We cannot access the pointer after fail is called.
        }

        pub fn handleHandshake(this: *HTTPClient, socket: Socket, success: i32, ssl_error: uws.us_bun_verify_error_t) void {
            log("onHandshake({d}) ssl_error.error_no={d}", .{ success, ssl_error.error_no });

            const handshake_success = if (success == 1) true else false;
            var reject_unauthorized = false;
            if (this.outgoing_websocket) |ws| {
                reject_unauthorized = CppWebSocketEngine.rejectUnauthorized(ws);
            }

            if (handshake_success) {
                // handshake completed but we may have ssl errors
                if (reject_unauthorized) {
                    // only reject the connection if reject_unauthorized == true
                    if (ssl_error.error_no != 0) {
                        log("TLS handshake failed: ssl_error={d}, has_custom_ctx={}", .{ ssl_error.error_no, this.secure != null });
                        this.fail(ErrorCode.tls_handshake_failed);
                        return;
                    }
                    const ssl_ptr = @as(*BoringSSL.c.SSL, @ptrCast(socket.getNativeHandle()));
                    if (BoringSSL.c.SSL_get_servername(ssl_ptr, 0)) |servername| {
                        const hostname = servername[0..bun.len(servername)];
                        if (!BoringSSL.checkServerIdentity(ssl_ptr, hostname)) {
                            this.fail(ErrorCode.tls_handshake_failed);
                        }
                    }
                }
            } else {
                // if we are here is because server rejected us, and the error_no is the cause of this
                // if we set reject_unauthorized == false this means the server requires custom CA aka NODE_EXTRA_CA_CERTS
                this.fail(ErrorCode.tls_handshake_failed);
            }
        }

        pub fn handleOpen(this: *HTTPClient, socket: Socket) void {
            log("onOpen", .{});
            this.tcp = socket;

            bun.assert(this.input_body_buf.len > 0);
            bun.assert(this.to_send.len == 0);

            if (comptime ssl) {
                if (this.hostname.len > 0) {
                    if (socket.getNativeHandle()) |handle| {
                        handle.configureHTTPClient(this.hostname);
                    }
                    bun.default_allocator.free(this.hostname);
                    this.hostname = "";
                }
            }

            // If using proxy, set state to proxy_handshake
            if (this.proxy != null) {
                this.state = .proxy_handshake;
            }

            const wrote = socket.write(this.input_body_buf);
            if (wrote < 0) {
                this.terminate(ErrorCode.failed_to_write);
                return;
            }

            this.to_send = this.input_body_buf[@as(usize, @intCast(wrote))..];
        }

        pub fn isSameSocket(this: *HTTPClient, socket: Socket) bool {
            return socket.socket.eq(this.tcp.socket);
        }

        pub fn handleData(this: *HTTPClient, socket: Socket, data: []const u8) void {
            log("onData", .{});

            // For tunnel mode after successful upgrade, forward all data to the tunnel
            // The tunnel will decrypt and pass to the WebSocket client
            if (this.state == .done) {
                if (this.proxy) |*p| {
                    if (p.getTunnel()) |tunnel| {
                        // Ref the tunnel to keep it alive during this call
                        // (in case the WebSocket client closes during processing)
                        tunnel.ref();
                        defer tunnel.deref();
                        tunnel.receive(data);
                    }
                }
                return;
            }

            if (this.outgoing_websocket == null) {
                this.state = .failed;
                this.clearData();
                socket.close(.failure);
                return;
            }
            this.ref();
            defer this.deref();

            bun.assert(this.isSameSocket(socket));

            if (comptime Environment.allow_assert)
                bun.assert(!socket.isShutdown());

            // Handle proxy handshake response
            if (this.state == .proxy_handshake) {
                this.handleProxyResponse(socket, data);
                return;
            }

            // Route through proxy tunnel if TLS handshake is in progress or complete
            if (this.proxy) |*p| {
                if (p.getTunnel()) |tunnel| {
                    tunnel.receive(data);
                    return;
                }
            }

            var body = data;
            if (this.body.items.len > 0) {
                bun.handleOom(this.body.appendSlice(bun.default_allocator, data));
                body = this.body.items;
            }

            const is_first = this.body.items.len == 0;
            const http_101 = "HTTP/1.1 101 ";
            if (is_first and body.len > http_101.len) {
                // fail early if we receive a non-101 status code
                if (!strings.hasPrefixComptime(body, http_101)) {
                    this.terminate(ErrorCode.expected_101_status_code);
                    return;
                }
            }

            const response = PicoHTTP.Response.parse(body, &this.headers_buf) catch |err| {
                switch (err) {
                    error.Malformed_HTTP_Response => {
                        this.terminate(ErrorCode.invalid_response);
                        return;
                    },
                    error.ShortRead => {
                        if (this.body.items.len == 0) {
                            bun.handleOom(this.body.appendSlice(bun.default_allocator, data));
                        }
                        return;
                    },
                }
            };

            this.processResponse(response, body[@as(usize, @intCast(response.bytes_read))..]);
        }

        fn handleProxyResponse(this: *HTTPClient, socket: Socket, data: []const u8) void {
            log("handleProxyResponse", .{});

            var body = data;
            if (this.body.items.len > 0) {
                bun.handleOom(this.body.appendSlice(bun.default_allocator, data));
                body = this.body.items;
            }

            // Check for HTTP 200 response from proxy
            const is_first = this.body.items.len == 0;
            const http_200 = "HTTP/1.1 200 ";
            const http_200_alt = "HTTP/1.0 200 ";
            if (is_first and body.len > http_200.len) {
                if (!strings.hasPrefixComptime(body, http_200) and !strings.hasPrefixComptime(body, http_200_alt)) {
                    // Proxy connection failed
                    this.terminate(ErrorCode.proxy_connect_failed);
                    return;
                }
            }

            // Parse the response to find the end of headers
            const response = PicoHTTP.Response.parse(body, &this.headers_buf) catch |err| {
                switch (err) {
                    error.Malformed_HTTP_Response => {
                        this.terminate(ErrorCode.invalid_response);
                        return;
                    },
                    error.ShortRead => {
                        if (this.body.items.len == 0) {
                            bun.handleOom(this.body.appendSlice(bun.default_allocator, data));
                        }
                        return;
                    },
                }
            };

            // Proxy returned non-200 status
            if (response.status_code != 200) {
                if (response.status_code == 407) {
                    this.terminate(ErrorCode.proxy_authentication_required);
                } else {
                    this.terminate(ErrorCode.proxy_connect_failed);
                }
                return;
            }

            // Proxy tunnel established
            log("Proxy tunnel established", .{});

            // Clear the body buffer for WebSocket handshake
            this.body.clearRetainingCapacity();

            const remain_buf = body[@as(usize, @intCast(response.bytes_read))..];

            // Safely unwrap proxy state - it must exist if we're in proxy_handshake state
            const p = if (this.proxy) |*proxy| proxy else {
                this.terminate(ErrorCode.proxy_tunnel_failed);
                return;
            };

            // For wss:// through proxy, we need to do TLS handshake inside the tunnel
            if (p.isTargetHttps()) {
                this.startProxyTLSHandshake(socket, remain_buf);
                return;
            }

            // For ws:// through proxy, send the WebSocket upgrade request
            this.state = .reading;

            // Free the CONNECT request buffer
            if (this.input_body_buf.len > 0) {
                bun.default_allocator.free(this.input_body_buf);
            }

            // Use the WebSocket upgrade request from proxy state
            this.input_body_buf = p.takeWebsocketRequestBuf();

            // Send the WebSocket upgrade request
            const wrote = socket.write(this.input_body_buf);
            if (wrote < 0) {
                this.terminate(ErrorCode.failed_to_write);
                return;
            }

            this.to_send = this.input_body_buf[@as(usize, @intCast(wrote))..];

            // If there's remaining data after the proxy response, process it
            if (remain_buf.len > 0) {
                this.handleData(socket, remain_buf);
            }
        }

        /// Start TLS handshake inside the proxy tunnel for wss:// connections
        fn startProxyTLSHandshake(this: *HTTPClient, socket: Socket, initial_data: []const u8) void {
            log("startProxyTLSHandshake", .{});

            // Safely unwrap proxy state - it must exist if we're called from handleProxyResponse
            const p = if (this.proxy) |*proxy| proxy else {
                this.terminate(ErrorCode.proxy_tunnel_failed);
                return;
            };

            // Get certificate verification setting
            const reject_unauthorized = if (this.outgoing_websocket) |ws| CppWebSocketEngine.rejectUnauthorized(ws) else true;

            // Create proxy tunnel with all parameters
            const tunnel = WebSocketProxyTunnel.init(ssl, this, socket, p.getTargetHost(), reject_unauthorized) catch {
                this.terminate(ErrorCode.proxy_tunnel_failed);
                return;
            };

            // Use ssl_config if available, otherwise use defaults
            const ssl_options: SSLConfig = if (this.ssl_config) |config| config.* else SSLConfig{
                .reject_unauthorized = 0, // We verify manually
                .request_cert = 1,
            };

            // Start TLS handshake
            tunnel.start(ssl_options, initial_data) catch {
                tunnel.deref();
                this.terminate(ErrorCode.proxy_tunnel_failed);
                return;
            };

            p.setTunnel(tunnel.handle());
            this.state = .proxy_tls_handshake;
        }

        /// Called by WebSocketProxyTunnel when TLS handshake completes successfully
        pub fn onProxyTLSHandshakeComplete(this: *HTTPClient) void {
            log("onProxyTLSHandshakeComplete", .{});

            // TLS handshake done - send WebSocket upgrade request through tunnel
            this.state = .reading;

            // Free the CONNECT request buffer
            if (this.input_body_buf.len > 0) {
                bun.default_allocator.free(this.input_body_buf);
                this.input_body_buf = &[_]u8{};
            }

            // Safely unwrap proxy state and send through the tunnel
            const p = if (this.proxy) |*proxy| proxy else {
                this.terminate(ErrorCode.proxy_tunnel_failed);
                return;
            };

            // Take the WebSocket upgrade request from proxy state (transfers ownership).
            // Store it in input_body_buf so handleWritable can retry on drain.
            this.input_body_buf = p.takeWebsocketRequestBuf();
            if (this.input_body_buf.len == 0) {
                this.terminate(ErrorCode.failed_to_write);
                return;
            }

            // Send through the tunnel (will be encrypted). Buffer any unwritten
            // portion in to_send so handleWritable retries when the socket drains.
            if (p.getTunnel()) |tunnel| {
                const wrote = tunnel.write(this.input_body_buf) catch {
                    this.terminate(ErrorCode.failed_to_write);
                    return;
                };
                this.to_send = this.input_body_buf[wrote..];
            } else {
                this.terminate(ErrorCode.proxy_tunnel_failed);
            }
        }

        /// Called by WebSocketProxyTunnel with decrypted data from the TLS tunnel
        pub fn handleDecryptedData(this: *HTTPClient, data: []const u8) void {
            log("handleDecryptedData: {} bytes", .{data.len});

            // Process as if it came directly from the socket
            var body = data;
            if (this.body.items.len > 0) {
                bun.handleOom(this.body.appendSlice(bun.default_allocator, data));
                body = this.body.items;
            }

            const is_first = this.body.items.len == 0;
            const http_101 = "HTTP/1.1 101 ";
            if (is_first and body.len > http_101.len) {
                // fail early if we receive a non-101 status code
                if (!strings.hasPrefixComptime(body, http_101)) {
                    this.terminate(ErrorCode.expected_101_status_code);
                    return;
                }
            }

            const response = PicoHTTP.Response.parse(body, &this.headers_buf) catch |err| {
                switch (err) {
                    error.Malformed_HTTP_Response => {
                        this.terminate(ErrorCode.invalid_response);
                        return;
                    },
                    error.ShortRead => {
                        if (this.body.items.len == 0) {
                            bun.handleOom(this.body.appendSlice(bun.default_allocator, data));
                        }
                        return;
                    },
                }
            };

            this.processResponse(response, body[@as(usize, @intCast(response.bytes_read))..]);
        }

        pub fn handleEnd(this: *HTTPClient, _: Socket) void {
            log("onEnd", .{});
            this.terminate(ErrorCode.ended);
        }

        pub fn processResponse(this: *HTTPClient, response: PicoHTTP.Response, remain_buf: []const u8) void {
            var upgrade_header = PicoHTTP.Header{ .name = "", .value = "" };
            var connection_header = PicoHTTP.Header{ .name = "", .value = "" };
            var websocket_accept_header = PicoHTTP.Header{ .name = "", .value = "" };
            var protocol_header_seen = false;

            // var visited_version = false;
            var deflate_result = DeflateNegotiationResult{};

            if (response.status_code != 101) {
                this.terminate(ErrorCode.expected_101_status_code);
                return;
            }

            for (response.headers.list) |header| {
                switch (header.name.len) {
                    "Connection".len => {
                        if (connection_header.name.len == 0 and strings.eqlCaseInsensitiveASCII(header.name, "Connection", false)) {
                            connection_header = header;
                        }
                    },
                    "Upgrade".len => {
                        if (upgrade_header.name.len == 0 and strings.eqlCaseInsensitiveASCII(header.name, "Upgrade", false)) {
                            upgrade_header = header;
                        }
                    },
                    "Sec-WebSocket-Version".len => {
                        if (strings.eqlCaseInsensitiveASCII(header.name, "Sec-WebSocket-Version", false)) {
                            if (!strings.eqlComptimeIgnoreLen(header.value, "13")) {
                                this.terminate(ErrorCode.invalid_websocket_version);
                                return;
                            }
                        }
                    },
                    "Sec-WebSocket-Accept".len => {
                        if (websocket_accept_header.name.len == 0 and strings.eqlCaseInsensitiveASCII(header.name, "Sec-WebSocket-Accept", false)) {
                            websocket_accept_header = header;
                        }
                    },
                    "Sec-WebSocket-Protocol".len => {
                        if (strings.eqlCaseInsensitiveASCII(header.name, "Sec-WebSocket-Protocol", false)) {
                            const valid = brk: {
                                // Can't have multiple protocol headers in the response.
                                if (protocol_header_seen) break :brk false;

                                protocol_header_seen = true;

                                var iterator = bun.http.HeaderValueIterator.init(header.value);

                                const protocol = iterator.next()
                                    // Can't be empty.
                                    orelse break :brk false;

                                // Can't have multiple protocols.
                                if (iterator.next() != null) break :brk false;

                                // Protocol must be in the list of allowed protocols.
                                if (!this.subprotocols.contains(protocol)) break :brk false;

                                if (this.outgoing_websocket) |ws| {
                                    var protocol_str = bun.String.cloneLatin1(protocol);
                                    defer protocol_str.deref();
                                    CppWebSocketEngine.setProtocol(ws, &protocol_str);
                                }
                                break :brk true;
                            };

                            if (!valid) {
                                this.terminate(ErrorCode.mismatch_client_protocol);
                                return;
                            }
                        }
                    },
                    "Sec-WebSocket-Extensions".len => {
                        if (strings.eqlCaseInsensitiveASCII(header.name, "Sec-WebSocket-Extensions", false)) {
                            // Per RFC 6455 §9.1, the server MUST NOT respond with an
                            // extension the client did not offer. Match upstream `ws`
                            // (lib/websocket.js: "Server sent a Sec-WebSocket-Extensions
                            // header but no extension was requested") and fail the
                            // handshake instead of silently accepting it.
                            if (!this.offered_permessage_deflate) {
                                this.terminate(ErrorCode.invalid_response);
                                return;
                            }
                            // This is a simplified parser. A full parser would handle multiple extensions and quoted values.
                            var it = std.mem.splitScalar(u8, header.value, ',');
                            while (it.next()) |ext_str| {
                                var ext_it = std.mem.splitScalar(u8, std.mem.trim(u8, ext_str, " \t"), ';');
                                const ext_name = std.mem.trim(u8, ext_it.next() orelse "", " \t");
                                if (strings.eqlComptime(ext_name, "permessage-deflate")) {
                                    deflate_result.enabled = true;
                                    while (ext_it.next()) |param_str| {
                                        var param_it = std.mem.splitScalar(u8, std.mem.trim(u8, param_str, " \t"), '=');
                                        const key = std.mem.trim(u8, param_it.next() orelse "", " \t");
                                        const value = std.mem.trim(u8, param_it.next() orelse "", " \t");

                                        if (strings.eqlComptime(key, "server_no_context_takeover")) {
                                            deflate_result.params.server_no_context_takeover = 1;
                                        } else if (strings.eqlComptime(key, "client_no_context_takeover")) {
                                            deflate_result.params.client_no_context_takeover = 1;
                                        } else if (strings.eqlComptime(key, "server_max_window_bits")) {
                                            if (value.len > 0) {
                                                // Remove quotes if present
                                                const trimmed_value = if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"')
                                                    value[1 .. value.len - 1]
                                                else
                                                    value;

                                                if (std.fmt.parseInt(u8, trimmed_value, 10) catch null) |bits| {
                                                    if (bits >= WebSocketDeflate.Params.MIN_WINDOW_BITS and bits <= WebSocketDeflate.Params.MAX_WINDOW_BITS) {
                                                        deflate_result.params.server_max_window_bits = bits;
                                                    }
                                                }
                                            }
                                        } else if (strings.eqlComptime(key, "client_max_window_bits")) {
                                            if (value.len > 0) {
                                                // Remove quotes if present
                                                const trimmed_value = if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"')
                                                    value[1 .. value.len - 1]
                                                else
                                                    value;

                                                if (std.fmt.parseInt(u8, trimmed_value, 10) catch null) |bits| {
                                                    if (bits >= WebSocketDeflate.Params.MIN_WINDOW_BITS and bits <= WebSocketDeflate.Params.MAX_WINDOW_BITS) {
                                                        deflate_result.params.client_max_window_bits = bits;
                                                    }
                                                }
                                            } else {
                                                // client_max_window_bits without value means use default (15)
                                                deflate_result.params.client_max_window_bits = 15;
                                            }
                                        }
                                    }
                                    break; // Found and parsed permessage-deflate, stop.
                                }
                            }
                        }
                    },
                    else => {},
                }
            }

            // if (!visited_version) {
            //     this.terminate(ErrorCode.invalid_websocket_version);
            //     return;
            // }

            if (@min(upgrade_header.name.len, upgrade_header.value.len) == 0) {
                this.terminate(ErrorCode.missing_upgrade_header);
                return;
            }

            if (@min(connection_header.name.len, connection_header.value.len) == 0) {
                this.terminate(ErrorCode.missing_connection_header);
                return;
            }

            if (@min(websocket_accept_header.name.len, websocket_accept_header.value.len) == 0) {
                this.terminate(ErrorCode.missing_websocket_accept_header);
                return;
            }

            if (!strings.eqlCaseInsensitiveASCII(connection_header.value, "Upgrade", true)) {
                this.terminate(ErrorCode.invalid_connection_header);
                return;
            }

            if (!strings.eqlCaseInsensitiveASCII(upgrade_header.value, "websocket", true)) {
                this.terminate(ErrorCode.invalid_upgrade_header);
                return;
            }

            if (!std.mem.eql(u8, websocket_accept_header.value, &this.expected_accept)) {
                this.terminate(ErrorCode.mismatch_websocket_accept_header);
                return;
            }

            const overflow_len = remain_buf.len;
            var overflow: []u8 = &.{};
            if (overflow_len > 0) {
                overflow = bun.default_allocator.alloc(u8, overflow_len) catch {
                    this.terminate(ErrorCode.invalid_response);
                    return;
                };
                @memcpy(overflow, remain_buf);
            }
            defer if (overflow.len > 0) bun.default_allocator.free(overflow);

            // Check if we're using a proxy tunnel (wss:// through HTTP proxy)
            if (this.proxy) |*p| {
                if (p.getTunnel()) |tunnel| {
                    // wss:// through HTTP proxy: use tunnel mode
                    // For tunnel mode, the upgrade client STAYS ALIVE to forward socket data to the tunnel.
                    // The socket continues to call handleData on the upgrade client, which forwards to tunnel.
                    // The tunnel forwards decrypted data to the WebSocket client.
                    if (!this.tcp.isClosed() and this.outgoing_websocket != null) {
                        this.tcp.timeout(0);
                        log("onDidConnect (tunnel mode)", .{});

                        // Release the ref that paired with C++'s m_upgradeClient: C++
                        // nulls m_upgradeClient inside didConnectWithTunnel() so it will
                        // never call cancel() to drop it. The TCP socket's ref (released
                        // in handleClose) is what keeps this struct alive to forward
                        // socket data to the tunnel after we switch to .done.
                        defer this.deref();
                        const ws = bun.take(&this.outgoing_websocket).?;
                        CppWebSocketEngine.ref(ws);
                        defer CppWebSocketEngine.unref(ws);

                        // Create the WebSocket client with the tunnel
                        CppWebSocketEngine.didConnectWithTunnel(this.globalThis, ws, tunnel, overflow, if (deflate_result.enabled) &deflate_result.params else null) catch |err| {
                            this.tcp.close(.failure);
                            this.globalThis.reportActiveExceptionAsUnhandled(err);
                            if (!this.globalThis.hasException()) CppWebSocketEngine.didAbruptClose(this.globalThis, ws, ErrorCode.failed_to_connect);
                            return;
                        };

                        // Switch state to connected - handleData will forward to tunnel
                        this.state = .done;
                    } else if (this.tcp.isClosed()) {
                        this.terminate(ErrorCode.cancel);
                    } else if (this.outgoing_websocket == null) {
                        this.tcp.close(.failure);
                    }
                    return;
                }
            }

            // The connected client retains its own SSL_CTX ref during didConnect.
            const saved_secure = this.secure;
            this.secure = null;
            defer if (saved_secure) |s| bun.BoringSSL.c.SSL_CTX_free(s);
            this.clearData();
            if (!this.tcp.isClosed() and this.outgoing_websocket != null) {
                this.tcp.timeout(0);
                log("onDidConnect", .{});

                // Once for the outgoing_websocket.
                defer this.deref();
                const ws = bun.take(&this.outgoing_websocket).?;
                CppWebSocketEngine.ref(ws);
                defer CppWebSocketEngine.unref(ws);
                const socket = this.tcp;

                // Normal mode: pass socket directly to WebSocket client
                this.tcp.detach();
                // Once again for the TCP socket.
                defer this.deref();
                if (socket.socket.get()) |native_socket| {
                    CppWebSocketEngine.didConnect(this.globalThis, ws, native_socket, overflow, if (deflate_result.enabled) &deflate_result.params else null, saved_secure) catch |err| {
                        this.globalThis.reportActiveExceptionAsUnhandled(err);
                        if (!this.globalThis.hasException()) CppWebSocketEngine.didAbruptClose(this.globalThis, ws, ErrorCode.failed_to_connect);
                    };
                } else {
                    this.terminate(ErrorCode.failed_to_connect);
                }
            } else if (this.tcp.isClosed()) {
                this.terminate(ErrorCode.cancel);
            } else if (this.outgoing_websocket == null) {
                this.tcp.close(.failure);
            }
        }

        pub fn memoryCost(this: *HTTPClient) usize {
            var cost: usize = @sizeOf(HTTPClient);
            cost += this.body.capacity;
            cost += this.to_send.len;
            return cost;
        }

        pub fn handleWritable(
            this: *HTTPClient,
            socket: Socket,
        ) void {
            bun.assert(this.isSameSocket(socket));

            // Forward to proxy tunnel if active
            if (this.proxy) |*p| {
                if (p.getTunnel()) |tunnel| {
                    tunnel.onWritable();
                    // In .done state (after WebSocket upgrade), just handle tunnel writes
                    if (this.state == .done) return;

                    // Flush any unwritten upgrade request bytes through the tunnel
                    if (this.to_send.len == 0) return;
                    this.ref();
                    defer this.deref();
                    const wrote = tunnel.write(this.to_send) catch {
                        this.terminate(ErrorCode.failed_to_write);
                        return;
                    };
                    this.to_send = this.to_send[@min(wrote, this.to_send.len)..];
                    return;
                }
            }

            if (this.to_send.len == 0)
                return;

            this.ref();
            defer this.deref();

            const wrote = socket.write(this.to_send);
            if (wrote < 0) {
                this.terminate(ErrorCode.failed_to_write);
                return;
            }
            this.to_send = this.to_send[@min(@as(usize, @intCast(wrote)), this.to_send.len)..];
        }
        pub fn handleTimeout(
            this: *HTTPClient,
            _: Socket,
        ) void {
            this.terminate(ErrorCode.timeout);
        }

        // In theory, this could be called immediately
        // In that case, we set `state` to `failed` and return, expecting the parent to call `destroy`.
        pub fn handleConnectError(this: *HTTPClient, _: Socket, _: uws.ConnectFailure) void {
            this.tcp.detach();

            // For the TCP socket.
            defer this.deref();

            if (this.state == .reading) {
                this.terminate(ErrorCode.failed_to_connect);
            } else {
                this.state = .failed;
            }
        }

        const binding_prefix = if (ssl) "webSocketHTTPSClient" else "webSocketHTTPClient";
        const ConnectSchema = WebSocketBindings.nativeExport(binding_prefix ++ "Connect");
        const CancelSchema = WebSocketBindings.nativeExport(binding_prefix ++ "Cancel");
        const MemoryCostSchema = WebSocketBindings.nativeExport(binding_prefix ++ "MemoryCost");

        fn bindCancel(args: bun.bindgen.Args(CancelSchema)) bun.bindgen.Return(CancelSchema) {
            args.client.cancel();
        }

        fn bindMemoryCost(args: bun.bindgen.Args(MemoryCostSchema)) bun.bindgen.Return(MemoryCostSchema) {
            return args.client.memoryCost();
        }

        const ConnectBinding = bun.bindgen.Fn(ConnectSchema, bindConnect);
        const CancelBinding = bun.bindgen.Fn(CancelSchema, bindCancel);
        const MemoryCostBinding = bun.bindgen.Fn(MemoryCostSchema, bindMemoryCost);

        pub fn exportAll() void {
            comptime {
                _ = ConnectBinding;
                _ = CancelBinding;
                _ = MemoryCostBinding;
            }
        }
    };
}

/// Keeps decoded UTF-8 header strings alive while an upgrade request is built.
const Headers8Bit = struct {
    slices: []bun.String.Slice,
    name_slices: [][]const u8,
    value_slices: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        name_views: anytype,
        value_views: @TypeOf(name_views),
    ) std.mem.Allocator.Error!Headers8Bit {
        const len = name_views.len();
        bun.assert(value_views.len() == len);
        if (len == 0) {
            return .{
                .slices = &.{},
                .name_slices = &.{},
                .value_slices = &.{},
                .allocator = allocator,
            };
        }
        const slices = try allocator.alloc(bun.String.Slice, len * 2);
        errdefer allocator.free(slices);

        const name_slices = try allocator.alloc([]const u8, len);
        errdefer allocator.free(name_slices);

        const value_slices = try allocator.alloc([]const u8, len);
        errdefer allocator.free(value_slices);

        var decoded: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < decoded) : (j += 1) slices[j].deinit();
        }
        var i: usize = 0;
        while (i < len) : (i += 1) {
            slices[i * 2] = try name_views.at(i).?.toUTF8(allocator);
            decoded += 1;
            slices[i * 2 + 1] = try value_views.at(i).?.toUTF8(allocator);
            decoded += 1;
            name_slices[i] = slices[i * 2].slice();
            value_slices[i] = slices[i * 2 + 1].slice();
        }

        return .{
            .slices = slices,
            .name_slices = name_slices,
            .value_slices = value_slices,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Headers8Bit) void {
        for (self.slices) |*s| s.deinit();
        if (self.slices.len > 0) {
            self.allocator.free(self.slices);
            self.allocator.free(self.name_slices);
            self.allocator.free(self.value_slices);
        }
    }

    pub fn names(self: Headers8Bit) []const []const u8 {
        return self.name_slices;
    }

    pub fn values(self: Headers8Bit) []const []const u8 {
        return self.value_slices;
    }
};

const log = Output.scoped(.WebSocketUpgradeClient, .visible);

fn bindParseSSLConfig(
    context: bun.bindgen.CallContext(ParseSSLConfigSchema),
    args: bun.bindgen.Args(ParseSSLConfigSchema),
) bun.bindgen.CallError(ParseSSLConfigSchema)!bun.bindgen.Return(ParseSSLConfigSchema) {
    const config_opt = try SSLConfigEngine.parse(context, &args.tlsOptions);
    if (config_opt) |config| {
        var owned_config = config;
        errdefer owned_config.deinit();
        const config_ptr = try bun.default_allocator.create(SSLConfig);
        config_ptr.* = owned_config;
        const OwnedConfig = @typeInfo(bun.bindgen.Return(ParseSSLConfigSchema)).optional.child;
        return OwnedConfig.initNative(config_ptr);
    }
    return null;
}

fn bindDestroySSLConfig(args: bun.bindgen.Args(DestroySSLConfigSchema)) bun.bindgen.Return(DestroySSLConfigSchema) {
    args.config.deinit();
    bun.default_allocator.destroy(args.config);
}

const WebSocketDeflate = @import("./WebSocketDeflate.zig");
const WebSocketProxy = @import("./WebSocketProxy.zig");
const WebSocketProxyTunnel = @import("./WebSocketProxyTunnelEngine.zig");
const UpgradeRequest = @import("./WebSocketUpgradeRequest.zig");
const std = @import("std");
const CppWebSocket = @import("./CppWebSocket.zig").CppWebSocket;
const CppWebSocketEngine = @import("./CppWebSocketEngine.zig");

const websocket_client = @import("../WebSocketClientEngine.zig");
const ErrorCode = websocket_client.ErrorCode;

const bun = @import("bun");
const Async = bun.Async;
const BoringSSL = bun.BoringSSL;
const Environment = bun.Environment;
const Output = bun.Output;
const PicoHTTP = bun.picohttp;
const default_allocator = bun.default_allocator;
const jsc = bun.jsc;
const strings = bun.strings;
const uws = bun.uws;
const SSLConfig = jsc.API.ServerConfig.SSLConfig;
const SSLConfigEngine = jsc.API.ServerConfig.SSLConfigEngine;
const WebSocketBindings = bun.bindgen.Module("websocket_client");
const ParseSSLConfigSchema = WebSocketBindings.nativeExport("webSocketParseSSLConfig");
const DestroySSLConfigSchema = WebSocketBindings.nativeExport("webSocketSSLConfigDestroy");
const ParseSSLConfigBinding = bun.bindgen.Fn(ParseSSLConfigSchema, bindParseSSLConfig);
const DestroySSLConfigBinding = bun.bindgen.Fn(DestroySSLConfigSchema, bindDestroySSLConfig);

comptime {
    _ = ParseSSLConfigBinding;
    _ = DestroySSLConfigBinding;
}
