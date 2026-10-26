//! UpgradedDuplex provides TLS/SSL encryption for Node.js-style duplex streams.
//!
//! This is used when you need to add TLS encryption to streams that are not traditional
//! network sockets. In Node.js, you can have duplex streams that represent arbitrary
//! read/write channels - these could be in-memory streams, custom transport protocols,
//! or any other bidirectional data flow that implements the duplex stream interface.
//!
//! Since these duplex streams don't have native SSL support (they're not actual socket
//! file descriptors),
//!
//! The duplex stream manages the SSL handshake, certificate validation, encryption/decryption,
//! and integrates with Bun's event loop for timeouts and async operations. It maintains
//! JavaScript callbacks for handling connection events and errors.

const UpgradedDuplex = @This();

wrapper: ?WrapperType,
origin: ?OwnedDuplex = null,
global: ?*jsc.JSGlobalObject = null,
ssl_error: CertError = .{},
vm: *jsc.VirtualMachine,
handler: bun.bindgen.BorrowedNative(DuplexUpgradeContext, .vm),
onDataCallback: ?OnReceivedDataBinding.CallbackWithData = null,
onEndCallback: ?OnEndBinding.CallbackWithData = null,
onWritableCallback: ?OnWritableBinding.CallbackWithData = null,
onCloseCallback: ?OnCloseBinding.CallbackWithData = null,
event_loop_timer: EventLoopTimer = .{
    .next = .epoch,
    .tag = .UpgradedDuplex,
},
current_timeout: u32 = 0,

pub const CertError = @import("./CertError.zig");

const WrapperType = SSLWrapper(*UpgradedDuplex);

const DuplexUpgradeContext = @import("./SocketEngine.zig").DuplexUpgradeContext;

fn onOpen(this: *UpgradedDuplex) void {
    log("onOpen", .{});
    this.handler.get().onOpen();
}

fn onData(this: *UpgradedDuplex, decoded_data: []const u8) void {
    log("onData ({})", .{decoded_data.len});
    this.handler.get().onData(decoded_data);
}

fn onHandshake(this: *UpgradedDuplex, handshake_success: bool, ssl_error: uws.us_bun_verify_error_t) void {
    log("onHandshake", .{});

    const retained_error = CertError.init(
        ssl_error.error_no,
        if (ssl_error.code == null or ssl_error.error_no == 0) "" else ssl_error.code[0..bun.len(ssl_error.code)],
        if (ssl_error.reason == null or ssl_error.error_no == 0) "" else ssl_error.reason[0..bun.len(ssl_error.reason)],
    ) catch |err| {
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(this.global.?);
        defer scope.deinit();
        var value = scope.takeThrownValue(err) catch return;
        defer value.deinit();
        this.handler.get().onError(.{ .value = value });
        return;
    };
    this.ssl_error.deinit();
    this.ssl_error = retained_error;
    this.handler.get().onHandshake(handshake_success, ssl_error);
}

fn onClose(this: *UpgradedDuplex) void {
    this.ref();
    defer this.deref();
    log("onClose", .{});
    defer this.deinit();

    this.handler.get().onClose();
    // closes the underlying duplex
    this.callWriteOrEnd(null, false);
}

fn callWriteOrEnd(this: *UpgradedDuplex, data: ?[]const u8, msg_more: bool) void {
    this.ref();
    defer this.deref();
    if (this.vm.isShuttingDown()) {
        return;
    }
    var origin = (this.origin orelse return).clone();
    defer origin.deinit();
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    origin.initScope(&scope);
    defer scope.deinit();
    scope.engine(UpgradedDuplexCallSchema).call(.{
        .duplex = origin.operand(&scope),
        .data = if (data) |bytes| bun.bindgen.BytesOperand.fromSlice(bytes) else null,
        .write = msg_more,
    }) catch |err| {
        var value = scope.takeThrownValue(err) catch return;
        defer value.deinit();
        this.handler.get().onError(.{ .value = value });
    };
}

