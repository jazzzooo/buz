exclusive: bool = false,
allow_half_open: bool = false,
reuse_port: bool = false,
ipv6_only: bool = false,

pub fn toNative(flags: @This(), comptime Uws: type) i32 {
    var result: i32 = if (flags.exclusive)
        Uws.LIBUS_LISTEN_EXCLUSIVE_PORT
    else if (flags.reuse_port)
        Uws.LIBUS_LISTEN_REUSE_PORT | Uws.LIBUS_LISTEN_REUSE_ADDR
    else
        Uws.LIBUS_LISTEN_DEFAULT;
    if (flags.allow_half_open) result |= Uws.LIBUS_SOCKET_ALLOW_HALF_OPEN;
    if (flags.ipv6_only) result |= Uws.LIBUS_SOCKET_IPV6_ONLY;
    return result;
}

test toNative {
    const Uws = struct {
        const LIBUS_LISTEN_DEFAULT = 0;
        const LIBUS_LISTEN_EXCLUSIVE_PORT = 1;
        const LIBUS_LISTEN_REUSE_PORT = 2;
        const LIBUS_LISTEN_REUSE_ADDR = 4;
        const LIBUS_SOCKET_ALLOW_HALF_OPEN = 8;
        const LIBUS_SOCKET_IPV6_ONLY = 16;
    };
    try std.testing.expectEqual(@as(i32, 30), (@This(){
        .reuse_port = true,
        .allow_half_open = true,
        .ipv6_only = true,
    }).toNative(Uws));
}

const std = @import("std");
