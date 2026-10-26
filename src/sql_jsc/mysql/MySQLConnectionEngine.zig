const JSMySQLConnection = @This();

pub const getConstructor = MySQLConnectionClass.constructor;

pub const JSBinding = struct {
    bindgen_state: bindgen.ClassState = .{},
    connection: bindgen.OwnedNative(JSMySQLConnection, .vm),

    pub const destroy = @This().deinit;

    fn deinit(this: *JSBinding) void {
        this.connection.deinit();
        bun.destroy(this);
    }

    pub fn hasPendingActivity(this: *const JSBinding) bool {
        return this.connection.get().wrapper_active.load(.acquire);
    }

    pub fn doClose(
        this: *JSBinding,
        _: bindgen.CallContext(MySQLConnectionCloseSchema),
        _: bindgen.Args(MySQLConnectionCloseSchema),
    ) bun.JSError!void {
        const connection = this.connection.get();
        connection.stopTimers();
        defer connection.updateReferenceType();
        connection.connection.cleanQueueAndClose(null);
    }

    pub fn getConnected(
        this: *JSBinding,
        _: bindgen.CallContext(MySQLConnectionConnectedSchema),
        _: bindgen.Args(MySQLConnectionConnectedSchema),
    ) bun.JSError!bool {
        return this.connection.get().connection.status == .connected;
    }

    pub fn doFlush(
        this: *JSBinding,
        _: bindgen.CallContext(MySQLConnectionFlushSchema),
        _: bindgen.Args(MySQLConnectionFlushSchema),
    ) bun.JSError!void {
        this.connection.get().registerAutoFlusher();
    }

    pub fn getOnClose(
        _: *JSBinding,
        _: bindgen.CallContext(MySQLConnectionOnCloseSchema),
        _: bindgen.Args(MySQLConnectionOnCloseSchema),
    ) bun.JSError!bindgen.Return(MySQLConnectionOnCloseSchema) {
        return null;
    }

    pub fn getOnConnect(
        _: *JSBinding,
        _: bindgen.CallContext(MySQLConnectionOnConnectSchema),
        _: bindgen.Args(MySQLConnectionOnConnectSchema),
    ) bun.JSError!bindgen.Return(MySQLConnectionOnConnectSchema) {
        return null;
    }

    pub fn doRef(
        this: *JSBinding,
        _: bindgen.CallContext(MySQLConnectionRefSchema),
        _: bindgen.Args(MySQLConnectionRefSchema),
    ) bun.JSError!void {
        const connection = this.connection.get();
        connection.poll_ref.ref(connection.vm);
    }

    pub fn doUnref(
        this: *JSBinding,
        _: bindgen.CallContext(MySQLConnectionUnrefSchema),
        _: bindgen.Args(MySQLConnectionUnrefSchema),
    ) bun.JSError!void {
        const connection = this.connection.get();
        connection.poll_ref.unref(connection.vm);
    }
};

__ref_count: RefCount = RefCount.init(),
js_wrapper: bindgen.ClassWrapperHandle(MySQLConnectionClassSchema, .weak) = .empty,
wrapper_active: std.atomic.Value(bool) = .init(false),
globalObject: *jsc.JSGlobalObject,
vm: *jsc.VirtualMachine,
poll_ref: bun.Async.KeepAlive = .{},

connection: MySQLConnection,

auto_flusher: AutoFlusher = .{},

idle_timeout_interval_ms: u32 = 0,
connection_timeout_ms: u32 = 0,
/// Before being connected, this is a connection timeout timer.
/// After being connected, this is an idle timeout timer.
timer: bun.api.Timer.EventLoopTimer = .{
    .tag = .MySQLConnectionTimeout,
    .next = .epoch,
},

