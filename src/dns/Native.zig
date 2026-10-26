fn lookup(loop: ?*c.struct_us_loop_t, hostname: [*c]const u8, port: u16, out: [*c]?*c.BunDNSRequest) callconv(.c) u8 {
    if (out == null) return c.BUN_DNS_INVALID_ARGUMENT;
    out[0] = null;
    const native_loop: *bun.uws.Loop = @ptrCast(@alignCast(loop orelse return c.BUN_DNS_INVALID_ARGUMENT));
    const host: ?[:0]const u8 = if (hostname != null) std.mem.span(@as([*:0]const u8, @ptrCast(hostname))) else null;
    var ready = false;
    const request = (Internal.getaddrinfo(native_loop, host, port, &ready) catch return c.BUN_DNS_OUT_OF_MEMORY).?;
    out[0] = @ptrCast(request);
    return if (ready) c.BUN_DNS_READY else c.BUN_DNS_PENDING;
}

fn subscribe(request: ?*c.BunDNSRequest, socket: ?*c.struct_us_connecting_socket_t) callconv(.c) u8 {
    const owner: *Internal.Request = @ptrCast(@alignCast(request orelse return 0));
    const observer: *bun.uws.ConnectingSocket = @ptrCast(socket orelse return 0);
    Internal.subscribeSocket(owner, observer) catch return 0;
    return 1;
}

fn cancel(request: ?*c.BunDNSRequest, socket: ?*c.struct_us_connecting_socket_t) callconv(.c) u8 {
    const owner: *Internal.Request = @ptrCast(@alignCast(request orelse return 0));
    const observer: *bun.uws.ConnectingSocket = @ptrCast(socket orelse return 0);
    return @intFromBool(Internal.cancelSocket(owner, observer));
}

fn release(request: ?*c.BunDNSRequest, invalidate: u8) callconv(.c) void {
    const owner: *Internal.Request = @ptrCast(@alignCast(request orelse return));
    Internal.freeaddrinfo(owner, invalidate != 0);
}

fn result(request: ?*c.BunDNSRequest, out: [*c][*c]const c.struct_addrinfo) callconv(.c) i32 {
    if (out == null) return c.EAI_FAIL;
    out[0] = null;
    const owner: *Internal.Request = @ptrCast(@alignCast(request orelse return c.EAI_FAIL));
    const resolved = Internal.getRequestResult(owner);
    out[0] = resolved.addresses();
    return resolved.err;
}

fn exportFunction(comptime name: []const u8, comptime implementation: anytype) void {
    const declared: *const @TypeOf(@field(c, name)) = &implementation;
    @export(declared, .{ .name = name });
}

comptime {
    exportFunction("bun_dns_lookup", lookup);
    exportFunction("bun_dns_subscribe", subscribe);
    exportFunction("bun_dns_cancel", cancel);
    exportFunction("bun_dns_release", release);
    exportFunction("bun_dns_result", result);
}

const std = @import("std");
const bun = @import("bun");
const c = @import("dns-native");
const Internal = @import("./InternalResolver.zig").Internal;
