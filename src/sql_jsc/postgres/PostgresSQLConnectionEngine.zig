const PostgresSQLConnection = @This();
const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});

pub const getConstructor = PostgresSQLConnectionClass.constructor;

pub const JSBinding = struct {
    bindgen_state: bindgen.ClassState = .{},
    connection: bindgen.OwnedNative(PostgresSQLConnection, .vm),

    pub const destroy = @This().deinit;

    fn deinit(this: *JSBinding) void {
        this.connection.deinit();
        bun.destroy(this);
    }

    pub fn hasPendingActivity(this: *const JSBinding) bool {
        return this.connection.get().hasPendingActivity();
    }

    pub fn doClose(
        this: *JSBinding,
        _: bindgen.CallContext(PostgresSQLConnectionCloseSchema),
        _: bindgen.Args(PostgresSQLConnectionCloseSchema),
    ) bun.JSError!void {
        this.connection.get().close();
    }

    pub fn getConnected(
        this: *JSBinding,
        _: bindgen.CallContext(PostgresSQLConnectionConnectedSchema),
        _: bindgen.Args(PostgresSQLConnectionConnectedSchema),
    ) bun.JSError!bool {
        return this.connection.get().connection.status == .connected;
    }

    pub fn doFlush(
        this: *JSBinding,
        _: bindgen.CallContext(PostgresSQLConnectionFlushSchema),
        _: bindgen.Args(PostgresSQLConnectionFlushSchema),
    ) bun.JSError!void {
        this.connection.get().registerAutoFlusher();
    }

    pub fn getOnClose(
        _: *JSBinding,
        _: bindgen.CallContext(PostgresSQLConnectionOnCloseSchema),
        _: bindgen.Args(PostgresSQLConnectionOnCloseSchema),
    ) bun.JSError!bindgen.Return(PostgresSQLConnectionOnCloseSchema) {
        return null;
    }

    pub fn getOnConnect(
        _: *JSBinding,
        _: bindgen.CallContext(PostgresSQLConnectionOnConnectSchema),
        _: bindgen.Args(PostgresSQLConnectionOnConnectSchema),
    ) bun.JSError!bindgen.Return(PostgresSQLConnectionOnConnectSchema) {
        return null;
    }

    pub fn doRef(
        this: *JSBinding,
        _: bindgen.CallContext(PostgresSQLConnectionRefSchema),
        _: bindgen.Args(PostgresSQLConnectionRefSchema),
    ) bun.JSError!void {
        const connection = this.connection.get();
        connection.poll_ref.ref(connection.vm);
        connection.updateHasPendingActivity();
    }

    pub fn doUnref(
        this: *JSBinding,
        _: bindgen.CallContext(PostgresSQLConnectionUnrefSchema),
        _: bindgen.Args(PostgresSQLConnectionUnrefSchema),
    ) bun.JSError!void {
        const connection = this.connection.get();
        connection.poll_ref.unref(connection.vm);
        connection.updateHasPendingActivity();
    }
};

pub fn toRef(this: *PostgresSQLConnection, global: *jsc.JSGlobalObject) bun.JSError!bindgen.ClassRef(PostgresSQLConnectionClassSchema) {
    const binding = bun.default_allocator.create(JSBinding) catch |err| {
        this.destroy();
        return err;
    };
    binding.* = .{ .connection = .init(this) };
    return PostgresSQLConnectionClass.adoptNativeRef(binding, global);
}

ref_count: RefCount = RefCount.init(),
poll_ref: bun.Async.KeepAlive = .{},
globalObject: *jsc.JSGlobalObject,
vm: *jsc.VirtualMachine,
pending_activity_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
js_wrapper: bindgen.ClassWrapperHandle(PostgresSQLConnectionClassSchema, .weak) = .empty,
connection: PostgresConnection,

idle_timeout_interval_ms: u32 = 0,
connection_timeout_ms: u32 = 0,

/// Before being connected, this is a connection timeout timer.
/// After being connected, this is an idle timeout timer.
timer: bun.api.Timer.EventLoopTimer = .{
    .tag = .PostgresSQLConnectionTimeout,
    .next = .epoch,
},

/// This timer controls the maximum lifetime of a connection.
/// It starts when the connection successfully starts (i.e. after handshake is complete).
/// It stops when the connection is closed.
max_lifetime_interval_ms: u32 = 0,
max_lifetime_timer: bun.api.Timer.EventLoopTimer = .{
    .tag = .PostgresSQLConnectionMaxLifetime,
    .next = .epoch,
},
auto_flusher: AutoFlusher = .{},

pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

pub fn onAutoFlush(this: *@This()) bool {
    if (this.connection.flags.has_backpressure) {
        debug("onAutoFlush: has backpressure", .{});
        // if we have backpressure, wait for onWritable
        return false;
    }
    this.ref();
    defer this.deref();
    debug("onAutoFlush: draining", .{});
    // drain as much as we can
    this.drainInternal();

    // if we dont have backpressure and if we still have data to send, return true otherwise return false and wait for onWritable
    const keep_flusher_registered = this.connection.canFlush();
    debug("onAutoFlush: keep_flusher_registered: {}", .{keep_flusher_registered});
    return keep_flusher_registered;
}

