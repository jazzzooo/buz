const Handlers = @This();

onOpen: ?bindgen.Callback(SocketOpenCallback) = null,
onClose: ?bindgen.Callback(SocketCloseCallback) = null,
onData: ?bindgen.Callback(SocketDataCallback) = null,
onWritable: ?bindgen.Callback(SocketDrainCallback) = null,
onTimeout: ?bindgen.Callback(SocketTimeoutCallback) = null,
onConnectError: ?bindgen.Callback(SocketConnectErrorCallback) = null,
onEnd: ?bindgen.Callback(SocketEndCallback) = null,
onError: ?bindgen.Callback(SocketErrorCallback) = null,
onHandshake: ?bindgen.Callback(SocketHandshakeCallback) = null,

binary_type: BinaryType = .buffer,

vm: *jsc.VirtualMachine,
globalObject: *jsc.JSGlobalObject,
active_connections: u32 = 0,
mode: SocketMode = .client,
connect_completion: ?ConnectCompletions.Owned = null,
connect_payload: ?*ConnectPayload = null,

const callback_fields = .{
    "onOpen",
    "onClose",
    "onData",
    "onWritable",
    "onTimeout",
    "onConnectError",
    "onEnd",
    "onError",
    "onHandshake",
};

pub fn markActive(this: *Handlers) void {
    Listener.log("markActive", .{});
    this.active_connections += 1;
}

pub const Scope = struct {
    handlers: *Handlers,

    /// Returns true if `handlers` was destroyed (client mode, last ref).
    /// Callers that also hold the pointer in a socket field must null it.
    pub fn exit(this: *Scope) bool {
        this.handlers.vm.eventLoop().exit();
        return this.handlers.markInactive();
    }
};

pub fn enter(this: *Handlers) Scope {
    this.markActive();
    this.vm.eventLoop().enter();
    return .{ .handlers = this };
}

// corker: Corker = .{},

pub fn prepareConnectCompletion(this: *Handlers) bun.OOM!void {
    if (this.connect_payload != null or this.connect_completion != null) {
        @panic("socket handlers already prepared a connection completion");
    }
    const payload = try bun.default_allocator.create(ConnectPayload);
    payload.* = .{};
    this.connect_payload = payload;
}

pub fn attachConnectCompletion(
    this: *Handlers,
    context: anytype,
    comptime ClassSchema: type,
    socket: *const bindgen.ClassRef(ClassSchema),
) void {
    if (this.connect_completion != null) @panic("socket handlers already have a connection completion");
    const payload = this.connect_payload orelse @panic("socket handlers did not prepare a connection payload");
    if (payload.result != null) @panic("socket handlers initialized a connection payload twice");
    payload.result = if (ClassSchema == TCPSocketClassSchema)
        .{ .tcp = socket.clone() }
    else if (ClassSchema == TLSSocketClassSchema)
        .{ .tls = socket.clone() }
    else
        @compileError("socket completions require a TCP or TLS socket reference");
    var completion = context.completion();
    this.connect_completion = ConnectCompletions.takeForContext(context, &completion);
}

pub fn resolveConnect(this: *Handlers) void {
    var completion = this.takeConnectCompletion() orelse return;
    const payload = this.takeConnectPayload();
    completion.complete(payload);
}

pub fn failConnect(this: *Handlers, value: *const bun.sys.SystemError) bool {
    var completion = this.takeConnectCompletion() orelse return false;
    this.destroyConnectPayload();
    const payload = bindgen.SystemError.fromSystemError(value) catch {
        completion.outOfMemory();
        return true;
    };
    completion.fail(.connect_failed, payload);
    return true;
}

pub fn rejectConnect(
    this: *Handlers,
    value: *bindgen.Root,
    options: bindgen.CompletionRejectionOptions,
) bool {
    var completion = this.takeConnectCompletion() orelse return false;
    this.destroyConnectPayload();
    completion.reject(value, options);
    return true;
}

pub fn failTLSConnect(this: *Handlers, code: u32) bool {
    var completion = this.takeConnectCompletion() orelse return false;
    this.destroyConnectPayload();
    const message = bun.BoringSSL.ErrorMessage.init(code);
    const payload = bindgen.ThreadSafeDOMString.fromUTF8(message.slice()) catch {
        completion.outOfMemory();
        return true;
    };
    completion.fail(.tls_boringssl, payload);
    return true;
}

pub fn outOfMemoryConnect(this: *Handlers) bool {
    var completion = this.takeConnectCompletion() orelse return false;
    this.destroyConnectPayload();
    completion.outOfMemory();
    return true;
}

