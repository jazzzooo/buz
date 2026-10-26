//! `us_quic_stream_t` — one bidirectional HTTP/3 request stream. Valid
//! until its `on_stream_close` callback returns.

pub const Stream = opaque {
    extern fn us_quic_stream_socket(s: *Stream) ?*Socket;
    pub const socket = us_quic_stream_socket;

    extern fn us_quic_stream_shutdown(s: *Stream) c_int;
    pub fn shutdown(s: *Stream) WriteError!void {
        if (us_quic_stream_shutdown(s) < 0) return error.HTTP3WriteError;
    }

    extern fn us_quic_stream_close(s: *Stream) void;
    pub const close = us_quic_stream_close;

    extern fn us_quic_stream_reset(s: *Stream) void;
    pub const reset = us_quic_stream_reset;

    extern fn us_quic_stream_header_count(s: *Stream) c_uint;
    pub const headerCount = us_quic_stream_header_count;

    extern fn us_quic_stream_header(s: *Stream, i: c_uint) ?*const Header;
    pub const header = us_quic_stream_header;

    extern fn us_quic_stream_ext(s: *Stream) *anyopaque;
    pub fn ext(s: *Stream, comptime T: type) *?*T {
        return @ptrCast(@alignCast(us_quic_stream_ext(s)));
    }

    extern fn us_quic_stream_write(s: *Stream, data: [*]const u8, len: c_uint) c_int;
    pub const WriteError = error{HTTP3WriteError};
    pub fn write(s: *Stream, data: []const u8) WriteError!usize {
        const result = us_quic_stream_write(s, data.ptr, @intCast(@min(data.len, std.math.maxInt(c_int))));
        if (result < 0) return error.HTTP3WriteError;
        return @intCast(result);
    }

    extern fn us_quic_stream_want_write(s: *Stream, want: c_int) void;
    pub fn wantWrite(s: *Stream, want: bool) void {
        us_quic_stream_want_write(s, @intFromBool(want));
    }

    const HeaderStatus = enum(u8) { success, out_of_memory, invalid, stream_error, _ };
    pub const HeaderError = error{ OutOfMemory, HTTP3HeaderEncodingError };
    extern fn us_quic_stream_send_headers(s: *Stream, h: [*]const Header, n: c_uint, end_stream: c_int) HeaderStatus;
    pub fn sendHeaders(s: *Stream, headers: []const Header, end_stream: bool) HeaderError!void {
        const count = std.math.cast(c_int, headers.len) orelse return error.HTTP3HeaderEncodingError;
        switch (us_quic_stream_send_headers(s, headers.ptr, @intCast(count), @intFromBool(end_stream))) {
            .success => {},
            .out_of_memory => return error.OutOfMemory,
            .invalid, .stream_error => return error.HTTP3HeaderEncodingError,
            else => @panic("Invalid native QUIC header status"),
        }
    }
};

const bun = @import("bun");
const std = @import("std");
const uws = bun.uws;

const Header = uws.quic.Header;
const Socket = uws.quic.Socket;