fn internalWrite(this: *UpgradedDuplex, encoded_data: []const u8) void {
    this.resetTimeout();

    // Possible scenarios:
    // Scenario 1: will not write if vm is shutting down (we cannot do anything about it)
    // Scenario 2: will not write if a exception is thrown (will be handled by onError)
    // Scenario 3: will be queued in memory and will be flushed later
    // Scenario 4: no write/end function exists (will be handled by onError)
    this.callWriteOrEnd(encoded_data, true);
}

fn ref(this: *UpgradedDuplex) void {
    this.handler.get().ref();
}

fn deref(this: *UpgradedDuplex) void {
    this.handler.get().deref();
}

pub fn flush(this: *UpgradedDuplex) void {
    this.ref();
    defer this.deref();
    if (this.wrapper) |*wrapper| {
        _ = wrapper.flush();
    }
}

fn onInternalReceiveData(this: *UpgradedDuplex, data: []const u8) void {
    this.ref();
    defer this.deref();
    if (this.wrapper) |*wrapper| {
        this.resetTimeout();
        wrapper.receiveData(data);
    }
}

fn onReceivedData(
    context: bun.bindgen.CallContext(OnReceivedDataSchema),
    args: bun.bindgen.Args(OnReceivedDataSchema),
) bun.JSError!void {
    log("onReceivedData", .{});

    if (context.callbackData()) |this| {
        this.ref();
        defer this.deref();
        if (this.vm.isShuttingDown() or this.origin == null) return;
        const data = args.data orelse return;
        const forced = try data.convertLast(context);
        try context.lease(forced.proof);
        switch (forced.converted.value) {
            .buffer => |buffer| this.onInternalReceiveData(buffer.unsafePtr("the generated receive-data frame owns the byte lease until synchronous TLS decoding finishes")),
            .nulled, .undefined => {},
            .invalid => {
                this.handler.get().onError(.invalid_duplex_data);
            },
        }
    }
}

fn onEnd(
    context: bun.bindgen.CallContext(OnEndSchema),
    args: bun.bindgen.Args(OnEndSchema),
) bun.JSError!void {
    log("onEnd", .{});

    _ = args;
    if (context.callbackData()) |this| {
        this.ref();
        defer this.deref();
        if (this.origin != null and this.wrapper != null) {
            this.handler.get().onEnd();
        }
    }
}

fn onWritable(
    context: bun.bindgen.CallContext(OnWritableSchema),
    args: bun.bindgen.Args(OnWritableSchema),
) bun.JSError!void {
    log("onWritable", .{});

    _ = args;
    if (context.callbackData()) |this| {
        this.ref();
        defer this.deref();
        if (this.wrapper) |*wrapper| {
            _ = wrapper.flush();
        }
        if (this.origin == null) return;
        this.handler.get().onWritable();
    }
}

fn onCloseJS(
    context: bun.bindgen.CallContext(OnCloseSchema),
    args: bun.bindgen.Args(OnCloseSchema),
) bun.JSError!void {
    log("onCloseJS", .{});

    _ = args;
    if (context.callbackData()) |this| {
        this.ref();
        defer this.deref();
        if (this.wrapper) |*wrapper| {
            _ = wrapper.shutdown(true);
        }
    }
}

pub fn onTimeout(this: *UpgradedDuplex) void {
    this.ref();
    defer this.deref();
    log("onTimeout", .{});

    const has_been_cleared = this.event_loop_timer.state == .CANCELLED or this.vm.scriptExecutionStatus() != .running;

    this.event_loop_timer.state = .FIRED;
    this.event_loop_timer.heap = .{};

    if (has_been_cleared) {
        return;
    }

    this.handler.get().onTimeout();
}

pub fn fromOwnedDuplex(
    globalThis: *jsc.JSGlobalObject,
    origin: *OwnedDuplex,
    handler: *DuplexUpgradeContext,
) UpgradedDuplex {
    return .{
        .vm = globalThis.bunVM(),
        .global = globalThis,
        .wrapper = null,
        .handler = .init(handler),
        .origin = origin.take(),
    };
}