/// This timer controls the maximum lifetime of a connection.
/// It starts when the connection successfully starts (i.e. after handshake is complete).
/// It stops when the connection is closed.
max_lifetime_interval_ms: u32 = 0,
max_lifetime_timer: bun.api.Timer.EventLoopTimer = .{
    .tag = .MySQLConnectionMaxLifetime,
    .next = .epoch,
},

pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

pub fn onAutoFlush(this: *@This()) bool {
    debug("onAutoFlush", .{});
    if (this.connection.hasBackpressure()) {
        // if we have backpressure, wait for onWritable
        return false;
    }

    // drain as much as we can
    this.drainInternal();

    // if we dont have backpressure and if we still have data to send, return true otherwise return false and wait for onWritable
    const keep_flusher_registered = this.connection.canFlush();
    return keep_flusher_registered;
}

fn registerAutoFlusher(this: *@This()) void {
    if (!this.auto_flusher.isRegistered() and // should not be registered

        this.connection.canFlush())
    {
        AutoFlusherEngine.registerUnchecked(@This(), this, &this.auto_flusher, this.vm);
    }
}

fn unregisterAutoFlusher(this: *@This()) void {
    if (this.auto_flusher.isRegistered()) {
        AutoFlusherEngine.unregister(@This(), this, &this.auto_flusher, this.vm);
    }
}

fn stopTimers(this: *@This()) void {
    debug("stopTimers", .{});
    if (this.timer.state == .ACTIVE) {
        this.vm.timer.remove(&this.timer);
    }
    if (this.max_lifetime_timer.state == .ACTIVE) {
        this.vm.timer.remove(&this.max_lifetime_timer);
    }
}
fn getTimeoutInterval(this: *@This()) u32 {
    return switch (this.connection.status) {
        .connected => {
            if (this.connection.isIdle()) {
                return this.idle_timeout_interval_ms;
            }
            return 0;
        },
        .failed => 0,
        else => {
            return this.connection_timeout_ms;
        },
    };
}
pub fn resetConnectionTimeout(this: *@This()) void {
    const interval = this.getTimeoutInterval();
    debug("resetConnectionTimeout {d}", .{interval});
    if (this.timer.state == .ACTIVE) {
        this.vm.timer.remove(&this.timer);
    }
    if (this.connection.status == .failed or
        this.connection.isProcessingData() or
        interval == 0) return;

    this.timer.next = bun.timespec.msFromNow(.allow_mocked_time, @intCast(interval));
    this.vm.timer.insert(&this.timer);
}

pub fn onConnectionTimeout(this: *@This()) void {
    this.timer.state = .FIRED;

    if (this.connection.isProcessingData()) {
        return;
    }

    if (this.connection.status == .failed) return;

    if (this.getTimeoutInterval() == 0) {
        this.resetConnectionTimeout();
        return;
    }

    switch (this.connection.status) {
        .connected => {
            this.failFmt(error.IdleTimeout, "Idle timeout reached after {f}", .{bun.fmt.fmtDurationOneDecimal(@as(u64, this.idle_timeout_interval_ms) *| std.time.ns_per_ms)});
        },
        .connecting => {
            this.failFmt(error.ConnectionTimedOut, "Connection timeout after {f}", .{bun.fmt.fmtDurationOneDecimal(@as(u64, this.connection_timeout_ms) *| std.time.ns_per_ms)});
        },
        .handshaking,
        .authenticating,
        .authentication_awaiting_pk,
        => {
            this.failFmt(error.ConnectionTimedOut, "Connection timeout after {f} (during authentication)", .{bun.fmt.fmtDurationOneDecimal(@as(u64, this.connection_timeout_ms) *| std.time.ns_per_ms)});
        },
        .disconnected, .failed => {},
    }
}

