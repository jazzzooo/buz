pub const PollFailure = @import("./PollFailure.zig").PollFailure;

pub const ListenFailure = extern struct {
    system_error: c_int = 0,
    server_name_error: uws.ServerNameError = .ok,
    poll_error: PollFailure = .{},
    socket_bound: c_int = 0,

    pub fn systemErrno(this: ListenFailure) ?bun.sys.SystemErrno {
        return if (this.poll_error.domain != .none)
            this.poll_error.systemErrno()
        else
            (PollFailure{ .domain = .system, .code = this.system_error }).systemErrno();
    }
};

pub const ListenConfig = struct {
    port: u16,
    host: ?[*:0]const u8 = null,
    options: c_int = 0,
};

pub fn NewApp(comptime ssl: bool) type {
    return struct {
        pub const is_ssl = ssl;
        const ssl_flag: i32 = @intFromBool(ssl);
        const ThisApp = @This();

        pub fn close(this: *ThisApp) void {
            return c.uws_app_close(ssl_flag, @as(*uws_app_s, @ptrCast(this)));
        }

        pub fn closeIdleConnections(this: *ThisApp) void {
            return c.uws_app_close_idle(ssl_flag, @as(*uws_app_s, @ptrCast(this)));
        }

        pub fn create(context: ?*uws.SslCtx, request_cert: bool, reject_unauthorized: bool) bun.OOM!*ThisApp {
            bun.assert((context != null) == ssl);
            return @ptrCast(c.uws_create_app(ssl_flag, context, @intFromBool(request_cert), @intFromBool(reject_unauthorized)) orelse return error.OutOfMemory);
        }

        pub fn destroy(app: *ThisApp) void {
            return c.uws_app_destroy(ssl_flag, @as(*uws_app_s, @ptrCast(app)));
        }

        pub fn setFlags(this: *ThisApp, require_host_header: bool, use_strict_method_validation: bool) void {
            return c.uws_app_set_flags(ssl_flag, @as(*uws_app_t, @ptrCast(this)), require_host_header, use_strict_method_validation);
        }

        pub fn setMaxHTTPHeaderSize(this: *ThisApp, max_header_size: u64) void {
            return c.uws_app_set_max_http_header_size(ssl_flag, @as(*uws_app_t, @ptrCast(this)), max_header_size);
        }

        pub fn setRequestHandler(app: *ThisApp, comptime T: type, context: T, comptime handler: fn (T, *Request, *Response) void) void {
            const Callback = struct {
                fn call(response: *anyopaque, request: *anyopaque, data: ?*anyopaque) callconv(.c) void {
                    handler(@ptrCast(@alignCast(data.?)), @ptrCast(@alignCast(request)), @ptrCast(@alignCast(response)));
                }
            };
            c.uws_app_set_request_handler(ssl_flag, @ptrCast(app), @ptrCast(context), Callback.call);
        }

        pub fn publishWithOptions(app: *ThisApp, topic: []const u8, message: []const u8, opcode: Opcode, compress: bool) bool {
            return c.uws_publish(
                @intFromBool(ssl),
                @ptrCast(app),
                topic.ptr,
                topic.len,
                message.ptr,
                message.len,
                opcode,
                compress,
            );
        }

        pub const ListenSocket = opaque {
            pub inline fn close(this: *ThisApp.ListenSocket) void {
                return @as(*uws.ListenSocket, @ptrCast(this)).close();
            }
            pub inline fn getLocalPort(this: *ThisApp.ListenSocket) i32 {
                return @as(*uws.ListenSocket, @ptrCast(this)).getLocalPort();
            }

            pub fn socket(this: *ThisApp.ListenSocket) uws.NewSocketHandler(ssl) {
                return uws.NewSocketHandler(ssl).from(@ptrCast(this));
            }
        };

        pub fn run(app: *ThisApp) void {
            return c.uws_app_run(ssl_flag, @as(*uws_app_t, @ptrCast(app)));
        }
        pub fn onClientError(
            app: *ThisApp,
            comptime UserData: type,
            user_data: UserData,
            comptime handler: fn (data: UserData, socket: *us_socket_t, error_code: u8, rawPacket: []const u8) void,
        ) void {
            const Wrapper = struct {
                pub fn handle(data: *anyopaque, _: c_int, socket: *us_socket_t, error_code: u8, raw_packet: ?[*]u8, raw_packet_length: c_int) callconv(.c) void {
                    @call(bun.callmod_inline, handler, .{
                        @as(UserData, @ptrCast(@alignCast(data))),
                        socket,
                        error_code,
                        if (raw_packet) |bytes| bytes[0..(@max(raw_packet_length, 0))] else "",
                    });
                }
            };
            return c.uws_app_set_on_clienterror(ssl_flag, @ptrCast(app), Wrapper.handle, @ptrCast(user_data));
        }

        pub fn listenWithConfig(
            app: *ThisApp,
            config: ListenConfig,
            failure: *ListenFailure,
        ) ?*ThisApp.ListenSocket {
            return @ptrCast(c.uws_app_listen_with_config(ssl_flag, @ptrCast(app), config.host, config.port, config.options, failure));
        }

        pub fn listenOnUnixSocket(
            app: *ThisApp,
            domain_name: [:0]const u8,
            flags: i32,
            failure: *ListenFailure,
        ) ?*ThisApp.ListenSocket {
            return @ptrCast(c.uws_app_listen_domain_with_options(
                ssl_flag,
                @as(*uws_app_t, @ptrCast(app)),
                domain_name.ptr,
                domain_name.len,
                flags,
                failure,
            ));
        }

        pub fn constructorFailed(app: *ThisApp) bool {
            return c.uws_constructor_failed(ssl_flag, app);
        }
        pub fn numSubscribers(app: *ThisApp, topic: []const u8) u32 {
            return c.uws_num_subscribers(ssl_flag, @as(*uws_app_t, @ptrCast(app)), topic.ptr, topic.len);
        }
        pub fn publish(app: *ThisApp, topic: []const u8, message: []const u8, opcode: Opcode, compress: bool) bool {
            return c.uws_publish(ssl_flag, @as(*uws_app_t, @ptrCast(app)), topic.ptr, topic.len, message.ptr, message.len, opcode, compress);
        }
        pub fn getNativeHandle(app: *ThisApp) ?*anyopaque {
            return c.uws_get_native_handle(ssl_flag, app);
        }
        pub fn removeServerName(app: *ThisApp, hostname_pattern: [*:0]const u8) void {
            return c.uws_remove_server_name(ssl_flag, @as(*uws_app_t, @ptrCast(app)), hostname_pattern);
        }
        pub fn addServerName(app: *ThisApp, hostname_pattern: [*:0]const u8, context: *uws.SslCtx) (bun.OOM || error{FailedToAddServerName})!void {
            return switch (c.uws_add_server_name_with_context(ssl_flag, @as(*uws_app_t, @ptrCast(app)), hostname_pattern, context)) {
                .ok => {},
                .out_of_memory => error.OutOfMemory,
                .duplicate, .invalid => error.FailedToAddServerName,
            };
        }
        pub fn missingServerName(app: *ThisApp, handler: c.uws_missing_server_handler, user_data: ?*anyopaque) void {
            return c.uws_missing_server_name(ssl_flag, @as(*uws_app_t, @ptrCast(app)), handler, user_data);
        }
        pub fn filter(app: *ThisApp, handler: c.uws_filter_handler, user_data: ?*anyopaque) void {
            return c.uws_filter(ssl_flag, @as(*uws_app_t, @ptrCast(app)), handler, user_data);
        }
        pub fn prepareWebSocketContext(app: *ThisApp, behavior: *const WebSocketBehavior) bun.OOM!*uws.WebSocketUpgradeContext {
            return c.uws_prepare_websocket_context(ssl_flag, @ptrCast(app), behavior) orelse error.OutOfMemory;
        }

        pub fn releaseWebSocketContext(context: *uws.WebSocketUpgradeContext) void {
            c.uws_websocket_context_release(ssl_flag, context);
        }

        pub fn prepareWebSocketDispatch(response: *Response, request: *Request) void {
            c.uws_res_prepare_websocket_dispatch(ssl_flag, @ptrCast(response), request);
        }

        /// HTTP response object for handling HTTP responses.
        ///
        /// This wraps the uWS HttpResponse template class from HttpResponse.h, providing
        /// methods for writing response data, setting headers, handling timeouts, and
        /// managing the response lifecycle. The response object supports both regular
        /// HTTP responses and chunked transfer encoding, and can handle large data
        /// writes by automatically splitting them into appropriately sized chunks.
        ///
        /// Key features:
        /// - Write response data with automatic chunking for large payloads
        /// - Set HTTP status codes and headers
        /// - Handle response timeouts and aborted requests
        /// - Support for WebSocket upgrades
        /// - Cork/uncork functionality for efficient batched writes
        /// - Automatic handling of Connection: close semantics
        pub const Response = @import("./Response.zig").NewResponse(ssl_flag);
        pub const WebSocket = @import("./WebSocket.zig").NewWebSocket(ssl_flag);
    };
}

