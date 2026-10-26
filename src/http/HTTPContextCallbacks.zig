pub fn Callbacks(comptime ssl: bool) type {
    const Handler = bun.http.NewHTTPContext(ssl).Handler;
    const Socket = uws.NewSocketHandler(ssl);
    const Implementation = struct {
        // The extension contains the ActiveSocket tagged-pointer word, not a
        // dereferenceable owner pointer. Handler decodes it before access.
        pub const Ext = *?*anyopaque;

        inline fn forward(ext: Ext, comptime name: []const u8, args: anytype) void {
            @call(.auto, @field(Handler, name), .{ext.* orelse return} ++ args);
        }

        pub fn onOpen(ext: Ext, socket: *uws.us_socket_t, _: bool, _: []const u8) void {
            forward(ext, "onOpen", .{Socket.from(socket)});
        }

        pub fn onData(ext: Ext, socket: *uws.us_socket_t, data: []const u8) void {
            forward(ext, "onData", .{ Socket.from(socket), data });
        }

        pub fn onWritable(ext: Ext, socket: *uws.us_socket_t) void {
            forward(ext, "onWritable", .{Socket.from(socket)});
        }

        pub fn onClose(ext: Ext, socket: *uws.us_socket_t, code: i32, reason: ?*anyopaque) void {
            forward(ext, "onClose", .{ Socket.from(socket), code, reason });
        }

        pub fn onTimeout(ext: Ext, socket: *uws.us_socket_t) void {
            forward(ext, "onTimeout", .{Socket.from(socket)});
        }

        pub fn onLongTimeout(ext: Ext, socket: *uws.us_socket_t) void {
            forward(ext, "onLongTimeout", .{Socket.from(socket)});
        }

        pub fn onEnd(ext: Ext, socket: *uws.us_socket_t) void {
            forward(ext, "onEnd", .{Socket.from(socket)});
        }

        pub fn onConnectError(ext: Ext, socket: *uws.us_socket_t, failure: uws.ConnectFailure) void {
            const owner = ext.*;
            socket.close(.failure);
            Handler.onConnectError(owner orelse return, Socket.from(socket), failure);
        }

        pub fn onConnectingError(socket: *uws.ConnectingSocket, failure: uws.ConnectFailure) void {
            Handler.onConnectError(socket.ext(?*anyopaque).* orelse return, Socket.fromConnecting(socket), failure);
        }
        pub fn onConnectingTimeout(socket: *uws.ConnectingSocket) void {
            forward(socket.ext(?*anyopaque), "onTimeout", .{Socket.fromConnecting(socket)});
        }
        pub fn onConnectingLongTimeout(socket: *uws.ConnectingSocket) void {
            forward(socket.ext(?*anyopaque), "onLongTimeout", .{Socket.fromConnecting(socket)});
        }

        pub fn onHandshake(ext: Ext, socket: *uws.us_socket_t, ok: bool, error_info: uws.us_bun_verify_error_t) void {
            forward(ext, "onHandshake", .{ Socket.from(socket), @as(i32, @intFromBool(ok)), error_info });
        }
    };
    return Implementation;
}

const bun = @import("bun");
const uws = bun.uws;