pub fn onMaxLifetimeTimeout(this: *@This()) void {
    this.max_lifetime_timer.state = .FIRED;
    if (this.connection.status == .failed) return;
    this.failFmt(error.LifetimeTimeout, "Max lifetime timeout reached after {f}", .{bun.fmt.fmtDurationOneDecimal(@as(u64, this.max_lifetime_interval_ms) *| std.time.ns_per_ms)});
}
fn setupMaxLifetimeTimerIfNecessary(this: *@This()) void {
    if (this.max_lifetime_interval_ms == 0) return;
    if (this.max_lifetime_timer.state == .ACTIVE) return;

    this.max_lifetime_timer.next = bun.timespec.msFromNow(.allow_mocked_time, @intCast(this.max_lifetime_interval_ms));
    this.vm.timer.insert(&this.max_lifetime_timer);
}

pub fn enqueueRequest(this: *@This(), item: *JSMySQLQuery) void {
    debug("enqueueRequest", .{});
    this.connection.enqueueRequest(item);
    this.resetConnectionTimeout();
    this.registerAutoFlusher();
}

pub fn close(this: *@This()) void {
    this.ref();
    this.stopTimers();
    this.unregisterAutoFlusher();
    defer {
        this.updateReferenceType();
        this.deref();
    }
    if (this.vm.isShuttingDown()) {
        this.connection.close();
    } else {
        this.connection.cleanQueueAndClose(null);
    }
}

fn drainInternal(this: *@This()) void {
    debug("drainInternal", .{});
    if (this.vm.isShuttingDown()) return this.close();
    this.ref();
    defer this.deref();
    const event_loop = this.vm.eventLoop();
    event_loop.enter();
    defer event_loop.exit();
    var wrapper = this.js_wrapper.toOwned() catch |err| return this.globalObject.reportActiveExceptionAsUnhandled(err);
    defer if (wrapper) |*reference| reference.deinit();
    this.connection.flushQueue() catch |err| {
        bun.assert_eql(err, error.AuthenticationFailed);
        this.fail("Authentication failed", err);
        return;
    };
}
pub fn deinit(this: *@This()) void {
    this.stopTimers();
    this.poll_ref.unref(this.vm);
    this.unregisterAutoFlusher();

    this.connection.cleanup();
    bun.destroy(this);
}

pub fn destroy(this: *@This()) void {
    this.js_wrapper.deinit();
    this.deref();
}

