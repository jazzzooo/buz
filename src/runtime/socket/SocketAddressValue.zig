const SocketAddressValue = @This();

raw: sockaddr,

pub const AddressError = error{InvalidLength};

pub fn init(address: []const u8, port_: u16) AddressError!SocketAddressValue {
    return switch (address.len) {
        4 => initIp4(address[0..4].*, port_),
        16 => initIp6(address[0..16].*, port_, 0, 0),
        else => error.InvalidLength,
    };
}

pub fn initIp4(address: [4]u8, port_: u16) SocketAddressValue {
    return .{ .raw = sockaddr.v4(
        std.mem.nativeToBig(u16, port_),
        std.mem.bytesToValue(u32, &address),
    ) };
}

pub const initIPv4 = initIp4;

pub fn initIp6(address: [16]u8, port_: u16, flow_info: u32, scope_id: u32) SocketAddressValue {
    return .{ .raw = sockaddr.v6(
        std.mem.nativeToBig(u16, port_),
        address,
        flow_info,
        scope_id,
    ) };
}

pub const initIPv6 = initIp6;

pub fn fromPosix(address: *const std.posix.sockaddr) ?SocketAddressValue {
    return switch (address.family) {
        std.posix.AF.INET => .{ .raw = .{ .sin = @as(*const sockaddr.in, @ptrCast(@alignCast(address))).* } },
        std.posix.AF.INET6 => .{ .raw = .{ .sin6 = @as(*const sockaddr.in6, @ptrCast(@alignCast(address))).* } },
        else => null,
    };
}

pub fn formatIp(this: *const SocketAddressValue, buffer: []u8) []const u8 {
    const address: *const anyopaque = if (this.family() == .INET)
        @ptrCast(&this.raw.sin.addr)
    else
        @ptrCast(&this.raw.sin6.addr);
    return std.mem.sliceTo(ares.ares_inet_ntop(this.family().int(), address, buffer.ptr, @intCast(buffer.len)) orelse unreachable, 0);
}

pub fn address4(this: *const SocketAddressValue) u32 {
    return this.raw.sin.addr;
}

pub fn address6(this: *const SocketAddressValue) [16]u8 {
    return this.raw.sin6.addr;
}

pub fn scopeId(this: *const SocketAddressValue) u32 {
    return this.raw.sin6.scope_id;
}

pub fn family(this: *const SocketAddressValue) AF {
    return @fromBackingInt(@intCast(this.raw.sin.family));
}

pub fn port(this: *const SocketAddressValue) u16 {
    return std.mem.bigToNative(u16, this.raw.sin.port);
}

pub fn flowLabel(this: *const SocketAddressValue) ?u32 {
    return if (this.family() == .INET6) this.raw.sin6.flowinfo else null;
}

pub const AF = enum(inet.sa_family_t) {
    INET = @intCast(inet.AF_INET),
    INET6 = @intCast(inet.AF_INET6),

    pub inline fn int(this: AF) inet.sa_family_t {
        return @backingInt(this);
    }

    pub fn upper(this: AF) [:0]const u8 {
        return switch (this) {
            .INET => "IPv4",
            .INET6 => "IPv6",
        };
    }
};

