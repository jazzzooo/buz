pub const Internal = struct {
    const log = bun.Output.scoped(.dns, .hidden);

    fn readMaxTimeToLive() u64 {
        return bun.env_var.BUN_CONFIG_DNS_TIME_TO_LIVE_SECONDS.get();
    }

    var ttl_once = bun.threadedOnce(readMaxTimeToLive);

    pub fn getMaxDNSTimeToLiveSeconds() u64 {
        return ttl_once.call(.{});
    }

    pub const Request = struct {
        const Key = struct {
            host: ?[:0]const u8,
            // getaddrinfo needs the service to avoid its UDP port-zero probe.
            // Consumers supply their own port when using the cached addresses.
            port: u16,
            hash: u64,

            fn init(host: ?[:0]const u8, port: u16) Key {
                return .{ .host = host, .port = port, .hash = if (host) |value| bun.hash(value) else 0 };
            }

            fn eql(this: Key, other: Key) bool {
                if (this.hash != other.hash) return false;
                if (this.host) |host| return if (other.host) |value| std.mem.eql(u8, host, value) else false;
                return other.host == null;
            }

            fn clone(this: Key) bun.OOM!Key {
                var copy = this;
                if (this.host) |host| copy.host = try bun.default_allocator.dupeSentinel(u8, host, 0);
                return copy;
            }
        };

        pub const Result = struct {
            entries: []ResultEntry = &.{},
            err: i32 = 0,

            pub fn addresses(this: Result) [*c]const c.struct_addrinfo {
                return if (this.entries.len > 0) &this.entries[0].info else null;
            }
        };

        key: Key,
        io: std.Io,
        result: ?Result = null,
        notify: std.ArrayListUnmanaged(DNSRequestOwner) = .empty,
        // One worker reference survives through the last notification. Each
        // consumer independently holds a reference through cancellation/delivery.
        refcount: usize = 2,
        cached: bool = false,
        valid: bool = true,
        completed_at: u64 = 0,

        fn isExpired(this: *Request, now: u64) bool {
            return this.result != null and now -| this.completed_at >= getMaxDNSTimeToLiveSeconds();
        }

        fn deinit(this: *Request) void {
            bun.assert(this.refcount == 0 and !this.cached and this.notify.items.len == 0);
            if (this.result) |result| bun.default_allocator.free(result.entries);
            this.notify.deinit(bun.default_allocator);
            if (this.key.host) |host| bun.default_allocator.free(host);
            bun.default_allocator.destroy(this);
        }
    };

    const GlobalCache = struct {
        lock: std.Io.Mutex = .init,
        cache: [256]*Request = undefined,
        len: usize = 0,

        fn get(this: *GlobalCache, key: Request.Key, now: u64) ?*Request {
            var index: usize = 0;
            while (index < this.len) {
                const entry = this.cache[index];
                if (!entry.valid or entry.isExpired(now)) {
                    entry.valid = false;
                    if (entry.refcount == 0) {
                        this.deleteAt(index);
                        entry.deinit();
                        continue;
                    }
                } else if (entry.key.eql(key)) {
                    return entry;
                }
                index += 1;
            }
            return null;
        }

        fn timestamp() u64 {
            return bun.getRoughTickCountMs(.force_real_time) / std.time.ms_per_s;
        }

        fn isNearlyFull(this: *GlobalCache) bool {
            return this.len * 5 >= this.cache.len * 4;
        }

        fn deleteAt(this: *GlobalCache, index: usize) void {
            this.cache[index].cached = false;
            this.len -= 1;
            this.cache[index] = this.cache[this.len];
            dns_cache_size.store(this.len, .monotonic);
        }

        fn remove(this: *GlobalCache, entry: *Request) void {
            for (this.cache[0..this.len], 0..) |candidate, index| {
                if (candidate == entry) {
                    this.deleteAt(index);
                    return;
                }
            }
            unreachable;
        }

        fn tryPush(this: *GlobalCache, entry: *Request) void {
            if (this.len == this.cache.len) {
                for (this.cache[0..this.len], 0..) |candidate, index| {
                    if (candidate.refcount == 0) {
                        this.deleteAt(index);
                        candidate.deinit();
                        break;
                    }
                } else return;
            }
            this.cache[this.len] = entry;
            this.len += 1;
            entry.cached = true;
            dns_cache_size.store(this.len, .monotonic);
        }

        fn release(this: *GlobalCache, request: *Request) void {
            bun.assert(request.refcount > 0);
            request.refcount -= 1;
            if (request.refcount == 0 and (!request.cached or !request.valid or this.isNearlyFull())) {
                if (request.cached) this.remove(request);
                request.deinit();
            }
        }
    };

    var global_cache: GlobalCache = .{};

    const default_hints: AddrInfo = .{
        .ai_family = c.AF_UNSPEC,
        .ai_flags = if (Environment.isPosix) c.AI_ADDRCONFIG else 0,
        .ai_socktype = c.SOCK_STREAM,
    };

    pub fn getHints() AddrInfo {
        var hints = default_hints;
        if (bun.feature_flag.BUN_FEATURE_FLAG_DISABLE_ADDRCONFIG.get()) hints.ai_flags &= ~@as(c_int, c.AI_ADDRCONFIG);
        if (bun.feature_flag.BUN_FEATURE_FLAG_DISABLE_IPV6.get()) {
            hints.ai_family = c.AF_INET;
        } else if (bun.feature_flag.BUN_FEATURE_FLAG_DISABLE_IPV4.get()) {
            hints.ai_family = c.AF_INET6;
        }
        return hints;
    }

    pub const QuicRegistration = struct {
        context: *anyopaque,
        notify_callback: *const fn (*anyopaque) void,
        notify_threadsafe_callback: *const fn (*anyopaque) void,

        pub fn init(observer: anytype) QuicRegistration {
            const Observer = std.meta.Child(@TypeOf(observer));
            const Callbacks = struct {
                fn notify(context: *anyopaque) void {
                    @as(*Observer, @ptrCast(@alignCast(context))).onDNSResolved();
                }

                fn notifyThreadsafe(context: *anyopaque) void {
                    @as(*Observer, @ptrCast(@alignCast(context))).onDNSResolvedThreadsafe();
                }
            };
            return .{
                .context = observer,
                .notify_callback = Callbacks.notify,
                .notify_threadsafe_callback = Callbacks.notifyThreadsafe,
            };
        }
    };

    const DNSRequestOwner = union(enum) {
        socket: *bun.uws.ConnectingSocket,
        quic: QuicRegistration,

        fn notifyThreadsafe(this: DNSRequestOwner) void {
            switch (this) {
                .socket => |socket| uws_native.us_internal_dns_callback_threadsafe(@ptrCast(socket)),
                .quic => |registration| registration.notify_threadsafe_callback(registration.context),
            }
        }

        fn notify(this: DNSRequestOwner) void {
            switch (this) {
                .socket => |socket| uws_native.us_internal_dns_callback(@ptrCast(socket)),
                .quic => |registration| registration.notify_callback(registration.context),
            }
        }
    };

    fn subscribe(request: *Request, owner: DNSRequestOwner) bun.OOM!void {
        const io = request.io;
        global_cache.lock.lockUncancelable(io);
        if (request.result != null) {
            global_cache.lock.unlock(io);
            owner.notify();
            return;
        }
        defer global_cache.lock.unlock(io);
        try request.notify.append(bun.default_allocator, owner);
    }

    pub fn registerQuic(request: *Request, registration: QuicRegistration) bun.OOM!void {
        try subscribe(request, .{ .quic = registration });
    }

    pub fn subscribeSocket(request: *Request, socket: *bun.uws.ConnectingSocket) bun.OOM!void {
        try subscribe(request, .{ .socket = socket });
    }

    const ResultEntry = struct {
        info: c.struct_addrinfo,
        addr: c.struct_sockaddr_storage,
    };

    fn addressSize(info: *const AddrInfo) ?usize {
        if (info.ai_addr == null) return null;
        const size: usize = switch (info.ai_family) {
            c.AF_INET => @sizeOf(c.struct_sockaddr_in),
            c.AF_INET6 => @sizeOf(c.struct_sockaddr_in6),
            else => return null,
        };
        return if (info.ai_addrlen >= size) size else null;
    }

    fn nextAddress(cursor: *[*c]AddrInfo, family: c_int) ?*AddrInfo {
        while (cursor.* != null) {
            const info: *AddrInfo = @ptrCast(cursor.*);
            cursor.* = info.ai_next;
            if (info.ai_family == family and addressSize(info) != null) return info;
        }
        return null;
    }

    fn processResults(first: *AddrInfo) bun.OOM![]ResultEntry {
        var count: usize = 0;
        var cursor: [*c]AddrInfo = first;
        while (cursor != null) : (cursor = cursor.*.ai_next) {
            const info: *AddrInfo = @ptrCast(cursor);
            if (addressSize(info) != null) count = std.math.add(usize, count, 1) catch return error.OutOfMemory;
        }
        const results = try bun.default_allocator.alloc(ResultEntry, count);
        var ipv4: [*c]AddrInfo = first;
        var ipv6: [*c]AddrInfo = first;
        var want_ipv6 = true;
        for (results, 0..) |*entry, index| {
            const info = if (want_ipv6)
                nextAddress(&ipv6, c.AF_INET6) orelse nextAddress(&ipv4, c.AF_INET).?
            else
                nextAddress(&ipv4, c.AF_INET) orelse nextAddress(&ipv6, c.AF_INET6).?;
            want_ipv6 = info.ai_family != c.AF_INET6;
            const size = addressSize(info).?;
            entry.addr = std.mem.zeroes(c.struct_sockaddr_storage);
            @memcpy(std.mem.asBytes(&entry.addr)[0..size], @as([*]const u8, @ptrCast(info.ai_addr))[0..size]);
            entry.info = .{
                .ai_flags = info.ai_flags,
                .ai_family = info.ai_family,
                .ai_socktype = info.ai_socktype,
                .ai_protocol = info.ai_protocol,
                .ai_addrlen = @intCast(size),
                .ai_addr = @ptrCast(&entry.addr),
                .ai_canonname = null,
                .ai_next = if (index + 1 < count) &results[index + 1].info else null,
            };
        }
        return results;
    }

    fn memoryError() i32 {
        return c.EAI_MEMORY;
    }

    fn notFoundError() i32 {
        return c.EAI_NONAME;
    }

    fn afterResult(request: *Request, info: [*c]AddrInfo, failure: i32) void {
        var result: Request.Result = .{ .err = failure };
        if (failure == 0 and info != null) {
            const addresses: *AddrInfo = @ptrCast(info);
            defer Platform.freeAddrInfo(addresses);
            result.entries = processResults(addresses) catch blk: {
                result.err = memoryError();
                break :blk &.{};
            };
        }
        if (result.err == 0 and result.entries.len == 0) result.err = notFoundError();

        const io = request.io;
        global_cache.lock.lockUncancelable(io);
        bun.assert(request.result == null);
        request.result = result;
        request.completed_at = GlobalCache.timestamp();
        if (result.err != 0) request.valid = false;
        var notifications = request.notify;
        request.notify = .empty;
        global_cache.lock.unlock(io);

        defer notifications.deinit(bun.default_allocator);
        for (notifications.items) |owner| owner.notifyThreadsafe();
        global_cache.lock.lockUncancelable(io);
        global_cache.release(request);
        global_cache.lock.unlock(io);
    }

    fn workPoolCallback(request: *Request) void {
        const port: ?u16 = if (request.key.port > 0) request.key.port else null;
        var hints = getHints();
        var result = Platform.lookup(request.key.host, port, &hints);
        if (result == .err and result.err == c.EAI_NONAME and hints.ai_flags & c.AI_ADDRCONFIG != 0) {
            hints.ai_flags &= ~@as(c_int, c.AI_ADDRCONFIG);
            result = Platform.lookup(request.key.host, port, &hints);
        }
        switch (result) {
            .addresses => |addresses| afterResult(request, addresses, 0),
            .err => |failure| afterResult(request, null, failure),
        }
    }

    var dns_cache_hits_completed = std.atomic.Value(usize).init(0);
    var dns_cache_hits_inflight = std.atomic.Value(usize).init(0);
    var dns_cache_size = std.atomic.Value(usize).init(0);
    var dns_cache_misses = std.atomic.Value(usize).init(0);
    var dns_cache_errors = std.atomic.Value(usize).init(0);
    var getaddrinfo_calls = std.atomic.Value(usize).init(0);

    pub const Stats = struct {
        cache_hits_completed: usize,
        cache_hits_inflight: usize,
        cache_misses: usize,
        size: usize,
        errors: usize,
        total_count: usize,
    };

    pub fn stats() Stats {
        return .{
            .cache_hits_completed = dns_cache_hits_completed.load(.monotonic),
            .cache_hits_inflight = dns_cache_hits_inflight.load(.monotonic),
            .cache_misses = dns_cache_misses.load(.monotonic),
            .size = dns_cache_size.load(.monotonic),
            .errors = dns_cache_errors.load(.monotonic),
            .total_count = getaddrinfo_calls.load(.monotonic),
        };
    }

    pub fn getaddrinfo(loop: *bun.uws.Loop, host: ?[:0]const u8, port: u16, is_cache_hit: ?*bool) bun.OOM!?*Request {
        if (is_cache_hit) |hit| hit.* = false;
        const key = Request.Key.init(host, port);
        const io = loop.internal_loop_data.getParent().io();
        global_cache.lock.lockUncancelable(io);
        errdefer global_cache.lock.unlock(io);
        _ = getaddrinfo_calls.fetchAdd(1, .monotonic);
        const cache_enabled = !bun.feature_flag.BUN_FEATURE_FLAG_DISABLE_DNS_CACHE.get();
        if (cache_enabled) {
            if (global_cache.get(key, GlobalCache.timestamp())) |entry| {
                const hit = is_cache_hit orelse {
                    global_cache.lock.unlock(io);
                    return null;
                };
                entry.refcount += 1;
                hit.* = entry.result != null;
                _ = if (hit.*) dns_cache_hits_completed.fetchAdd(1, .monotonic) else dns_cache_hits_inflight.fetchAdd(1, .monotonic);
                global_cache.lock.unlock(io);
                return entry;
            }
        }

        const request = try bun.default_allocator.create(Request);
        errdefer bun.default_allocator.destroy(request);
        request.* = .{ .key = try key.clone(), .io = io };
        if (cache_enabled) global_cache.tryPush(request);
        _ = dns_cache_misses.fetchAdd(1, .monotonic);
        global_cache.lock.unlock(io);

        bun.BackgroundWork.go(loop.internal_loop_data.getParent().backgroundTasks(), bun.default_allocator, *Request, request, workPoolCallback) catch |failure| {
            afterResult(request, null, switch (failure) {
                error.OutOfMemory => memoryError(),
                error.ConcurrencyUnavailable => c.EAI_AGAIN,
            });
        };
        return request;
    }

    pub fn prefetch(loop: *bun.uws.Loop, hostname: ?[:0]const u8, port: u16) bun.OOM!void {
        if (try getaddrinfo(loop, hostname, port, null)) |request| freeaddrinfo(request, false);
    }

    pub fn cancelSocket(request: *Request, socket: *bun.uws.ConnectingSocket) bool {
        const io = request.io;
        global_cache.lock.lockUncancelable(io);
        defer global_cache.lock.unlock(io);
        // Completion moves the subscriber list while holding this lock. Once
        // the result exists, delivery owns the socket's remaining lifetime.
        if (request.result != null) return false;
        for (request.notify.items, 0..) |owner, index| {
            switch (owner) {
                .socket => |candidate| if (candidate == socket) {
                    _ = request.notify.swapRemove(index);
                    return true;
                },
                .quic => {},
            }
        }
        return false;
    }

    pub fn freeaddrinfo(request: *Request, invalidate: bool) void {
        const io = request.io;
        global_cache.lock.lockUncancelable(io);
        defer global_cache.lock.unlock(io);
        if (invalidate) {
            request.valid = false;
            _ = dns_cache_errors.fetchAdd(1, .monotonic);
        }
        global_cache.release(request);
    }

    pub fn getRequestResult(request: *Request) Request.Result {
        const io = request.io;
        global_cache.lock.lockUncancelable(io);
        defer global_cache.lock.unlock(io);
        return request.result.?;
    }
};

const std = @import("std");
const bun = @import("bun");
const Environment = bun.Environment;
const c = @import("dns-native");
const Platform = @import("./Platform.zig");
const AddrInfo = Platform.AddrInfo;
const uws_native = @import("usockets-native");
