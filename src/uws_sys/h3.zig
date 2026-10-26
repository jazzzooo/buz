//! HTTP/3 bindings. Method names mirror NewApp/NewResponse 1:1 so the
//! comptime callers in server.zig and the `inline else` arms in AnyResponse
//! see the same surface regardless of transport.

pub const ListenSocket = opaque {
    pub fn close(this: *ListenSocket) void {
        c.uws_h3_listen_socket_close(this);
    }
    pub fn getLocalPort(this: *ListenSocket) i32 {
        return c.uws_h3_listen_socket_port(this);
    }
    pub fn getLocalAddress(this: *ListenSocket, buf: []u8) ?[]const u8 {
        const n = c.uws_h3_listen_socket_local_address(this, buf.ptr, @intCast(buf.len));
        if (n <= 0) return null;
        return buf[0..@intCast(n)];
    }
};

pub const Request = opaque {
    pub fn setParameters(req: *Request, parameters: *const []const []const u8) void {
        c.uws_h3_req_set_parameter_source(req, @ptrCast(@constCast(parameters)), @import("./Request.zig").parameterAt);
    }

    pub fn clearParameters(req: *Request) void {
        c.uws_h3_req_set_parameter_source(req, null, null);
    }
    pub fn isAncient(_: *Request) bool {
        return false;
    }
    pub fn getYield(this: *Request) bool {
        return c.uws_h3_req_get_yield(this);
    }
    pub fn setYield(this: *Request, y: bool) void {
        c.uws_h3_req_set_yield(this, y);
    }
    pub fn url(this: *Request) []const u8 {
        var p: [*]const u8 = undefined;
        return p[0..c.uws_h3_req_get_url(this, &p)];
    }
    pub fn method(this: *Request) []const u8 {
        var p: [*]const u8 = undefined;
        return p[0..c.uws_h3_req_get_method(this, &p)];
    }

    pub fn rawMethod(req: *Request) []const u8 {
        var ptr: [*]const u8 = undefined;
        return ptr[0..c.uws_h3_req_get_raw_method(req, &ptr)];
    }
    pub fn header(this: *Request, name: []const u8) ?[]const u8 {
        var p: [*]const u8 = undefined;
        const n = c.uws_h3_req_get_header(this, name.ptr, name.len, &p);
        return if (n == 0) null else p[0..n];
    }
    pub fn query(this: *Request, name: []const u8) []const u8 {
        var p: [*]const u8 = undefined;
        return p[0..c.uws_h3_req_get_query(this, name.ptr, name.len, &p)];
    }
    pub fn parameter(this: *Request, idx: u16) []const u8 {
        var p: [*]const u8 = undefined;
        return p[0..c.uws_h3_req_get_parameter(this, idx, &p)];
    }
    pub fn forEachHeader(
        this: *Request,
        comptime Ctx: type,
        comptime cb: fn (ctx: Ctx, name: []const u8, value: []const u8) void,
        ctx: Ctx,
    ) void {
        const Wrap = struct {
            fn each(n: [*]const u8, nl: usize, v: [*]const u8, vl: usize, ud: ?*anyopaque) callconv(.c) void {
                cb(@ptrCast(@alignCast(ud.?)), n[0..nl], v[0..vl]);
            }
        };
        c.uws_h3_req_for_each_header(this, Wrap.each, ctx);
    }
};