/// Referenced by `dispatch.zig` (kind = `.mysql[_tls]`).
pub fn SocketHandler(comptime ssl: bool) type {
    return struct {
        pub const SocketType = uws.NewSocketHandler(ssl);
        fn _socket(s: SocketType) uws.AnySocket {
            if (comptime ssl) {
                return uws.AnySocket{ .SocketTLS = s };
            }

            return uws.AnySocket{ .SocketTCP = s };
        }
        pub fn onOpen(this: *JSMySQLConnection, s: SocketType) void {
            const socket = _socket(s);
            this.connection.setSocket(socket);

            if (socket == .SocketTCP) {
                // This handshake is not TLS handleshake is actually the MySQL handshake
                // When a connection is upgraded to TLS, the onOpen callback is called again and at this moment we dont wanna to change the status to handshaking
                this.connection.status = .handshaking;
                this.ref(); // keep a ref for the socket
            }
            // Only set up the timers after all status changes are complete — the timers rely on the status to determine timeouts.
            this.setupMaxLifetimeTimerIfNecessary();
            this.resetConnectionTimeout();
            this.updateReferenceType();
        }

        fn onHandshake_(
            this: *JSMySQLConnection,
            _: anytype,
            success: i32,
            ssl_error: uws.us_bun_verify_error_t,
        ) void {
            const handshakeWasSuccessful = this.connection.doHandshake(success, ssl_error) catch |err| return this.failFmt(err, "Failed to send handshake response", .{});
            if (!handshakeWasSuccessful) {
                var value = CallbackError.systemErrorRoot(this.globalObject, uws_jsc.verifyErrorInput(&ssl_error)) catch |err| {
                    this.failWithException(err);
                    return;
                };
                defer value.deinit();
                this.failWithError(.{ .original = &value });
            }
        }

        pub const onHandshake = if (ssl) onHandshake_ else null;

        pub fn onClose(this: *JSMySQLConnection, _: SocketType, _: i32, _: ?*anyopaque) void {
            defer this.deref();
            this.fail("Connection closed", error.ConnectionClosed);
        }

        pub fn onEnd(_: *JSMySQLConnection, socket: SocketType) void {
            // no half closed sockets
            socket.close(.normal);
        }

        pub fn onConnectError(this: *JSMySQLConnection, _: SocketType, failure: uws.ConnectFailure) void {
            this.fail("Connection closed", if (failure.isOutOfMemory()) error.OutOfMemory else error.ConnectionClosed);
        }

        pub fn onTimeout(this: *JSMySQLConnection, _: SocketType) void {
            this.fail("Connection timeout", error.ConnectionTimedOut);
        }

        pub fn onData(this: *JSMySQLConnection, _: SocketType, data: []const u8) void {
            this.ref();
            defer this.deref();
            const vm = this.vm;

            defer {
                // reset the connection timeout after we're done processing the data
                this.resetConnectionTimeout();
                this.updateReferenceType();
                this.registerAutoFlusher();
            }
            if (this.vm.isShuttingDown()) {
                // we are shutting down lets not process the data
                return;
            }

            const event_loop = vm.eventLoop();
            event_loop.enter();
            defer event_loop.exit();
            var wrapper = this.js_wrapper.toOwned() catch |err| return this.globalObject.reportActiveExceptionAsUnhandled(err);
            defer if (wrapper) |*reference| reference.deinit();

            this.connection.readAndProcessData(data) catch |err| {
                this.onError(null, err);
            };
        }

        pub fn onWritable(this: *JSMySQLConnection, _: SocketType) void {
            this.connection.resetBackpressure();
            this.drainInternal();
        }
    };
}

fn updateReferenceType(this: *@This()) void {
    if (this.connection.isActive()) {
        debug("connection is active", .{});
        this.wrapper_active.store(true, .release);
        if (this.connection.status == .connected and this.connection.isIdle()) {
            this.poll_ref.unref(this.vm);
        } else {
            this.poll_ref.ref(this.vm);
        }
        return;
    }
    this.wrapper_active.store(false, .release);
    this.poll_ref.unref(this.vm);
}

