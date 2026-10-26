pub fn callErrorHandler(socket: *UDP.UDPSocket, failure: bun.JSError) void {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(socket.globalThis);
    defer scope.deinit();
    var value = scope.takeThrownValue(failure) catch return;
    defer value.deinit();
    var root = value.toRoot() catch |err| return socket.globalThis.reportActiveExceptionAsUnhandled(err);
    defer root.deinit();
    callErrorHandlerRoot(socket, &root);
}

pub fn callSystemErrorHandler(socket: *UDP.UDPSocket, failure: bun.sys.Error) void {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(socket.globalThis);
    defer scope.deinit();
    var value = bun.bindgen.SystemError.createSysErrorInstance(&scope, failure) catch |err| {
        callErrorHandler(socket, err);
        return;
    };
    defer value.deinit();
    var root = value.toRoot() catch |err| return callErrorHandler(socket, err);
    defer root.deinit();
    callErrorHandlerRoot(socket, &root);
}

fn callErrorHandlerRoot(socket: *UDP.UDPSocket, error_value: *const bun.bindgen.Root) void {
    const global = socket.globalThis;
    const vm = global.bunVM();
    if (vm.isShuttingDown()) return;

    const wrapper = socket.wrapper orelse return reportUnhandled(socket, error_value);
    var receiver = (wrapper.toOwned() catch |err| return global.reportActiveExceptionAsUnhandled(err)) orelse
        return reportUnhandled(socket, error_value);
    defer receiver.deinit();
    var callback = (UDP.UDPSocketOnErrorSlot.ownedCallback(&receiver) catch |err|
        return global.reportActiveExceptionAsUnhandled(err)) orelse return reportUnhandled(socket, error_value);
    defer callback.deinit();

    const event_loop = vm.eventLoop();
    event_loop.enter();
    defer event_loop.exit();
    var invocation: @TypeOf(callback).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    const value = error_value.view(&invocation) catch |err| return global.reportActiveExceptionAsUnhandled(err);
    invocation.call(.{
        .bindingThis = receiver.operand(&invocation),
        .@"error" = value.operand(&invocation),
    }) catch |err| global.reportActiveExceptionAsUnhandled(err);
}

fn reportUnhandled(socket: *UDP.UDPSocket, error_value: *const bun.bindgen.Root) void {
    const global = socket.globalThis;
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    const value = error_value.view(&scope) catch |err| return global.reportActiveExceptionAsUnhandled(err);
    _ = scope.reportUncaughtException(value.operand(&scope).asAny(), false);
}

const bun = @import("bun");
const UDP = @import("./udp_socket.zig");