pub const Response = opaque {
    pub fn end(this: *Response, data: []const u8, close_connection: bool) WriteError!void {
        _ = try c.uws_h3_res_end(this, data.ptr, data.len, close_connection).check();
    }
    pub fn tryEnd(this: *Response, data: []const u8, total: usize, close_connection: bool) WriteError!bool {
        return c.uws_h3_res_try_end(this, data.ptr, data.len, total, close_connection).check();
    }
    pub fn endWithoutBody(this: *Response, close_connection: bool) WriteError!void {
        _ = try c.uws_h3_res_end_without_body(this, close_connection).check();
    }
    pub fn endStream(this: *Response, close_connection: bool) WriteError!void {
        _ = try c.uws_h3_res_end_stream(this, close_connection).check();
    }
    pub fn write(this: *Response, data: []const u8) WriteError!WriteResult {
        var len: usize = data.len;
        return if (try c.uws_h3_res_write(this, data.ptr, &len).check()) .{ .want_more = len } else .{ .backpressure = len };
    }
    pub fn writeStatus(this: *Response, status: []const u8) WriteError!void {
        _ = try c.uws_h3_res_write_status(this, status.ptr, status.len).check();
    }
    pub fn writeHeader(this: *Response, key: []const u8, value: []const u8) WriteError!void {
        _ = try c.uws_h3_res_write_header(this, key.ptr, key.len, value.ptr, value.len).check();
    }
    pub fn writeHeaderInt(this: *Response, key: []const u8, value: u64) WriteError!void {
        _ = try c.uws_h3_res_write_header_int(this, key.ptr, key.len, value).check();
    }
    pub fn writeMark(this: *Response) WriteError!void {
        _ = try c.uws_h3_res_write_mark(this).check();
    }
    pub fn markWroteContentLengthHeader(this: *Response) void {
        c.uws_h3_res_mark_wrote_content_length_header(this);
    }
    pub fn writeContinue(this: *Response) WriteError!void {
        _ = try c.uws_h3_res_write_continue(this).check();
    }
    pub fn flushHeaders(this: *Response, immediate: bool) WriteError!void {
        _ = try c.uws_h3_res_flush_headers(this, immediate).check();
    }
    pub fn pause(this: *Response) void {
        c.uws_h3_res_pause(this);
    }
    pub fn @"resume"(this: *Response) void {
        c.uws_h3_res_resume(this);
    }
    pub fn timeout(this: *Response, seconds: u8) void {
        c.uws_h3_res_timeout(this, seconds);
    }
    pub fn resetTimeout(this: *Response) void {
        c.uws_h3_res_reset_timeout(this);
    }
    pub fn getWriteOffset(this: *Response) u64 {
        return c.uws_h3_res_get_write_offset(this);
    }
    pub fn overrideWriteOffset(this: *Response, off: u64) void {
        c.uws_h3_res_override_write_offset(this, off);
    }
    pub fn getBufferedAmount(this: *Response) u64 {
        return c.uws_h3_res_get_buffered_amount(this);
    }
    pub fn hasResponded(this: *Response) bool {
        return c.uws_h3_res_has_responded(this);
    }
    pub fn state(this: *Response) State {
        return c.uws_h3_res_state(this);
    }
    pub fn shouldCloseConnection(this: *Response) bool {
        return this.state().isHttpConnectionClose();
    }
    pub fn isCorked(_: *Response) bool {
        return false;
    }
    pub fn uncork(_: *Response) WriteError!void {}
    pub fn isConnectRequest(_: *Response) bool {
        return false;
    }
    pub fn markNeedsMore(_: *Response) void {}
    pub fn getSocketData(this: *Response) ?*anyopaque {
        return c.uws_h3_res_get_socket_data(this);
    }
    pub fn getRemoteSocketInfo(this: *Response) ?SocketAddress {
        var addr: SocketAddress = .{ .ip = undefined, .port = undefined, .is_ipv6 = undefined };
        var ip_ptr: [*]const u8 = undefined;
        const len = c.uws_h3_res_get_remote_address_info(this, &ip_ptr, &addr.port, &addr.is_ipv6);
        if (len == 0) return null;
        addr.ip = ip_ptr[0..len];
        return addr;
    }
    pub fn forceClose(this: *Response) void {
        c.uws_h3_res_force_close(this);
    }

    pub fn onWritable(
        this: *Response,
        comptime UD: type,
        comptime handler: fn (UD, u64, *Response) bool,
        ud: UD,
    ) void {
        const W = struct {
            fn cb(r: *Response, off: u64, p: ?*anyopaque) callconv(.c) bool {
                return handler(@ptrCast(@alignCast(p.?)), off, r);
            }
        };
        c.uws_h3_res_on_writable(this, W.cb, ud);
    }
    pub fn clearOnWritable(this: *Response) void {
        c.uws_h3_res_clear_on_writable(this);
    }
    pub fn onAborted(
        this: *Response,
        comptime UD: type,
        comptime handler: fn (UD, *Response) void,
        ud: UD,
    ) void {
        const W = struct {
            fn cb(r: *Response, p: ?*anyopaque) callconv(.c) void {
                handler(@ptrCast(@alignCast(p.?)), r);
            }
        };
        c.uws_h3_res_on_aborted(this, W.cb, ud);
    }
    pub fn clearAborted(this: *Response) void {
        c.uws_h3_res_on_aborted(this, null, null);
    }
    pub fn onTimeout(
        this: *Response,
        comptime UD: type,
        comptime handler: fn (UD, *Response) void,
        ud: UD,
    ) void {
        const W = struct {
            fn cb(r: *Response, p: ?*anyopaque) callconv(.c) void {
                handler(@ptrCast(@alignCast(p.?)), r);
            }
        };
        c.uws_h3_res_on_timeout(this, W.cb, ud);
    }
    pub fn clearTimeout(this: *Response) void {
        c.uws_h3_res_on_timeout(this, null, null);
    }
    pub fn onData(
        this: *Response,
        comptime UD: type,
        comptime handler: fn (UD, *Response, []const u8, bool) void,
        ud: UD,
    ) void {
        const W = struct {
            fn cb(r: *Response, ptr: [*c]const u8, len: usize, last: bool, p: ?*anyopaque) callconv(.c) void {
                handler(@ptrCast(@alignCast(p.?)), r, if (len > 0) ptr[0..len] else "", last);
            }
        };
        c.uws_h3_res_on_data(this, W.cb, ud);
    }
    pub fn clearOnData(this: *Response) void {
        c.uws_h3_res_on_data(this, null, null);
    }
    pub fn corked(this: *Response, comptime handler: anytype, args: std.meta.ArgsTuple(@TypeOf(handler))) WriteError!void {
        _ = this;
        @call(.auto, handler, args);
    }
    pub fn runCorkedWithType(this: *Response, comptime UD: type, comptime handler: fn (UD) void, ud: UD) WriteError!void {
        const W = struct {
            fn cb(p: ?*anyopaque) callconv(.c) void {
                handler(@ptrCast(@alignCast(p.?)));
            }
        };
        c.uws_h3_res_cork(this, ud, W.cb);
    }
};

