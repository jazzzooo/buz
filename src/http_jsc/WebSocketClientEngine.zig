/// This is the Zig implementation of the WebSocket client.
///
/// It manages the WebSocket connection, including sending and receiving data,
/// handling connection events, and managing the WebSocket state.
///
/// The WebSocket client supports both secure (TLS) and non-secure connections.
///
/// This is only used **after** the websocket handshaking step is completed.
pub fn NewWebSocketClient(comptime ssl: bool) type {
    return struct {
        pub const Socket = uws.NewSocketHandler(ssl);

        const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
        pub const ref = RefCount.ref;
        pub const deref = RefCount.deref;

        ref_count: RefCount,

        tcp: Socket,
        outgoing_websocket: ?*CppWebSocket = null,

        receive_state: ReceiveState = ReceiveState.need_header,
        receiving_type: Opcode = Opcode.ResB,
        // we need to start with final so we validate the first frame
        receiving_is_final: bool = true,

        ping_frame_bytes: [128 + 6]u8 = @splat(0),
        ping_len: u8 = 0,
        ping_received: bool = false,
        pong_received: bool = false,
        close_received: bool = false,
        close_frame_buffering: bool = false,
        pending_close: ?struct { code: u16, reason: bun.String } = null,

        receive_frame: usize = 0,
        receive_body_remain: usize = 0,
        receive_pending_chunk_len: usize = 0,
        receive_buffer: bun.LinearFifo(u8, .Dynamic),

        send_buffer: bun.LinearFifo(u8, .Dynamic),

        globalThis: *jsc.JSGlobalObject,
        poll_ref: Async.KeepAlive = Async.KeepAlive.init(),

        header_fragment: ?u8 = null,

        payload_length_frame_bytes: [8]u8 = @splat(0),
        payload_length_frame_len: u8 = 0,

        initial_data_handler: ?*InitialDataHandler = null,
        event_loop: *jsc.EventLoop = undefined,
        deflate: ?*WebSocketDeflate = null,

        // Track if current message is compressed
        receiving_compressed: bool = false,
        // Track compression state of the entire message (across fragments)
        message_is_compressed: bool = false,

        /// `us_ssl_ctx_t` inherited from the upgrade client when it was built
        /// with a custom CA. The socket's `SSL*` references the `SSL_CTX`
        /// inside, so this must outlive the connection. Null when the upgrade
        /// used the shared default context.
        secure: ?*uws.SslCtx = null,

        // Proxy tunnel for wss:// through HTTP proxy.
        // When set, all I/O goes through the tunnel (TLS encryption/decryption).
        // The tunnel handles the TLS layer, so this is used with ssl=false.
        proxy_tunnel: ?*WebSocketProxyTunnel = null,

        const stack_frame_size = 1024;
        // Minimum message size to compress (RFC 7692 recommendation)
        const MIN_COMPRESS_SIZE = 860;
        // DEFLATE overhead
        const COMPRESSION_OVERHEAD = 4;

        const WebSocket = @This();

        fn shouldCompress(this: *const WebSocket, data_len: usize, opcode: Opcode) bool {
            // Check if compression is available
            if (this.deflate == null) return false;

            // Only compress Text and Binary messages
            if (opcode != .Text and opcode != .Binary) return false;

            // Don't compress small messages where overhead exceeds benefit
            if (data_len < MIN_COMPRESS_SIZE) return false;

            return true;
        }

        pub const onClose = handleClose;
        pub const onData = handleData;
        pub const onWritable = handleWritable;
        pub const onTimeout = handleTimeout;
        pub const onLongTimeout = handleTimeout;
        pub const onConnectError = handleConnectError;
        pub const onEnd = handleEnd;
        pub const onHandshake = handleHandshake;

        pub fn clearData(this: *WebSocket) void {
            log("clearData", .{});
            this.poll_ref.unref(this.globalThis.bunVM());
            this.clearReceiveBuffers(true);
            this.clearSendBuffers(true);
            if (bun.take(&this.pending_close)) |pending| pending.reason.deref();
            this.ping_received = false;
            this.pong_received = false;
            this.ping_len = 0;
            this.close_frame_buffering = false;
            this.receive_pending_chunk_len = 0;
            this.receiving_compressed = false;
            this.message_is_compressed = false;
            if (this.deflate) |d| d.deinit();
            this.deflate = null;
            if (this.secure) |s| {
                bun.BoringSSL.c.SSL_CTX_free(s);
                this.secure = null;
            }
            // Clean up proxy tunnel if we own one
            // Set to null FIRST to prevent re-entrancy (shutdown can trigger callbacks)
            if (this.proxy_tunnel) |tunnel| {
                this.proxy_tunnel = null;
                // Detach the websocket from the tunnel before shutdown so the
                // tunnel's onClose callback doesn't dispatch a spurious 1006
                // after we've already handled a clean close.
                tunnel.clearConnectedWebSocket();
                tunnel.shutdown();
                tunnel.deref();
                // Release the I/O-layer ref taken in createWithTunnel() — the
                // tunnel was this struct's socket-equivalent owner. In the
                // non-tunnel path this same ref is released by handleClose()
                // when the adopted uSockets socket fires its close event, but
                // tunnel mode never adopts a socket so that callback never runs.
                // Callers that touch `this` after clearData() must hold a local
                // ref guard (see cancel/finalize).
                this.deref();
            }
        }

        pub fn cancel(this: *WebSocket) void {
            log("cancel", .{});
            // clearData() may drop the tunnel's I/O-layer ref; keep `this`
            // alive until we've finished closing the socket below.
            this.ref();
            defer this.deref();

            const had_tunnel = this.proxy_tunnel != null;
            this.clearData();

            if (comptime ssl) {
                // we still want to send pending SSL buffer + close_notify
                this.tcp.close(.normal);
            } else {
                this.tcp.close(.failure);
            }

            // In tunnel mode tcp is .detached so close() above is a no-op and
            // handleClose() never fires. Mirror what handleClose() does for
            // the non-tunnel path: drop the C++ ref (if still held) via
            // dispatchAbruptClose so e.g. ws.terminate() — which calls
            // cancel() then sets m_connectedWebSocketKind = None, bypassing
            // the destructor's finalize() — does not leak. When reached via
            // fail(), outgoing_websocket is already null and this is a no-op.
            if (had_tunnel) {
                this.dispatchAbruptClose(ErrorCode.ended);
            }
        }

        pub fn fail(this: *WebSocket, code: ErrorCode) void {
            if (this.outgoing_websocket) |ws| {
                this.outgoing_websocket = null;
                log("fail ({s})", .{@tagName(code)});
                CppWebSocketEngine.didAbruptClose(this.globalThis, ws, code);
                this.deref();
            }

            this.cancel();
        }

        pub fn handleHandshake(this: *WebSocket, socket: Socket, success: i32, ssl_error: uws.us_bun_verify_error_t) void {
            const authorized = if (success == 1) true else false;

            log("onHandshake({d})", .{success});

            if (this.outgoing_websocket) |ws| {
                const reject_unauthorized = CppWebSocketEngine.rejectUnauthorized(ws);

                // Only reject the connection if reject_unauthorized is true
                if (reject_unauthorized) {
                    // Check for SSL errors
                    if (ssl_error.error_no != 0) {
                        this.outgoing_websocket = null;
                        CppWebSocketEngine.didAbruptClose(this.globalThis, ws, ErrorCode.failed_to_connect);
                        return;
                    }

                    // Check authorization status
                    if (!authorized) {
                        this.outgoing_websocket = null;
                        CppWebSocketEngine.didAbruptClose(this.globalThis, ws, ErrorCode.failed_to_connect);
                        return;
                    }

                    // Check server identity
                    const ssl_ptr = @as(*BoringSSL.c.SSL, @ptrCast(socket.getNativeHandle()));
                    if (BoringSSL.c.SSL_get_servername(ssl_ptr, 0)) |servername| {
                        const hostname = servername[0..bun.len(servername)];
                        if (!BoringSSL.checkServerIdentity(ssl_ptr, hostname)) {
                            this.outgoing_websocket = null;
                            CppWebSocketEngine.didAbruptClose(this.globalThis, ws, ErrorCode.failed_to_connect);
                        }
                    }
                }
                // If reject_unauthorized is false, we accept the connection regardless of SSL errors
            }
        }
        pub fn handleClose(this: *WebSocket, _: Socket, _: c_int, _: ?*anyopaque) void {
            log("onClose", .{});
            this.clearData();
            this.tcp.detach();

            this.dispatchAbruptClose(ErrorCode.ended);

            // For the socket.
            this.deref();
        }

        pub fn terminate(this: *WebSocket, code: ErrorCode) void {
            log("terminate", .{});
            this.fail(code);
        }

        fn clearReceiveBuffers(this: *WebSocket, free: bool) void {
            this.receive_buffer.head = 0;
            this.receive_buffer.count = 0;

            if (free) {
                this.receive_buffer.deinit();
                this.receive_buffer.buf.len = 0;
            }

            this.receive_pending_chunk_len = 0;
            this.receive_body_remain = 0;
        }

        fn clearSendBuffers(this: *WebSocket, free: bool) void {
            this.send_buffer.head = 0;
            this.send_buffer.count = 0;
            if (free) {
                this.send_buffer.deinit();
                this.send_buffer.buf.len = 0;
            }
        }

        fn dispatchCompressedData(this: *WebSocket, data_: []const u8, kind: Opcode) void {
            const deflate = this.deflate orelse {
                this.terminate(ErrorCode.compression_unsupported);
                return;
            };

            // Decompress the data
            var decompressed = deflate.rare_data.arrayList();
            defer decompressed.deinit();

            deflate.decompress(data_, &decompressed) catch |err| {
                const error_code = switch (err) {
                    error.InflateFailed => ErrorCode.invalid_compressed_data,
                    error.TooLarge => ErrorCode.message_too_big,
                    error.OutOfMemory => ErrorCode.failed_to_allocate_memory,
                };
                this.terminate(error_code);
                return;
            };

            this.dispatchData(decompressed.items, kind);
        }

        /// Data will be cloned in C++.
        fn dispatchData(this: *WebSocket, data_: []const u8, kind: Opcode) void {
            const out = this.outgoing_websocket orelse {
                this.clearData();
                return;
            };

            switch (kind) {
                .Text => {
                    // this function encodes to UTF-16 if > 127
                    // so we don't need to worry about latin1 non-ascii code points
                    // we avoid trim since we wanna keep the utf8 validation intact
                    const utf16_bytes_ = strings.toUTF16Alloc(bun.default_allocator, data_, true, false) catch {
                        this.terminate(ErrorCode.invalid_utf8);
                        return;
                    };
                    if (utf16_bytes_) |utf16| {
                        CppWebSocketEngine.didReceiveText(this.globalThis, out, false, .{ .utf16 = utf16 });
                    } else {
                        CppWebSocketEngine.didReceiveText(this.globalThis, out, true, .{ .latin1 = data_ });
                    }
                },
                .Binary, .Ping, .Pong => {
                    CppWebSocketEngine.didReceiveBytes(this.globalThis, out, data_, @backingInt(kind));
                },
                else => {
                    this.terminate(ErrorCode.unexpected_opcode);
                },
            }
        }

        pub fn consume(this: *WebSocket, data_: []const u8, left_in_fragment: usize, kind: Opcode, is_final: bool) usize {
            bun.assert(data_.len <= left_in_fragment);

            // For compressed messages, we must buffer all fragments until the message is complete
            if (this.receiving_compressed) {
                // Always buffer compressed data
                if (data_.len > 0) {
                    var writable = this.receive_buffer.writableWithSize(data_.len) catch {
                        this.terminate(ErrorCode.closed);
                        return 0;
                    };
                    @memcpy(writable[0..data_.len], data_);
                    this.receive_buffer.update(data_.len);
                }

                if (left_in_fragment >= data_.len and left_in_fragment - data_.len - this.receive_pending_chunk_len == 0) {
                    this.receive_pending_chunk_len = 0;
                    this.receive_body_remain = 0;
                    if (is_final) {
                        // Decompress the complete message
                        this.dispatchCompressedData(this.receive_buffer.readableSlice(0), kind);
                        this.clearReceiveBuffers(false);
                        this.receiving_compressed = false;
                        this.message_is_compressed = false;
                    }
                } else {
                    this.receive_pending_chunk_len -|= left_in_fragment;
                }
                return data_.len;
            }

            // Non-compressed path remains the same
            // did all the data fit in the buffer?
            // we can avoid copying & allocating a temporary buffer
            if (is_final and data_.len == left_in_fragment and this.receive_pending_chunk_len == 0) {
                if (this.receive_buffer.count == 0) {
                    this.dispatchData(data_, kind);
                    this.message_is_compressed = false;
                    return data_.len;
                } else if (data_.len == 0) {
                    this.dispatchData(this.receive_buffer.readableSlice(0), kind);
                    this.clearReceiveBuffers(false);
                    this.message_is_compressed = false;
                    return 0;
                }
            }

            // this must come after the above check
            if (data_.len == 0) return 0;

            var writable = this.receive_buffer.writableWithSize(data_.len) catch unreachable;
            @memcpy(writable[0..data_.len], data_);
            this.receive_buffer.update(data_.len);

            if (left_in_fragment >= data_.len and left_in_fragment - data_.len - this.receive_pending_chunk_len == 0) {
                this.receive_pending_chunk_len = 0;
                this.receive_body_remain = 0;
                if (is_final) {
                    this.dispatchData(this.receive_buffer.readableSlice(0), kind);
                    this.clearReceiveBuffers(false);
                    this.message_is_compressed = false;
                }
            } else {
                this.receive_pending_chunk_len -|= left_in_fragment;
            }
            return data_.len;
        }

        pub fn handleData(this: *WebSocket, socket: Socket, data_: []const u8) void {

            // after receiving close we should ignore the data
            if (this.close_received) return;
            this.ref();
            defer this.deref();

            // Due to scheduling, it is possible for the websocket onData
            // handler to run with additional data before the microtask queue is
            // drained.
            if (this.initial_data_handler) |initial_handler| {
                // This calls `handleData`
                // We deliberately do not set this.initial_data_handler to null here, that's done in handleWithoutDeinit.
                // We do not free the memory here since the lifetime is managed by the microtask queue (it should free when called from there)
                initial_handler.handleWithoutDeinit();

                // handleWithoutDeinit is supposed to clear the handler from WebSocket*
                // to prevent an infinite loop
                bun.assert(this.initial_data_handler == null);

                // If we disconnected for any reason in the re-entrant case, we should just ignore the data
                if (this.outgoing_websocket == null or !this.hasTCP())
                    return;
            }

            var data = data_;
            var receive_state = this.receive_state;
            var terminated = false;
            var is_fragmented = false;
            var receiving_type = this.receiving_type;
            var receive_body_remain = this.receive_body_remain;
            var is_final = this.receiving_is_final;
            var last_receive_data_type = receiving_type;

            defer {
                if (terminated) {
                    this.close_received = true;
                } else {
                    this.receive_state = receive_state;
                    this.receiving_type = last_receive_data_type;
                    this.receive_body_remain = receive_body_remain;
                }
            }

            var header_bytes: [@sizeOf(usize)]u8 = @splat(0);

            // In the WebSocket specification, control frames may not be fragmented.
            // However, the frame parser should handle fragmented control frames nonetheless.
            // Whether or not the frame parser is given a set of fragmented bytes to parse is subject
            // to the strategy in which the client buffers and coalesces received bytes.

            while (true) {
                log("onData ({s})", .{@tagName(receive_state)});

                switch (receive_state) {
                    // 0                   1                   2                   3
                    // 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
                    // +-+-+-+-+-------+-+-------------+-------------------------------+
                    // |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
                    // |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
                    // |N|V|V|V|       |S|             |   (if payload len==126/127)   |
                    // | |1|2|3|       |K|             |                               |
                    // +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
                    // |     Extended payload length continued, if payload len == 127  |
                    // + - - - - - - - - - - - - - - - +-------------------------------+
                    // |                               |Masking-key, if MASK set to 1  |
                    // +-------------------------------+-------------------------------+
                    // | Masking-key (continued)       |          Payload Data         |
                    // +-------------------------------- - - - - - - - - - - - - - - - +
                    // :                     Payload Data continued ...                :
                    // + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
                    // |                     Payload Data continued ...                |
                    // +---------------------------------------------------------------+
                    .need_header => {
                        if (data.len < 2) {
                            bun.assert(data.len > 0);
                            if (this.header_fragment == null) {
                                this.header_fragment = data[0];
                                break;
                            }
                        }

                        if (this.header_fragment) |header_fragment| {
                            header_bytes[0] = header_fragment;
                            header_bytes[1] = data[0];
                            data = data[1..];
                        } else {
                            header_bytes[0..2].* = data[0..2].*;
                            data = data[2..];
                        }
                        this.header_fragment = null;

                        receive_body_remain = 0;
                        var need_compression = false;
                        is_final = false;

                        receive_state = Protocol.parseHeader(
                            header_bytes[0..2].*,
                            &receiving_type,
                            &receive_body_remain,
                            &is_fragmented,
                            &is_final,
                            &need_compression,
                        );
                        if (receiving_type == .Continue) {
                            // if is final is true continue is invalid
                            if (this.receiving_is_final) {
                                // nothing to continue here
                                // Per Autobahn test case 5.9: "The connection is failed immediately, since there is no message to continue."
                                this.terminate(ErrorCode.unexpected_opcode);
                                terminated = true;
                                break;
                            }
                            // only update final if is a valid continue
                            this.receiving_is_final = is_final;
                        } else if (receiving_type == .Text or receiving_type == .Binary) {
                            // if the last one is not final this is invalid because we are waiting a continue
                            if (!this.receiving_is_final) {
                                this.terminate(ErrorCode.unexpected_opcode);
                                terminated = true;
                                break;
                            }
                            // for text and binary frames we need to keep track of final and type
                            this.receiving_is_final = is_final;
                            last_receive_data_type = receiving_type;
                        } else if (receiving_type.isControl() and is_fragmented) {
                            // Control frames must not be fragmented.
                            this.terminate(ErrorCode.control_frame_is_fragmented);
                            terminated = true;
                            break;
                        }

                        switch (receiving_type) {
                            .Continue, .Text, .Binary, .Ping, .Pong, .Close => {},
                            else => {
                                this.terminate(ErrorCode.unsupported_control_frame);
                                terminated = true;
                                break;
                            },
                        }

                        if (need_compression and this.deflate == null) {
                            this.terminate(ErrorCode.compression_unsupported);
                            terminated = true;
                            break;
                        }

                        // Control frames must not be compressed
                        if (need_compression and receiving_type.isControl()) {
                            this.terminate(ErrorCode.invalid_control_frame);
                            terminated = true;
                            break;
                        }

                        // Track compression state for this message
                        if (receiving_type == .Text or receiving_type == .Binary) {
                            // New message starts - set both compression states
                            this.message_is_compressed = need_compression;
                            this.receiving_compressed = need_compression;
                        } else if (receiving_type == .Continue) {
                            // Continuation frame - use the compression state from the message start
                            this.receiving_compressed = this.message_is_compressed;
                        }

                        // Handle when the payload length is 0, but it is a message
                        //
                        // This should become
                        //
                        // - ArrayBuffer(0)
                        // - ""
                        // - Buffer(0) (etc)
                        //
                        if (receive_body_remain == 0 and receive_state == .need_body and is_final) {
                            _ = this.consume(
                                "",
                                receive_body_remain,
                                last_receive_data_type,
                                is_final,
                            );

                            // Return to the header state to read the next frame
                            receive_state = .need_header;
                            is_fragmented = false;
                            this.receiving_compressed = false;
                            this.message_is_compressed = false;

                            // Bail out if there's nothing left to read
                            if (data.len == 0) break;
                        }
                    },
                    .need_mask => {
                        this.terminate(.unexpected_mask_from_server);
                        terminated = true;
                        break;
                    },
                    .extended_payload_length_64, .extended_payload_length_16 => |rc| {
                        const byte_size = switch (rc) {
                            .extended_payload_length_64 => @as(usize, 8),
                            .extended_payload_length_16 => @as(usize, 2),
                            else => unreachable,
                        };

                        // we need to wait for more data
                        if (data.len == 0) {
                            break;
                        }

                        // copy available payload length bytes to a buffer held on this client instance
                        const total_received = @min(byte_size - this.payload_length_frame_len, data.len);
                        @memcpy(this.payload_length_frame_bytes[this.payload_length_frame_len..][0..total_received], data[0..total_received]);
                        this.payload_length_frame_len += @intCast(total_received);
                        data = data[total_received..];

                        // short read on payload length - we need to wait for more data
                        // whatever bytes were returned from the short read are kept in `payload_length_frame_bytes`
                        if (this.payload_length_frame_len < byte_size) {
                            break;
                        }

                        // Multibyte length quantities are expressed in network byte order
                        receive_body_remain = switch (byte_size) {
                            8 => @as(usize, std.mem.readInt(u64, this.payload_length_frame_bytes[0..8], .big)),
                            2 => @as(usize, std.mem.readInt(u16, this.payload_length_frame_bytes[0..2], .big)),
                            else => unreachable,
                        };

                        this.payload_length_frame_len = 0;

                        receive_state = .need_body;

                        if (receive_body_remain == 0) {
                            // this is an error
                            // the server should've set length to zero
                            this.terminate(ErrorCode.invalid_control_frame);
                            terminated = true;
                            break;
                        }
                    },
                    .ping => {
                        if (!this.ping_received) {
                            if (receive_body_remain > 125) {
                                this.terminate(ErrorCode.invalid_control_frame);
                                terminated = true;
                                break;
                            }
                            this.ping_len = @truncate(receive_body_remain);
                            receive_body_remain = 0;
                            this.ping_received = true;
                        }
                        const ping_len = this.ping_len;

                        if (data.len > 0) {
                            // copy the data to the ping frame
                            const total_received = @min(ping_len, receive_body_remain + data.len);
                            const slice = this.ping_frame_bytes[6..][receive_body_remain..total_received];
                            @memcpy(slice, data[0..slice.len]);
                            receive_body_remain = total_received;
                            data = data[slice.len..];
                        }
                        const pending_body = ping_len - receive_body_remain;
                        if (pending_body > 0) {
                            // wait for more data it can be fragmented
                            break;
                        }

                        const ping_data = this.ping_frame_bytes[6..][0..ping_len];
                        this.dispatchData(ping_data, .Ping);

                        receive_state = .need_header;
                        receive_body_remain = 0;
                        receiving_type = last_receive_data_type;
                        this.ping_received = false;

                        // we need to send all pongs to pass autobahn tests
                        _ = this.sendPong(socket);
                        if (data.len == 0) break;
                    },
                    .pong => {
                        if (!this.pong_received) {
                            if (receive_body_remain > 125) {
                                this.terminate(ErrorCode.invalid_control_frame);
                                terminated = true;
                                break;
                            }
                            this.ping_len = @truncate(receive_body_remain);
                            receive_body_remain = 0;
                            this.pong_received = true;
                        }
                        const pong_len = this.ping_len;

                        if (data.len > 0) {
                            const total_received = @min(pong_len, receive_body_remain + data.len);
                            const slice = this.ping_frame_bytes[6..][receive_body_remain..total_received];
                            @memcpy(slice, data[0..slice.len]);
                            receive_body_remain = total_received;
                            data = data[slice.len..];
                        }
                        const pending_body = pong_len - receive_body_remain;
                        if (pending_body > 0) {
                            // wait for more data - pong payload is fragmented across TCP segments
                            break;
                        }

                        const pong_data = this.ping_frame_bytes[6..][0..pong_len];
                        this.dispatchData(pong_data, .Pong);

                        receive_state = .need_header;
                        receive_body_remain = 0;
                        receiving_type = last_receive_data_type;
                        this.pong_received = false;

                        if (data.len == 0) break;
                    },
                    .need_body => {
                        const to_consume = @min(receive_body_remain, data.len);

                        const consumed = this.consume(data[0..to_consume], receive_body_remain, last_receive_data_type, is_final);

                        receive_body_remain -= consumed;
                        data = data[to_consume..];
                        if (receive_body_remain == 0) {
                            receive_state = .need_header;
                            is_fragmented = false;
                        }

                        if (data.len == 0) break;
                    },

                    .close => {
                        if (receive_body_remain == 1 or receive_body_remain > 125) {
                            this.terminate(ErrorCode.invalid_control_frame);
                            terminated = true;
                            break;
                        }

                        if (receive_body_remain > 0) {
                            if (!this.close_frame_buffering) {
                                this.ping_len = @truncate(receive_body_remain);
                                receive_body_remain = 0;
                                this.close_frame_buffering = true;
                            }
                            const to_copy = @min(data.len, this.ping_len - receive_body_remain);
                            @memcpy(this.ping_frame_bytes[6 + receive_body_remain ..][0..to_copy], data[0..to_copy]);
                            receive_body_remain += to_copy;
                            data = data[to_copy..];
                            if (receive_body_remain < this.ping_len) break;

                            this.close_received = true;
                            const close_data = this.ping_frame_bytes[6..][0..this.ping_len];
                            if (this.ping_len >= 2) {
                                var code = std.mem.readInt(u16, close_data[0..2], .big);
                                if (code == 1001) code = 1000;
                                if ((code < 1000) or (code >= 1004 and code < 1007) or (code >= 1016 and code <= 2999)) code = 1002;
                                var buf: [125]u8 = undefined;
                                @memcpy(buf[0 .. this.ping_len - 2], close_data[2..this.ping_len]);
                                this.sendCloseWithBody(socket, code, buf[0 .. this.ping_len - 2]);
                            } else {
                                this.sendClose();
                            }
                            this.close_frame_buffering = false;
                            terminated = true;
                            break;
                        }

                        this.close_received = true;
                        this.sendClose();
                        terminated = true;
                        break;
                    },
                    .fail => {
                        this.terminate(ErrorCode.unsupported_control_frame);
                        terminated = true;
                        break;
                    },
                }
            }
        }

        pub fn sendClose(this: *WebSocket) void {
            this.sendCloseWithBody(this.tcp, 1000, &.{});
        }

        fn enqueueEncodedBytes(
            this: *WebSocket,
            socket: Socket,
            bytes: []const u8,
        ) bool {
            // For tunnel mode, write through the tunnel instead of direct socket
            if (this.proxy_tunnel) |tunnel| {
                const wrote = tunnel.write(bytes) catch {
                    this.terminate(ErrorCode.failed_to_write);
                    return false;
                };
                // Buffer any data the tunnel couldn't accept
                if (wrote < bytes.len) {
                    _ = this.copyToSendBuffer(bytes[wrote..], false);
                }
                return true;
            }

            // fast path: no backpressure, no queue, just send the bytes.
            if (!this.hasBackpressure()) {
                // Do not set MSG_MORE, see https://github.com/oven-sh/bun/issues/4010
                const wrote = socket.write(bytes);
                const expected = @as(c_int, @intCast(bytes.len));
                if (wrote == expected) {
                    return true;
                }

                if (wrote < 0) {
                    this.terminate(ErrorCode.failed_to_write);
                    return false;
                }

                _ = this.copyToSendBuffer(bytes[@as(usize, @intCast(wrote))..], false);
                return true;
            }

            return this.copyToSendBuffer(bytes, true);
        }

        fn copyToSendBuffer(this: *WebSocket, bytes: []const u8, do_write: bool) bool {
            return this.sendData(.{ .raw = bytes }, do_write, .Binary);
        }

        fn sendData(this: *WebSocket, bytes: Copy, do_write: bool, opcode: Opcode) bool {
            const should_compress = this.deflate != null and (opcode == .Text or opcode == .Binary) and bytes != .raw;

            if (should_compress) {
                // For compressed messages, we need to compress the content first
                var temp_buffer: ?[]u8 = null;
                const allocator = this.deflate.?.rare_data.allocator();
                defer if (temp_buffer) |buf| allocator.free(buf);
                const content_to_compress: []const u8 = switch (bytes) {
                    .utf16 => |utf16| brk: {
                        // Convert UTF16 to UTF8 for compression
                        const content_byte_len: usize = strings.elementLengthUTF16IntoUTF8(utf16);
                        temp_buffer = allocator.alloc(u8, content_byte_len) catch return false;
                        const encode_result = strings.copyUTF16IntoUTF8(temp_buffer.?, utf16);
                        break :brk temp_buffer.?[0..encode_result.written];
                    },
                    .latin1 => |latin1| brk: {
                        // Convert Latin1 to UTF8 for compression
                        const content_byte_len: usize = strings.elementLengthLatin1IntoUTF8(latin1);
                        if (content_byte_len == latin1.len) {
                            // It's all ascii, we don't need to copy it an extra time.
                            break :brk latin1;
                        }

                        temp_buffer = allocator.alloc(u8, content_byte_len) catch return false;
                        const encode_result = strings.copyLatin1IntoUTF8(temp_buffer.?, latin1);
                        break :brk temp_buffer.?[0..encode_result.written];
                    },
                    .bytes => |b| b,
                    .raw => unreachable,
                };

                // Check if compression is worth it
                if (!this.shouldCompress(content_to_compress.len, opcode)) {
                    return this.sendDataUncompressed(bytes, do_write, opcode);
                }

                {
                    // Compress the content
                    var compressed = std.array_list.Managed(u8).init(allocator);
                    defer compressed.deinit();

                    this.deflate.?.compress(content_to_compress, &compressed) catch {
                        // If compression fails, fall back to uncompressed
                        return this.sendDataUncompressed(bytes, do_write, opcode);
                    };

                    // Create the compressed frame
                    const frame_size = WebsocketHeader.frameSizeIncludingMask(compressed.items.len);
                    const writable = this.send_buffer.writableWithSize(frame_size) catch return false;
                    Copy.writeCompressedFrame(nextMask(this.globalThis), writable[0..frame_size], compressed.items, opcode, true);
                    this.send_buffer.update(frame_size);
                }

                if (do_write) {
                    if (comptime Environment.allow_assert) {
                        if (this.proxy_tunnel == null) {
                            bun.assert(!this.tcp.isShutdown());
                            bun.assert(!this.tcp.isClosed());
                            bun.assert(this.tcp.isEstablished());
                        }
                    }
                    return this.sendBuffer(this.send_buffer.readableSlice(0));
                }
            } else {
                return this.sendDataUncompressed(bytes, do_write, opcode);
            }

            return true;
        }

        fn sendDataUncompressed(this: *WebSocket, bytes: Copy, do_write: bool, opcode: Opcode) bool {
            var content_byte_len: usize = 0;
            const write_len = bytes.len(&content_byte_len);
            bun.assert(write_len > 0);

            const writable = this.send_buffer.writableWithSize(write_len) catch unreachable;
            writeFrame(bytes, this.globalThis, writable[0..write_len], content_byte_len, opcode);
            this.send_buffer.update(write_len);

            if (do_write) {
                if (comptime Environment.allow_assert) {
                    if (this.proxy_tunnel == null) {
                        bun.assert(!this.tcp.isShutdown());
                        bun.assert(!this.tcp.isClosed());
                        bun.assert(this.tcp.isEstablished());
                    }
                }
                return this.sendBuffer(this.send_buffer.readableSlice(0));
            }

            return true;
        }

        fn sendBuffer(
            this: *WebSocket,
            out_buf: []const u8,
        ) bool {
            bun.assert(out_buf.len > 0);
            // Do not use MSG_MORE, see https://github.com/oven-sh/bun/issues/4010
            const wrote: usize = if (this.proxy_tunnel) |tunnel|
                // In tunnel mode, route through the tunnel's TLS layer
                // instead of the detached raw socket.
                tunnel.write(out_buf) catch {
                    this.terminate(ErrorCode.failed_to_write);
                    return false;
                }
            else blk: {
                if (this.tcp.isClosed()) {
                    return false;
                }
                const w = this.tcp.write(out_buf);
                if (w < 0) {
                    this.terminate(ErrorCode.failed_to_write);
                    return false;
                }
                break :blk @intCast(w);
            };
            const readable = this.send_buffer.readableSlice(0);
            if (readable.ptr == out_buf.ptr) {
                this.send_buffer.discard(wrote);
            }
            return true;
        }

        fn sendPong(this: *WebSocket, socket: Socket) bool {
            if (!this.hasTCP()) {
                this.dispatchAbruptClose(ErrorCode.ended);
                return false;
            }

            var header = @as(WebsocketHeader, @bitCast(@as(u16, 0)));
            header.final = true;
            header.opcode = .Pong;

            const to_mask = this.ping_frame_bytes[6..][0..this.ping_len];

            header.mask = true;
            header.len = @as(u7, @truncate(this.ping_len));
            this.ping_frame_bytes[0..2].* = header.slice();

            if (to_mask.len > 0) {
                Protocol.applyMask(nextMask(this.globalThis), this.ping_frame_bytes[2..6], to_mask, to_mask);
                return this.enqueueEncodedBytes(socket, this.ping_frame_bytes[0 .. 6 + @as(usize, this.ping_len)]);
            } else {
                @memset(this.ping_frame_bytes[2..6], 0); //autobahn tests require that we mask empty pongs
                return this.enqueueEncodedBytes(socket, this.ping_frame_bytes[0..6]);
            }
        }

        fn sendCloseWithBody(
            this: *WebSocket,
            socket: Socket,
            code: u16,
            body: []const u8,
        ) void {
            bun.assert(body.len <= 123);
            if (this.pending_close != null) return;
            log("Sending close with code {d}", .{code});
            if (!this.hasTCP()) {
                this.dispatchAbruptClose(ErrorCode.ended);
                this.clearData();
                return;
            }
            var final_body_bytes: [128 + 8]u8 = undefined;
            var header = @as(WebsocketHeader, @bitCast(@as(u16, 0)));
            header.final = true;
            header.opcode = .Close;
            header.mask = true;
            header.len = @as(u7, @truncate(body.len + 2));
            final_body_bytes[0..2].* = header.slice();
            const mask_buf: *[4]u8 = final_body_bytes[2..6];
            final_body_bytes[6..8].* = @bitCast(@byteSwap(code));

            var reason = bun.String.empty;
            if (body.len > 0) {
                // close is always utf8
                if (!strings.isValidUTF8(body)) {
                    this.terminate(ErrorCode.invalid_utf8);
                    return;
                }
                reason = bun.String.cloneUTF8(body);
                @memcpy(final_body_bytes[8..][0..body.len], body);
            }

            // we must mask the code
            var slice = final_body_bytes[0 .. 8 + body.len];
            Protocol.applyMask(nextMask(this.globalThis), mask_buf, slice[6..], slice[6..]);

            this.pending_close = .{ .code = code, .reason = reason };
            if (this.enqueueEncodedBytes(socket, slice)) this.finishCloseIfDrained();
        }
        fn finishCloseIfDrained(this: *WebSocket) void {
            if (this.pending_close == null or this.hasBackpressure()) return;
            this.ref();
            defer this.deref();

            var pending = bun.take(&this.pending_close).?;
            defer pending.reason.deref();
            this.clearData();
            this.dispatchClose(pending.code, &pending.reason);
            this.tcp.close(.normal);
        }

        pub fn isSameSocket(this: *WebSocket, socket: Socket) bool {
            return socket.socket.eq(this.tcp.socket);
        }

        pub fn handleEnd(this: *WebSocket, socket: Socket) void {
            bun.assert(this.isSameSocket(socket));
            this.terminate(ErrorCode.ended);
        }

        pub fn handleWritable(
            this: *WebSocket,
            socket: Socket,
        ) void {
            if (this.close_received and this.pending_close == null) return;
            this.ref();
            defer this.deref();
            bun.assert(this.isSameSocket(socket));
            const send_buf = this.send_buffer.readableSlice(0);
            if (send_buf.len > 0 and !this.sendBuffer(send_buf)) return;
            this.finishCloseIfDrained();
        }
        pub fn handleTimeout(
            this: *WebSocket,
            _: Socket,
        ) void {
            this.terminate(ErrorCode.timeout);
        }
        pub fn handleConnectError(this: *WebSocket, _: Socket, _: uws.ConnectFailure) void {
            this.tcp.detach();
            this.terminate(ErrorCode.failed_to_connect);
        }

        pub fn hasBackpressure(this: *const WebSocket) bool {
            if (this.send_buffer.count > 0) return true;
            if (this.proxy_tunnel) |tunnel| return tunnel.hasBackpressure();
            return false;
        }

        pub fn writeBinaryData(
            this: *WebSocket,
            data: []const u8,
            op: u8,
        ) void {
            // In tunnel mode, SSLWrapper.writeData() can synchronously fire
            // onClose → ws.fail() → cancel() → clearData() and free `this`
            // before the catch block in enqueueEncodedBytes/sendBuffer runs.
            this.ref();
            defer this.deref();

            if (!this.hasTCP() or op > 0xF) {
                this.dispatchAbruptClose(ErrorCode.ended);
                return;
            }

            const opcode: Opcode = @fromBackingInt(@intCast(op));
            const bytes = Copy{ .bytes = data };
            // fast path: small frame, no backpressure, attempt to send without allocating
            const frame_size = WebsocketHeader.frameSizeIncludingMask(data.len);
            if (!this.hasBackpressure() and frame_size < stack_frame_size) {
                var inline_buf: [stack_frame_size]u8 = undefined;
                writeFrame(bytes, this.globalThis, inline_buf[0..frame_size], data.len, opcode);
                _ = this.enqueueEncodedBytes(this.tcp, inline_buf[0..frame_size]);
                return;
            }

            _ = this.sendData(bytes, !this.hasBackpressure(), opcode);
        }
        fn hasTCP(this: *WebSocket) bool {
            // For tunnel mode, we have an active connection through the tunnel
            if (this.proxy_tunnel != null) return true;
            return !this.tcp.isClosed() and !this.tcp.isShutdown();
        }

        pub fn writeString(
            this: *WebSocket,
            code_units: bun.bindgen.UnsafeStringCodeUnits,
            op: u8,
        ) void {
            // See writeBinaryData() — tunnel.write() can re-enter fail().
            this.ref();
            defer this.deref();

            if (!this.hasTCP()) {
                this.dispatchAbruptClose(ErrorCode.ended);
                return;
            }
            const tcp = this.tcp;

            // Note: 0 is valid

            const opcode = @as(Opcode, @fromBackingInt(@intCast(@as(u4, @truncate(op)))));
            {
                var inline_buf: [stack_frame_size]u8 = undefined;

                switch (code_units) {
                    .latin1 => |latin1| if (latin1.len < stack_frame_size) {
                        const bytes = Copy{ .latin1 = latin1 };
                        var byte_len: usize = 0;
                        const frame_size = bytes.len(&byte_len);
                        if (!this.hasBackpressure() and frame_size < stack_frame_size) {
                            writeFrame(bytes, this.globalThis, inline_buf[0..frame_size], byte_len, opcode);
                            _ = this.enqueueEncodedBytes(tcp, inline_buf[0..frame_size]);
                            return;
                        }
                    },
                    .utf16 => |utf16| if ((utf16.len * 4) < stack_frame_size and !this.hasBackpressure()) {
                        const bytes = Copy{ .utf16 = utf16 };
                        var byte_len: usize = 0;
                        const frame_size = bytes.len(&byte_len);
                        bun.assert(frame_size <= stack_frame_size);
                        writeFrame(bytes, this.globalThis, inline_buf[0..frame_size], byte_len, opcode);
                        _ = this.enqueueEncodedBytes(tcp, inline_buf[0..frame_size]);
                        return;
                    },
                }
            }

            _ = this.sendData(
                switch (code_units) {
                    .latin1 => |latin1| Copy{ .latin1 = latin1 },
                    .utf16 => |utf16| Copy{ .utf16 = utf16 },
                },
                !this.hasBackpressure(),
                opcode,
            );
        }

        fn dispatchAbruptClose(this: *WebSocket, code: ErrorCode) void {
            const out = this.outgoing_websocket orelse return;
            this.poll_ref.unref(this.globalThis.bunVM());
            this.outgoing_websocket = null;
            CppWebSocketEngine.didAbruptClose(this.globalThis, out, code);
            this.deref();
        }

        fn dispatchClose(this: *WebSocket, code: u16, reason: *bun.String) void {
            const out = this.outgoing_websocket orelse return;
            this.poll_ref.unref(this.globalThis.bunVM());
            this.outgoing_websocket = null;
            CppWebSocketEngine.didClose(this.globalThis, out, code, reason);
            this.deref();
        }

        pub fn close(this: *WebSocket, code: u16, reason: []const u8) void {
            // In tunnel mode, SSLWrapper.writeData() (via sendCloseWithBody →
            // enqueueEncodedBytes → tunnel.write) can synchronously fire
            // onClose → ws.fail() → cancel() → clearData() and free `this`
            // before sendCloseWithBody's own clearData/dispatchClose run.
            this.ref();
            defer this.deref();

            if (!this.hasTCP()) {
                this.terminate(ErrorCode.ended);
                return;
            }
            const tcp = this.tcp;
            this.sendCloseWithBody(tcp, code, reason);
        }

        const InitialDataHandler = struct {
            task: jsc.NativeMicrotask = undefined,
            adopted: ?bun.bindgen.RefNative(WebSocket, .vm),
            ws: *CppWebSocket,
            slice: []u8,

            pub fn create(adopted: *WebSocket, ws: *CppWebSocket, bytes: []const u8) bun.OOM!*@This() {
                const slice = try bun.default_allocator.dupe(u8, bytes);
                CppWebSocketEngine.ref(ws);
                return jsc.NativeMicrotask.create(@This(), .{
                    .adopted = .init(adopted),
                    .ws = ws,
                    .slice = slice,
                });
            }

            pub fn handleWithoutDeinit(this: *@This()) void {
                var adopted = bun.take(&this.adopted) orelse return;
                defer adopted.deinit();
                const this_socket = adopted.get();
                this_socket.initial_data_handler = null;
                const ws = this.ws;
                defer CppWebSocketEngine.unref(ws);

                // For tunnel mode, tcp is detached but connection is still active through the tunnel
                const is_connected = !this_socket.tcp.isClosed() or this_socket.proxy_tunnel != null;
                if (this_socket.outgoing_websocket != null and is_connected) {
                    this_socket.handleData(this_socket.tcp, this.slice);
                }
            }

            pub fn run(this: *@This()) void {
                this.handleWithoutDeinit();
            }

            pub fn deinit(this: *@This()) void {
                if (bun.take(&this.adopted)) |value| {
                    var adopted = value;
                    adopted.get().initial_data_handler = null;
                    CppWebSocketEngine.unref(this.ws);
                    adopted.deinit();
                }
                bun.default_allocator.free(this.slice);
            }
        };

        fn queueInitialData(this: *WebSocket, buffered_data: []const u8) bun.JSError!void {
            if (buffered_data.len == 0) return;
            const initial_data = try InitialDataHandler.create(this, this.outgoing_websocket.?, buffered_data);
            this.initial_data_handler = initial_data;
            try this.globalThis.queueMicrotaskTask(&initial_data.task);
        }

        const AdoptionError = bun.JSError || error{ DeflateInitFailed, InflateInitFailed };

        fn adoptionFailure(comptime Schema: type, context: bun.bindgen.CallContext(Schema), err: AdoptionError) bun.bindgen.CallError(Schema) {
            return switch (err) {
                error.DeflateInitFailed, error.InflateInitFailed => context.fail(.compression_init_failed, {}),
                else => |failure| failure,
            };
        }

        pub fn adoptSocket(
            outgoing: *CppWebSocket,
            input_socket: *uws.us_socket_t,
            globalThis: *jsc.JSGlobalObject,
            buffered_data: []const u8,
            deflate_params: ?*const WebSocketDeflate.Params,
            secure: ?*uws.SslCtx,
        ) AdoptionError!?*WebSocket {
            const vm = globalThis.bunVM();
            const ws = try bun.default_allocator.create(WebSocket);
            ws.* = .{
                .ref_count = .init(),
                .tcp = .{ .socket = .{ .detached = {} } },
                .outgoing_websocket = outgoing,
                .globalThis = globalThis,
                .send_buffer = bun.LinearFifo(u8, .Dynamic).init(bun.default_allocator),
                .receive_buffer = bun.LinearFifo(u8, .Dynamic).init(bun.default_allocator),
                .event_loop = vm.eventLoop(),
                .secure = if (secure) |context| retained: {
                    _ = bun.BoringSSL.c.SSL_CTX_up_ref(context);
                    break :retained context;
                } else null,
            };
            errdefer ws.deref();

            if (deflate_params) |params| {
                ws.deflate = try WebSocketDeflate.init(bun.default_allocator, params.*, vm.rareData().websocketDeflate());
            }

            try ws.send_buffer.ensureTotalCapacity(2048);
            try ws.receive_buffer.ensureTotalCapacity(2048);
            try ws.queueInitialData(buffered_data);

            if (!Socket.adoptGroup(
                input_socket,
                vm.rareData().wsClientGroup(vm, ssl),
                if (ssl) .ws_client_tls else .ws_client,
                WebSocket,
                "tcp",
                ws,
            )) {
                ws.deref();
                return null;
            }

            ws.poll_ref.ref(globalThis.bunVM());

            // And lastly, ref the new websocket since C++ has a reference to it
            ws.ref();

            return ws;
        }

        /// Initialize a WebSocket client that uses a proxy tunnel for I/O.
        /// Used for wss:// through HTTP proxy where TLS is handled by the tunnel.
        /// The tunnel takes ownership of socket I/O, and this client reads/writes through it.
        pub fn createWithTunnel(
            outgoing: *CppWebSocket,
            tunnel: *WebSocketProxyTunnel,
            globalThis: *jsc.JSGlobalObject,
            buffered_data: []const u8,
            deflate_params: ?*const WebSocketDeflate.Params,
        ) AdoptionError!*WebSocket {
            // ref_count starts at 1: this is the I/O-layer ref, owned by the
            // tunnel connection (analogous to the adopted-socket ref in adoptSocket()
            // that handleClose() releases). It is released in clearData() when
            // proxy_tunnel is detached. The ws.ref() below adds the C++ ref
            // paired with m_connectedWebSocket.
            const ws = try bun.default_allocator.create(WebSocket);
            ws.* = .{
                .ref_count = .init(),
                .tcp = .{ .socket = .{ .detached = {} } }, // No direct socket - using tunnel
                .outgoing_websocket = outgoing,
                .globalThis = globalThis,
                .send_buffer = bun.LinearFifo(u8, .Dynamic).init(bun.default_allocator),
                .receive_buffer = bun.LinearFifo(u8, .Dynamic).init(bun.default_allocator),
                .event_loop = globalThis.bunVM().eventLoop(),
            };
            errdefer ws.deref();

            if (deflate_params) |params| {
                ws.deflate = try WebSocketDeflate.init(bun.default_allocator, params.*, globalThis.bunVM().rareData().websocketDeflate());
            }

            try ws.send_buffer.ensureTotalCapacity(2048);
            try ws.receive_buffer.ensureTotalCapacity(2048);
            try ws.queueInitialData(buffered_data);

            tunnel.ref();
            ws.proxy_tunnel = tunnel;
            ws.poll_ref.ref(globalThis.bunVM());
            ws.ref();

            return ws;
        }

        /// Handle data received from the proxy tunnel (already decrypted).
        /// Called by the WebSocketProxyTunnel when it receives and decrypts data.
        pub fn handleTunnelData(this: *WebSocket, data: []const u8) void {
            // Process the decrypted data as if it came from the socket
            // hasTCP() now returns true for tunnel mode, so this will work correctly
            this.handleData(this.tcp, data);
        }

        /// Called by the WebSocketProxyTunnel when the underlying socket drains.
        /// Flushes any buffered plaintext data through the tunnel.
        pub fn handleTunnelWritable(this: *WebSocket) void {
            if (this.close_received and this.pending_close == null) return;
            // sendBuffer → tunnel.write() can re-enter fail() synchronously
            // (see writeBinaryData). The tunnel ref-guards itself in
            // onWritable() but not this struct.
            this.ref();
            defer this.deref();

            const send_buf = this.send_buffer.readableSlice(0);
            if (send_buf.len > 0 and !this.sendBuffer(send_buf)) return;
            this.finishCloseIfDrained();
        }

        pub fn finalize(this: *WebSocket) void {
            log("finalize", .{});
            // clearData() may drop the tunnel's I/O-layer ref and the block
            // below drops the C++ ref; keep `this` alive until we've finished
            // the tcp close check.
            this.ref();
            defer this.deref();

            this.clearData();

            // This is only called by outgoing_websocket.
            if (this.outgoing_websocket != null) {
                this.outgoing_websocket = null;
                this.deref();
            }

            if (!this.tcp.isClosed()) {
                // no need to be .failure we still wanna to send pending SSL buffer + close_notify
                if (comptime ssl) {
                    this.tcp.close(.normal);
                } else {
                    this.tcp.close(.failure);
                }
            }
        }

        pub fn deinit(this: *WebSocket) void {
            this.clearData();
            if (this.deflate) |d| d.deinit();
            this.deflate = null;
            bun.destroy(this);
        }

        pub fn memoryCost(this: *WebSocket) usize {
            var cost: usize = @sizeOf(WebSocket);
            cost += this.send_buffer.buf.len;
            cost += this.receive_buffer.buf.len;
            // This is under-estimated a little, as we don't include usockets context.
            return cost;
        }

        const binding_prefix = if (ssl) "webSocketClientTLS" else "webSocketClient";
        const AdoptSocketSchema = WebSocketBindings.nativeExport(binding_prefix ++ "AdoptSocket");
        const CancelSchema = WebSocketBindings.nativeExport(binding_prefix ++ "Cancel");
        const CloseSchema = WebSocketBindings.nativeExport(binding_prefix ++ "Close");
        const FinalizeSchema = WebSocketBindings.nativeExport(binding_prefix ++ "Finalize");
        const MemoryCostSchema = WebSocketBindings.nativeExport(binding_prefix ++ "MemoryCost");
        const WriteBytesSchema = WebSocketBindings.nativeExport(binding_prefix ++ "WriteBytes");
        const WriteTextSchema = WebSocketBindings.nativeExport(binding_prefix ++ "WriteText");
        const CreateWithTunnelSchema = WebSocketBindings.nativeExport("webSocketClientCreateWithTunnel");

        fn bindAdoptSocket(
            context: bun.bindgen.CallContext(AdoptSocketSchema),
            args: *bun.bindgen.Args(AdoptSocketSchema),
        ) bun.bindgen.CallError(AdoptSocketSchema)!bun.bindgen.Return(AdoptSocketSchema) {
            const buffered_data = args.bufferedData.unsafePtr("the generated native-export frame owns the initial data until adoptSocket copies it");
            const outgoing = args.outgoing;
            const socket = args.socket.get();
            const deflate_params: ?*const WebSocketDeflate.Params = if (args.deflateParams) |params| @ptrCast(@alignCast(params)) else null;
            const secure = args.sslContext;
            const client = (adoptSocket(outgoing, socket, context.viewToken().globalObject(), buffered_data, deflate_params, secure) catch |err|
                return adoptionFailure(AdoptSocketSchema, context, err)) orelse return null;
            _ = args.socket.takeNative();
            const Owner = @typeInfo(bun.bindgen.Return(AdoptSocketSchema)).optional.child;
            return Owner.initNative(client);
        }

        fn bindCreateWithTunnel(
            context: bun.bindgen.CallContext(CreateWithTunnelSchema),
            args: bun.bindgen.Args(CreateWithTunnelSchema),
        ) bun.bindgen.CallError(CreateWithTunnelSchema)!bun.bindgen.Return(CreateWithTunnelSchema) {
            const buffered_data = args.bufferedData.unsafePtr("the generated native-export frame owns the initial data until createWithTunnel copies it");
            const outgoing = args.outgoing;
            const tunnel = args.tunnel;
            const deflate_params: ?*const WebSocketDeflate.Params = if (args.deflateParams) |params| @ptrCast(@alignCast(params)) else null;
            const client = createWithTunnel(outgoing, tunnel, context.viewToken().globalObject(), buffered_data, deflate_params) catch |err|
                return adoptionFailure(CreateWithTunnelSchema, context, err);
            return bun.bindgen.Return(CreateWithTunnelSchema).initNative(client);
        }

        fn bindCancel(args: bun.bindgen.Args(CancelSchema)) bun.bindgen.Return(CancelSchema) {
            args.client.cancel();
        }

        fn bindClose(args: bun.bindgen.Args(CloseSchema)) bun.bindgen.Return(CloseSchema) {
            args.client.close(args.code, args.reason.unsafePtr("the C++ close call keeps the reason bytes alive until the synchronous send returns"));
        }

        fn bindFinalize(args: *bun.bindgen.Args(FinalizeSchema)) bun.bindgen.Return(FinalizeSchema) {
            args.client.takeNative().finalize();
        }

        fn bindMemoryCost(args: bun.bindgen.Args(MemoryCostSchema)) bun.bindgen.Return(MemoryCostSchema) {
            return args.client.memoryCost();
        }

        fn bindWriteBytes(args: bun.bindgen.Args(WriteBytesSchema)) bun.bindgen.Return(WriteBytesSchema) {
            const bytes = args.bytes.unsafePtr("the C++ caller owns the input bytes until the synchronous WebSocket send encodes or copies the frame");
            args.client.writeBinaryData(bytes, args.opcode);
        }

        fn bindWriteText(args: bun.bindgen.Args(WriteTextSchema)) bun.bindgen.Return(WriteTextSchema) {
            const code_units = args.text.unsafePtr("the C++ caller owns the string until the synchronous WebSocket send encodes the frame");
            args.client.writeString(code_units, args.opcode);
        }

        const AdoptSocketBinding = bun.bindgen.Fn(AdoptSocketSchema, bindAdoptSocket);
        const CreateWithTunnelBinding = if (ssl) void else bun.bindgen.Fn(CreateWithTunnelSchema, bindCreateWithTunnel);
        const CancelBinding = bun.bindgen.Fn(CancelSchema, bindCancel);
        const CloseBinding = bun.bindgen.Fn(CloseSchema, bindClose);
        const FinalizeBinding = bun.bindgen.Fn(FinalizeSchema, bindFinalize);
        const MemoryCostBinding = bun.bindgen.Fn(MemoryCostSchema, bindMemoryCost);
        const WriteBytesBinding = bun.bindgen.Fn(WriteBytesSchema, bindWriteBytes);
        const WriteTextBinding = bun.bindgen.Fn(WriteTextSchema, bindWriteText);

        pub fn exportAll() void {
            comptime {
                _ = AdoptSocketBinding;
                if (!ssl) _ = CreateWithTunnelBinding;
                _ = CancelBinding;
                _ = CloseBinding;
                _ = FinalizeBinding;
                _ = MemoryCostBinding;
                _ = WriteBytesBinding;
                _ = WriteTextBinding;
            }
        }
    };
}

