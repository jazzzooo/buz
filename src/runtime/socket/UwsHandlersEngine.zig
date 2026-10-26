//! Application callback tables for uSockets groups. Each adapter recovers
//! the group's native owner or the socket's typed extension payload.

/// `Ext = *?*T`: the socket ext stores a single pointer to the heap-allocated
/// owner (matching the old `socket.ext(**anyopaque).* = this` pattern). It is
/// optional because a connect/accept can fail and dispatch `onClose` /
/// `onConnectError` BEFORE the caller has had a chance to stash `this` in the
/// freshly-calloc'd ext slot — pretending it's `**T` there is a NULL deref the
/// type system can't see.
fn PtrHandler(comptime T: type, comptime ssl: bool) type {
    const S = uws.NewSocketHandler(ssl);
    return struct {
        pub const Ext = *?*T;
        inline fn wrap(s: *us_socket_t) S {
            return S.from(s);
        }
        pub fn onOpen(ext: Ext, s: *us_socket_t, _: bool, _: []const u8) void {
            const this = ext.* orelse return;
            if (@hasDecl(T, "onOpen")) this.onOpen(wrap(s));
        }
        pub fn onData(ext: Ext, s: *us_socket_t, data: []const u8) void {
            const this = ext.* orelse return;
            if (@hasDecl(T, "onData")) this.onData(wrap(s), data);
        }
        pub fn onWritable(ext: Ext, s: *us_socket_t) void {
            const this = ext.* orelse return;
            if (@hasDecl(T, "onWritable")) this.onWritable(wrap(s));
        }
        pub fn onClose(ext: Ext, s: *us_socket_t, code: i32, reason: ?*anyopaque) void {
            const this = ext.* orelse return;
            if (@hasDecl(T, "onClose")) this.onClose(wrap(s), code, reason);
        }
        pub fn onTimeout(ext: Ext, s: *us_socket_t) void {
            const this = ext.* orelse return;
            if (@hasDecl(T, "onTimeout")) this.onTimeout(wrap(s));
        }
        pub fn onLongTimeout(ext: Ext, s: *us_socket_t) void {
            const this = ext.* orelse return;
            if (@hasDecl(T, "onLongTimeout")) this.onLongTimeout(wrap(s));
        }
        pub fn onEnd(ext: Ext, s: *us_socket_t) void {
            const this = ext.* orelse return;
            if (@hasDecl(T, "onEnd")) this.onEnd(wrap(s));
        }
        pub fn onConnectError(ext: Ext, s: *us_socket_t, failure: uws.ConnectFailure) void {
            // Close FIRST, then notify — same order `main`'s `configure()`
            // trampoline used. The handler may re-enter `connectInner`
            // synchronously (node:net `autoSelectFamily` falls back to the
            // next address from inside the JS `connectError` callback); on
            // Windows/libuv, starting the next attempt's `uv_poll_t` while
            // this half-open one is still active and then closing it
            // *afterwards* leaves the second poll never delivering
            // writable/error → process hang (Win11-aarch64
            // double-connect.test, test-net-server-close).
            //
            // Safe for TLS too: `us_internal_ssl_close` short-circuits
            // SEMI_SOCKET straight to `close_raw`, and `close_raw` skips
            // dispatch for SEMI_SOCKET, so no `on_handshake`/`on_close` lands
            // in JS before we read `ext`/`this`.
            const this = ext.*;
            s.close(.failure);
            if (this) |t| {
                if (@hasDecl(T, "onConnectError")) t.onConnectError(wrap(s), failure);
            }
        }
        pub fn onConnectingError(c: *ConnectingSocket, failure: uws.ConnectFailure) void {
            const this = c.ext(?*T).* orelse return;
            if (@hasDecl(T, "onConnectError"))
                this.onConnectError(S.fromConnecting(c), failure);
        }
        pub fn onConnectingTimeout(c: *ConnectingSocket) void {
            const this = c.ext(?*T).* orelse return;
            if (@hasDecl(T, "onTimeout")) this.onTimeout(S.fromConnecting(c));
        }
        pub fn onConnectingLongTimeout(c: *ConnectingSocket) void {
            const this = c.ext(?*T).* orelse return;
            if (@hasDecl(T, "onLongTimeout")) this.onLongTimeout(S.fromConnecting(c));
        }
        pub fn onHandshake(ext: Ext, s: *us_socket_t, ok: bool, err: uws.us_bun_verify_error_t) void {
            const this = ext.* orelse return;
            if (@hasDecl(T, "onHandshake")) this.onHandshake(wrap(s), @intFromBool(ok), err);
        }
        pub fn onFd(ext: Ext, s: *us_socket_t, fd: c_int) void {
            const this = ext.* orelse return closeReceivedDescriptor(fd);
            if (@hasDecl(T, "onFd")) this.onFd(wrap(s), fd) else closeReceivedDescriptor(fd);
        }
    };
}

