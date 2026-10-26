const b = @import("bindgen_schema");
const http = @import("binding_schema_NodeHTTP");

const ordinary = b.SurfaceMemberOptions{ .attributes = .{} };
const hidden = b.SurfaceMemberOptions{
    .attributes = .{ .enumerable = false },
};
const readonly = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false },
};
const tag = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .enumerable = false },
};

fn method(comptime property_name: []const u8, comptime declaration_name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(property_name, http.schema.function(declaration_name), ordinary);
}

fn hiddenMethod(comptime property_name: []const u8, comptime declaration_name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(property_name, http.schema.function(declaration_name), hidden);
}

fn socketGetter(comptime name: []const u8, comptime getter: []const u8, comptime options: b.SurfaceMemberOptions) b.SurfaceMember {
    return b.surfaceFunctionGetter(name, http.schema.function(getter), options);
}

fn socketAccessor(comptime name: []const u8, comptime getter: []const u8, comptime setter: []const u8, comptime options: b.SurfaceMemberOptions) b.SurfaceMember {
    return b.surfaceFunctionAccessor(name, http.schema.function(getter), http.schema.function(setter), options);
}

const server_socket = b.objectSurface("JSNodeHTTPServerSocketPrototype", .{
    socketAccessor("onclose", "serverSocketGetOnClose", "serverSocketSetOnClose", ordinary),
    socketAccessor("ondrain", "serverSocketGetOnDrain", "serverSocketSetOnDrain", ordinary),
    socketAccessor("ondata", "serverSocketGetOnData", "serverSocketSetOnData", ordinary),
    socketGetter("bytesWritten", "serverSocketGetBytesWritten", ordinary),
    socketGetter("closed", "serverSocketGetClosed", readonly),
    socketGetter("response", "serverSocketGetResponse", readonly),
    socketAccessor("duplex", "serverSocketGetDuplex", "serverSocketSetDuplex", ordinary),
    socketGetter("remoteAddress", "serverSocketGetRemoteAddress", readonly),
    socketGetter("localAddress", "serverSocketGetLocalAddress", readonly),
    hiddenMethod("close", "serverSocketClose"),
    hiddenMethod("write", "serverSocketWrite"),
    hiddenMethod("end", "serverSocketEnd"),
    socketGetter("secureEstablished", "serverSocketGetSecureEstablished", readonly),
}, .{ .installation = .reified });

const http_parser = b.objectSurface("JSHTTPParserPrototype", .{
    method("close", "httpParserClose"),
    method("free", "httpParserFree"),
    method("remove", "httpParserRemove"),
    method("execute", "httpParserExecute"),
    method("finish", "httpParserFinish"),
    method("initialize", "httpParserInitialize"),
    method("pause", "httpParserPause"),
    method("resume", "httpParserResume"),
    method("consume", "httpParserConsume"),
    method("unconsume", "httpParserUnconsume"),
    method("getCurrentBuffer", "httpParserGetCurrentBuffer"),
    method("duration", "httpParserDuration"),
    method("headersCompleted", "httpParserHeadersCompleted"),
    b.surfaceSymbolString(.to_string_tag, "HTTPParser", tag),
}, .{ .installation = .reified });

const connections_list = b.objectSurface("JSConnectionsListPrototype", .{
    method("all", "connectionsListAll"),
    method("idle", "connectionsListIdle"),
    method("active", "connectionsListActive"),
    method("expired", "connectionsListExpired"),
    b.surfaceSymbolString(.to_string_tag, "ConnectionsList", tag),
}, .{ .installation = .reified });

pub const schema = b.moduleWithSurfaces("NodeHTTPSurfaces", .{ server_socket, http_parser, connections_list });