pub fn retainConnectError(this: *Handlers, value: anytype) ?bindgen.Root {
    return value.toRoot() catch |failure| {
        if (failure == error.OutOfMemory and this.outOfMemoryConnect()) return null;
        this.globalObject.reportActiveExceptionAsUnhandled(failure);
        return null;
    };
}

fn takeConnectCompletion(this: *Handlers) ?ConnectCompletions.Owned {
    const completion = this.connect_completion orelse return null;
    this.connect_completion = null;
    return completion;
}

fn takeConnectPayload(this: *Handlers) *ConnectPayload {
    const payload = this.connect_payload orelse @panic("socket connection payload was already consumed");
    this.connect_payload = null;
    return payload;
}

fn destroyConnectPayload(this: *Handlers) void {
    const payload = this.connect_payload orelse return;
    this.connect_payload = null;
    payload.destroy();
}

/// Returns true when the client-mode allocation has been destroyed so the
/// caller can null any `*Handlers` it still holds (the socket's `handlers`
/// field). Without that, a subsequent `connectInner` reusing the same native
/// socket as `prev` would `deinit`/`destroy` the freed pointer.
pub fn markInactive(this: *Handlers) bool {
    Listener.log("markInactive", .{});
    this.active_connections -= 1;
    if (this.active_connections == 0) {
        if (this.mode == .server) {
            const listen_socket: *Listener = @fieldParentPtr("handlers", this);
            // allow it to be GC'd once the last connection is closed and it's not listening anymore
            if (listen_socket.listener == .none) {
                listen_socket.poll_ref.unref(this.vm);
                listen_socket.clearStrongSelf();
            }
        } else {
            const vm = this.vm;
            this.deinit();
            vm.allocator.destroy(this);
            return true;
        }
    }
    return false;
}

pub fn callErrorHandler(
    this: *Handlers,
    comptime ClassSchema: type,
    receiver: *const bindgen.ClassRef(ClassSchema),
    failure: SocketFailure,
) bool {
    if (this.vm.isShuttingDown()) return false;
    const global = this.globalObject;
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    var root = socketFailureRoot(&scope, failure) catch |err| {
        global.reportActiveExceptionAsUnhandled(err);
        return false;
    };
    defer root.deinit();
    return this.callErrorHandlerRoot(ClassSchema, receiver, &root);
}

fn socketFailureRoot(context: anytype, failure: SocketFailure) bun.JSError!bindgen.Root {
    switch (failure) {
        .value => |value| return value.toRoot(),
        .system => |err| {
            var value = try bindgen.SystemError.createSysErrorInstance(context, err);
            defer value.deinit();
            return value.toRoot();
        },
        .invalid_duplex_data => {
            var message = try bindgen.DOMString.fromUTF8("Stream has StringDecoder set or is in objectMode");
            defer message.deinit();
            var value = try context.engineIn("ErrorCode", "create").call(.{
                .code = .ERR_STREAM_WRAP,
                .message = message.operand(),
            });
            defer value.deinit();
            return value.toRoot();
        },
    }
}

pub fn callErrorHandlerException(
    this: *Handlers,
    comptime ClassSchema: type,
    receiver: *const bindgen.ClassRef(ClassSchema),
    failure: bun.JSError,
) bool {
    if (this.vm.isShuttingDown()) return false;
    const callback = this.onError orelse {
        this.globalObject.reportActiveExceptionAsUnhandled(failure);
        return false;
    };
    var invocation: bindgen.Callback(SocketErrorCallback).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    var thrown = invocation.takeThrownValue(failure) catch return false;
    defer thrown.deinit();
    const value = thrown.view(&invocation) catch |err| {
        this.globalObject.reportActiveExceptionAsUnhandled(err);
        return false;
    };
    this.dispatchErrorCallback(ClassSchema, receiver, &invocation, value);
    return true;
}

pub fn callErrorHandlerRoot(
    this: *Handlers,
    comptime ClassSchema: type,
    receiver: *const bindgen.ClassRef(ClassSchema),
    error_value: *const bindgen.Root,
) bool {
    if (this.vm.isShuttingDown()) return false;
    const callback = this.onError orelse {
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalObject);
        defer scope.deinit();
        const value = error_value.view(&scope) catch |err| {
            this.globalObject.reportActiveExceptionAsUnhandled(err);
            return false;
        };
        _ = scope.reportUncaughtException(value.operand(&scope).asAny(), false);
        return false;
    };
    var invocation: bindgen.Callback(SocketErrorCallback).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    const value = error_value.view(&invocation) catch |err| {
        this.globalObject.reportActiveExceptionAsUnhandled(err);
        return false;
    };
    this.dispatchErrorCallback(ClassSchema, receiver, &invocation, value);
    return true;
}