// ── Bun.connect / Bun.listen ────────────────────────────────────────────────
pub fn BunSocket(comptime ssl: bool) type {
    return PtrHandler(api.NewSocket(ssl), ssl);
}

pub fn socketCallbacks(comptime ssl: bool) *const VTable {
    const Table = struct {
        const value = if (ssl) tls: {
            var callbacks = vtable.make(BunSocket(true)).*;
            callbacks.on_ssl_raw_data = onRawTLSData;
            break :tls callbacks;
        } else vtable.make(BunSocket(false)).*;
    };
    return &Table.value;
}

pub fn listenerCallbacks(comptime ssl: bool) *const VTable {
    const Table = struct {
        const value = listener: {
            var callbacks = socketCallbacks(ssl).*;
            callbacks.on_open = vtable.Trampolines(BunListener(ssl)).on_open;
            break :listener callbacks;
        };
    };
    return &Table.value;
}

fn onRawTLSData(socket: *us_socket_t, data: [*c]u8, length: c_int) callconv(.c) ?*us_socket_t {
    const TLSSocket = api.NewSocket(true);
    const tls = socket.ext(?*TLSSocket).* orelse return socket;
    if (tls.twin) |raw| raw.onData(TLSSocket.Socket.from(socket), data[0..@intCast(length)]);
    return socket;
}

/// The accept callback allocates the wrapper before ordinary socket events
/// can recover it from the extension payload.
pub fn BunListener(comptime ssl: bool) type {
    const S = uws.NewSocketHandler(ssl);
    return struct {
        // No `Ext` decl — owner comes from `s.group().owner(Listener)`.
        pub fn onOpen(s: *us_socket_t, _: bool, _: []const u8) void {
            const listener = s.group().owner(api.Listener);
            const ns = api.Listener.onCreate(ssl, listener, S.from(s)) orelse return;
            ns.onOpen(S.from(s));
        }
    };
}

/// Like `PtrHandler` but the callbacks live on a separate namespace `H` (the
/// driver's pre-existing `SocketHandler(ssl)` adapter) rather than as methods
/// on the owner type itself. Ext stores `*Owner` (optional for the same reason
/// as `PtrHandler`).
fn NsHandler(comptime Owner: type, comptime H: type, comptime ssl: bool) type {
    const S = uws.NewSocketHandler(ssl);
    return struct {
        pub const Ext = *?*Owner;
        inline fn wrap(s: *us_socket_t) S {
            return S.from(s);
        }
        pub fn onOpen(ext: Ext, s: *us_socket_t, _: bool, _: []const u8) void {
            const this = ext.* orelse return;
            if (@hasDecl(H, "onOpen")) H.onOpen(this, wrap(s));
        }
        pub fn onData(ext: Ext, s: *us_socket_t, data: []const u8) void {
            const this = ext.* orelse return;
            if (@hasDecl(H, "onData")) H.onData(this, wrap(s), data);
        }
        pub fn onWritable(ext: Ext, s: *us_socket_t) void {
            const this = ext.* orelse return;
            if (@hasDecl(H, "onWritable")) H.onWritable(this, wrap(s));
        }
        pub fn onClose(ext: Ext, s: *us_socket_t, code: i32, reason: ?*anyopaque) void {
            const this = ext.* orelse return;
            if (@hasDecl(H, "onClose")) H.onClose(this, wrap(s), code, reason);
        }
        pub fn onTimeout(ext: Ext, s: *us_socket_t) void {
            const this = ext.* orelse return;
            if (@hasDecl(H, "onTimeout")) H.onTimeout(this, wrap(s));
        }
        pub fn onLongTimeout(ext: Ext, s: *us_socket_t) void {
            const this = ext.* orelse return;
            if (@hasDecl(H, "onLongTimeout")) H.onLongTimeout(this, wrap(s));
        }
        pub fn onEnd(ext: Ext, s: *us_socket_t) void {
            const this = ext.* orelse return;
            if (@hasDecl(H, "onEnd")) H.onEnd(this, wrap(s));
        }
        pub fn onConnectError(ext: Ext, s: *us_socket_t, failure: uws.ConnectFailure) void {
            // Close before notify — see PtrHandler.onConnectError.
            const this = ext.*;
            s.close(.failure);
            if (this) |t| {
                if (@hasDecl(H, "onConnectError")) H.onConnectError(t, wrap(s), failure);
            }
        }
        pub fn onConnectingError(c: *ConnectingSocket, failure: uws.ConnectFailure) void {
            const this = c.ext(?*Owner).* orelse return;
            if (@hasDecl(H, "onConnectError"))
                H.onConnectError(this, S.fromConnecting(c), failure);
        }
        pub fn onConnectingTimeout(c: *ConnectingSocket) void {
            const this = c.ext(?*Owner).* orelse return;
            if (@hasDecl(H, "onTimeout")) H.onTimeout(this, S.fromConnecting(c));
        }
        pub fn onConnectingLongTimeout(c: *ConnectingSocket) void {
            const this = c.ext(?*Owner).* orelse return;
            if (@hasDecl(H, "onLongTimeout")) H.onLongTimeout(this, S.fromConnecting(c));
        }
        pub fn onHandshake(ext: Ext, s: *us_socket_t, ok: bool, err: uws.us_bun_verify_error_t) void {
            const this = ext.* orelse return;
            if (@hasDecl(H, "onHandshake") and @TypeOf(H.onHandshake) != @TypeOf(null))
                H.onHandshake(this, wrap(s), @intFromBool(ok), err);
        }
    };
}