pub fn getJSHandlers(this: *UpgradedDuplex, context: anytype) bun.JSError!bun.bindgen.BrandedValueResult(CreateHandlerArraySchema.ReturnType) {
    const globalThis = this.global.?;
    if (this.onDataCallback == null)
        this.onDataCallback = try OnReceivedDataBinding.createCallbackWithData(globalThis, this);
    if (this.onEndCallback == null)
        this.onEndCallback = try OnEndBinding.createCallbackWithData(globalThis, this);
    if (this.onWritableCallback == null)
        this.onWritableCallback = try OnWritableBinding.createCallbackWithData(globalThis, this);
    if (this.onCloseCallback == null)
        this.onCloseCallback = try OnCloseBinding.createCallbackWithData(globalThis, this);

    return context.engineIn("UpgradedDuplex", "createHandlerArray").call(.{
        .onData = this.onDataCallback.?.operand(context).asAny(),
        .onEnd = this.onEndCallback.?.operand(context).asAny(),
        .onWritable = this.onWritableCallback.?.operand(context).asAny(),
        .onClose = this.onCloseCallback.?.operand(context).asAny(),
    });
}

pub fn startTLS(this: *UpgradedDuplex, ssl_options: jsc.API.ServerConfig.SSLConfig, is_client: bool) !void {
    bun.assert(this.wrapper == null);
    this.wrapper = try WrapperType.init(ssl_options.asUSockets(), is_client, .{
        .ctx = this,
        .onOpen = UpgradedDuplex.onOpen,
        .onHandshake = UpgradedDuplex.onHandshake,
        .onData = UpgradedDuplex.onData,
        .onClose = UpgradedDuplex.onClose,
        .write = UpgradedDuplex.internalWrite,
    });

    this.wrapper.?.start();
}

/// Adopts `ctx` (one ref) — freed on both success (via `wrapper.deinit`) and
/// error. Mirrors `startTLS` but skips the
/// `SSLConfig.asUSockets() → us_ssl_ctx_from_options()` round-trip so a
/// memoised `SecureContext` can be reused on the duplex/named-pipe path.
pub fn startTLSWithCTX(this: *UpgradedDuplex, ctx: *bun.BoringSSL.c.SSL_CTX, is_client: bool) !void {
    errdefer bun.BoringSSL.c.SSL_CTX_free(ctx);
    bun.assert(this.wrapper == null);
    this.wrapper = try WrapperType.initWithCTX(ctx, is_client, .{
        .ctx = this,
        .onOpen = UpgradedDuplex.onOpen,
        .onHandshake = UpgradedDuplex.onHandshake,
        .onData = UpgradedDuplex.onData,
        .onClose = UpgradedDuplex.onClose,
        .write = UpgradedDuplex.internalWrite,
    });

    this.wrapper.?.start();
}

pub fn encodeAndWrite(this: *UpgradedDuplex, data: []const u8) i32 {
    this.ref();
    defer this.deref();
    log("encodeAndWrite (len: {})", .{data.len});
    if (this.wrapper) |*wrapper| {
        return @as(i32, @intCast(wrapper.writeData(data) catch 0));
    }
    return 0;
}

pub fn rawWrite(this: *UpgradedDuplex, encoded_data: []const u8) i32 {
    this.ref();
    defer this.deref();
    this.internalWrite(encoded_data);
    return @intCast(encoded_data.len);
}

pub fn close(this: *UpgradedDuplex) void {
    this.ref();
    defer this.deref();
    if (this.wrapper) |*wrapper| {
        _ = wrapper.shutdown(true);
    }
}

pub fn shutdown(this: *UpgradedDuplex) void {
    this.ref();
    defer this.deref();
    if (this.wrapper) |*wrapper| {
        _ = wrapper.shutdown(false);
    }
}

pub fn shutdownRead(this: *UpgradedDuplex) void {
    this.ref();
    defer this.deref();
    if (this.wrapper) |*wrapper| {
        _ = wrapper.shutdownRead();
    }
}

pub fn isShutdown(this: *UpgradedDuplex) bool {
    if (this.wrapper) |wrapper| {
        return wrapper.isShutdown();
    }
    return true;
}

pub fn isClosed(this: *UpgradedDuplex) bool {
    if (this.wrapper) |wrapper| {
        return wrapper.ssl == null or wrapper.isClosed();
    }
    return true;
}

pub fn isEstablished(this: *UpgradedDuplex) bool {
    return !this.isClosed();
}