fn callErrorHandlerView(
    this: *Handlers,
    comptime ClassSchema: type,
    receiver: *const bindgen.ClassRef(ClassSchema),
    context: anytype,
    error_value: anytype,
) bool {
    if (this.vm.isShuttingDown()) return false;
    const callback = this.onError orelse {
        _ = context.reportUncaughtException(error_value.operand(context).asAny(), false);
        return false;
    };
    var root = error_value.toRoot() catch |err| {
        this.globalObject.reportActiveExceptionAsUnhandled(err);
        return false;
    };
    defer root.deinit();
    var invocation: bindgen.Callback(SocketErrorCallback).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    const value = root.view(&invocation) catch |err| {
        this.globalObject.reportActiveExceptionAsUnhandled(err);
        return false;
    };
    this.dispatchErrorCallback(ClassSchema, receiver, &invocation, value);
    return true;
}

fn dispatchErrorCallback(
    this: *Handlers,
    comptime ClassSchema: type,
    receiver: *const bindgen.ClassRef(ClassSchema),
    invocation: *bindgen.Callback(SocketErrorCallback).Invocation,
    value: bindgen.AnyView,
) void {
    invocation.call(.{
        .bindingThis = socketOperand(ClassSchema, receiver, invocation),
        .socket = socketOperand(ClassSchema, receiver, invocation),
        .@"error" = value.operand(invocation),
    }) catch |err| this.globalObject.reportActiveExceptionAsUnhandled(err);
}

pub fn callHandshake(
    this: *Handlers,
    comptime ClassSchema: type,
    receiver: *const bindgen.ClassRef(ClassSchema),
    authorized: bool,
    ssl_error: bun.uws.us_bun_verify_error_t,
) bun.JSError!void {
    const callback = this.onHandshake orelse return;
    var invocation: bindgen.Callback(SocketHandshakeCallback).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    var authorization_error = if (ssl_error.error_no == 0)
        null
    else
        try bindgen.SystemError.createErrorInstance(&invocation, bun.api.UWSBindings.verifyErrorInput(&ssl_error));
    defer if (authorization_error) |*value| value.deinit();
    const result = invocation.call(.{
        .bindingThis = socketOperand(ClassSchema, receiver, &invocation),
        .socket = socketOperand(ClassSchema, receiver, &invocation),
        .authorized = authorized,
        .authorizationError = if (authorization_error) |*value| value.operand(&invocation) else null,
    }) catch |err| {
        _ = this.callErrorHandlerException(ClassSchema, receiver, err);
        return;
    };
    switch (result) {
        .@"error" => |error_result| {
            const value = try error_result.view(&invocation);
            _ = this.callErrorHandlerView(ClassSchema, receiver, &invocation, value);
        },
        .ignored => {},
    }
}

pub fn callClose(
    this: *Handlers,
    comptime ClassSchema: type,
    receiver: *const bindgen.ClassRef(ClassSchema),
    errno: c_int,
) bun.JSError!void {
    const callback = this.onClose orelse return;
    var invocation: bindgen.Callback(SocketCloseCallback).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    var error_value = if (errno != 0) try bindgen.SystemError.createSysErrorInstance(&invocation, bun.sys.Error.fromCodeInt(errno, .read)) else null;
    defer if (error_value) |*value| value.deinit();
    invocation.call(.{
        .bindingThis = socketOperand(ClassSchema, receiver, &invocation),
        .socket = socketOperand(ClassSchema, receiver, &invocation),
        .@"error" = if (error_value) |*value| value.operand(&invocation) else null,
    }) catch |err| {
        _ = this.callErrorHandlerException(ClassSchema, receiver, err);
    };
}

pub fn callData(
    this: *Handlers,
    comptime ClassSchema: type,
    receiver: *const bindgen.ClassRef(ClassSchema),
    bytes: []const u8,
) bun.JSError!void {
    const callback = this.onData orelse return;
    var invocation: @TypeOf(callback).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    const data = bindgen.BytesOperand.fromSlice(bytes);
    const value: @FieldType(bindgen.Args(SocketDataCallback), "data") = switch (this.binary_type) {
        .buffer => .{ .buffer = data },
        .arraybuffer => .{ .arraybuffer = data },
        .uint8array => .{ .uint8array = data },
    };
    invocation.call(.{
        .bindingThis = socketOperand(ClassSchema, receiver, &invocation),
        .socket = socketOperand(ClassSchema, receiver, &invocation),
        .data = value,
    }) catch |err| {
        _ = this.callErrorHandlerException(ClassSchema, receiver, err);
    };
}