pub const uws_app_s = opaque {};
pub const uws_app_t = uws_app_s;

pub const c = struct {
    extern fn uws_prepare_websocket_context(c_int, *uws_app_t, *const WebSocketBehavior) ?*uws.WebSocketUpgradeContext;
    extern fn uws_websocket_context_release(c_int, *uws.WebSocketUpgradeContext) void;
    extern fn uws_res_prepare_websocket_dispatch(c_int, *uws.uws_res, *Request) void;
    extern fn uws_app_set_request_handler(c_int, *uws_app_t, ?*anyopaque, ?*const fn (*anyopaque, *anyopaque, ?*anyopaque) callconv(.c) void) void;
    pub const uws_method_handler = ?*const fn (*uws.uws_res, *Request, ?*anyopaque) callconv(.c) void;
    pub const uws_filter_handler = ?*const fn (*uws.uws_res, i32, ?*anyopaque) callconv(.c) void;
    pub const uws_missing_server_handler = ?*const fn ([*c]const u8, ?*anyopaque) callconv(.c) void;

    pub extern fn uws_app_close(ssl: i32, app: *uws_app_s) void;
    pub extern fn uws_app_close_idle(ssl: i32, app: *uws_app_s) void;
    pub extern fn uws_app_set_on_clienterror(ssl: c_int, app: *uws_app_s, handler: *const fn (*anyopaque, c_int, *us_socket_t, u8, ?[*]u8, c_int) callconv(.c) void, user_data: *anyopaque) void;
    pub extern fn uws_create_app(ssl: i32, context: ?*uws.SslCtx, request_cert: i32, reject_unauthorized: i32) ?*uws_app_t;
    pub extern fn uws_app_destroy(ssl: i32, app: *uws_app_t) void;
    pub extern fn uws_app_set_flags(ssl: i32, app: *uws_app_t, require_host_header: bool, use_strict_method_validation: bool) void;
    pub extern fn uws_app_set_max_http_header_size(ssl: i32, app: *uws_app_t, max_header_size: u64) void;
    pub extern fn uws_app_run(ssl: i32, *uws_app_t) void;
    pub extern fn uws_app_listen_with_config(
        ssl: i32,
        app: *uws_app_t,
        host: [*c]const u8,
        port: u16,
        options: i32,
        failure: *ListenFailure,
    ) ?*ListenSocket;
    pub extern fn uws_constructor_failed(ssl: i32, app: *uws_app_t) bool;
    pub extern fn uws_num_subscribers(ssl: i32, app: *uws_app_t, topic: [*c]const u8, topic_length: usize) c_uint;
    pub extern fn uws_publish(ssl: i32, app: *uws_app_t, topic: [*c]const u8, topic_length: usize, message: [*c]const u8, message_length: usize, opcode: Opcode, compress: bool) bool;
    pub extern fn uws_get_native_handle(ssl: i32, app: *anyopaque) ?*anyopaque;
    pub extern fn uws_remove_server_name(ssl: i32, app: *uws_app_t, hostname_pattern: [*c]const u8) void;
    pub extern fn uws_add_server_name_with_context(ssl: i32, app: *uws_app_t, hostname_pattern: [*c]const u8, context: *uws.SslCtx) uws.ServerNameError;
    pub extern fn uws_missing_server_name(ssl: i32, app: *uws_app_t, handler: uws_missing_server_handler, user_data: ?*anyopaque) void;
    pub extern fn uws_filter(ssl: i32, app: *uws_app_t, handler: uws_filter_handler, user_data: ?*anyopaque) void;

    pub extern fn uws_app_listen_domain_with_options(
        ssl_flag: c_int,
        app: *uws_app_t,
        domain: [*:0]const u8,
        pathlen: usize,
        i32,
        failure: *ListenFailure,
    ) ?*ListenSocket;
};

const bun = @import("bun");

const uws = bun.uws;
const ListenSocket = bun.uws.ListenSocket;
const Opcode = bun.uws.Opcode;
const Request = bun.uws.Request;
const WebSocketBehavior = bun.uws.WebSocketBehavior;
const us_socket_t = bun.uws.us_socket_t;
