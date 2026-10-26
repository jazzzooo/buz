pub fn didAbruptClose(global: *jsc.JSGlobalObject, websocket: *CppWebSocket, reason: ErrorCode) void {
    var scope = EventLoopScope.init(global);
    defer scope.deinit();
    bun.bindgen.Engine(WebSocketDidAbruptCloseSchema).call(global, .{
        .webSocket = websocket,
        .errorCode = @backingInt(reason),
    });
}

pub fn didClose(global: *jsc.JSGlobalObject, websocket: *CppWebSocket, code: u16, reason: *bun.String) void {
    var scope = EventLoopScope.init(global);
    defer scope.deinit();
    var bound_reason = takeDOMString(reason);
    defer bound_reason.deinit();
    bun.bindgen.Engine(WebSocketDidCloseSchema).call(global, .{
        .webSocket = websocket,
        .code = code,
        .reason = bound_reason.operand(),
    });
}

pub fn didReceiveText(global: *jsc.JSGlobalObject, websocket: *CppWebSocket, clone: bool, value: bun.TextView) void {
    var scope = EventLoopScope.init(global);
    defer scope.deinit();
    var text = bindText(value, clone);
    defer text.deinit();
    bun.bindgen.Engine(WebSocketDidReceiveTextSchema).call(global, .{
        .webSocket = websocket,
        .text = text.operand(),
    });
}

pub fn didReceiveBytes(global: *jsc.JSGlobalObject, websocket: *CppWebSocket, bytes: []const u8, opcode: u8) void {
    var scope = EventLoopScope.init(global);
    defer scope.deinit();
    bun.bindgen.Engine(WebSocketDidReceiveBytesSchema).call(global, .{
        .webSocket = websocket,
        .bytes = bun.bindgen.BytesOperand.fromSlice(bytes),
        .opcode = opcode,
    });
}

pub fn rejectUnauthorized(websocket: *CppWebSocket) bool {
    return bun.bindgen.Engine(WebSocketRejectUnauthorizedSchema).call(.{ .webSocket = websocket });
}

pub fn didConnect(
    global: *jsc.JSGlobalObject,
    websocket: *CppWebSocket,
    socket: *uws.Socket,
    buffered_data: []const u8,
    deflate_params: ?*const WebSocketDeflate.Params,
    secure: ?*uws.SslCtx,
) bun.JSError!void {
    var scope = EventLoopScope.init(global);
    defer scope.deinit();
    const Operation = bun.bindgen.Engine(WebSocketDidConnectSchema);
    bun.bindgen.Engine(WebSocketClearUpgradeClientSchema).call(.{ .webSocket = websocket });
    var args: bun.bindgen.Args(WebSocketDidConnectSchema) = .{
        .webSocket = websocket,
        .socket = .initNative(socket),
        .bufferedData = bun.bindgen.BytesOperand.fromSlice(buffered_data),
        .deflateParams = if (deflate_params) |params| @ptrCast(@constCast(params)) else null,
        .sslContext = secure,
    };
    socket.ext(?*anyopaque).* = null;
    try Operation.call(global, &args);
}

pub fn didConnectWithTunnel(
    global: *jsc.JSGlobalObject,
    websocket: *CppWebSocket,
    tunnel: WebSocketProxy.Tunnel,
    buffered_data: []const u8,
    deflate_params: ?*const WebSocketDeflate.Params,
) bun.JSError!void {
    var scope = EventLoopScope.init(global);
    defer scope.deinit();
    bun.bindgen.Engine(WebSocketClearUpgradeClientSchema).call(.{ .webSocket = websocket });
    try bun.bindgen.Engine(WebSocketDidConnectWithTunnelSchema).call(global, .{
        .webSocket = websocket,
        .tunnel = @ptrCast(@alignCast(tunnel.context)),
        .bufferedData = bun.bindgen.BytesOperand.fromSlice(buffered_data),
        .deflateParams = if (deflate_params) |params| @ptrCast(@constCast(params)) else null,
    });
}