pub fn createInstance(
    context: bindgen.CallContext(CreateConnectionSchema),
    args: bindgen.Args(CreateConnectionSchema),
) bindgen.CallError(CreateConnectionSchema)!bindgen.Return(CreateConnectionSchema) {
    const globalObject = context.viewToken().globalObject();
    const vm = globalObject.bunVM();
    const port: i32 = @intCast(args.port);
    var ssl_mode: SSLMode = @fromBackingInt(@intCast(args.sslMode));

    var tls_config: jsc.API.ServerConfig.SSLConfig = .{};
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
                tls_config = (try jsc.API.ServerConfig.SSLConfigEngine.parse(context, config)) orelse .{};
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

    _ = args.useUnnamedPreparedStatements;

    const ptr = try bun.default_allocator.create(JSMySQLConnection);
    ptr.* = .{
        .globalObject = globalObject,
        .vm = vm,
        .idle_timeout_interval_ms = args.idleTimeout,
        .connection_timeout_ms = args.connectionTimeout,
        .max_lifetime_interval_ms = args.maxLifetime,
        .connection = MySQLConnection.init(
            connection_strings.database,
            connection_strings.username,
            connection_strings.password,
            connection_strings.options,
            connection_strings.takeBuffer(),
            tls_config,
            secure,
            ssl_mode,
        ),
    };
    secure = null;
    tls_config = .{};

    const binding = bun.default_allocator.create(JSBinding) catch |err| {
        ptr.destroy();
        return err;
    };
    binding.* = .{ .connection = .init(ptr) };
    var connection_ref = try MySQLConnectionClass.adoptNativeRef(binding, globalObject);
    errdefer connection_ref.deinit();
    ptr.js_wrapper = try MySQLConnectionClass.WeakWrapper.initRef(&connection_ref);
    var on_connect = try args.onConnect.toOwned();
    defer on_connect.deinit();
    var on_close = try args.onClose.toOwned();
    defer on_close.deinit();
    MySQLConnectionOnConnectSlot.setOwnedCallbackOnOwned(&connection_ref, &on_connect);
    MySQLConnectionOnCloseSlot.setOwnedCallbackOnOwned(&connection_ref, &on_close);
    ptr.connection.status = .connecting;
    ptr.wrapper_active.store(true, .release);

    {
        var hostname = if (args.hostname) |value| try value.toUTF8(bun.default_allocator) else bun.String.Slice.empty;
        defer hostname.deinit();

        // MySQL always opens plain TCP first; STARTTLS adopts into the TLS
        // group after the SSLRequest exchange.
        const group = vm.rareData().mysqlGroup(vm, false);
        const result = if (connection_strings.path.len > 0)
            uws.SocketTCP.connectUnixGroup(group, .mysql, null, connection_strings.path, ptr, false)
        else
            uws.SocketTCP.connectGroup(group, .mysql, null, hostname.slice(), port, ptr, false);
        ptr.connection.setSocket(.{
            .SocketTCP = result catch |err| {
                ptr.connection.status = .failed;
                ptr.wrapper_active.store(false, .release);
                return globalObject.throwError(err, "failed to connect to mysql");
            },
        });
    }
    ptr.resetConnectionTimeout();
    ptr.poll_ref.ref(vm);

    return connection_ref;
}

fn consumeOnConnectCallback(this: *const @This()) bun.JSError!?bindgen.Callback(MySQLConnectionOnConnectSlot.SemanticType) {
    if (this.vm.isShuttingDown()) return null;
    var wrapper = (try this.js_wrapper.toOwned()) orelse return null;
    defer wrapper.deinit();
    return MySQLConnectionOnConnectSlot.takeOwnedCallback(&wrapper);
}

fn consumeOnCloseCallback(this: *const @This()) bun.JSError!?bindgen.Callback(MySQLConnectionOnCloseSlot.SemanticType) {
    if (this.vm.isShuttingDown()) return null;
    var wrapper = (try this.js_wrapper.toOwned()) orelse return null;
    defer wrapper.deinit();
    return MySQLConnectionOnCloseSlot.takeOwnedCallback(&wrapper);
}

pub inline fn isAbleToWrite(this: *const @This()) bool {
    return this.connection.isAbleToWrite();
}
pub inline fn isClosed(this: *const @This()) bool {
    return this.connection.status == .disconnected or this.connection.status == .failed;
}
pub inline fn isConnected(this: *const @This()) bool {
    return this.connection.status == .connected;
}
pub inline fn canPipeline(this: *@This()) bool {
    return this.connection.canPipeline();
}
pub inline fn canPrepareQuery(this: *@This()) bool {
    return this.connection.canPrepareQuery();
}
pub inline fn canExecuteQuery(this: *@This()) bool {
    return this.connection.canExecuteQuery();
}
pub inline fn getWriter(this: *@This()) NewWriter(MySQLConnection.Writer) {
    return this.connection.writer();
}
fn failFmt(this: *@This(), error_code: AnyMySQLError.Error, comptime fmt: [:0]const u8, args: anytype) void {
    const message = std.fmt.allocPrint(bun.default_allocator, fmt, args) catch {
        this.failWithException(error.OutOfMemory);
        return;
    };
    defer bun.default_allocator.free(message);

    const description = AnyMySQLError.describe(message, error_code);
    this.failWithPayload(description.message, .{ .code = description.code });
}