pub fn ssl(this: *UpgradedDuplex) ?*BoringSSL.SSL {
    if (this.wrapper) |wrapper| {
        return wrapper.ssl;
    }
    return null;
}

pub fn sslError(this: *UpgradedDuplex) us_bun_verify_error_t {
    return .{
        .error_no = this.ssl_error.error_no,
        .code = @ptrCast(this.ssl_error.code.ptr),
        .reason = @ptrCast(this.ssl_error.reason.ptr),
    };
}

pub fn resetTimeout(this: *UpgradedDuplex) void {
    this.setTimeoutInMilliseconds(this.current_timeout);
}
pub fn setTimeoutInMilliseconds(this: *UpgradedDuplex, ms: c_uint) void {
    if (this.event_loop_timer.state == .ACTIVE) {
        this.vm.timer.remove(&this.event_loop_timer);
    }
    this.current_timeout = ms;

    // if the interval is 0 means that we stop the timer
    if (ms == 0) {
        return;
    }

    // reschedule the timer
    this.event_loop_timer.next = bun.timespec.msFromNow(.allow_mocked_time, ms);
    this.vm.timer.insert(&this.event_loop_timer);
}
pub fn setTimeout(this: *UpgradedDuplex, seconds: c_uint) void {
    log("setTimeout({d})", .{seconds});
    this.setTimeoutInMilliseconds(seconds * 1000);
}

pub fn deinit(this: *UpgradedDuplex) void {
    log("deinit", .{});
    // clear the timer
    this.setTimeout(0);

    if (this.wrapper) |*wrapper| {
        // Active wrapper calls resume after close callbacks; retain the deinitialized payload until the owner dies.
        wrapper.deinit();
    }

    if (this.origin) |*origin| {
        origin.deinit();
        this.origin = null;
    }
    if (this.onDataCallback) |*callback| {
        callback.clearData();
        callback.deinit();
    }
    if (this.onEndCallback) |*callback| {
        callback.clearData();
        callback.deinit();
    }
    if (this.onWritableCallback) |*callback| {
        callback.clearData();
        callback.deinit();
    }
    if (this.onCloseCallback) |*callback| {
        callback.clearData();
        callback.deinit();
    }
    this.onDataCallback = null;
    this.onEndCallback = null;
    this.onWritableCallback = null;
    this.onCloseCallback = null;
    this.ssl_error.deinit();
}

const log = bun.Output.scoped(.UpgradedDuplex, .visible);

const SSLWrapper = @import("./ssl_wrapper.zig").SSLWrapper;
const SocketFailure = @import("./SocketFailure.zig").SocketFailure;

const bun = @import("bun");
const jsc = bun.jsc;
const BoringSSL = bun.BoringSSL.c;
const EventLoopTimer = bun.api.Timer.EventLoopTimer;

const uws = bun.uws;

const BindingModule = bun.bindgen.Module("UpgradedDuplex");
const CreateHandlerArraySchema = BindingModule.engineShim("createHandlerArray");
const UpgradedDuplexCallSchema = BindingModule.engineShim("upgradedDuplexCall");
const OwnedDuplex = bun.bindgen.OwnedBrandedValue(UpgradedDuplexCallSchema.args[0].ArgumentType);
const OnReceivedDataSchema = BindingModule.function("onReceivedData");
const OnReceivedDataBinding = bun.bindgen.Fn(OnReceivedDataSchema, onReceivedData);
const OnEndSchema = BindingModule.function("onEnd");
const OnEndBinding = bun.bindgen.Fn(OnEndSchema, onEnd);
const OnWritableSchema = BindingModule.function("onWritable");
const OnWritableBinding = bun.bindgen.Fn(OnWritableSchema, onWritable);
const OnCloseSchema = BindingModule.function("onClose");
const OnCloseBinding = bun.bindgen.Fn(OnCloseSchema, onCloseJS);

comptime {
    _ = OnReceivedDataBinding;
    _ = OnEndBinding;
    _ = OnWritableBinding;
    _ = OnCloseBinding;
}
const us_bun_verify_error_t = uws.us_bun_verify_error_t;