pub fn ref(websocket: *CppWebSocket) void {
    bun.bindgen.Engine(WebSocketIncrementPendingActivitySchema).call(.{ .webSocket = websocket });
}

pub fn unref(websocket: *CppWebSocket) void {
    bun.bindgen.Engine(WebSocketDecrementPendingActivitySchema).call(.{ .webSocket = websocket });
}

pub fn setProtocol(websocket: *CppWebSocket, protocol: *bun.String) void {
    var bound_protocol = takeDOMString(protocol);
    defer bound_protocol.deinit();
    bun.bindgen.Engine(WebSocketSetProtocolSchema).call(.{
        .webSocket = websocket,
        .protocol = bound_protocol.operand(),
    });
}

const EventLoopScope = struct {
    loop: *jsc.EventLoop,

    fn init(global: *jsc.JSGlobalObject) EventLoopScope {
        const loop = global.bunVM().eventLoop();
        loop.enter();
        return .{ .loop = loop };
    }

    fn deinit(scope: *EventLoopScope) void {
        scope.loop.exit();
    }
};

fn takeDOMString(value: *bun.String) bun.bindgen.DOMString {
    const owned = value.*;
    value.* = .empty;
    return bun.bindgen.DOMString.fromBunString(owned) catch bun.outOfMemory();
}

fn bindText(value: bun.TextView, clone: bool) bun.bindgen.DOMString {
    if (clone) return bun.bindgen.DOMString.fromTextView(value) catch bun.outOfMemory();
    if (value.isEmpty()) return bun.bindgen.DOMString.fromUTF8("") catch bun.outOfMemory();

    // Non-cloned values are globally allocated so the engine string can
    // adopt their backing store.
    const owned = switch (value) {
        .utf16 => |units| bun.String.createExternalGloballyAllocated(.utf16, @constCast(units)),
        .latin1 => |bytes| bun.String.createExternalGloballyAllocated(.latin1, @constCast(bytes)),
        .utf8 => unreachable,
    };
    return bun.bindgen.DOMString.fromBunString(owned) catch bun.outOfMemory();
}

const CppWebSocket = @import("./CppWebSocket.zig").CppWebSocket;
const WebSocketDeflate = @import("./WebSocketDeflate.zig");
const WebSocketProxy = @import("./WebSocketProxy.zig");
const ErrorCode = @import("../WebSocketClientEngine.zig").ErrorCode;

const bun = @import("bun");
const jsc = bun.jsc;
const uws = bun.uws;
const WebSocketBindings = bun.bindgen.Module("websocket_client");
const WebSocketDidAbruptCloseSchema = WebSocketBindings.engineShim("webSocketDidAbruptClose");
const WebSocketDidConnectSchema = WebSocketBindings.engineShim("webSocketDidConnect");
const WebSocketClearUpgradeClientSchema = WebSocketBindings.engineShim("webSocketClearUpgradeClient");
const WebSocketDidConnectWithTunnelSchema = WebSocketBindings.engineShim("webSocketDidConnectWithTunnel");
const WebSocketDidCloseSchema = WebSocketBindings.engineShim("webSocketDidClose");
const WebSocketDidReceiveBytesSchema = WebSocketBindings.engineShim("webSocketDidReceiveBytes");
const WebSocketDidReceiveTextSchema = WebSocketBindings.engineShim("webSocketDidReceiveText");
const WebSocketRejectUnauthorizedSchema = WebSocketBindings.engineShim("webSocketRejectUnauthorized");
const WebSocketIncrementPendingActivitySchema = WebSocketBindings.engineShim("webSocketIncrementPendingActivity");
const WebSocketDecrementPendingActivitySchema = WebSocketBindings.engineShim("webSocketDecrementPendingActivity");
const WebSocketSetProtocolSchema = WebSocketBindings.engineShim("webSocketSetProtocol");
