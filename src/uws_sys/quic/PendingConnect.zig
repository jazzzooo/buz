//! `us_quic_pending_connect_s` — DNS-pending client connect. Created when
//! `Context.connect` returns 0 (cache miss); holds the DNS request that the
//! caller registers a callback on.
//! Consumed by exactly one of `resolved()` or `cancel()`.

pub const PendingConnect = opaque {
    pub fn addrinfo(this: *PendingConnect) *bun.dns.internal.Request {
        return @ptrCast(@alignCast(c.us_quic_pending_connect_addrinfo(@ptrCast(this)).?));
    }

    pub const Result = union(enum) {
        socket: *Socket,
        out_of_memory,
        failed,
    };

    pub fn resolved(this: *PendingConnect) Result {
        var socket: ?*c.us_quic_socket_t = null;
        return switch (c.us_quic_pending_connect_resolved(@ptrCast(this), &socket)) {
            c.US_QUIC_CONNECT_READY => .{ .socket = @ptrCast(socket.?) },
            c.US_QUIC_CONNECT_OUT_OF_MEMORY => .out_of_memory,
            else => .failed,
        };
    }

    pub fn cancel(this: *PendingConnect) void {
        c.us_quic_pending_connect_cancel(@ptrCast(this));
    }
};

const bun = @import("bun");
const c = @import("usockets-native");
const uws = bun.uws;
const Socket = uws.quic.Socket;