pub const ErrorCode = Protocol.ErrorCode;

fn discardUpgradeSocket(args: *bun.bindgen.Args(DiscardUpgradeSocketSchema)) void {
    const socket = args.socket.takeNative();
    socket.ext(?*anyopaque).* = null;
    socket.close(.failure);
}

const DiscardUpgradeSocketSchema = WebSocketBindings.nativeExport("discardUpgradeSocket");
const DiscardUpgradeSocketBinding = bun.bindgen.Fn(DiscardUpgradeSocketSchema, discardUpgradeSocket);

comptime {
    _ = DiscardUpgradeSocketBinding;
}

fn nextMask(global: *jsc.JSGlobalObject) [4]u8 {
    return global.bunVM().rareData().entropySlice(4)[0..4].*;
}

fn writeFrame(copy: Copy, global: *jsc.JSGlobalObject, buffer: []u8, content_byte_len: usize, opcode: Opcode) void {
    copy.writeFrame(if (copy == .raw) @splat(0) else nextMask(global), buffer, content_byte_len, opcode);
}

const ReceiveState = Protocol.ReceiveState;

const Copy = Protocol.Copy;

const log = Output.scoped(.WebSocketClient, .visible);

const string = []const u8;

const WebSocketDeflate = @import("./websocket_client/WebSocketDeflate.zig");
const WebSocketProxyTunnel = @import("./websocket_client/WebSocketProxyTunnelEngine.zig");
const Protocol = @import("./WebSocketProtocol.zig");
const std = @import("std");
const CppWebSocket = @import("./websocket_client/CppWebSocket.zig").CppWebSocket;
const CppWebSocketEngine = @import("./websocket_client/CppWebSocketEngine.zig");

const Opcode = @import("../http/websocket.zig").Opcode;
const WebsocketHeader = @import("../http/websocket.zig").WebsocketHeader;

const bun = @import("bun");
const Async = bun.Async;
const BoringSSL = bun.BoringSSL;
const Environment = bun.Environment;
const Output = bun.Output;
const default_allocator = bun.default_allocator;
const jsc = bun.jsc;
const strings = bun.strings;
const uws = bun.uws;
const WebSocketBindings = bun.bindgen.Module("websocket_client");