// ── WebSocket client ────────────────────────────────────────────────────────
pub fn WSUpgrade(comptime ssl: bool) type {
    return PtrHandler(websocket_upgrade_client.NewHTTPUpgradeClient(ssl), ssl);
}
pub fn WSClient(comptime ssl: bool) type {
    return PtrHandler(websocket_client.NewWebSocketClient(ssl), ssl);
}

// ── SQL drivers ─────────────────────────────────────────────────────────────
pub fn Postgres(comptime ssl: bool) type {
    const C = bun.api.Postgres.PostgresSQLConnection;
    return NsHandler(C, C.SocketHandler(ssl), ssl);
}
pub fn MySQL(comptime ssl: bool) type {
    return NsHandler(mysql.MySQLConnection, mysql.MySQLConnection.SocketHandler(ssl), ssl);
}
pub fn Valkey(comptime ssl: bool) type {
    return NsHandler(js_valkey.JSValkeyClient, js_valkey.SocketHandler(ssl), ssl);
}

// ── Bun.spawn IPC / process.send() ──────────────────────────────────────────
// Ext is `*IPC.SendQueue` for both child-side `process.send` and parent-side
// `Bun.spawn({ipc})`. Handlers live in `ipc.zig` as free functions, not
// methods on SendQueue, so we adapt manually instead of via PtrHandler.
pub const SpawnIPC = struct {
    const H = IPC.IPCHandlers.PosixSocket;
    const S = uws.NewSocketHandler(false);
    pub const Ext = *?*IPC.SendQueue;
    pub fn onOpen(_: Ext, _: *us_socket_t, _: bool, _: []const u8) void {}
    pub fn onData(ext: Ext, s: *us_socket_t, data: []const u8) void {
        H.onData(ext.* orelse return, S.from(s), data);
    }
    pub fn onFd(ext: Ext, s: *us_socket_t, fd: c_int) void {
        H.onFd(ext.* orelse return closeReceivedDescriptor(fd), S.from(s), fd);
    }
    pub fn onWritable(ext: Ext, s: *us_socket_t) void {
        H.onWritable(ext.* orelse return, S.from(s));
    }
    pub fn onClose(ext: Ext, s: *us_socket_t, code: i32, reason: ?*anyopaque) void {
        H.onClose(ext.* orelse return, S.from(s), code, reason);
    }
    pub fn onTimeout(ext: Ext, s: *us_socket_t) void {
        H.onTimeout(ext.* orelse return, S.from(s));
    }
    pub fn onEnd(ext: Ext, s: *us_socket_t) void {
        H.onEnd(ext.* orelse return, S.from(s));
    }
};

const IPC = @import("../../jsc/ipc.zig");
const js_valkey = @import("../valkey_jsc/ValkeyClientEngine.zig");
const mysql = @import("../../sql_jsc/MySQLEngine.zig");
const websocket_client = @import("../../http_jsc/WebSocketClientEngine.zig");
const websocket_upgrade_client = @import("../../http_jsc/websocket_client/WebSocketUpgradeClientEngine.zig");

const bun = @import("bun");
const api = bun.api;

const uws = bun.uws;
const ConnectingSocket = uws.ConnectingSocket;
const us_socket_t = uws.us_socket_t;
const VTable = uws.SocketGroup.VTable;
const vtable = @import("../../uws_sys/vtable.zig");

fn closeReceivedDescriptor(fd: c_int) void {
    if (comptime bun.Environment.isPosix) _ = @import("std").c.close(fd);
}