pub fn socketOperand(comptime ClassSchema: type, receiver: *const bindgen.ClassRef(ClassSchema), context: anytype) SocketCallbackArgument {
    return if (ClassSchema == TCPSocketClassSchema)
        .{ .tcp = receiver.operand(context) }
    else if (ClassSchema == TLSSocketClassSchema)
        .{ .tls = receiver.operand(context) }
    else
        @compileError("socket callbacks require a TCP or TLS socket reference");
}

fn initialized(
    globalObject: *jsc.JSGlobalObject,
    generated: anytype,
    is_server: bool,
) Handlers {
    return .{
        .vm = globalObject.bunVM(),
        .globalObject = globalObject,
        .mode = if (is_server) .server else .client,
        .binary_type = switch (generated.binary_type) {
            .arraybuffer => .arraybuffer,
            .buffer => .buffer,
            .uint8array => .uint8array,
        },
    };
}

pub fn fromArgument(
    globalObject: *jsc.JSGlobalObject,
    context: anytype,
    generated: anytype,
    is_server: bool,
) bun.bindgen.CallError(@TypeOf(context))!Handlers {
    var result = initialized(globalObject, generated, is_server);
    errdefer result.deinit();
    inline for (callback_fields) |field| {
        if (@field(generated, field)) |optional_callback| {
            if (optional_callback) |callback| {
                @field(result, field) = try callback.toOwned();
            }
        }
    }
    if (result.onData == null and result.onWritable == null) {
        return context.fail(.no_data_or_drain, {});
    }
    return result;
}

pub fn replaceCallbacks(this: *Handlers, replacement: *Handlers) void {
    inline for (callback_fields) |field| {
        if (@field(this, field)) |*callback| callback.deinit();
        @field(this, field) = @field(replacement, field);
        @field(replacement, field) = null;
    }
    this.binary_type = replacement.binary_type;
}

pub fn take(this: *Handlers) Handlers {
    const result = this.*;
    inline for (callback_fields) |field| @field(this, field) = null;
    this.connect_completion = null;
    this.connect_payload = null;
    return result;
}

pub fn deinit(this: *Handlers) void {
    inline for (callback_fields) |field| {
        if (@field(this, field)) |*callback| callback.deinit();
        @field(this, field) = null;
    }
    if (this.connect_completion) |*completion| completion.release();
    this.connect_completion = null;
    this.destroyConnectPayload();
    this.* = undefined;
}
pub const SocketConfig = struct {
    hostname_or_unix: bun.String.Slice,
    port: ?u16 = null,
    fd: ?bun.FD = null,
    ssl: ?SSLConfig = null,
    handlers: Handlers,
    default_data: bun.bindgen.Root,
    flags: SocketFlags = .{},

    pub fn deinit(this: *SocketConfig) void {
        this.handlers.deinit();
        this.deinitExcludingHandlers();
        this.handlers = undefined;
    }

    /// Deinitializes everything except `handlers`.
    pub fn deinitExcludingHandlers(this: *SocketConfig) void {
        this.hostname_or_unix.deinit();
        bun.memory.deinit(&this.ssl);
        this.default_data.deinit();
        const handlers = this.handlers;
        this.* = undefined;
        // make sure pointers to `this.handlers` are still valid
        this.handlers = handlers;
    }

    pub fn socketFlags(this: *const SocketConfig) i32 {
        return this.flags.toNative(uws);
    }

    pub fn fromGenerated(
        globalObject: *jsc.JSGlobalObject,
        context: anytype,
        generated: anytype,
        is_server: bool,
    ) bun.bindgen.CallError(@TypeOf(context))!SocketConfig {
        var result: SocketConfig = blk: {
            var ssl: ?SSLConfig = if (generated.tls) |*tls| switch (tls.*) {
                .boolean => |b| if (b) .zero else null,
                .object => |*ssl| try SSLConfigEngine.parse(context, ssl),
            } else if (generated.secure_context != null) .zero else null;
            errdefer bun.memory.deinit(&ssl);
            var handlers = try Handlers.fromArgument(globalObject, context, &generated.handlers, is_server);
            errdefer handlers.deinit();
            break :blk .{
                .hostname_or_unix = .empty,
                .fd = if (generated.fd) |fd| .fromUV(fd) else null,
                .ssl = ssl,
                .handlers = handlers,
                .default_data = try generated.data.toRoot(),
            };
        };
        errdefer result.deinit();

        if (result.fd != null) {
            // If a user passes a file descriptor then prefer it over hostname or unix
        } else if (generated.unix_) |*unix| {
            if (unix.length() == 0) return context.fail(.empty_unix, {});
            result.hostname_or_unix = try unix.toUTF8(bun.default_allocator);
            const slice = result.hostname_or_unix.slice();
            if (strings.hasPrefixComptime(slice, "file://") or
                strings.hasPrefixComptime(slice, "unix://") or
                strings.hasPrefixComptime(slice, "sock://"))
            {
                const without_prefix = try bun.default_allocator.dupe(u8, slice[7..]);
                result.hostname_or_unix.deinit();
                result.hostname_or_unix = .init(bun.default_allocator, without_prefix);
            }
        } else if (generated.hostname) |*hostname| {
            if (hostname.length() == 0) return context.fail(.empty_hostname, {});
            result.hostname_or_unix = try hostname.toUTF8(bun.default_allocator);
            const slice = result.hostname_or_unix.slice();
            result.port = generated.port orelse bun.URL.parse(slice).getPort() orelse {
                return context.fail(.missing_port, {});
            };
            result.flags = .{
                .exclusive = generated.exclusive,
                .allow_half_open = generated.allow_half_open,
                .reuse_port = generated.reuse_port,
                .ipv6_only = generated.ipv6_only,
            };
        } else {
            return context.fail(.hostname_or_unix_required, {});
        }
        return result;
    }
};