fn registerAutoFlusher(this: *PostgresSQLConnection) void {
    const data_to_send = this.connection.write_buffer.len();
    debug("registerAutoFlusher: backpressure: {} registered: {} data_to_send: {}", .{ this.connection.flags.has_backpressure, this.auto_flusher.isRegistered(), data_to_send });

    if (!this.auto_flusher.isRegistered() and // should not be registered
        !this.connection.flags.has_backpressure and // if has backpressure we need to wait for onWritable event
        data_to_send > 0 and // we need data to send
        this.connection.status == .connected //and we need to be connected
    ) {
        AutoFlusherEngine.registerUnchecked(@This(), this, &this.auto_flusher, this.vm);
    }
}

fn unregisterAutoFlusher(this: *PostgresSQLConnection) void {
    debug("unregisterAutoFlusher registered: {}", .{this.auto_flusher.isRegistered()});
    if (this.auto_flusher.isRegistered()) {
        AutoFlusherEngine.unregister(@This(), this, &this.auto_flusher, this.vm);
    }
}

fn getTimeoutInterval(this: *const PostgresSQLConnection) u32 {
    return switch (this.connection.status) {
        .connected => this.idle_timeout_interval_ms,
        .failed => 0,
        else => this.connection_timeout_ms,
    };
}
pub fn disableConnectionTimeout(this: *PostgresSQLConnection) void {
    if (this.timer.state == .ACTIVE) {
        this.vm.timer.remove(&this.timer);
    }
    this.timer.state = .CANCELLED;
}
pub fn resetConnectionTimeout(this: *PostgresSQLConnection) void {
    // if we are processing data, don't reset the timeout, wait for the data to be processed
    if (this.connection.isProcessingData()) return;
    const interval = this.getTimeoutInterval();
    if (this.timer.state == .ACTIVE) {
        this.vm.timer.remove(&this.timer);
    }
    if (interval == 0) {
        return;
    }

    this.timer.next = bun.timespec.msFromNow(.allow_mocked_time, @intCast(interval));
    this.vm.timer.insert(&this.timer);
}

fn setupMaxLifetimeTimerIfNecessary(this: *PostgresSQLConnection) void {
    if (this.max_lifetime_interval_ms == 0) return;
    if (this.max_lifetime_timer.state == .ACTIVE) return;

    this.max_lifetime_timer.next = bun.timespec.msFromNow(.allow_mocked_time, @intCast(this.max_lifetime_interval_ms));
    this.vm.timer.insert(&this.max_lifetime_timer);
}

pub fn onConnectionTimeout(this: *PostgresSQLConnection) void {
    debug("onConnectionTimeout", .{});

    this.timer.state = .FIRED;
    if (this.connection.isProcessingData()) {
        return;
    }

    if (this.getTimeoutInterval() == 0) {
        this.resetConnectionTimeout();
        return;
    }

    switch (this.connection.status) {
        .connected => {
            this.failFmt("ERR_POSTGRES_IDLE_TIMEOUT", "Idle timeout reached after {f}", .{bun.fmt.fmtDurationOneDecimal(@as(u64, this.idle_timeout_interval_ms) *| std.time.ns_per_ms)});
        },
        else => {
            this.failFmt("ERR_POSTGRES_CONNECTION_TIMEOUT", "Connection timeout after {f}", .{bun.fmt.fmtDurationOneDecimal(@as(u64, this.connection_timeout_ms) *| std.time.ns_per_ms)});
        },
        .sent_startup_message => {
            this.failFmt("ERR_POSTGRES_CONNECTION_TIMEOUT", "Connection timeout after {f} (sent startup message, but never received response)", .{bun.fmt.fmtDurationOneDecimal(@as(u64, this.connection_timeout_ms) *| std.time.ns_per_ms)});
        },
    }
}

pub fn onMaxLifetimeTimeout(this: *PostgresSQLConnection) void {
    debug("onMaxLifetimeTimeout", .{});
    this.max_lifetime_timer.state = .FIRED;
    if (this.connection.status == .failed) return;
    this.failFmt("ERR_POSTGRES_LIFETIME_TIMEOUT", "Max lifetime timeout reached after {f}", .{bun.fmt.fmtDurationOneDecimal(@as(u64, this.max_lifetime_interval_ms) *| std.time.ns_per_ms)});
}

fn start(this: *PostgresSQLConnection) void {
    this.setupMaxLifetimeTimerIfNecessary();
    this.resetConnectionTimeout();
    this.connection.sendStartupMessage();

    this.drainInternal();
}

pub fn hasPendingActivity(this: *PostgresSQLConnection) bool {
    return this.pending_activity_count.load(.acquire) > 0;
}