pub const sockaddr = extern union {
    sin: inet.sockaddr_in,
    sin6: inet.sockaddr_in6,

    pub fn v4(port_: inet.in_port_t, address: u32) sockaddr {
        return .{ .sin = .{
            .family = AF.INET.int(),
            .port = port_,
            .addr = address,
        } };
    }

    pub fn v6(port_: inet.in_port_t, address: [16]u8, flow_info: u32, scope_id: u32) sockaddr {
        return .{ .sin6 = .{
            .family = AF.INET6.int(),
            .port = port_,
            .flowinfo = flow_info,
            .scope_id = scope_id,
            .addr = address,
        } };
    }

    pub fn as_v4(this: *const sockaddr) ?u32 {
        if (this.sin.family == std.posix.AF.INET) return this.sin.addr;
        if (this.sin.family != std.posix.AF.INET6) return null;
        if (!std.mem.allEqual(u8, this.sin6.addr[0..10], 0)) return null;
        if (this.sin6.addr[10] != 255 or this.sin6.addr[11] != 255) return null;
        return std.mem.bytesToValue(u32, this.sin6.addr[12..16]);
    }

    pub fn family(this: *const sockaddr) AF {
        return switch (this.sin.family) {
            std.posix.AF.INET => .INET,
            std.posix.AF.INET6 => .INET6,
            else => unreachable,
        };
    }

    pub fn fmt(this: *const sockaddr, buffer: *[inet.INET6_ADDRSTRLEN]u8) [:0]const u8 {
        const address: *const anyopaque = if (this.family() == .INET)
            @ptrCast(&this.sin.addr)
        else
            @ptrCast(&this.sin6.addr);
        const formatted = std.mem.sliceTo(ares.ares_inet_ntop(this.family().int(), address, buffer, buffer.len) orelse {
            std.debug.panic("invalid IPv6 socket address", .{});
        }, 0);
        if (bun.Environment.isDebug) bun.assertWithLocation(bun.strings.isAllASCII(formatted), @src());
        return formatted;
    }

    pub const @"127.0.0.1": sockaddr = .v4(0, std.mem.nativeToBig(u32, 0x7f000001));
    pub const @"::": sockaddr = .v6(0, inet.IN6ADDR_ANY_INIT, 0, 0);

    pub const in = inet.sockaddr_in;
    pub const in6 = inet.sockaddr_in6;
};

pub const inet = if (bun.Environment.isWindows) struct {
    const ws2 = std.os.windows.ws2_32;

    pub const IN4ADDR_LOOPBACK: u32 = ws2.IN4ADDR_LOOPBACK;
    pub const INET6_ADDRSTRLEN = 46;
    pub const IN6ADDR_ANY_INIT: [16]u8 = @splat(0);
    pub const AF_INET = ws2.AF.INET;
    pub const AF_INET6 = ws2.AF.INET6;
    pub const sa_family_t = ws2.ADDRESS_FAMILY;
    pub const in_port_t = std.os.windows.USHORT;
    pub const socklen_t = ares.socklen_t;
    pub const sockaddr_in = std.posix.sockaddr.in;
    pub const sockaddr_in6 = std.posix.sockaddr.in6;
} else struct {
    pub const IN4ADDR_LOOPBACK = bun.c.IN4ADDR_LOOPBACK;
    pub const INET6_ADDRSTRLEN = bun.c.INET6_ADDRSTRLEN;
    pub const IN6ADDR_ANY_INIT: [16]u8 = @splat(0);
    pub const AF_INET = bun.c.AF_INET;
    pub const AF_INET6 = bun.c.AF_INET6;
    pub const sa_family_t = bun.c.sa_family_t;
    pub const in_port_t = bun.c.in_port_t;
    pub const socklen_t = ares.socklen_t;
    pub const sockaddr_in = std.posix.sockaddr.in;
    pub const sockaddr_in6 = std.posix.sockaddr.in6;
};

comptime {
    const other_socklens = if (@hasDecl(bun.c, "socklen_t"))
        .{ std.posix.socklen_t, bun.c.socklen_t }
    else
        .{std.posix.socklen_t};
    for (other_socklens) |other_socklen| {
        if (@sizeOf(inet.socklen_t) != @sizeOf(other_socklen)) @compileError("socklen_t size mismatch");
        if (@alignOf(inet.socklen_t) != @alignOf(other_socklen)) @compileError("socklen_t alignment mismatch");
    }
    std.debug.assert(AF.INET.int() == ares.AF.INET);
    std.debug.assert(AF.INET6.int() == ares.AF.INET6);
}

const std = @import("std");
const bun = @import("bun");
const ares = bun.c_ares;
