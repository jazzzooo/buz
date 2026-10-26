const NodeHTTPBindings = bindgen.Module("NodeHTTP");
const GetServerAllClosedPromiseSchema = NodeHTTPBindings.function("getServerAllClosedPromise");
const SetServerIdleTimeoutSchema = NodeHTTPBindings.function("setServerIdleTimeout");
const SetCustomOptionsSchema = NodeHTTPBindings.function("setCustomOptions");

pub fn getServerAllClosedPromise(
    context: bindgen.CallContext(GetServerAllClosedPromiseSchema),
    args: bindgen.Args(GetServerAllClosedPromiseSchema),
) bindgen.CallError(GetServerAllClosedPromiseSchema)!bindgen.Return(GetServerAllClosedPromiseSchema) {
    return switch (args.server) {
        .http => |server| bun.api.HTTPServer.fromProductionClassRef(server).getAllClosedPromise(context),
        .https => |server| bun.api.HTTPSServer.fromProductionClassRef(server).getAllClosedPromise(context),
        .debug_http => |server| bun.api.HTTPServer.fromDebugClassRef(server).getAllClosedPromise(context),
        .debug_https => |server| bun.api.HTTPSServer.fromDebugClassRef(server).getAllClosedPromise(context),
    };
}

pub fn setServerIdleTimeout(args: bindgen.Args(SetServerIdleTimeoutSchema)) void {
    bun.api.AnyServer.fromBinding(args.server).setIdleTimeout(args.seconds);
}

pub fn setCustomOptions(args: bindgen.Args(SetCustomOptionsSchema)) bun.JSError!void {
    var callback = try args.callback.toOwned();
    defer callback.deinit();
    const server = bun.api.AnyServer.fromBinding(args.server);
    server.setFlags(args.requireHostHeader, args.strictMethods);
    server.setMaxHTTPHeaderSize(args.maxHeaderSize);
    server.setOnClientError(&callback);
}

const bun = @import("bun");
const bindgen = bun.bindgen;