fn failWithException(this: *@This(), failure: bun.JSError) void {
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

fn abandon(this: *@This()) void {
    this.connection.status = .failed;
    this.connection.queue.deinit();
    this.close();
}

fn failWithPayload(this: *@This(), message: []const u8, options: ErrorPacket.MySQLErrorOptions) void {
    var payload = MySQLErrorJSC.createMySQLErrorPayload(message, options) catch {
        this.failWithException(error.OutOfMemory);
        return;
    };
    defer MySQLErrorJSC.deinitMySQLErrorPayload(&payload);
    this.failWithError(.{ .payload = .{ .value = &payload, .message = message, .options = options } });
}

const ConnectionFailure = union(enum) {
    original: *const bindgen.Root,
    payload: struct {
        value: *const MySQLConnectionErrorPayload,
        message: []const u8,
        options: ErrorPacket.MySQLErrorOptions,
    },
};

fn failWithError(this: *@This(), failure: ConnectionFailure) void {
    this.ref();

    defer {
        if (this.vm.isShuttingDown()) {
            this.connection.close();
        } else {
            switch (failure) {
                .original => |value| this.connection.cleanQueueAndClose(value),
                .payload => |payload| this.connection.cleanQueueAndCloseWithPayload(payload.message, payload.options),
            }
        }
        this.updateReferenceType();
        this.deref();
    }
    this.stopTimers();

    if (this.connection.status == .failed) return;

    this.connection.status = .failed;
    if (this.vm.isShuttingDown() or this.globalObject.pendingExceptionKind() == .termination) return;

    var on_close = (this.consumeOnCloseCallback() catch |err| return this.globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer on_close.deinit();
    const loop = this.vm.eventLoop();
    var wrapper = this.js_wrapper.toOwned() catch |err| return this.globalObject.reportActiveExceptionAsUnhandled(err);
    defer if (wrapper) |*reference| reference.deinit();
    loop.enter();
    defer loop.exit();
    var invocation: @TypeOf(on_close).Invocation = undefined;
    on_close.beginInvocation(&invocation);
    defer invocation.deinit();
    var original_value = switch (failure) {
        .original => |value| bindgen.AnyResult.fromRoot(value, &invocation),
        .payload => bindgen.AnyResult.initUndefined(&invocation),
    };
    defer original_value.deinit();
    invocation.call(.{
        .original = original_value.operand(&invocation),
        .payload = switch (failure) {
            .original => null,
            .payload => |payload| invocation.argument("payload", payload.value),
        },
    }) catch |err| this.globalObject.reportActiveExceptionAsUnhandled(err);
}

fn fail(this: *@This(), message: []const u8, err: AnyMySQLError.Error) void {
    if (this.connection.status == .failed) {
        this.updateReferenceType();
        return;
    }
    if (CallbackError.pending(this.globalObject)) |failure| return this.failWithException(failure);
    switch (err) {
        error.JSError, error.JSTerminated, error.OutOfMemory => |failure| this.failWithException(failure),
        error.ShortRead => bun.unreachablePanic("Assertion failed: ShortRead should be handled by the caller in mysql", .{}),
        else => {
            const description = AnyMySQLError.describe(message, err);
            this.failWithPayload(description.message, .{ .code = description.code });
        },
    }
}
pub fn onConnectionEstabilished(this: *@This()) void {
    if (this.vm.isShuttingDown()) return;
    var on_connect = (this.consumeOnConnectCallback() catch |err| return this.globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer on_connect.deinit();
    var connection_ref = (this.js_wrapper.toOwned() catch |err| return this.globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer connection_ref.deinit();
    const Holder = struct {
        task: jsc.NativeMicrotask = undefined,
        callback: bindgen.Callback(MySQLConnectionOnConnectSlot.SemanticType),
        connection: bindgen.ClassRef(MySQLConnectionClassSchema),

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
    this.globalObject.queueMicrotaskTask(&holder.task) catch |err|
        this.fail("Unable to queue connection callback", err);
}
pub fn onQueryResult(this: *@This(), request: *JSMySQLQuery, result: MySQLQueryResult) void {
    _ = this;
    request.resolve(result);
}
pub fn onResultRow(this: *@This(), request: *JSMySQLQuery, statement: *MySQLStatement, Context: type, reader: NewReader(Context)) (error{ShortRead} || bun.JSError)!void {
    const result_mode = request.getResultMode();
    var stack_fallback_buffer: [4096]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buffer, bun.default_allocator);
    const allocator = stack_fallback.allocator();
    var row = ResultRow{
        .date_converter = SQLDateConverterEngine.init(this.globalObject),
        .columns = statement.columns,
        .binary = !request.isSimple(),
        .raw = result_mode == .raw,
        .bigint = request.isBigintSupported(),
    };
    const result_layout: ?*const ResultLayout = switch (result_mode) {
        .objects => try statement.layout(request.bindingValues()),
        .raw, .values => null,
    };
    defer row.deinit(allocator);
    row.decode(allocator, reader) catch |err| {
        if (err == error.ShortRead) {
            return error.ShortRead;
        }
        this.connection.queue.markCurrentRequestAsFinished(request);
        request.reject(err);
        return;
    };
    var created_rows = try row.appendResultRow(
        request.bindingValues(),
        request.pendingRows(),
        result_mode,
        result_layout,
    );
    defer if (created_rows) |*rows| rows.deinit();
    if (CallbackError.pending(this.globalObject)) |err| {
        this.connection.queue.markCurrentRequestAsFinished(request);
        request.rejectWithException(err);
        return;
    }
    statement.result_count += 1;

    if (created_rows) |*rows| request.adoptPendingRows(rows.take());
}
pub fn onError(this: *@This(), request: ?*JSMySQLQuery, err: AnyMySQLError.Error) void {
    if (request) |_request| {
        if (this.vm.isShuttingDown()) {
            _request.markAsFailed();
            return;
        }
        _request.reject(err);
    } else {
        if (this.vm.isShuttingDown()) {
            this.close();
            return;
        }
        this.fail("Connection closed", err);
    }
}
pub fn onErrorPacket(
    this: *@This(),
    request: ?*JSMySQLQuery,
    err: ErrorPacket,
) void {
    if (request) |_request| {
        if (this.vm.isShuttingDown()) {
            _request.markAsFailed();
        } else {
            if (CallbackError.pending(this.globalObject)) |failure| {
                _request.rejectWithException(failure);
            } else {
                const description = err.describe();
                _request.rejectWithPayload(description.message, description.options);
            }
        }
    } else {
        if (this.vm.isShuttingDown()) {
            this.close();
            return;
        }
        if (CallbackError.pending(this.globalObject)) |failure| {
            this.failWithException(failure);
        } else {
            const description = err.describe();
            this.failWithPayload(description.message, description.options);
        }
    }
}

pub fn acquireStatement(this: *@This(), signature: *Signature) bun.OOM!*MySQLStatement {
    if (this.connection.statements.get(signature)) |statement| {
        statement.ref();
        return statement;
    }

    const statement = try bun.default_allocator.create(MySQLStatement);
    errdefer bun.default_allocator.destroy(statement);
    try this.connection.statements.ensureUnusedCapacity(bun.default_allocator, 1);
    statement.* = .{
        .signature = signature.*,
        .ref_count = .initExactRefs(2),
        .status = .pending,
    };
    signature.* = .{};
    this.connection.statements.putAssumeCapacity(&statement.signature, statement);
    return statement;
}

const RefCount = bun.ptr.RefCount(@This(), "__ref_count", deinit, .{});

pub const Writer = MySQLConnection.Writer;

const debug = bun.Output.scoped(.MySQLConnection, .visible);

const AnyMySQLError = @import("../../sql/mysql/protocol/AnyMySQLError.zig");
const ResultLayout = @import("../../sql_jsc/shared/ResultLayout.zig");
const ErrorPacket = @import("../../sql/mysql/protocol/ErrorPacket.zig");
const JSMySQLQuery = @import("./MySQLQueryEngine.zig");
const MySQLConnectionCore = @import("./MySQLConnection.zig");
const MySQLQueryResult = @import("../../sql/mysql/MySQLQueryResult.zig");
const MySQLStatement = @import("./MySQLStatement.zig");
const Signature = @import("./protocol/Signature.zig");
const MySQLRequestQueue = @import("./MySQLRequestQueueEngine.zig");
const ResultSet = @import("./protocol/ResultSet.zig");
const SQLDateConverterEngine = @import("../shared/SQLDateConverterEngine.zig");
const ResultRow = ResultSet.Row(SQLDateConverterEngine);
const MySQLErrorJSC = @import("./protocol/error_packet_jsc.zig");
const std = @import("std");
const NewReader = @import("../../sql/mysql/protocol/NewReader.zig").NewReader;
const NewWriter = @import("../../sql/mysql/protocol/NewWriter.zig").NewWriter;
const SSLMode = @import("mysql_domain").SSLMode;

const bun = @import("bun");
const bindgen = bun.bindgen;
const uws = bun.uws;
const uws_jsc = bun.api.UWSBindings;

const jsc = bun.jsc;
const CallbackError = @import("../shared/CallbackError.zig");
const AutoFlusher = jsc.WebCore.AutoFlusher;
const AutoFlusherEngine = jsc.WebCore.AutoFlusherEngine;

const MySQLConnectionIntegration = struct {
    pub const Connection = JSMySQLConnection;
    pub const ErrorReason = *const bindgen.Root;
    pub const Query = JSMySQLQuery;
    pub const RequestQueue = MySQLRequestQueue;
    pub fn owner(connection: anytype) *Connection {
        return @fieldParentPtr("connection", connection);
    }

    pub fn io(connection: *Connection) std.Io {
        return connection.vm.io;
    }

    pub fn mysqlTLSGroup(connection: *Connection) *uws.SocketGroup {
        return connection.vm.rareData().mysqlGroup(connection.vm, true);
    }
};

const MySQLConnection = MySQLConnectionCore.WithIntegration(MySQLConnectionIntegration);

const MySQLConnectionBindingModule = bindgen.Module("MySQLConnection");
const MySQLConnectionClassSchema = MySQLConnectionBindingModule.class("MySQLConnection");
const MySQLConnectionClass = bindgen.Class(MySQLConnectionClassSchema, JSBinding);
const MySQLConnectionCloseSchema = MySQLConnectionClassSchema.member("close");
const MySQLConnectionConnectedSchema = MySQLConnectionClassSchema.member("connected");
const MySQLConnectionFlushSchema = MySQLConnectionClassSchema.member("flush");
const MySQLConnectionOnCloseSchema = MySQLConnectionClassSchema.member("onclose");
const MySQLConnectionOnConnectSchema = MySQLConnectionClassSchema.member("onconnect");
const MySQLConnectionRefSchema = MySQLConnectionClassSchema.member("ref");
const MySQLConnectionUnrefSchema = MySQLConnectionClassSchema.member("unref");
const MySQLConnectionOnConnectSlot = MySQLConnectionClass.CachedSlot("onconnect");
const MySQLConnectionOnCloseSlot = MySQLConnectionClass.CachedSlot("onclose");
const MySQLConnectionErrorPayload = MySQLErrorJSC.OwnedPayload;
const SQLBindings = bindgen.Module("SQLBinding");
const CreateConnectionSchema = SQLBindings.function("mysqlCreateConnection");
pub const CreateConnectionBinding = bindgen.Fn(CreateConnectionSchema, createInstance);

comptime {
    _ = MySQLConnectionClass;
    _ = CreateConnectionBinding;
}