pub const App = opaque {
    pub fn setRequestHandler(app: *App, comptime T: type, context: T, comptime handler: fn (T, *Request, *Response) void) void {
        const Callback = struct {
            fn call(response: *anyopaque, request: *anyopaque, data: ?*anyopaque) callconv(.c) void {
                handler(@ptrCast(@alignCast(data.?)), @ptrCast(@alignCast(request)), @ptrCast(@alignCast(response)));
            }
        };
        c.uws_h3_app_set_request_handler(app, @ptrCast(context), Callback.call);
    }
    pub fn create(opts: uws.SocketContext.BunSocketContextOptions, idle_timeout_s: u32) ?*App {
        return c.uws_h3_create_app(opts, idle_timeout_s);
    }
    pub fn addServerNameWithOptions(this: *App, hostname: [:0]const u8, opts: uws.SocketContext.BunSocketContextOptions) !void {
        if (!c.uws_h3_app_add_server_name(this, hostname.ptr, opts)) return error.FailedToAddServerName;
    }
    pub fn destroy(this: *App) void {
        c.uws_h3_app_destroy(this);
    }
    pub fn close(this: *App) void {
        c.uws_h3_app_close(this);
    }

    pub fn listenWithConfig(
        this: *App,
        comptime UD: type,
        ud: UD,
        comptime handler: fn (UD, ?*ListenSocket) void,
        config: ListenConfig,
    ) void {
        const W = struct {
            fn cb(ls: ?*ListenSocket, p: ?*anyopaque) callconv(.c) void {
                handler(@ptrCast(@alignCast(p.?)), ls);
            }
        };
        c.uws_h3_app_listen_with_config(this, config.host, config.port, config.options, W.cb, ud);
    }
};

pub const ListenConfig = extern struct {
    port: u16,
    host: ?[*:0]const u8 = null,
    options: i32 = 0,
};

