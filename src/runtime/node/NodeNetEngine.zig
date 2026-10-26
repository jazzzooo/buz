pub fn reconnect(
    context: bun.bindgen.CallContext(DoConnectSchema),
    args: bun.bindgen.Args(DoConnectSchema),
) bun.bindgen.CallError(DoConnectSchema)!void {
    var previous_tcp: ?*bun.api.TCPSocket = null;
    var previous_tls: ?*bun.api.TLSSocket = null;
    if (args.previous_socket) |socket| switch (socket) {
        .tcp => |tcp| previous_tcp = tcp.get(bun.api.TCPSocket.JSBinding).socket.get(),
        .tls => |tls| previous_tls = tls.get(bun.api.TLSSocket.JSBinding).socket.get(),
    };
    return bun.api.Listener.connectFromBinding(
        context,
        previous_tcp,
        previous_tls,
        &args.options,
    );
}

pub fn createDetached(
    context: bun.bindgen.CallContext(NewDetachedSocketSchema),
    args: bun.bindgen.Args(NewDetachedSocketSchema),
) bun.bindgen.CallError(NewDetachedSocketSchema)!bun.bindgen.Return(NewDetachedSocketSchema) {
    if (!(args.is_ssl orelse false)) {
        const socket = bun.api.TCPSocket.new(.{
            .core = .{ .socket = .detached, .allocator = bun.default_allocator },
            .ref_count = .init(),
            .protos = null,
            .handlers = null,
        });
        return .{ .tcp = try socket.getThisRefResult(context) };
    }

    const socket = bun.api.TLSSocket.new(.{
        .core = .{ .socket = .detached, .allocator = bun.default_allocator },
        .ref_count = .init(),
        .protos = null,
        .handlers = null,
    });
    return .{ .tls = try socket.getThisRefResult(context) };
}

const bun = @import("bun");
const NodeSocketBindings = bun.bindgen.Module("NodeSocket");
const DoConnectSchema = NodeSocketBindings.function("doConnect");
const NewDetachedSocketSchema = NodeSocketBindings.function("newDetachedSocket");
