pub const InternalLoopData = extern struct {
    pub const us_internal_async = opaque {};

    sweep_timer: ?*Timer,
    sweep_timer_count: i32,
    wakeup_async: ?*us_internal_async,
    head: ?*SocketGroup,
    quic_head: ?*anyopaque,
    quic_next_tick_us: i64,
    quic_timer: ?*Timer,
    iterator: ?*SocketGroup,
    recv_buf: [*]u8,
    send_buf: [*]u8,
    ssl_data: ?*anyopaque,
    pre_cb: ?*fn (?*Loop) callconv(.c) void,
    post_cb: ?*fn (?*Loop) callconv(.c) void,
    closed_udp_head: ?*udp.Socket,
    closed_head: ?*us_socket_t,
    low_prio_head: ?*us_socket_t,
    low_prio_budget: i32,
    dns_ready_head: std.atomic.Value(?*ConnectingSocket),
    closed_connecting_head: ?*ConnectingSocket,
    parent_ptr: ?*anyopaque,
    parent_vtable: ?*const ParentEventLoop.VTable,
    parent_tag: c_char,
    iteration_nr: usize,
    before_wait_ctx: ?*anyopaque,
    before_wait_cb: ?*const fn (?*anyopaque) callconv(.c) void,
    dispatch_ready_poll: ?*const fn (*Loop, ?*anyopaque) callconv(.c) void,
    tick_depth: c_int,
    pending_sweeps: u64,
    sweep_in_progress: u8,

    pub fn recvSlice(this: *InternalLoopData) []u8 {
        return this.recv_buf[0..LIBUS_RECV_BUFFER_LENGTH];
    }

    pub fn shouldEnableDateHeaderTimer(this: *const InternalLoopData) bool {
        return this.sweep_timer_count > 0;
    }

    pub fn setBeforeWait(
        this: *InternalLoopData,
        context: ?*anyopaque,
        callback: ?*const fn (?*anyopaque) callconv(.c) void,
    ) void {
        this.before_wait_ctx = context;
        this.before_wait_cb = callback;
    }

    pub fn setParent(this: *InternalLoopData, parent: ParentEventLoop) void {
        this.parent_ptr = switch (parent.kind) {
            .js => @ptrCast(parent.context.get(*bun.jsc.EventLoop)),
            .mini => @ptrCast(parent.context.get(*bun.MiniEventLoop)),
        };
        this.parent_vtable = parent.vtable;
        this.parent_tag = @intCast(@backingInt(parent.kind) + 1);
    }

    pub fn getParent(this: *const InternalLoopData) ParentEventLoop {
        return .{
            .context = switch (this.parent_tag) {
                1 => .init(@as(*bun.jsc.EventLoop, @ptrCast(@alignCast(this.parent_ptr orelse @panic("Parent loop not set - pointer is null"))))),
                2 => .init(@as(*bun.MiniEventLoop, @ptrCast(@alignCast(this.parent_ptr orelse @panic("Parent loop not set - pointer is null"))))),
                else => @panic("Parent loop data corrupted - tag is invalid"),
            },
            .kind = switch (this.parent_tag) {
                1 => .js,
                2 => .mini,
                else => @panic("Parent loop data corrupted - tag is invalid"),
            },
            .vtable = this.parent_vtable orelse @panic("Parent loop not set - vtable is null"),
        };
    }

    const LIBUS_RECV_BUFFER_LENGTH = 524288;

    comptime {
        const Native = @import("usockets-native").struct_us_internal_loop_data_t;
        if (@sizeOf(@This()) != @sizeOf(Native) or @alignOf(@This()) != @alignOf(Native))
            @compileError("uSockets loop data layout mismatch");
        for (@typeInfo(@This()).@"struct".field_names) |field| {
            if (@offsetOf(@This(), field) != @offsetOf(Native, field))
                @compileError("uSockets loop data field offset mismatch: " ++ field);
        }
    }
};

const std = @import("std");
const bun = @import("bun");
const ParentEventLoop = @import("../event_loop/ParentEventLoop.zig");

const uws = bun.uws;
const ConnectingSocket = uws.ConnectingSocket;
const Loop = uws.Loop;
const SocketGroup = uws.SocketGroup;
const Timer = uws.Timer;
const udp = uws.udp;
const us_socket_t = uws.us_socket_t;