const c = struct {
    extern fn uws_h3_req_get_raw_method(*Request, *[*]const u8) usize;
    extern fn uws_h3_app_set_request_handler(*App, ?*anyopaque, ?*const fn (*anyopaque, *anyopaque, ?*anyopaque) callconv(.c) void) void;
    extern fn uws_h3_req_set_parameter_source(*Request, ?*anyopaque, ?*const fn (*anyopaque, c_uint, *[*]const u8) callconv(.c) usize) void;
    const Handler = ?*const fn (*Response, *Request, ?*anyopaque) callconv(.c) void;
    const ListenHandler = ?*const fn (?*ListenSocket, ?*anyopaque) callconv(.c) void;
    const HeaderCb = *const fn ([*]const u8, usize, [*]const u8, usize, ?*anyopaque) callconv(.c) void;

    extern fn uws_h3_create_app(uws.SocketContext.BunSocketContextOptions, u32) ?*App;
    extern fn uws_h3_app_destroy(*App) void;
    extern fn uws_h3_app_close(*App) void;
    extern fn uws_h3_app_add_server_name(*App, [*:0]const u8, uws.SocketContext.BunSocketContextOptions) bool;
    extern fn uws_h3_res_write_continue(*Response) NativeWriteStatus;
    extern fn uws_h3_app_listen_with_config(*App, ?[*:0]const u8, u16, i32, ListenHandler, ?*anyopaque) void;
    extern fn uws_h3_listen_socket_port(*ListenSocket) i32;
    extern fn uws_h3_listen_socket_local_address(*ListenSocket, [*]u8, c_int) c_int;
    extern fn uws_h3_listen_socket_close(*ListenSocket) void;

    extern fn uws_h3_res_state(*Response) State;
    extern fn uws_h3_res_end(*Response, [*c]const u8, usize, bool) NativeWriteStatus;
    extern fn uws_h3_res_end_stream(*Response, bool) NativeWriteStatus;
    extern fn uws_h3_res_force_close(*Response) void;
    extern fn uws_h3_res_try_end(*Response, [*c]const u8, usize, usize, bool) NativeWriteStatus;
    extern fn uws_h3_res_end_without_body(*Response, bool) NativeWriteStatus;
    extern fn uws_h3_res_pause(*Response) void;
    extern fn uws_h3_res_resume(*Response) void;
    extern fn uws_h3_res_write_status(*Response, [*c]const u8, usize) NativeWriteStatus;
    extern fn uws_h3_res_write_header(*Response, [*c]const u8, usize, [*c]const u8, usize) NativeWriteStatus;
    extern fn uws_h3_res_write_header_int(*Response, [*c]const u8, usize, u64) NativeWriteStatus;
    extern fn uws_h3_res_mark_wrote_content_length_header(*Response) void;
    extern fn uws_h3_res_write_mark(*Response) NativeWriteStatus;
    extern fn uws_h3_res_flush_headers(*Response, bool) NativeWriteStatus;
    extern fn uws_h3_res_write(*Response, ?[*]const u8, *usize) NativeWriteStatus;
    extern fn uws_h3_res_get_write_offset(*Response) u64;
    extern fn uws_h3_res_override_write_offset(*Response, u64) void;
    extern fn uws_h3_res_has_responded(*Response) bool;
    extern fn uws_h3_res_get_buffered_amount(*Response) u64;
    extern fn uws_h3_res_reset_timeout(*Response) void;
    extern fn uws_h3_res_timeout(*Response, u8) void;
    extern fn uws_h3_res_get_socket_data(*Response) ?*anyopaque;
    extern fn uws_h3_res_on_writable(*Response, ?*const fn (*Response, u64, ?*anyopaque) callconv(.c) bool, ?*anyopaque) void;
    extern fn uws_h3_res_clear_on_writable(*Response) void;
    extern fn uws_h3_res_on_aborted(*Response, ?*const fn (*Response, ?*anyopaque) callconv(.c) void, ?*anyopaque) void;
    extern fn uws_h3_res_on_timeout(*Response, ?*const fn (*Response, ?*anyopaque) callconv(.c) void, ?*anyopaque) void;
    extern fn uws_h3_res_on_data(*Response, ?*const fn (*Response, [*c]const u8, usize, bool, ?*anyopaque) callconv(.c) void, ?*anyopaque) void;
    extern fn uws_h3_res_cork(*Response, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
    extern fn uws_h3_res_get_remote_address_info(*Response, *[*]const u8, *i32, *bool) usize;

    extern fn uws_h3_req_get_yield(*Request) bool;
    extern fn uws_h3_req_set_yield(*Request, bool) void;
    extern fn uws_h3_req_get_url(*Request, *[*]const u8) usize;
    extern fn uws_h3_req_get_method(*Request, *[*]const u8) usize;
    extern fn uws_h3_req_get_header(*Request, [*c]const u8, usize, *[*]const u8) usize;
    extern fn uws_h3_req_get_query(*Request, [*c]const u8, usize, *[*]const u8) usize;
    extern fn uws_h3_req_get_parameter(*Request, u16, *[*]const u8) usize;
    extern fn uws_h3_req_for_each_header(*Request, HeaderCb, ?*anyopaque) void;
};

const bun = @import("bun");
const std = @import("std");

const State = @import("./Response.zig").State;
const WriteResult = @import("./Response.zig").WriteResult;
const WriteError = @import("./Response.zig").WriteError;
const NativeWriteStatus = @import("./Response.zig").NativeWriteStatus;

const uws = bun.uws;
const SocketAddress = uws.SocketAddress;