const bun = @import("bun");
const bindgen = bun.bindgen;
const strings = bun.strings;
const uws = bun.uws;
const Listener = bun.api.Listener;
const SSLConfig = bun.api.ServerConfig.SSLConfig;
const SSLConfigEngine = bun.api.ServerConfig.SSLConfigEngine;
const SocketMode = bun.api.socket.SocketMode;
const SocketFlags = @import("./SocketFlags.zig");

const jsc = bun.jsc;
const BinaryType = enum { buffer, arraybuffer, uint8array };
pub const SocketFailure = @import("./SocketFailure.zig").SocketFailure;
const SocketOpenCallback = bindgen.CallbackSchema("SocketOpenCallback");
const SocketCloseCallback = bindgen.CallbackSchema("SocketCloseCallback");
const SocketErrorCallback = bindgen.CallbackSchema("SocketErrorCallback");
const SocketDataCallback = bindgen.CallbackSchema("SocketDataCallback");
const SocketDrainCallback = bindgen.CallbackSchema("SocketDrainCallback");
const SocketHandshakeCallback = bindgen.CallbackSchema("SocketHandshakeCallback");
const SocketEndCallback = bindgen.CallbackSchema("SocketEndCallback");
const SocketConnectErrorCallback = bindgen.CallbackSchema("SocketConnectErrorCallback");
const SocketTimeoutCallback = bindgen.CallbackSchema("SocketTimeoutCallback");
const SocketCallbackArgument = @FieldType(bindgen.Args(SocketOpenCallback), "socket");
const SocketBindingModule = bindgen.Module("Socket");
const TCPSocketClassSchema = SocketBindingModule.class("TCPSocket");
const TLSSocketClassSchema = SocketBindingModule.class("TLSSocket");
const BunConnectSchema = bindgen.Module("BunObject").function("connect");
const NodeDoConnectSchema = bindgen.Module("NodeSocket").function("doConnect");
const ConnectResult = bindgen.Return(BunConnectSchema);
const ConnectPayload = struct {
    result: ?ConnectResult = null,

    fn takeResult(payload: *@This()) ConnectResult {
        const result = payload.result orelse @panic("socket completion payload has no result");
        payload.result = null;
        return result;
    }

    fn destroy(payload: *@This()) void {
        if (payload.result) |*result| switch (result.*) {
            inline else => |*reference| reference.deinit(),
        };
        payload.result = null;
        bun.default_allocator.destroy(payload);
    }
};

const ConnectCompletionOps = struct {
    pub fn materialize(
        comptime FunctionSchema: type,
        _: bindgen.MaterializationContext(FunctionSchema),
        payload: *ConnectPayload,
    ) bindgen.Return(FunctionSchema) {
        return payload.takeResult();
    }

    pub fn destroyPayload(payload: *ConnectPayload) void {
        payload.destroy();
    }

};

pub const ConnectCompletions = bindgen.MaterializedCompletionSet(
    .{ BunConnectSchema, NodeDoConnectSchema },
    ConnectPayload,
    ConnectCompletionOps,
);