fn updateHasPendingActivity(this: *PostgresSQLConnection) void {
    const a: u32 = if (this.connection.requests.readableLength() > 0) 1 else 0;
    const b: u32 = switch (this.connection.status) {
        // Terminal states: nothing more will happen on this connection, so
        // allow GC to collect the JS wrapper (and ultimately call deinit()).
        // We must still outlive the socket's onClose callback — for SSL
        // sockets `close(.normal)` defers the actual close until the peer's
        // close_notify arrives, so the struct must stay alive until then.
        // The socket's onClose re-enters here after failure cleanup
        // with isClosed() == true, at which point GC can proceed.
        .disconnected, .failed => @intFromBool(!this.connection.socket.isClosed()),
        else => 1,
    };
    this.pending_activity_count.store(a + b, .release);
}

pub fn setStatus(this: *PostgresSQLConnection, status: Status) void {
    if (this.connection.status == status) return;
    defer this.updateHasPendingActivity();

    this.connection.status = status;
    this.resetConnectionTimeout();
    if (this.vm.isShuttingDown()) return;

    switch (status) {
        .connected => {
            var on_connect = (this.consumeOnConnectCallback() catch |err| return this.globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
            defer on_connect.deinit();
            var connection_ref = (this.js_wrapper.toOwned() catch |err| return this.globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
            defer connection_ref.deinit();
            const Holder = struct {
                task: jsc.NativeMicrotask = undefined,
                callback: bindgen.Callback(PostgresSQLConnectionOnConnectSlot.SemanticType),
                connection: bindgen.ClassRef(PostgresSQLConnectionClassSchema),

                pub fn run(holder: *@This()) bun.JSError!void {
                    var invocation: @TypeOf(holder.callback).Invocation = undefined;
                    holder.callback.beginInvocation(&invocation);
                    defer invocation.deinit();
                    try invocation.call(.{
                        .@"error" = false,
                        .connection = holder.connection.operand(&invocation),
                    });
                }

                pub fn deinit(holder: *@This()) void {
                    holder.callback.deinit();
                    holder.connection.deinit();
                }
            };
            const holder = jsc.NativeMicrotask.create(Holder, .{
                .callback = on_connect.take(),
                .connection = connection_ref.take(),
            }) catch |err| {
                this.fail("Unable to queue connection callback", err);
                return;
            };
            this.globalObject.queueMicrotaskTask(&holder.task) catch |err| {
                this.fail("Unable to queue connection callback", err);
                return;
            };
            this.poll_ref.unref(this.vm);
        },
        else => {},
    }
}

pub fn destroy(this: *PostgresSQLConnection) void {
    this.stopTimers();
    this.js_wrapper.deinit();
    this.deref();
}

pub fn flushDataAndResetTimeout(this: *PostgresSQLConnection) void {
    this.resetConnectionTimeout();
    // defer flushing, so if many queries are running in parallel in the same connection, we don't flush more than once
    this.registerAutoFlusher();
}

fn failWithException(this: *PostgresSQLConnection, failure: bun.JSError) void {
    this.ref();
    defer this.deref();
    if (this.vm.isShuttingDown()) return this.abandon();
    var original = CallbackError.takeRoot(this.globalObject, failure) catch |err| {
        this.abandon();
        return this.globalObject.reportActiveExceptionAsUnhandled(err);
    };
    defer original.deinit();
    this.failWithError(.{ .original = &original });
}

fn abandon(this: *PostgresSQLConnection) void {
    defer this.updateHasPendingActivity();
    this.stopTimers();
    this.unregisterAutoFlusher();
    this.connection.status = .failed;
    this.refAndCloseWithReason(.abandon);
}

fn failWithPayload(this: *PostgresSQLConnection, message: []const u8, options: PostgresErrorOptions) void {
    var payload = PostgresErrorJSC.createPostgresErrorPayload(message, options) catch {
        this.failWithException(error.OutOfMemory);
        return;
    };
    defer PostgresErrorJSC.deinitPostgresErrorPayload(&payload);
    this.failWithError(.{ .payload = .{
        .value = &payload,
        .message = message,
        .options = options,
    } });
}

fn failWithPreparedPayload(this: *PostgresSQLConnection, payload: *const PostgresConnectionErrorPayload) void {
    this.failWithError(.{ .prepared_payload = payload });
}

const ConnectionFailure = union(enum) {
    original: *const bindgen.Root,
    payload: struct {
        value: *const PostgresConnectionErrorPayload,
        message: []const u8,
        options: PostgresErrorOptions,
    },
    prepared_payload: *const PostgresConnectionErrorPayload,
};

fn failWithError(this: *PostgresSQLConnection, failure: ConnectionFailure) void {
    defer this.updateHasPendingActivity();
    this.stopTimers();
    if (this.connection.status == .failed) return;

    this.connection.status = .failed;

    this.ref();
    defer this.deref();
    // we defer the refAndClose so the on_close will be called first before we reject the pending requests
    defer switch (failure) {
        .original => |value| this.refAndClose(value),
        .payload => |payload| this.refAndCloseWithPayload(payload.message, payload.options),
        .prepared_payload => this.refAndClose(null),
    };
    if (this.vm.isShuttingDown() or this.globalObject.pendingExceptionKind() == .termination) return;
    var on_close = (this.consumeOnCloseCallback() catch |err| return this.globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer on_close.deinit();

    const loop = this.vm.eventLoop();
    loop.enter();
    defer loop.exit();
    var invocation: @TypeOf(on_close).Invocation = undefined;
    on_close.beginInvocation(&invocation);
    defer invocation.deinit();
    var original_value = switch (failure) {
        .original => |value| bindgen.AnyResult.fromRoot(value, &invocation),
        .payload, .prepared_payload => bindgen.AnyResult.initUndefined(&invocation),
    };
    defer original_value.deinit();
    invocation.call(.{
        .original = original_value.operand(&invocation),
        .payload = switch (failure) {
            .original => null,
            .payload => |payload| invocation.argument("payload", payload.value),
            .prepared_payload => |payload| invocation.argument("payload", payload),
        },
    }) catch |err| this.globalObject.reportActiveExceptionAsUnhandled(err);
}

pub fn failFmt(this: *PostgresSQLConnection, code: []const u8, comptime fmt: [:0]const u8, args: anytype) void {
    const message = std.fmt.allocPrint(bun.default_allocator, fmt, args) catch {
        this.failWithException(error.OutOfMemory);
        return;
    };
    defer bun.default_allocator.free(message);

    this.failWithPayload(message, .{ .code = code });
}

pub fn fail(this: *PostgresSQLConnection, message: []const u8, err: AnyPostgresError) void {
    debug("failed: {s}: {s}", .{ message, @errorName(err) });
    if (this.connection.status == .failed) {
        this.updateHasPendingActivity();
        return;
    }
    if (CallbackError.pending(this.globalObject)) |failure| return this.failWithException(failure);
    switch (err) {
        error.JSError, error.JSTerminated, error.OutOfMemory => |failure| this.failWithException(failure),
        error.ShortRead => bun.unreachablePanic("Assertion failed: ShortRead should be handled by the caller in postgres", .{}),
        else => {
            var message_buffer: [256]u8 = undefined;
            const description = AnyPostgresErrorModule.describe(message, err, &message_buffer);
            this.failWithPayload(description.message, description.options);
        },
    }
}

pub fn onClose(this: *PostgresSQLConnection) void {
    this.unregisterAutoFlusher();

    if (this.vm.isShuttingDown()) {
        defer this.updateHasPendingActivity();
        this.stopTimers();
        if (this.connection.status == .failed) return;

        this.connection.status = .failed;
        this.cleanUpRequests(null);
    } else {
        const loop = this.vm.eventLoop();
        loop.enter();
        defer loop.exit();
        this.poll_ref.unref(this.vm);

        this.fail("Connection closed", error.ConnectionClosed);
    }
}

pub fn onOpen(this: *PostgresSQLConnection, socket: uws.AnySocket) void {
    this.poll_ref.ref(this.vm);
    this.updateHasPendingActivity();
    this.connection.open(socket);
}

pub fn onHandshake(this: *PostgresSQLConnection, success: i32, ssl_error: uws.us_bun_verify_error_t) void {
    if (!this.connection.handshakeSucceeded(success, ssl_error)) {
        var value = CallbackError.systemErrorRoot(this.globalObject, uws_jsc.verifyErrorInput(&ssl_error)) catch |err| {
            this.failWithException(err);
            return;
        };
        defer value.deinit();
        this.failWithError(.{ .original = &value });
    }
}

pub fn onTimeout(this: *PostgresSQLConnection) void {
    _ = this;
    debug("onTimeout", .{});
}

pub fn onDrain(this: *PostgresSQLConnection) void {
    this.connection.drain();
}

fn drainInternal(this: *PostgresSQLConnection) void {
    debug("drainInternal", .{});
    if (this.vm.isShuttingDown()) return this.close();

    const event_loop = this.vm.eventLoop();
    event_loop.enter();
    defer event_loop.exit();

    this.connection.flushData();

    if (!this.connection.flags.has_backpressure and this.connection.flags.is_ready_for_query) {
        // no backpressure yet so pipeline more if possible and flush again
        this.connection.advanceAndFlush();
    }
}

pub fn onData(this: *PostgresSQLConnection, data: []const u8) void {
    this.ref();
    this.connection.flags.is_processing_data = true;
    const vm = this.vm;

    this.disableConnectionTimeout();
    defer {
        if (this.connection.status == .connected and !this.connection.hasQueryRunning() and this.connection.write_buffer.remaining().len == 0) {
            // Don't keep the process alive when there's nothing to do.
            this.poll_ref.unref(vm);
        } else if (this.connection.status == .connected) {
            // Keep the process alive if there's something to do.
            this.poll_ref.ref(vm);
        }
        this.connection.flags.is_processing_data = false;

        // reset the connection timeout after we're done processing the data
        this.resetConnectionTimeout();
        this.deref();
    }

    const event_loop = vm.eventLoop();
    event_loop.enter();
    defer event_loop.exit();
    this.connection.readAndProcessData(data);
}

pub fn call(
    context: bindgen.CallContext(CreateConnectionSchema),
    args: bindgen.Args(CreateConnectionSchema),
) bindgen.CallError(CreateConnectionSchema)!bindgen.Return(CreateConnectionSchema) {
    const globalObject = context.viewToken().globalObject();
    const vm = globalObject.bunVM();
    const port: i32 = @intCast(args.port);
    var ssl_mode: SSLMode = @fromBackingInt(@intCast(args.sslMode));

    var tls_config: SSLConfig = .{};
    var secure: ?*uws.SslCtx = null;
    errdefer {
        if (secure) |s| bun.BoringSSL.c.SSL_CTX_free(s);
        tls_config.deinit();
    }
    if (ssl_mode != .disable) {
        const converted_tls = try args.tls.convert(context);
        if (converted_tls.value) |*tls| switch (tls.*) {
            .enabled => |enabled| {
                if (!enabled) ssl_mode = .disable;
            },
            .config => |*config| {
                tls_config = (try SSLConfigEngine.parse(context, config)) orelse .{};
            },
        };

        if (ssl_mode != .disable) {
            var err: uws.TLSContextFailure = .{};
            const rare_data = try vm.tryRareData();
            secure = rare_data.sslCtxCache().getOrCreateOpts(tls_config.asUSocketsForClientVerification(), &err) orelse {
                return @import("../../runtime/socket/TLSFailure.zig").fromContextCreation(context, err);
            };
        }
    }

    var connection_strings = try @import("../shared/SQLTypes.zig").ConnectionStrings.init(context, args);
    defer connection_strings.deinit();

    const ptr: *PostgresSQLConnection = try bun.default_allocator.create(PostgresSQLConnection);

    ptr.* = PostgresSQLConnection{
        .globalObject = globalObject,
        .vm = vm,
        .connection = PostgresConnection.init(
            connection_strings.database,
            connection_strings.username,
            connection_strings.password,
            connection_strings.path,
            connection_strings.options,
            connection_strings.takeBuffer(),
            tls_config,
            secure,
            ssl_mode,
            args.useUnnamedPreparedStatements,
        ),
        .idle_timeout_interval_ms = args.idleTimeout,
        .connection_timeout_ms = args.connectionTimeout,
        .max_lifetime_interval_ms = args.maxLifetime,
    };
    secure = null;
    tls_config = .{};

    var connection_ref = try ptr.toRef(globalObject);
    errdefer connection_ref.deinit();
    ptr.js_wrapper = try PostgresSQLConnectionClass.WeakWrapper.initRef(&connection_ref);
    var on_connect = try args.onConnect.toOwned();
    defer on_connect.deinit();
    var on_close = try args.onClose.toOwned();
    defer on_close.deinit();
    PostgresSQLConnectionOnConnectSlot.setOwnedCallbackOnOwned(&connection_ref, &on_connect);
    PostgresSQLConnectionOnCloseSlot.setOwnedCallbackOnOwned(&connection_ref, &on_close);
    ptr.updateHasPendingActivity();

    {
        var hostname = if (args.hostname) |value| try value.toUTF8(bun.default_allocator) else bun.String.Slice.empty;
        defer hostname.deinit();

        // Postgres always opens plain TCP first (SSLRequest happens in-band),
        // so even `ssl_mode != .disable` lands in the TCP group; `setupTLS()`
        // adopts into `postgres_tls_group` after the server's `S`.
        const group = vm.rareData().postgresGroup(vm, false);
        const result = if (connection_strings.path.len > 0)
            uws.SocketTCP.connectUnixGroup(group, .postgres, null, connection_strings.path, ptr, false)
        else
            uws.SocketTCP.connectGroup(group, .postgres, null, hostname.slice(), port, ptr, false);

        ptr.connection.socket = .{ .SocketTCP = result catch |err| {
            ptr.connection.status = .failed;
            ptr.updateHasPendingActivity();
            return globalObject.throwError(err, "failed to connect to postgresql");
        } };
    }

    ptr.updateHasPendingActivity();
    ptr.resetConnectionTimeout();
    ptr.poll_ref.ref(vm);
    bun.analytics.Features.postgres_connections += 1;
    return connection_ref;
}

/// Referenced by `dispatch.zig` (kind = `.postgres[_tls]`). Now the only
/// caller — `configure()` is gone.
pub fn SocketHandler(comptime ssl: bool) type {
    return struct {
        const SocketType = uws.NewSocketHandler(ssl);
        fn _socket(s: SocketType) Socket {
            if (comptime ssl) {
                return Socket{ .SocketTLS = s };
            }

            return Socket{ .SocketTCP = s };
        }
        pub fn onOpen(this: *PostgresSQLConnection, socket: SocketType) void {
            if (this.vm.isShuttingDown()) {
                @branchHint(.unlikely);
                this.close();
                return;
            }
            this.onOpen(_socket(socket));
        }

        fn onHandshake_(this: *PostgresSQLConnection, _: anytype, success: i32, ssl_error: uws.us_bun_verify_error_t) void {
            if (this.vm.isShuttingDown()) {
                @branchHint(.unlikely);
                this.close();
                return;
            }
            this.onHandshake(success, ssl_error);
        }

        pub const onHandshake = if (ssl) onHandshake_ else null;

        pub fn onClose(this: *PostgresSQLConnection, socket: SocketType, _: i32, _: ?*anyopaque) void {
            _ = socket;
            this.onClose();
        }

        pub fn onEnd(this: *PostgresSQLConnection, socket: SocketType) void {
            _ = socket;
            this.onClose();
        }

        pub fn onConnectError(this: *PostgresSQLConnection, socket: SocketType, failure: uws.ConnectFailure) void {
            _ = socket;
            if (this.vm.isShuttingDown()) {
                @branchHint(.unlikely);
                this.close();
                return;
            }
            if (failure.isOutOfMemory()) {
                this.fail("Connection failed", error.OutOfMemory);
                return;
            }
            this.onClose();
        }

        pub fn onTimeout(this: *PostgresSQLConnection, socket: SocketType) void {
            _ = socket;
            if (this.vm.isShuttingDown()) {
                @branchHint(.unlikely);
                this.close();
                return;
            }
            this.onTimeout();
        }

        pub fn onData(this: *PostgresSQLConnection, socket: SocketType, data: []const u8) void {
            _ = socket;
            if (this.vm.isShuttingDown()) {
                @branchHint(.unlikely);
                this.close();
                return;
            }
            this.onData(data);
        }

        pub fn onWritable(this: *PostgresSQLConnection, socket: SocketType) void {
            _ = socket;
            if (this.vm.isShuttingDown()) {
                @branchHint(.unlikely);
                this.close();
                return;
            }
            this.onDrain();
        }
    };
}

fn close(this: *@This()) void {
    this.disconnect();
    this.unregisterAutoFlusher();
    this.connection.write_buffer.clearAndFree(bun.default_allocator);
}

pub fn stopTimers(this: *PostgresSQLConnection) void {
    if (this.timer.state == .ACTIVE) {
        this.vm.timer.remove(&this.timer);
    }
    if (this.max_lifetime_timer.state == .ACTIVE) {
        this.vm.timer.remove(&this.max_lifetime_timer);
    }
}

pub fn deinit(this: *@This()) void {
    this.disconnect();
    this.stopTimers();
    this.connection.deinit();
    bun.default_allocator.destroy(this);
}

fn cleanUpRequests(this: *@This(), original: ?*const bindgen.Root) void {
    this.cleanUpRequestsWithReason(if (original) |value| .{ .original = value } else .none);
}

const CleanupReason = union(enum) {
    none,
    abandon,
    original: *const bindgen.Root,
    payload: struct {
        message: []const u8,
        options: PostgresErrorOptions,
    },
};

fn rejectCleanupRequest(this: *@This(), request: *PostgresSQLQuery, reason: CleanupReason) void {
    if (this.vm.isShuttingDown() or this.globalObject.pendingExceptionKind() == .termination) return request.markRunFailed();
    switch (reason) {
        .abandon => request.markRunFailed(),
        .none => request.onError(.{ .postgres_error = AnyPostgresError.ConnectionClosed }, this.globalObject),
        .original => |value| request.rejectWithRoot(value, this.globalObject),
        .payload => |payload| request.rejectWithPayload(payload.message, payload.options, this.globalObject),
    }
}

fn cleanUpRequestsWithReason(this: *@This(), reason: CleanupReason) void {
    while (this.connection.current()) |request| {
        // Rejection callbacks can close the connection and drain the remaining queue.
        this.connection.requests.discard(1);
        defer request.deref();
        switch (request.getStatus()) {
            .pending => {
                if (request.getStatement()) |stmt| {
                    stmt.error_response = .{ .postgres_error = AnyPostgresError.ConnectionClosed };
                    stmt.status = .failed;
                }
                this.rejectCleanupRequest(request, reason);
            },
            .binding,
            .running,
            .partial_response,
            => {
                this.connection.finishRequest(request);
                this.rejectCleanupRequest(request, reason);
            },
            .success, .fail => {},
        }
    }
}
fn refAndClose(this: *@This(), original: ?*const bindgen.Root) void {
    this.refAndCloseWithReason(if (original) |value| .{ .original = value } else .none);
}

fn refAndCloseWithPayload(this: *@This(), message: []const u8, options: PostgresErrorOptions) void {
    this.refAndCloseWithReason(.{ .payload = .{ .message = message, .options = options } });
}

fn refAndCloseWithReason(this: *@This(), reason: CleanupReason) void {
    if (!this.connection.socket.isClosed()) {
        this.poll_ref.ref(this.vm);
        this.connection.socket.close();
    }

    this.cleanUpRequestsWithReason(reason);
}

pub fn disconnect(this: *@This()) void {
    this.stopTimers();
    this.unregisterAutoFlusher();
    if (this.connection.status == .connected) {
        this.connection.status = .disconnected;
        this.refAndClose(null);
    }
}

fn queryWriteFailed(this: *PostgresSQLConnection, request: *PostgresSQLQuery, err: AnyPostgresError) bool {
    if (CallbackError.pending(this.globalObject)) |failure| {
        request.rejectWithException(failure, this.globalObject);
        return false;
    } else {
        request.onWriteFail(err, this.globalObject);
        return true;
    }
}

fn queryFailed(this: *PostgresSQLConnection, request: *PostgresSQLQuery, err: PostgresSQLStatement.Error) void {
    request.onError(err, this.globalObject);
}

fn queryResult(this: *PostgresSQLConnection, request: *PostgresSQLQuery, command: []const u8, is_last: bool) void {
    request.onResult(command, this.globalObject, is_last);
}

fn connectionError(this: *PostgresSQLConnection, err: *const protocol.ErrorResponse) void {
    var payload = ErrorResponseJSC.toPayload(err.*) catch {
        this.failWithException(error.OutOfMemory);
        return;
    };
    defer PostgresErrorJSC.deinitPostgresErrorPayload(&payload);
    this.failWithPreparedPayload(&payload);
}

fn dataRow(
    this: *PostgresSQLConnection,
    request: *PostgresSQLQuery,
    statement: *PostgresSQLStatement,
    reader: protocol.PayloadReader,
) AnyPostgresError!void {
    const result_mode = request.getResultMode();
    const result_layout: ?*const ResultLayout = switch (result_mode) {
        .objects => try statement.layout(request.bindingValues()),
        .raw, .values => null,
    };

    var putter = DataCellPutter{
        .list = &.{},
        .fields = statement.fields,
        .binary = request.isBinary(),
        .bigint = request.isBigintSupported(),
        .date_converter = SQLDateConverterEngine.init(this.globalObject),
    };

    var stack_buf: [70]DataCell.SQLDataCell = undefined;
    var cells: []DataCell.SQLDataCell = stack_buf[0..@min(statement.fields.len, stack_buf.len)];
    var free_cells = false;
    defer {
        for (cells) |*cell| cell.deinit();
        if (free_cells) bun.default_allocator.free(cells);
    }

    if (statement.fields.len > stack_buf.len) {
        cells = try bun.default_allocator.alloc(DataCell.SQLDataCell, statement.fields.len);
        free_cells = true;
    }
    @memset(cells, DataCell.SQLDataCell{ .tag = .null, .value = .{ .null = 0 } });
    putter.list = cells;

    if (result_mode == .raw) {
        try protocol.DataRow.decode(&putter, reader, DataCellPutter.putRaw);
    } else {
        try protocol.DataRow.decode(&putter, reader, DataCellPutter.put);
    }
    if (!(try request.isAlive())) {
        bun.assertf(false, "query value was freed earlier than expected", .{});
        return error.ExpectedRequest;
    }
    var created_rows = try putter.appendResultRow(
        request.bindingValues(),
        request.pendingRows(),
        result_mode,
        result_layout,
    );
    defer if (created_rows) |*rows| rows.deinit();
    if (created_rows) |*rows| request.adoptPendingRows(rows.take());
}

pub fn updateRef(this: *PostgresSQLConnection) void {
    this.updateHasPendingActivity();
    if (this.pending_activity_count.raw > 0) {
        this.poll_ref.ref(this.vm);
    } else {
        this.poll_ref.unref(this.vm);
    }
}

pub fn consumeOnConnectCallback(this: *const PostgresSQLConnection) bun.JSError!?bindgen.Callback(PostgresSQLConnectionOnConnectSlot.SemanticType) {
    debug("consumeOnConnectCallback", .{});
    var wrapper = (try this.js_wrapper.toOwned()) orelse return null;
    defer wrapper.deinit();
    const on_connect = (try PostgresSQLConnectionOnConnectSlot.takeOwnedCallback(&wrapper)) orelse return null;
    debug("consumeOnConnectCallback exists", .{});
    return on_connect;
}

pub fn consumeOnCloseCallback(this: *const PostgresSQLConnection) bun.JSError!?bindgen.Callback(PostgresSQLConnectionOnCloseSlot.SemanticType) {
    debug("consumeOnCloseCallback", .{});
    var wrapper = (try this.js_wrapper.toOwned()) orelse return null;
    defer wrapper.deinit();
    const on_close = (try PostgresSQLConnectionOnCloseSlot.takeOwnedCallback(&wrapper)) orelse return null;
    debug("consumeOnCloseCallback exists", .{});
    return on_close;
}

const debug = bun.Output.scoped(.Postgres, .visible);

const DataCell = @import("./DataCell.zig");
const SQLDateConverterEngine = @import("../shared/SQLDateConverterEngine.zig");
const DataCellPutter = DataCell.Putter(SQLDateConverterEngine);
const ResultLayout = @import("../../sql_jsc/shared/ResultLayout.zig");
const PostgresRequest = @import("./PostgresRequest.zig");
const PostgresSQLQuery = @import("./PostgresSQLQueryEngine.zig");
const PostgresSQLStatement = @import("./PostgresSQLStatement.zig");
const protocol = @import("../../sql/postgres/PostgresProtocol.zig");
const SSLConfig = @import("../../runtime/socket/SSLConfig.zig");
const SSLConfigEngine = @import("../../runtime/socket/SSLConfigEngine.zig");
const std = @import("std");
const SSLMode = @import("../../sql/postgres/SSLMode.zig").SSLMode;
const Status = @import("../../sql/postgres/Status.zig").Status;

const AnyPostgresErrorModule = @import("../../sql/postgres/AnyPostgresError.zig");
const AnyPostgresError = AnyPostgresErrorModule.AnyPostgresError;
const PostgresErrorOptions = AnyPostgresErrorModule.PostgresErrorOptions;
const PostgresErrorJSC = @import("./error_jsc.zig");
const ErrorResponseJSC = @import("./protocol/error_response_jsc.zig");

const bun = @import("bun");
const bindgen = bun.bindgen;

const jsc = bun.jsc;
const CallbackError = @import("../shared/CallbackError.zig");
const AutoFlusher = jsc.WebCore.AutoFlusher;
const AutoFlusherEngine = jsc.WebCore.AutoFlusherEngine;

const uws = bun.uws;
const uws_jsc = bun.api.UWSBindings;
const Socket = uws.AnySocket;

const PostgresConnectionIntegration = struct {
    pub const Connection = PostgresSQLConnection;
    pub const Query = PostgresSQLQuery;
    pub const RequestQueue = PostgresRequest.Queue(PostgresSQLQuery);

    pub fn owner(connection: anytype) *Connection {
        return @fieldParentPtr("connection", connection);
    }

    pub fn io(connection: *Connection) std.Io {
        return connection.vm.io;
    }

    pub fn postgresTLSGroup(connection: *Connection) *uws.SocketGroup {
        return connection.vm.rareData().postgresGroup(connection.vm, true);
    }

    pub fn start(connection: *Connection) void {
        connection.start();
    }

    pub fn drain(connection: *Connection) void {
        connection.drainInternal();
    }

    pub fn isShuttingDown(connection: *Connection) bool {
        return connection.vm.isShuttingDown();
    }

    pub fn close(connection: *Connection) void {
        connection.close();
    }

    pub fn fail(connection: *Connection, message: []const u8, err: AnyPostgresError) void {
        connection.fail(message, err);
    }

    pub fn flushDataAndResetTimeout(connection: *Connection) void {
        connection.flushDataAndResetTimeout();
    }

    pub fn queryIsAlive(query: *Query) bun.JSError!bool {
        return query.isAlive();
    }

    pub fn queryWriteFailed(connection: *Connection, query: *Query, err: AnyPostgresError) bool {
        return connection.queryWriteFailed(query, err);
    }

    pub fn queryFailed(connection: *Connection, query: *Query, err: PostgresSQLStatement.Error) void {
        connection.queryFailed(query, err);
    }

    pub fn dataRow(
        connection: *Connection,
        query: *Query,
        statement: *PostgresSQLStatement,
        reader: protocol.PayloadReader,
    ) AnyPostgresError!void {
        return connection.dataRow(query, statement, reader);
    }

    pub fn setStatus(connection: *Connection, status: Status) void {
        connection.setStatus(status);
    }

    pub fn updateRef(connection: *Connection) void {
        connection.updateRef();
    }

    pub fn registerAutoFlusher(connection: *Connection) void {
        connection.registerAutoFlusher();
    }

    pub fn queryResult(connection: *Connection, query: *Query, command: []const u8, is_last: bool) void {
        connection.queryResult(query, command, is_last);
    }

    pub fn connectionError(connection: *Connection, err: *const protocol.ErrorResponse) void {
        connection.connectionError(err);
    }
};

const PostgresConnectionCore = @import("./PostgresConnection.zig");
const PostgresConnection = PostgresConnectionCore.WithIntegration(PostgresConnectionIntegration);

const PostgresSQLConnectionBindingModule = bindgen.Module("PostgresSQLConnection");
const PostgresSQLConnectionClassSchema = PostgresSQLConnectionBindingModule.class("PostgresSQLConnection");
const PostgresSQLConnectionClass = bindgen.Class(PostgresSQLConnectionClassSchema, JSBinding);
const PostgresSQLConnectionCloseSchema = PostgresSQLConnectionClassSchema.member("close");
const PostgresSQLConnectionConnectedSchema = PostgresSQLConnectionClassSchema.member("connected");
const PostgresSQLConnectionFlushSchema = PostgresSQLConnectionClassSchema.member("flush");
const PostgresSQLConnectionOnCloseSchema = PostgresSQLConnectionClassSchema.member("onclose");
const PostgresSQLConnectionOnConnectSchema = PostgresSQLConnectionClassSchema.member("onconnect");
const PostgresSQLConnectionRefSchema = PostgresSQLConnectionClassSchema.member("ref");
const PostgresSQLConnectionUnrefSchema = PostgresSQLConnectionClassSchema.member("unref");
const PostgresSQLConnectionOnConnectSlot = PostgresSQLConnectionClass.CachedSlot("onconnect");
const PostgresSQLConnectionOnCloseSlot = PostgresSQLConnectionClass.CachedSlot("onclose");
const PostgresConnectionErrorPayload = PostgresErrorJSC.OwnedPayload;
const SQLBindings = bindgen.Module("SQLBinding");
const CreateConnectionSchema = SQLBindings.function("postgresCreateConnection");
pub const CreateConnectionBinding = bindgen.Fn(CreateConnectionSchema, call);

comptime {
    _ = PostgresSQLConnectionClass;
    _ = CreateConnectionBinding;
}
