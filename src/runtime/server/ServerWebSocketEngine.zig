const ServerWebSocket = @This();

ref_count: RefCount,
handler: *WebSocketServer.Handler,
wrapper: ?ServerWebSocketClass.ActivityWrapper = null,
socket: SocketState = .pending,
binary_type: ServerWebSocketBinaryType = .nodebuffer,
signal: ?*bun.webcore.AbortSignal = null,
close_callback_pending: bool = false,
activity_ref_held: bool = false,

const RefCount = bun.ptr.RefCount(ServerWebSocket, "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

pub const JSBinding = struct {
    bindgen_state: bindgen.ClassState = .{},
    socket: bindgen.RefNative(ServerWebSocket, .vm),

    pub const destroy = @This().deinit;

    fn deinit(this: *JSBinding) void {
        this.socket.deinit();
        bun.destroy(this);
    }

    pub fn memoryUsage(this: *const JSBinding, _: bindgen.MemoryUsageContext(.vm)) usize {
        return @sizeOf(JSBinding) + this.socket.get().memoryCost();
    }

    pub fn hasPendingActivity(this: *const JSBinding) bool {
        return this.socket.get().close_callback_pending;
    }

    pub fn bindGetBinaryType(
        this: *JSBinding,
        _: bindgen.CallContext(ServerWebSocketBinaryTypeGetterSchema),
        _: bindgen.Args(ServerWebSocketBinaryTypeGetterSchema),
    ) bun.JSError!ServerWebSocketBinaryType {
        return this.socket.get().getBinaryType();
    }

    pub fn bindSetBinaryType(
        this: *JSBinding,
        _: bindgen.CallContext(ServerWebSocketBinaryTypeSetterSchema),
        args: bindgen.Args(ServerWebSocketBinaryTypeSetterSchema),
    ) bun.JSError!void {
        this.socket.get().setBinaryType(args.value);
    }

    pub fn bindClose(
        this: *JSBinding,
        _: bindgen.CallContext(ServerWebSocketCloseSchema),
        args: bindgen.Args(ServerWebSocketCloseSchema),
    ) bun.JSError!void {
        try this.socket.get().close(args.code, args.reason);
    }

    pub fn bindCork(
        this: *JSBinding,
        context: bindgen.CallContext(ServerWebSocketCorkSchema),
        args: bindgen.Args(ServerWebSocketCorkSchema),
    ) bindgen.CallError(ServerWebSocketCorkSchema)!bindgen.Return(ServerWebSocketCorkSchema) {
        const callback = args.callback orelse return context.fail(.missing_callback, {});
        if (this.socket.get().isClosed()) {
            return bindgen.Return(ServerWebSocketCorkSchema).initUndefined(context);
        }
        return this.socket.get().cork(
            callback,
            args.bindingThis,
        );
    }

    pub fn bindGetBufferedAmount(
        this: *JSBinding,
        _: bindgen.CallContext(ServerWebSocketGetBufferedAmountSchema),
        _: bindgen.Args(ServerWebSocketGetBufferedAmountSchema),
    ) bun.JSError!usize {
        return this.socket.get().getBufferedAmount();
    }

    pub fn bindIsSubscribed(
        this: *JSBinding,
        context: bindgen.CallContext(ServerWebSocketIsSubscribedSchema),
        args: bindgen.Args(ServerWebSocketIsSubscribedSchema),
    ) bindgen.CallError(ServerWebSocketIsSubscribedSchema)!bool {
        const topic = args.topic orelse return context.fail(.missing_topic, {});
        if (topic.length() == 0) return context.fail(.empty_topic, {});
        return this.socket.get().isSubscribed(topic);
    }

    pub fn bindPing(
        this: *JSBinding,
        context: bindgen.CallContext(ServerWebSocketPingSchema),
        args: bindgen.Args(ServerWebSocketPingSchema),
    ) bun.JSError!i64 {
        _ = context;
        return this.socket.get().sendPing(args.data, "ping", .ping);
    }

    pub fn bindPong(
        this: *JSBinding,
        context: bindgen.CallContext(ServerWebSocketPongSchema),
        args: bindgen.Args(ServerWebSocketPongSchema),
    ) bun.JSError!i64 {
        _ = context;
        return this.socket.get().sendPing(args.data, "pong", .pong);
    }

    pub fn bindPublish(
        this: *JSBinding,
        context: bindgen.CallContext(ServerWebSocketPublishSchema),
        args: bindgen.Args(ServerWebSocketPublishSchema),
    ) bindgen.CallError(ServerWebSocketPublishSchema)!i64 {
        const topic = args.topic orelse return context.fail(.missing_topic, {});
        if (topic.length() == 0) return context.fail(.empty_topic, {});
        const data = args.data orelse return context.fail(.missing_message, {});
        return this.socket.get().publish(topic, data, args.compress orelse false);
    }

    pub fn bindPublishBinary(
        this: *JSBinding,
        context: bindgen.CallContext(ServerWebSocketPublishBinarySchema),
        args: bindgen.Args(ServerWebSocketPublishBinarySchema),
    ) bindgen.CallError(ServerWebSocketPublishBinarySchema)!i64 {
        const topic = args.topic orelse return context.fail(.missing_topic, {});
        if (topic.length() == 0) return context.fail(.empty_topic, {});
        const data = args.data orelse return context.fail(.missing_message, {});
        return this.socket.get().publishBinary(topic, data, args.compress orelse false);
    }

    pub fn bindPublishText(
        this: *JSBinding,
        context: bindgen.CallContext(ServerWebSocketPublishTextSchema),
        args: bindgen.Args(ServerWebSocketPublishTextSchema),
    ) bindgen.CallError(ServerWebSocketPublishTextSchema)!i64 {
        const topic = args.topic orelse return context.fail(.missing_topic, {});
        if (topic.length() == 0) return context.fail(.empty_topic, {});
        const data = args.data orelse return context.fail(.missing_message, {});
        return this.socket.get().publishText(topic, data, args.compress orelse false);
    }

    pub fn bindGetReadyState(
        this: *JSBinding,
        _: bindgen.CallContext(ServerWebSocketReadyStateSchema),
        _: bindgen.Args(ServerWebSocketReadyStateSchema),
    ) bun.JSError!i32 {
        return this.socket.get().getReadyState();
    }

    pub fn bindGetRemoteAddress(
        this: *JSBinding,
        _: bindgen.CallContext(ServerWebSocketRemoteAddressSchema),
        _: bindgen.Args(ServerWebSocketRemoteAddressSchema),
    ) bun.JSError!?bindgen.DOMString {
        return this.socket.get().getRemoteAddress();
    }

    pub fn bindSend(
        this: *JSBinding,
        context: bindgen.CallContext(ServerWebSocketSendSchema),
        args: bindgen.Args(ServerWebSocketSendSchema),
    ) bindgen.CallError(ServerWebSocketSendSchema)!i64 {
        const data = args.data orelse return context.fail(.missing_message, {});
        return this.socket.get().send(data, args.compress orelse false);
    }

    pub fn bindSendBinary(
        this: *JSBinding,
        context: bindgen.CallContext(ServerWebSocketSendBinarySchema),
        args: bindgen.Args(ServerWebSocketSendBinarySchema),
    ) bindgen.CallError(ServerWebSocketSendBinarySchema)!i64 {
        const data = args.data orelse return context.fail(.missing_message, {});
        return this.socket.get().sendBinary(data, args.compress orelse false);
    }

    pub fn bindSendText(
        this: *JSBinding,
        context: bindgen.CallContext(ServerWebSocketSendTextSchema),
        args: bindgen.Args(ServerWebSocketSendTextSchema),
    ) bindgen.CallError(ServerWebSocketSendTextSchema)!i64 {
        const data = args.data orelse return context.fail(.missing_message, {});
        return this.socket.get().sendText(data, args.compress orelse false);
    }

    pub fn bindSubscribe(
        this: *JSBinding,
        context: bindgen.CallContext(ServerWebSocketSubscribeSchema),
        args: bindgen.Args(ServerWebSocketSubscribeSchema),
    ) bindgen.CallError(ServerWebSocketSubscribeSchema)!bool {
        const topic = args.topic orelse return context.fail(.missing_topic, {});
        if (topic.length() == 0) return context.fail(.empty_topic, {});
        return this.socket.get().subscribe(topic);
    }

    pub fn bindGetSubscriptions(
        this: *JSBinding,
        context: bindgen.CallContext(ServerWebSocketSubscriptionsSchema),
        _: bindgen.Args(ServerWebSocketSubscriptionsSchema),
    ) bun.JSError!bindgen.Return(ServerWebSocketSubscriptionsSchema) {
        return this.socket.get().getSubscriptions(context);
    }

    pub fn bindTerminate(
        this: *JSBinding,
        _: bindgen.CallContext(ServerWebSocketTerminateSchema),
        _: bindgen.Args(ServerWebSocketTerminateSchema),
    ) bun.JSError!void {
        this.socket.get().terminate();
    }

    pub fn bindUnsubscribe(
        this: *JSBinding,
        context: bindgen.CallContext(ServerWebSocketUnsubscribeSchema),
        args: bindgen.Args(ServerWebSocketUnsubscribeSchema),
    ) bindgen.CallError(ServerWebSocketUnsubscribeSchema)!bool {
        const topic = args.topic orelse return context.fail(.missing_topic, {});
        if (topic.length() == 0) return context.fail(.empty_topic, {});
        return this.socket.get().unsubscribe(topic);
    }
};

const SocketState = union(enum) {
    pending,
    open: uws.AnyWebSocket,
    closing: uws.AnyWebSocket,
    closed,
};

inline fn websocket(this: *const ServerWebSocket) uws.AnyWebSocket {
    return switch (this.socket) {
        .open => |socket| socket,
        else => @panic("server WebSocket is not open"),
    };
}

pub fn init(handler: *WebSocketServer.Handler, data: ?bindgen.AnyView) bun.JSError!*ServerWebSocket {
    const globalObject = handler.state.globalObject;
    const this = try bun.default_allocator.create(ServerWebSocket);
    this.* = .{
        .ref_count = .init(),
        .handler = handler,
    };

    const binding = bun.default_allocator.create(JSBinding) catch |err| {
        this.deref();
        return err;
    };
    binding.* = .{ .socket = .adopt(this) };
    var wrapper = try ServerWebSocketClass.adoptNativeRef(binding, globalObject);
    defer wrapper.deinit();
    this.wrapper = try ServerWebSocketClass.ActivityWrapper.initRef(&wrapper);
    if (data) |value| ServerWebSocketDataSlot.setViewOnOwned(&wrapper, value);
    this.retainActivity();
    return this;
}

pub fn attachSignal(this: *ServerWebSocket, signal: ?*bun.webcore.AbortSignal) void {
    bun.assert(this.signal == null);
    this.signal = signal;
}

pub fn cancelBeforeUpgrade(this: *ServerWebSocket) void {
    this.releaseActivity();
}

fn retainActivity(this: *ServerWebSocket) void {
    bun.assert(!this.activity_ref_held);
    this.ref();
    this.activity_ref_held = true;
    this.close_callback_pending = true;
}

fn releaseActivity(this: *ServerWebSocket) void {
    if (!this.activity_ref_held) return;
    this.close_callback_pending = false;
    this.activity_ref_held = false;
    this.deref();
}

fn callCorkedInInvocation(
    comptime CallbackType: type,
    socket: uws.AnyWebSocket,
    callback: *bindgen.Callback(CallbackType).Invocation,
    args: bindgen.Args(CallbackType),
) bun.JSError!bindgen.Return(CallbackType) {
    const Invocation = struct {
        callback: *bindgen.Callback(CallbackType).Invocation,
        args: bindgen.Args(CallbackType),
        result: ?(bun.JSError!bindgen.Return(CallbackType)) = null,

        fn run(invocation: *@This()) void {
            invocation.result = invocation.callback.call(invocation.args);
        }
    };
    var invocation: Invocation = .{ .callback = callback, .args = args };
    var cork_failure: ?bun.OOM = null;
    socket.cork(&invocation, Invocation.run) catch |err| {
        cork_failure = err;
    };
    const result = try invocation.result.?;
    if (cork_failure) |err| return err;
    return result;
}

fn deinit(this: *ServerWebSocket) void {
    bun.assert(!this.activity_ref_held);
    bun.assert(!this.close_callback_pending);
    if (this.wrapper) |*wrapper| wrapper.deinit();
    if (this.signal) |signal| {
        this.signal = null;
        signal.pendingActivityUnref();
        signal.unref();
    }
    bun.destroy(this);
}

pub fn memoryCost(this: *const ServerWebSocket) usize {
    const socket = switch (this.socket) {
        .open => |socket| socket,
        else => return @sizeOf(ServerWebSocket),
    };
    return socket.memoryCost() + @sizeOf(ServerWebSocket);
}

const log = Output.scoped(.WebSocketServer, .visible);

pub fn onOpen(this: *ServerWebSocket, ws: uws.AnyWebSocket) void {
    log("OnOpen", .{});

    if (this.socket != .pending) @panic("server WebSocket opened twice");
    this.socket = .{ .open = ws };

    const handler = this.handler;
    const vm = this.handler.state.vm;
    handler.connectionOpened();
    const globalObject = handler.state.globalObject;
    if (vm.isShuttingDown()) {
        log("onOpen called after script execution", .{});
        ws.close();
        return;
    }

    handler.enterDispatch();
    defer handler.leaveDispatch();

    if (!handler.onOpen.configured) return;
    var receiver = ((this.wrapper orelse return).toOwned() catch |err| return globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer receiver.deinit();
    var callback = ((handler.state.server orelse return).webSocketCallback("wsOnOpen") catch |err| return globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer callback.deinit();

    const loop = vm.eventLoop();
    loop.enter();
    defer loop.exit();

    var invocation: @TypeOf(callback).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    callCorkedInInvocation(ServeWebSocketOpenCallback, ws, &invocation, .{
        .socket = receiver.operand(&invocation),
    }) catch |err| {
        const err_value: ?bindgen.AnyResult = invocation.takeThrownValue(err) catch null;
        log("onOpen exception", .{});

        if (this.socket == .open) {
            this.socket = .closed;
            handler.connectionClosed();
            // we un-gracefully close the connection if there was an exception
            // we don't want any event handlers to fire after this for anything other than error()
            // https://github.com/oven-sh/bun/issues/1480
            ws.close();
        }

        if (err_value) |value| handler.runErrorCallbackView(&invocation, value);
    };
}

pub fn onMessage(
    this: *ServerWebSocket,
    ws: uws.AnyWebSocket,
    message: []const u8,
    opcode: uws.Opcode,
) void {
    log("onMessage({d}): {s}", .{
        @backingInt(opcode),
        message,
    });
    const handler = this.handler;
    if (!handler.onMessage.configured) return;
    const globalObject = handler.state.globalObject;
    // This is the start of a task.
    const vm = handler.state.vm;
    if (vm.isShuttingDown()) {
        log("onMessage called after script execution", .{});
        ws.close();
        return;
    }

    handler.enterDispatch();
    defer handler.leaveDispatch();

    const loop = vm.eventLoop();
    loop.enter();
    defer loop.exit();

    var receiver = ((this.wrapper orelse return).toOwned() catch |err| return globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer receiver.deinit();
    var callback = ((handler.state.server orelse return).webSocketCallback("wsOnMessage") catch |err| return globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer callback.deinit();
    var callback_invocation: bindgen.Callback(ServeWebSocketMessageCallback).Invocation = undefined;
    callback.beginInvocation(&callback_invocation);
    defer callback_invocation.deinit();
    var text: ?bindgen.DOMString = null;
    defer if (text) |*value| value.deinit();
    const message_value: ServeWebSocketMessage = switch (opcode) {
        .text => value: {
            text = bindgen.DOMString.fromUTF8(message) catch |err| {
                handler.runErrorCallbackFailure(&callback_invocation, err);
                return;
            };
            break :value .{ .text = text.?.operand() };
        },
        .binary => this.binaryMessage(&callback_invocation, message) catch |err| {
            handler.runErrorCallbackFailure(&callback_invocation, err);
            return;
        },
        else => unreachable,
    };

    const result = callCorkedInInvocation(ServeWebSocketMessageCallback, ws, &callback_invocation, .{
        .socket = receiver.operand(&callback_invocation),
        .message = message_value,
    }) catch |err| {
        handler.runErrorCallbackFailure(&callback_invocation, err);
        return;
    };

    switch (result) {
        .error_value => |error_value| handler.runErrorCallbackView(&callback_invocation, error_value),
        .ignored => {},
    }
}

pub inline fn isClosed(this: *const ServerWebSocket) bool {
    return switch (this.socket) {
        .closing, .closed => true,
        .pending, .open => false,
    };
}

pub fn onDrain(this: *ServerWebSocket, _: uws.AnyWebSocket) void {
    log("onDrain", .{});

    const handler = this.handler;
    const vm = handler.state.vm;
    if (this.isClosed() or vm.isShuttingDown())
        return;

    if (!handler.onDrain.configured) return;
    handler.enterDispatch();
    defer handler.leaveDispatch();
    const globalObject = handler.state.globalObject;
    var receiver = ((this.wrapper orelse return).toOwned() catch |err| return globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer receiver.deinit();
    var callback = ((handler.state.server orelse return).webSocketCallback("wsOnDrain") catch |err| return globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer callback.deinit();

    const loop = vm.eventLoop();
    loop.enter();
    defer loop.exit();
    var invocation: @TypeOf(callback).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    callCorkedInInvocation(ServeWebSocketDrainCallback, this.websocket(), &invocation, .{
        .socket = receiver.operand(&invocation),
    }) catch |err| handler.runErrorCallbackFailure(&invocation, err);
}

fn binaryMessage(this: *const ServerWebSocket, context: anytype, data: []const u8) bun.JSError!ServeWebSocketMessage {
    if (this.binary_type == .arraybuffer) {
        const value = try context.engineIn("array_buffers", "createArrayBufferFromBytes").call(.{ .bytes = bun.bindgen.BytesOperand.fromSlice(data) });
        return .{ .array_buffer = value.operand(context) };
    }
    const value = try context.engineIn("array_buffers", "createUint8ArrayFromBytes").call(.{
        .bytes = bun.bindgen.BytesOperand.fromSlice(data),
        .buffer = this.binary_type == .nodebuffer,
    });
    return .{ .uint8_array = value.operand(context) };
}

pub fn onPing(this: *ServerWebSocket, _: uws.AnyWebSocket, data: []const u8) void {
    log("onPing: {s}", .{data});
    this.onControlMessage("onPing", "wsOnPing", data);
}

pub fn onPong(this: *ServerWebSocket, _: uws.AnyWebSocket, data: []const u8) void {
    log("onPong: {s}", .{data});

    this.onControlMessage("onPong", "wsOnPong", data);
}

fn onControlMessage(
    this: *ServerWebSocket,
    comptime handler_field: []const u8,
    comptime slot_name: []const u8,
    data: []const u8,
) void {
    const handler = this.handler;
    if (!@field(handler, handler_field).configured) return;
    const globalThis = handler.state.globalObject;
    const vm = handler.state.vm;
    if (vm.isShuttingDown()) return;

    handler.enterDispatch();
    defer handler.leaveDispatch();
    const loop = vm.eventLoop();
    loop.enter();
    defer loop.exit();
    var receiver = ((this.wrapper orelse return).toOwned() catch |err| return globalThis.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer receiver.deinit();
    var callback = ((handler.state.server orelse return).webSocketCallback(slot_name) catch |err| return globalThis.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer callback.deinit();
    var invocation: @TypeOf(callback).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    const data_value = this.binaryMessage(&invocation, data) catch |err| {
        handler.runErrorCallbackFailure(&invocation, err);
        return;
    };
    invocation.call(.{
        .socket = receiver.operand(&invocation),
        .data = data_value,
    }) catch |err| handler.runErrorCallbackFailure(&invocation, err);
}

pub fn onClose(this: *ServerWebSocket, _: uws.AnyWebSocket, code: i32, message: []const u8) void {
    log("onClose", .{});
    defer this.releaseActivity();

    const handler = this.handler;
    handler.enterDispatch();
    defer handler.leaveDispatch();

    const was_open = switch (this.socket) {
        .open, .closing => true,
        .pending, .closed => false,
    };
    this.socket = .closed;
    if (was_open) {
        handler.connectionClosed();
    }
    const signal = this.signal;
    this.signal = null;

    defer {
        if (signal) |sig| {
            sig.pendingActivityUnref();
            sig.unref();
        }
    }

    const vm = handler.state.vm;
    if (vm.isShuttingDown()) {
        return;
    }

    if (handler.onClose.configured) {
        const globalObject = handler.state.globalObject;
        const loop = vm.eventLoop();
        // Abort listeners can force-close the socket that owns the reason bytes.
        var reason_result = bindgen.DOMString.fromUTF8(message);
        defer {
            if (reason_result) |*reason| reason.deinit() else |_| {}
        }

        loop.enter();
        defer loop.exit();

        if (signal) |sig| {
            if (!sig.aborted()) {
                sig.signal(handler.state.globalObject, .ConnectionClosed);
            }
        }

        var receiver = ((this.wrapper orelse return).toOwned() catch |err| return globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
        defer receiver.deinit();
        var callback = ((handler.state.server orelse return).webSocketCallback("wsOnClose") catch |err| return globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
        defer callback.deinit();
        var invocation: @TypeOf(callback).Invocation = undefined;
        callback.beginInvocation(&invocation);
        defer invocation.deinit();
        const reason = reason_result catch |err| {
            log("onClose error (message)", .{});
            handler.runErrorCallbackFailure(&invocation, err);
            return;
        };
        invocation.call(.{
            .socket = receiver.operand(&invocation),
            .code = code,
            .reason = reason.operand(),
        }) catch |err| {
            log("onClose error", .{});
            handler.runErrorCallbackFailure(&invocation, err);
            return;
        };
    } else if (signal) |sig| {
        const loop = vm.eventLoop();

        loop.enter();
        defer loop.exit();

        if (!sig.aborted()) {
            sig.signal(handler.state.globalObject, .ConnectionClosed);
        }
    }
}

pub fn behavior(comptime ServerType: type, comptime ssl: bool, opts: uws.WebSocketBehavior) uws.WebSocketBehavior {
    return uws.WebSocketBehavior.Wrap(ServerType, @This(), ssl).apply(opts);
}

pub fn publish(
    this: *ServerWebSocket,
    topic_value: bindgen.DOMStringView,
    message_value: anytype,
    compress: bool,
) bun.OOM!i64 {
    const app = this.handler.state.app orelse {
        log("publish() closed", .{});
        return 0;
    };
    const flags = this.handler.flags;
    const ssl = flags.ssl;
    const publish_to_self = flags.publish_to_self;

    const topic_slice = try topic_value.toUTF8(bun.default_allocator);
    defer topic_slice.deinit();

    return switch (message_value) {
        .buffer => |buffer_value| publishBytes(this, app, ssl, publish_to_self, topic_slice.slice(), buffer_value.unsafePtr("the generated entry frame owns the message lease until synchronous publication consumes or copies its bytes"), .binary, compress),
        .string => |string_value| string: {
            const message_slice = try string_value.toUTF8(bun.default_allocator);
            defer message_slice.deinit();
            break :string publishBytes(this, app, ssl, publish_to_self, topic_slice.slice(), message_slice.slice(), .text, compress);
        },
    };
}

pub fn publishText(
    this: *ServerWebSocket,
    topic_value: bindgen.DOMStringView,
    message_value: bindgen.DOMStringView,
    compress: bool,
) bun.OOM!i64 {
    const app = this.handler.state.app orelse {
        log("publish() closed", .{});
        return 0;
    };
    const flags = this.handler.flags;
    const ssl = flags.ssl;
    const publish_to_self = flags.publish_to_self;

    const topic_slice = try topic_value.toUTF8(bun.default_allocator);
    defer topic_slice.deinit();
    const message_slice = try message_value.toUTF8(bun.default_allocator);
    defer message_slice.deinit();
    return publishBytes(this, app, ssl, publish_to_self, topic_slice.slice(), message_slice.slice(), .text, compress);
}

pub fn publishBinary(
    this: *ServerWebSocket,
    topic_value: bindgen.DOMStringView,
    message_value: anytype,
    compress: bool,
) bun.OOM!i64 {
    const app = this.handler.state.app orelse {
        log("publish() closed", .{});
        return 0;
    };
    const flags = this.handler.flags;
    const ssl = flags.ssl;
    const publish_to_self = flags.publish_to_self;
    const topic_slice = try topic_value.toUTF8(bun.default_allocator);
    defer topic_slice.deinit();
    return publishBytes(this, app, ssl, publish_to_self, topic_slice.slice(), message_value.unsafePtr("the generated entry frame owns the message lease until synchronous publication consumes or copies its bytes"), .binary, compress);
}

fn publishBytes(
    this: *ServerWebSocket,
    app: @import("./WebSocketServerContextEngine.zig").Handler.State.App,
    ssl: bool,
    publish_to_self: bool,
    topic: []const u8,
    message: []const u8,
    opcode: uws.Opcode,
    compress: bool,
) i64 {
    bun.debugAssert(ssl == (app == .https));
    const result = if (!publish_to_self and !this.isClosed())
        this.websocket().publish(topic, message, opcode, compress)
    else switch (app) {
        inline else => |typed_app| typed_app.publishWithOptions(topic, message, opcode, compress),
    };
    return if (result) @intCast(message.len) else 0;
}

pub fn cork(
    this: *ServerWebSocket,
    callback: bindgen.CallbackView(ServerWebSocketCorkCallbackType),
    receiver: bindgen.ClassRefView(ServerWebSocketClassSchema),
) bun.JSError!bindgen.Return(ServerWebSocketCorkCallbackType) {
    bun.debugAssert(!this.isClosed());

    const BindingCorker = struct {
        callback: bindgen.CallbackView(ServerWebSocketCorkCallbackType),
        receiver: bindgen.ClassRefView(ServerWebSocketClassSchema),
        result: ?bindgen.Return(ServerWebSocketCorkCallbackType) = null,
        failure: ?bun.JSError = null,

        fn run(corker: *@This()) void {
            corker.result = corker.callback.call(.{ .bindingThis = corker.receiver }) catch |err| {
                corker.failure = err;
                return;
            };
        }
    };
    var corker = BindingCorker{
        .callback = callback,
        .receiver = receiver,
    };
    var cork_failure: ?bun.OOM = null;
    this.websocket().cork(&corker, BindingCorker.run) catch |err| {
        cork_failure = err;
    };
    if (corker.failure) |err| return err;
    if (cork_failure) |err| return err;
    return corker.result.?;
}

pub fn send(
    this: *ServerWebSocket,
    message_value: anytype,
    compress: bool,
) bun.OOM!i64 {
    if (this.isClosed()) {
        log("send() closed", .{});
        return 0;
    }

    return switch (message_value) {
        .buffer => |buffer_value| sendBytes(this, buffer_value.unsafePtr("the generated entry frame owns the message lease until the synchronous WebSocket send consumes or copies its bytes"), .binary, compress, "send"),
        .string => |string_value| string: {
            const message_slice = try string_value.toUTF8(bun.default_allocator);
            defer message_slice.deinit();
            break :string sendBytes(this, message_slice.slice(), .text, compress, "send");
        },
    };
}

pub fn sendText(
    this: *ServerWebSocket,
    message_value: bindgen.DOMStringView,
    compress: bool,
) bun.OOM!i64 {
    if (this.isClosed()) {
        log("sendText() closed", .{});
        return 0;
    }

    const message_slice = try message_value.toUTF8(bun.default_allocator);
    defer message_slice.deinit();
    return sendBytes(this, message_slice.slice(), .text, compress, "sendText");
}

pub fn sendBinary(
    this: *ServerWebSocket,
    message_value: anytype,
    compress: bool,
) bun.OOM!i64 {
    if (this.isClosed()) {
        log("sendBinary() closed", .{});
        return 0;
    }

    return sendBytes(this, message_value.unsafePtr("the generated entry frame owns the message lease until the synchronous WebSocket send consumes or copies its bytes"), .binary, compress, "sendBinary");
}

fn sendBytes(this: *ServerWebSocket, bytes: []const u8, opcode: uws.Opcode, compress: bool, comptime operation: []const u8) bun.OOM!i64 {
    switch (this.websocket().send(bytes, opcode, compress, true)) {
        .backpressure => {
            log(operation ++ "() backpressure ({d} bytes)", .{bytes.len});
            return -1;
        },
        .success => {
            log(operation ++ "() success ({d} bytes)", .{bytes.len});
            return @intCast(bytes.len);
        },
        .dropped => {
            log(operation ++ "() dropped ({d} bytes)", .{bytes.len});
            return 0;
        },
        .out_of_memory => return error.OutOfMemory,
    }
}

inline fn sendPing(
    this: *ServerWebSocket,
    value_optional: anytype,
    comptime name: string,
    comptime opcode: uws.Opcode,
) bun.OOM!i64 {
    if (this.isClosed()) {
        return 0;
    }

    const value = value_optional orelse return sendBytes(this, &.{}, opcode, false, name);
    return switch (value) {
        .buffer => |buffer_value| sendBytes(this, buffer_value.unsafePtr("the generated entry frame owns the control-frame lease until the synchronous WebSocket send consumes or copies its bytes"), opcode, false, name),
        .string => |string_value| string: {
            const message_slice = try string_value.toUTF8(bun.default_allocator);
            defer message_slice.deinit();
            break :string sendBytes(this, message_slice.slice(), opcode, false, name);
        },
    };
}

pub fn getReadyState(this: *ServerWebSocket) i32 {
    log("getReadyState()", .{});

    if (this.isClosed()) {
        return 3;
    }

    return 1;
}

pub fn close(
    this: *ServerWebSocket,
    code_value: ?i32,
    reason_value: ?bindgen.DOMStringView,
) bun.OOM!void {
    log("close()", .{});

    if (this.isClosed()) {
        return;
    }

    const code = code_value orelse 1000;
    const message_value = if (reason_value) |reason|
        try reason.toUTF8(bun.default_allocator)
    else
        bun.String.Slice.empty;
    defer message_value.deinit();

    if (this.isClosed()) {
        return;
    }

    const socket = this.websocket();
    this.socket = .{ .closing = socket };
    try socket.end(code, message_value.slice());
}

pub fn terminate(this: *ServerWebSocket) void {
    log("terminate()", .{});

    if (this.isClosed()) {
        return;
    }

    const socket = this.websocket();
    this.socket = .{ .closing = socket };
    socket.close();
}

pub fn getBinaryType(this: *ServerWebSocket) ServerWebSocketBinaryType {
    log("getBinaryType()", .{});

    return this.binary_type;
}

pub fn setBinaryType(this: *ServerWebSocket, value: ServerWebSocketBinaryType) void {
    log("setBinaryType()", .{});

    this.binary_type = value;
}

pub fn getBufferedAmount(this: *ServerWebSocket) usize {
    log("getBufferedAmount()", .{});

    if (this.isClosed()) {
        return 0;
    }

    return this.websocket().getBufferedAmount();
}
pub fn subscribe(
    this: *ServerWebSocket,
    topic_value: bindgen.DOMStringView,
) bun.OOM!bool {
    if (this.isClosed()) {
        return true;
    }

    const topic = try topic_value.toUTF8(bun.default_allocator);
    defer topic.deinit();
    return this.websocket().subscribe(topic.slice());
}
pub fn unsubscribe(this: *ServerWebSocket, topic_value: bindgen.DOMStringView) bun.OOM!bool {
    if (this.isClosed()) {
        return true;
    }

    const topic = try topic_value.toUTF8(bun.default_allocator);
    defer topic.deinit();
    return this.websocket().unsubscribe(topic.slice());
}
pub fn isSubscribed(
    this: *ServerWebSocket,
    topic_value: bindgen.DOMStringView,
) bun.OOM!bool {
    if (this.isClosed()) {
        return false;
    }

    const topic = try topic_value.toUTF8(bun.default_allocator);
    defer topic.deinit();
    return this.websocket().isSubscribed(topic.slice());
}

pub fn getSubscriptions(
    this: *ServerWebSocket,
    context: bindgen.CallContext(ServerWebSocketSubscriptionsSchema),
) bun.OOM!bindgen.Return(ServerWebSocketSubscriptionsSchema) {
    if (this.isClosed()) {
        return bindgen.Return(ServerWebSocketSubscriptionsSchema).fromUTF8Slices(&.{});
    }

    const active_websocket = this.websocket();
    const operation = context.engineIn("ServerWebSocket", "uwsWebSocketTopics");
    const WebSocketHandle = @FieldType(@TypeOf(operation).Args, "websocket");
    return operation.call(.{
        .websocket = @as(WebSocketHandle, @ptrCast(active_websocket.raw())),
        .tls = switch (active_websocket) {
            .ssl => true,
            .tcp => false,
        },
    });
}

pub fn getRemoteAddress(
    this: *ServerWebSocket,
) bun.OOM!?bindgen.DOMString {
    if (this.isClosed()) {
        return null;
    }

    var buf: [64]u8 = @splat(0);
    var text_buf: [512]u8 = undefined;

    const address_bytes = this.websocket().getRemoteAddress(&buf);
    const address: SocketAddressValue = switch (address_bytes.len) {
        4 => .initIp4(address_bytes[0..4].*, 0),
        16 => .initIp6(address_bytes[0..16].*, 0, 0, 0),
        else => return null,
    };

    const text = address.formatIp(&text_buf);
    return try bindgen.DOMString.fromUTF8(text);
}

const string = []const u8;

const std = @import("std");

const bun = @import("bun");
const bindgen = bun.bindgen;
const Output = bun.Output;
const uws = bun.uws;
const WebSocketServer = bun.api.server.WebSocketServerContext;
const SocketAddressValue = @import("../socket/SocketAddressValue.zig");

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;

const ServerWebSocketBindingModule = bindgen.Module("ServerWebSocket");
const ServerWebSocketClassSchema = ServerWebSocketBindingModule.class("ServerWebSocket");
const ServerWebSocketClass = bindgen.Class(ServerWebSocketClassSchema, JSBinding);
const ServerWebSocketBinaryTypeGetterSchema = ServerWebSocketClassSchema.memberKind("binaryType", .getter);
const ServerWebSocketBinaryTypeSetterSchema = ServerWebSocketClassSchema.memberKind("binaryType", .setter);
const ServerWebSocketBinaryType = bindgen.Return(ServerWebSocketBinaryTypeGetterSchema);
const ServerWebSocketCloseSchema = ServerWebSocketClassSchema.member("close");
const ServerWebSocketCorkSchema = ServerWebSocketClassSchema.member("cork");
const ServerWebSocketCorkCallbackType = ServerWebSocketCorkSchema.args[0].ArgumentType;
const ServerWebSocketGetBufferedAmountSchema = ServerWebSocketClassSchema.member("getBufferedAmount");
const ServerWebSocketIsSubscribedSchema = ServerWebSocketClassSchema.member("isSubscribed");
const ServerWebSocketPingSchema = ServerWebSocketClassSchema.member("ping");
const ServerWebSocketPongSchema = ServerWebSocketClassSchema.member("pong");
const ServerWebSocketPublishSchema = ServerWebSocketClassSchema.member("publish");
const ServerWebSocketPublishBinarySchema = ServerWebSocketClassSchema.member("publishBinary");
const ServerWebSocketPublishTextSchema = ServerWebSocketClassSchema.member("publishText");
const ServerWebSocketReadyStateSchema = ServerWebSocketClassSchema.memberKind("readyState", .getter);
const ServerWebSocketRemoteAddressSchema = ServerWebSocketClassSchema.memberKind("remoteAddress", .getter);
const ServerWebSocketSendSchema = ServerWebSocketClassSchema.member("send");
const ServerWebSocketSendBinarySchema = ServerWebSocketClassSchema.member("sendBinary");
const ServerWebSocketSendTextSchema = ServerWebSocketClassSchema.member("sendText");
const ServerWebSocketSubscribeSchema = ServerWebSocketClassSchema.member("subscribe");
const ServerWebSocketSubscriptionsSchema = ServerWebSocketClassSchema.memberKind("subscriptions", .getter);
const ServerWebSocketTerminateSchema = ServerWebSocketClassSchema.member("terminate");
const ServerWebSocketUnsubscribeSchema = ServerWebSocketClassSchema.member("unsubscribe");
const ServerWebSocketDataSlot = ServerWebSocketClass.CachedSlot("data");
const ServeWebSocketOpenCallback = bindgen.CallbackSchema("ServeWebSocketOpenCallback");
const ServeWebSocketMessageCallback = bindgen.CallbackSchema("ServeWebSocketMessageCallback");
const ServeWebSocketCloseCallback = bindgen.CallbackSchema("ServeWebSocketCloseCallback");
const ServeWebSocketDrainCallback = bindgen.CallbackSchema("ServeWebSocketDrainCallback");
const ServeWebSocketMessage = @FieldType(bindgen.Args(ServeWebSocketMessageCallback), "message");

comptime {
    _ = ServerWebSocketClass;
}
