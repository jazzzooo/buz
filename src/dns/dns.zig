pub const AI_V4MAPPED: c_int = if (bun.Environment.isWindows) 2048 else bun.c.AI_V4MAPPED;
pub const AI_ADDRCONFIG: c_int = if (bun.Environment.isWindows) 1024 else bun.c.AI_ADDRCONFIG;
pub const AI_ALL: c_int = if (bun.Environment.isWindows) 256 else bun.c.AI_ALL;
pub const AI = if (bun.Environment.isWindows) bun.windows.libuv.AI else std.c.AI;
pub const AddrInfo = Platform.AddrInfo;

pub const GetAddrInfo = struct {
    name: []const u8 = "",
    port: u16 = 0,
    options: Options = Options{},

    pub fn clone(this: GetAddrInfo) bun.OOM!Owned {
        return .{
            .name = try bun.default_allocator.dupeSentinel(u8, this.name, 0),
            .port = this.port,
            .options = this.options,
        };
    }

    pub const Owned = struct {
        name: [:0]const u8,
        port: u16,
        options: Options,

        pub fn view(this: Owned) GetAddrInfo {
            return .{ .name = this.name, .port = this.port, .options = this.options };
        }

        pub fn deinit(this: *Owned) void {
            bun.default_allocator.free(this.name);
            this.* = undefined;
        }

        pub fn lookup(this: Owned) Result.Outcome {
            var hints = this.options.toLibC();
            const addresses = switch (Platform.lookup(this.name, this.port, if (hints) |*hint| hint else null)) {
                .addresses => |value| value,
                .err => |status| {
                    const err = Platform.lookupError(status);
                    return if (err == .ENOMEM) .out_of_memory else .{ .err = err };
                },
            };
            defer Platform.freeAddrInfo(addresses);
            return .{ .result = Result.toList(default_allocator, addresses) catch return .out_of_memory };
        }
    };

    pub fn eql(this: GetAddrInfo, other: GetAddrInfo) bool {
        return this.port == other.port and
            @as(u64, @bitCast(this.options)) == @as(u64, @bitCast(other.options)) and
            std.mem.eql(u8, this.name, other.name);
    }

    pub fn toCAres(this: GetAddrInfo) bun.c_ares.AddrInfo_hints {
        var hints: bun.c_ares.AddrInfo_hints = undefined;
        @memset(std.mem.asBytes(&hints)[0..@sizeOf(bun.c_ares.AddrInfo_hints)], 0);

        hints.ai_family = this.options.family.toLibC();
        hints.ai_socktype = this.options.socktype.toLibC();
        hints.ai_protocol = this.options.protocol.toLibC();
        hints.ai_flags = @bitCast(this.options.flags);

        return hints;
    }

    pub fn hash(self: GetAddrInfo) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const bytes =
            std.mem.asBytes(&self.port) ++
            std.mem.asBytes(&self.options);

        hasher.update(bytes);
        hasher.update(self.name);

        return hasher.final();
    }

    pub const Options = packed struct(u64) {
        family: Family = .unspecified,
        /// Leaving this unset leads to many duplicate addresses returned.
        /// Node hardcodes to `SOCK_STREAM`.
        /// There don't seem to be any issues in Node's repo about this
        /// So I think it's likely that nobody actually needs `SOCK_DGRAM` as a flag
        /// https://github.com/nodejs/node/blob/2eff28fb7a93d3f672f80b582f664a7c701569fb/src/cares_wrap.cc#L1609
        socktype: SocketType = .stream,
        protocol: Protocol = .unspecified,
        backend: Backend = Backend.default,
        flags: AI = .{},
        _: u24 = 0,

        pub fn toLibC(this: Options) ?AddrInfo {
            if (this.family == .unspecified and this.socktype == .unspecified and this.protocol == .unspecified and this.flags == AI{}) {
                return null;
            }

            var hints: AddrInfo = undefined;
            @memset(std.mem.asBytes(&hints)[0..@sizeOf(AddrInfo)], 0);

            hints.ai_family = this.family.toLibC();
            hints.ai_socktype = this.socktype.toLibC();
            hints.ai_protocol = this.protocol.toLibC();
            hints.ai_flags = @bitCast(this.flags);
            return hints;
        }
    };

    pub const Family = enum(u2) {
        unspecified,
        inet,
        inet6,
        unix,

        pub const map = bun.ComptimeStringMap(Family, .{
            .{ "IPv4", Family.inet },
            .{ "IPv6", Family.inet6 },
            .{ "ipv4", Family.inet },
            .{ "ipv6", Family.inet6 },
            .{ "any", Family.unspecified },
        });

        pub fn toLibC(this: Family) i32 {
            return switch (this) {
                .unspecified => 0,
                .inet => std.posix.AF.INET,
                .inet6 => std.posix.AF.INET6,
                .unix => std.posix.AF.UNIX,
            };
        }
    };

    pub const SocketType = enum(u2) {
        unspecified,
        stream,
        dgram,

        pub const map = bun.ComptimeStringMap(SocketType, .{
            .{ "stream", SocketType.stream },
            .{ "dgram", SocketType.dgram },
            .{ "tcp", SocketType.stream },
            .{ "udp", SocketType.dgram },
        });

        pub fn toLibC(this: SocketType) i32 {
            switch (this) {
                .unspecified => return 0,
                .stream => return std.posix.SOCK.STREAM,
                .dgram => return std.posix.SOCK.DGRAM,
            }
        }
    };

    pub const Protocol = enum(u2) {
        unspecified,
        tcp,
        udp,

        pub const map = bun.ComptimeStringMap(Protocol, .{
            .{ "tcp", Protocol.tcp },
            .{ "udp", Protocol.udp },
        });

        pub fn toLibC(this: Protocol) i32 {
            switch (this) {
                .unspecified => return 0,
                .tcp => return std.posix.IPPROTO.TCP,
                .udp => return std.posix.IPPROTO.UDP,
            }
        }
    };

    pub const Backend = enum(u2) {
        c_ares,
        system,
        libc,

        pub const label = bun.ComptimeStringMap(GetAddrInfo.Backend, .{
            .{ "c-ares", .c_ares },
            .{ "c_ares", .c_ares },
            .{ "cares", .c_ares },
            .{ "async", .c_ares },
            .{ "libc", .libc },
            .{ "system", .system },
            .{ "getaddrinfo", .libc },
        });

        pub const default: GetAddrInfo.Backend = switch (bun.Environment.os) {
            .mac, .windows => .system,
            // Android: c-ares can't discover nameservers (no /etc/resolv.conf,
            // no JNI for ares_library_init_android). bionic getaddrinfo proxies
            // through netd which knows the real resolvers.
            else => if (bun.Environment.isAndroid) .system else .c_ares,
        };
    };

    pub const Result = struct {
        address: SocketAddressValue,
        ttl: i32 = 0,

        pub const List = std.array_list.Managed(Result);

        pub const Outcome = union(enum) {
            pending,
            result: List,
            err: bun.c_ares.Error,
            out_of_memory,

            pub fn deinit(this: *Outcome) void {
                switch (this.*) {
                    .result => |*list| list.deinit(),
                    .pending, .err, .out_of_memory => {},
                }
                this.* = .pending;
            }
        };

        pub fn toList(allocator: std.mem.Allocator, addrinfo: *AddrInfo) !List {
            var list = try List.initCapacity(allocator, addrInfoCount(addrinfo));

            var addr: [*c]AddrInfo = addrinfo;
            while (addr != null) : (addr = addr.*.ai_next) {
                const a: *AddrInfo = @ptrCast(addr);
                list.appendAssumeCapacity(fromAddrInfo(a) orelse continue);
            }

            return list;
        }

        pub fn fromAddrInfo(addrinfo: *AddrInfo) ?Result {
            if (addrinfo.ai_addr == null) return null;
            return Result{
                .address = SocketAddressValue.fromPosix(@ptrCast(@alignCast(addrinfo.ai_addr))) orelse return null,
                // no TTL in POSIX getaddrinfo()
                .ttl = 0,
            };
        }
    };
};
pub fn addressToString(address: *const SocketAddressValue) bun.OOM!bun.String {
    var buf: [512]u8 = undefined;
    return String.cloneLatin1(address.formatIp(&buf));
}

pub fn addrInfoCount(addrinfo: *AddrInfo) usize {
    var count: usize = 0;
    var current: [*c]AddrInfo = addrinfo;
    while (current != null) : (current = current.*.ai_next) {
        count += @intFromBool(current.*.ai_addr != null);
    }
    return count;
}

pub fn freeAddrInfo(addrinfo: *AddrInfo) void {
    Platform.freeAddrInfo(addrinfo);
}

pub const internal = @import("./InternalResolver.zig").Internal;

comptime {
    _ = @import("./Native.zig");
}

const std = @import("std");

const bun = @import("bun");
const String = bun.String;
const default_allocator = bun.default_allocator;
const SocketAddressValue = @import("../runtime/socket/SocketAddressValue.zig");
const Platform = @import("./Platform.zig");
