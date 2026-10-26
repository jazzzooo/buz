//! Zig mirror of `struct us_socket_group_t`. Embedded by value in its owner
//! (Listener, VirtualMachine, uWS App, HTTPThread) — never heap-allocated on
//! its own. The loop links it lazily on first socket and unlinks on last, so
//! unused kinds cost nothing.
//!
//! `extern struct` so field order/padding match the C definition exactly — Zig
//! is free to reorder non-extern struct fields, and this is read/written
//! directly by C (loop.c walks `head_sockets`/`iterator`, context.c flips
//! `linked`).

pub const SocketGroup = extern struct {
    loop: ?*Loop = null,
    vtable: ?*const VTable = null,
    /// Embedding owner — typed access via `owner(T)`. `?*anyopaque` only
    /// because the C ABI slot is heterogenous (Listener / uWS App / RareData /
    /// null); never read this field directly.
    ext: ?*anyopaque = null,
    head_sockets: ?*us_socket_t = null,
    head_connecting_sockets: ?*ConnectingSocket = null,
    head_listen_sockets: ?*uws.ListenSocket = null,
    iterator: ?*us_socket_t = null,
    connecting_iterator: ?*ConnectingSocket = null,
    prev: ?*SocketGroup = null,
    next: ?*SocketGroup = null,
    global_tick: u32 = 0,
    timestamp: u8 = 0,
    long_timestamp: u8 = 0,
    linked: u8 = 0,

    pub const VTable = extern struct {
        on_open: ?*const fn (*us_socket_t, c_int, [*c]u8, c_int) callconv(.c) ?*us_socket_t = null,
        on_data: ?*const fn (*us_socket_t, [*c]u8, c_int) callconv(.c) ?*us_socket_t = null,
        on_fd: ?*const fn (*us_socket_t, c_int) callconv(.c) ?*us_socket_t = null,
        on_writable: ?*const fn (*us_socket_t) callconv(.c) ?*us_socket_t = null,
        on_close: ?*const fn (*us_socket_t, c_int, ?*anyopaque) callconv(.c) ?*us_socket_t = null,
        on_timeout: ?*const fn (*us_socket_t) callconv(.c) ?*us_socket_t = null,
        on_long_timeout: ?*const fn (*us_socket_t) callconv(.c) ?*us_socket_t = null,
        on_end: ?*const fn (*us_socket_t) callconv(.c) ?*us_socket_t = null,
        on_connect_error: ?*const fn (*us_socket_t, *const uws.ConnectFailure) callconv(.c) ?*us_socket_t = null,
        on_connecting_error: ?*const fn (*ConnectingSocket, *const uws.ConnectFailure) callconv(.c) ?*ConnectingSocket = null,
        on_handshake: ?*const fn (*us_socket_t, c_int, uws.us_bun_verify_error_t, ?*anyopaque) callconv(.c) void = null,
        on_ssl_raw_data: ?*const fn (*us_socket_t, [*c]u8, c_int) callconv(.c) ?*us_socket_t = null,
        on_connecting_timeout: ?*const fn (*ConnectingSocket) callconv(.c) void = null,
        on_connecting_long_timeout: ?*const fn (*ConnectingSocket) callconv(.c) void = null,
        retain_group: ?*const fn (*SocketGroup) callconv(.c) void = null,
        release_group: ?*const fn (*SocketGroup) callconv(.c) void = null,
    };

    comptime {
        verifyLayout(SocketGroup, native.struct_us_socket_group_t);
        verifyLayout(VTable, native.struct_us_socket_vtable_t);
    }

    /// Initialise an embedded group. `owner_ptr` (any single-item pointer or
    /// `null`) is what `group.owner(T)` recovers inside handlers — pass the
    /// embedding struct so dispatch can find it from a raw `*us_socket_t`.
    pub fn init(self: *SocketGroup, loop_: *Loop, vt: *const VTable, owner_ptr: anytype) void {
        const P = @TypeOf(owner_ptr);
        const erased: ?*anyopaque = if (P == @TypeOf(null)) null else switch (@typeInfo(P)) {
            .pointer => |p| if (p.size == .one) @ptrCast(@constCast(owner_ptr)) else @compileError("SocketGroup.init owner must be a single-item pointer"),
            .optional => if (owner_ptr) |o| @ptrCast(@constCast(o)) else null,
            else => @compileError("SocketGroup.init owner must be a pointer or null"),
        };
        c.us_socket_group_init(self, loop_, vt, erased);
    }

    pub fn deinit(self: *SocketGroup) void {
        c.us_socket_group_deinit(self);
    }

    pub fn closeAll(self: *SocketGroup) void {
        c.us_socket_group_close_all(self);
    }

    /// Non-null after `init`. The fields stay `?*T` only because the struct is
    /// zero-init'd by default and read directly by C; these accessors encode
    /// the post-init invariant.
    pub fn getLoop(self: *const SocketGroup) *Loop {
        return self.loop.?;
    }

    /// Recover the embedding owner. Only valid for groups whose `init` passed a
    /// non-null owner (Listener, uWS App/Context). Per-kind VM groups in
    /// `RareData` pass `null`, so callers must know which they have.
    pub fn owner(self: *const SocketGroup, comptime T: type) *T {
        return @ptrCast(@alignCast(self.ext.?));
    }

    pub fn isEmpty(self: *const SocketGroup) bool {
        return self.head_sockets == null and
            self.head_connecting_sockets == null and
            self.head_listen_sockets == null;
    }

    pub fn listen(
        self: *SocketGroup,
        kind: SocketKind,
        ssl_ctx: ?*SslCtx,
        host: ?[*:0]const u8,
        port: c_int,
        options: c_int,
        socket_ext_size: c_int,
        err: *uws.ListenFailure,
    ) ?*uws.ListenSocket {
        return c.us_socket_group_listen(self, @backingInt(kind), ssl_ctx, host, port, options, socket_ext_size, err);
    }

    pub fn listenUnix(
        self: *SocketGroup,
        kind: SocketKind,
        ssl_ctx: ?*SslCtx,
        path: [*]const u8,
        pathlen: usize,
        options: c_int,
        socket_ext_size: c_int,
        err: *uws.ListenFailure,
    ) ?*uws.ListenSocket {
        return c.us_socket_group_listen_unix(self, @backingInt(kind), ssl_ctx, path, pathlen, options, socket_ext_size, err);
    }

    pub const ConnectResult = union(enum) {
        socket: *us_socket_t,
        connecting: *ConnectingSocket,
        failed: uws.ConnectFailure,
    };

    pub const SocketResult = union(enum) {
        socket: *us_socket_t,
        failed: uws.ConnectFailure,
    };

    pub fn connect(
        self: *SocketGroup,
        kind: SocketKind,
        ssl_ctx: ?*SslCtx,
        host: [*:0]const u8,
        port: c_int,
        options: c_int,
        socket_ext_size: c_int,
    ) ConnectResult {
        var has_dns_resolved: c_int = 0;
        var failure: uws.ConnectFailure = .{};
        const ptr = c.us_socket_group_connect(self, @backingInt(kind), ssl_ctx, host, port, options, socket_ext_size, &has_dns_resolved, &failure) orelse return .{ .failed = failure };
        return if (has_dns_resolved != 0)
            .{ .socket = @ptrCast(@alignCast(ptr)) }
        else
            .{ .connecting = @ptrCast(@alignCast(ptr)) };
    }

    pub fn connectUnix(
        self: *SocketGroup,
        kind: SocketKind,
        ssl_ctx: ?*SslCtx,
        path: [*]const u8,
        pathlen: usize,
        options: c_int,
        socket_ext_size: c_int,
    ) SocketResult {
        var failure: uws.ConnectFailure = .{};
        const socket = c.us_socket_group_connect_unix(self, @backingInt(kind), ssl_ctx, path, pathlen, options, socket_ext_size, &failure) orelse return .{ .failed = failure };
        return .{ .socket = socket };
    }

    pub fn fromFd(
        self: *SocketGroup,
        kind: SocketKind,
        ssl_ctx: ?*SslCtx,
        socket_ext_size: c_int,
        fd: uws.LIBUS_SOCKET_DESCRIPTOR,
        ipc: bool,
    ) SocketResult {
        var failure: uws.ConnectFailure = .{};
        const socket = c.us_socket_from_fd(self, @backingInt(kind), ssl_ctx, socket_ext_size, fd, @intFromBool(ipc), &failure) orelse return .{ .failed = failure };
        return .{ .socket = socket };
    }

    pub fn nextInLoop(self: *SocketGroup) ?*SocketGroup {
        return c.us_socket_group_next(self);
    }
};

