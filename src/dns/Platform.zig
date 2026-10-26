pub const AddrInfo = if (bun.Environment.isWindows) c.ADDRINFOW else c.struct_addrinfo;

pub const Lookup = union(enum) {
    addresses: *AddrInfo,
    err: i32,
};

var sockets_mutex: std.atomic.Mutex = .unlocked;
var sockets_initialized: bool = false;

fn initializeSockets() ?i32 {
    if (comptime !bun.Environment.isWindows) return null;
    while (!sockets_mutex.tryLock()) std.atomic.spinLoopHint();
    defer sockets_mutex.unlock();
    if (sockets_initialized) return null;
    var data: c.WSADATA = undefined;
    const result = c.WSAStartup(0x0202, &data);
    if (result == c.WSAENOBUFS) return c.EAI_MEMORY;
    if (result != 0) return result;
    sockets_initialized = true;
    return null;
}

pub fn lookup(hostname: ?[:0]const u8, port: ?u16, hints: ?*const AddrInfo) Lookup {
    if (initializeSockets()) |err| return .{ .err = err };
    var service_buffer: [6]u8 = undefined;
    const service: ?[:0]const u8 = if (port) |value|
        std.mem.printSentinel(&service_buffer, "{d}", .{value}, 0) catch unreachable
    else
        null;
    var addresses: [*c]AddrInfo = null;
    const status = if (comptime bun.Environment.isWindows) result: {
        const wide_hostname = if (hostname) |value|
            std.unicode.wtf8ToWtf16LeAllocZ(bun.default_allocator, value) catch |err| return .{ .err = switch (err) {
                error.OutOfMemory => c.EAI_MEMORY,
                error.InvalidWtf8 => c.EAI_NONAME,
            } }
        else
            null;
        defer if (wide_hostname) |value| bun.default_allocator.free(value);
        var wide_service: [6]u16 = undefined;
        const service_ptr: ?[*:0]const u16 = if (service) |value| wide: {
            for (value, 0..) |byte, index| wide_service[index] = byte;
            wide_service[value.len] = 0;
            break :wide @ptrCast(&wide_service);
        } else null;
        break :result c.GetAddrInfoW(if (wide_hostname) |value| value.ptr else null, service_ptr, hints, &addresses);
    } else c.getaddrinfo(if (hostname) |value| value.ptr else null, if (service) |value| value.ptr else null, hints, &addresses);
    if (status != 0) return .{ .err = status };
    if (addresses == null) return .{ .err = c.EAI_NONAME };
    return .{ .addresses = @ptrCast(addresses) };
}

pub fn lookupError(status: c_int) bun.c_ares.Error {
    if (status == c.EAI_NONAME) return .ENOTFOUND;
    if (@hasDecl(c, "EAI_NODATA") and status == c.EAI_NODATA) return .ENOTFOUND;
    if (status == c.EAI_AGAIN) return .ETIMEOUT;
    if (status == c.EAI_BADFLAGS) return .EBADFLAGS;
    if (status == c.EAI_FAIL) return .EBADRESP;
    if (status == c.EAI_FAMILY) return .EBADFAMILY;
    if (@hasDecl(c, "EAI_ADDRFAMILY") and status == c.EAI_ADDRFAMILY) return .EBADFAMILY;
    if (status == c.EAI_MEMORY) return .ENOMEM;
    if (status == c.EAI_SERVICE) return .ESERVICE;
    if (status == c.EAI_SOCKTYPE) return .ECONNREFUSED;
    if (@hasDecl(c, "EAI_BADHINTS") and status == c.EAI_BADHINTS) return .EBADHINTS;
    if (@hasDecl(c, "EAI_PROTOCOL") and status == c.EAI_PROTOCOL) return .EBADQUERY;
    if (@hasDecl(c, "EAI_IDN_ENCODE") and status == c.EAI_IDN_ENCODE) return .EBADSTR;
    if (@hasDecl(c, "EAI_CANCELED") and status == c.EAI_CANCELED) return .ECANCELLED;
    if (comptime bun.Environment.isWindows) {
        if (status == c.WSANOTINITIALISED or status == c.WSASYSNOTREADY or status == c.WSAVERNOTSUPPORTED) return .ENOTINITIALIZED;
    }
    return .ENOTFOUND;
}

pub fn freeAddrInfo(addrinfo: *AddrInfo) void {
    if (comptime bun.Environment.isWindows) c.FreeAddrInfoW(addrinfo) else c.freeaddrinfo(addrinfo);
}

const bun = @import("bun");
const std = @import("std");
const c = @import("dns-native");