const c = struct {
    extern fn us_socket_group_init(*SocketGroup, *Loop, ?*const SocketGroup.VTable, ?*anyopaque) void;
    extern fn us_socket_group_deinit(*SocketGroup) void;
    extern fn us_socket_group_close_all(*SocketGroup) void;
    extern fn us_socket_group_timestamp(*SocketGroup) c_ushort;
    extern fn us_socket_group_loop(*SocketGroup) *Loop;
    extern fn us_socket_group_next(*SocketGroup) ?*SocketGroup;
    extern fn us_socket_group_listen(*SocketGroup, u8, ?*SslCtx, ?[*:0]const u8, c_int, c_int, c_int, *uws.ListenFailure) ?*uws.ListenSocket;
    extern fn us_socket_group_listen_unix(*SocketGroup, u8, ?*SslCtx, [*]const u8, usize, c_int, c_int, *uws.ListenFailure) ?*uws.ListenSocket;
    /// Returns `us_socket_t*` (fast path) OR `us_connecting_socket_t*` (slow
    /// path), discriminated by `*is_connecting`. The public `connect()` method
    /// turns this into the typed `ConnectResult` union — call that, not this.
    extern fn us_socket_group_connect(*SocketGroup, u8, ?*SslCtx, [*:0]const u8, c_int, c_int, c_int, *c_int, *uws.ConnectFailure) ?*anyopaque;
    extern fn us_socket_group_connect_unix(*SocketGroup, u8, ?*SslCtx, [*]const u8, usize, c_int, c_int, *uws.ConnectFailure) ?*us_socket_t;
    extern fn us_socket_from_fd(*SocketGroup, u8, ?*SslCtx, c_int, uws.LIBUS_SOCKET_DESCRIPTOR, c_int, *uws.ConnectFailure) ?*us_socket_t;
};

const bun = @import("bun");
const native = @import("usockets-native");

fn verifyLayout(comptime Zig: type, comptime C: type) void {
    if (@sizeOf(Zig) != @sizeOf(C) or @alignOf(Zig) != @alignOf(C))
        @compileError("uSockets native layout mismatch");
    for (@typeInfo(Zig).@"struct".field_names) |field| {
        if (@offsetOf(Zig, field) != @offsetOf(C, field))
            @compileError("uSockets native field offset mismatch: " ++ field);
    }
}

const uws = bun.uws;
const ConnectingSocket = uws.ConnectingSocket;
const Loop = uws.Loop;
const SocketKind = uws.SocketKind;
const SslCtx = uws.SslCtx;
const us_socket_t = uws.us_socket_t;
