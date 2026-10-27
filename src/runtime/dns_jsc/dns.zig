const dns = @This();

const INET6_ADDRSTRLEN = if (bun.Environment.isWindows) 65 else 46;
const IANA_DNS_PORT = 53;

const LibC = struct {
    pub fn lookup(this: *Resolver, query_init: GetAddrInfo, globalThis: *jsc.JSGlobalObject, completion: DnsQueryCompletions.Owned) void {
        const key = GetAddrInfoRequest.PendingCacheKey.init(query_init);

        var cache = this.getOrPutIntoPendingCache(key, .pending_host_cache_native);
        if (cache == .inflight) {
            const dns_lookup = DNSLookup.init(this, globalThis, globalThis.allocator(), completion) catch {
                var owned = completion;
                owned.outOfMemory();
                return;
            };

            cache.inflight.append(dns_lookup);

            return;
        }

        const request = GetAddrInfoRequest.init(
            cache,
            .{ .libc = .pending },
            this,
            query_init,
            globalThis,
            "pending_host_cache_native",
            completion,
        ) catch {
            var owned = completion;
            owned.outOfMemory();
            return;
        };

        const io = GetAddrInfoRequest.Task.createOnJSThread(globalThis, request) catch {
            request.backend.libc = .out_of_memory;
            request.then();
            return;
        };

        io.schedule();
    }
};

pub fn normalizeDNSName(name: []const u8, backend: *GetAddrInfo.Backend) []const u8 {
    if (backend.* == .c_ares) {
        // https://github.com/c-ares/c-ares/issues/477
        if (strings.endsWithComptime(name, ".localhost")) {
            backend.* = .system;
            return "localhost";
        } else if (strings.endsWithComptime(name, ".local")) {
            backend.* = .system;
            // https://github.com/c-ares/c-ares/pull/463
        } else if (strings.isIPV6Address(name)) {
            backend.* = .system;
        }
        // getaddrinfo() is inconsistent with ares_getaddrinfo() when using localhost
        else if (strings.eqlComptime(name, "localhost")) {
            backend.* = .system;
        }
    }

    return name;
}

const PendingCacheConfig = struct {
    pending_cache: bool = false,
    pos_in_pending: u5 = 0,
};

fn NamePendingCacheKey(comptime Request: type, comptime Lookup: type) type {
    const Key = struct {
        hash: u64,
        name: []const u8,
        lookup: *Request = undefined,

        pub fn init(name: []const u8) @This() {
            return .{ .hash = std.hash.Wyhash.hash(0, name), .name = name };
        }

        fn eql(this: @This(), other: @This()) bool {
            return this.hash == other.hash and std.mem.eql(u8, this.name, other.name);
        }

        pub fn append(this: *@This(), lookup: *Lookup) void {
            this.lookup.tail.next = lookup;
            this.lookup.tail = lookup;
        }
    };
    return Key;
}

pub fn ResolveInfoRequest(comptime cares_type: type, comptime type_name: []const u8) type {
    const Request = struct {
        const log = Output.scoped(.ResolveInfoRequest, .hidden);

        resolver_for_caching: ?*Resolver = null,
        cache: @This().CacheConfig = @This().CacheConfig{},
        head: CAresLookup(cares_type, type_name),
        tail: *CAresLookup(cares_type, type_name) = undefined,

        pub fn init(
            cache: Resolver.LookupCacheHit(@This()),
            resolver: ?*Resolver,
            name: []const u8,
            globalThis: *jsc.JSGlobalObject,
            comptime cache_field: []const u8,
            completion: DnsQueryCompletions.Owned,
        ) !*@This() {
            var request = try globalThis.allocator().create(@This());
            var poll_ref = Async.KeepAlive.init();
            poll_ref.ref(globalThis.bunVM());
            if (resolver) |resolver_| resolver_.ref();
            request.* = .{
                .resolver_for_caching = resolver,
                .head = .{
                    .resolver = resolver,
                    .poll_ref = poll_ref,
                    .globalThis = globalThis,
                    .completion = completion,
                    .allocated = false,
                    .name = name,
                },
            };
            request.tail = &request.head;
            if (cache == .new) {
                const pending_cache = &@field(resolver.?, cache_field);
                request.resolver_for_caching = resolver;
                request.cache = @This().CacheConfig{
                    .pending_cache = true,
                    .pos_in_pending = @intCast(pending_cache.indexOf(cache.new).?),
                };
                cache.new.lookup = request;
                pending_cache.used.set(request.cache.pos_in_pending);
            }
            return request;
        }

        pub const CacheConfig = PendingCacheConfig;
        pub const PendingCacheKey = NamePendingCacheKey(@This(), CAresLookup(cares_type, type_name));

        pub fn onCaresComplete(this: *@This(), raw_error: ?c_ares.Error, timeout: i32, raw_result: ?*cares_type) void {
            const scope = Resolver.QueryCompletion.init(this.resolver_for_caching);
            defer scope.deinit();
            const err_ = scope.failure(raw_error);
            const result = if (err_ == null) raw_result else null;
            defer {
                if (err_ != null) {
                    if (raw_result) |value| value.deinit();
                }
            }
            if (this.resolver_for_caching) |resolver| {
                if (this.cache.pending_cache) {
                    resolver.drainPendingCares(
                        this.cache.pos_in_pending,
                        err_,
                        timeout,
                        @This(),
                        cares_type,
                        type_name,
                        result,
                    );
                    return;
                }
            }

            var head = this.head;
            bun.default_allocator.destroy(this);

            head.processResolve(err_, timeout, result);
        }
    };
    return Request;
}

pub const GetHostByAddrInfoRequest = struct {
    const log = Output.scoped(@This(), .visible);

    resolver_for_caching: ?*Resolver = null,
    cache: @This().CacheConfig = @This().CacheConfig{},
    head: CAresReverse,
    tail: *CAresReverse = undefined,

    pub fn init(
        cache: Resolver.LookupCacheHit(@This()),
        resolver: ?*Resolver,
        name: []const u8,
        globalThis: *jsc.JSGlobalObject,
        comptime cache_field: []const u8,
        completion: DnsQueryCompletions.Owned,
    ) !*@This() {
        var request = try globalThis.allocator().create(@This());
        var poll_ref = Async.KeepAlive.init();
        poll_ref.ref(globalThis.bunVM());
        if (resolver) |resolver_| resolver_.ref();
        request.* = .{
            .resolver_for_caching = resolver,
            .head = .{
                .resolver = resolver,
                .poll_ref = poll_ref,
                .globalThis = globalThis,
                .completion = completion,
                .allocated = false,
                .name = name,
            },
        };
        request.tail = &request.head;
        if (cache == .new) {
            const pending_cache = &@field(resolver.?, cache_field);
            request.resolver_for_caching = resolver;
            request.cache = @This().CacheConfig{
                .pending_cache = true,
                .pos_in_pending = @intCast(pending_cache.indexOf(cache.new).?),
            };
            cache.new.lookup = request;
            pending_cache.used.set(request.cache.pos_in_pending);
        }
        return request;
    }

    pub const CacheConfig = PendingCacheConfig;
    pub const PendingCacheKey = NamePendingCacheKey(@This(), CAresReverse);

    pub fn onCaresComplete(this: *@This(), raw_error: ?c_ares.Error, timeout: i32, raw_result: ?*const c_ares.struct_hostent) void {
        const scope = Resolver.QueryCompletion.init(this.resolver_for_caching);
        defer scope.deinit();
        const err_ = scope.failure(raw_error);
        const result = if (err_ == null) raw_result else null;
        if (this.resolver_for_caching) |resolver| {
            if (this.cache.pending_cache) {
                resolver.drainPendingAddrCares(
                    this.cache.pos_in_pending,
                    err_,
                    timeout,
                    result,
                );
                return;
            }
        }

        var head = this.head;
        bun.default_allocator.destroy(this);

        head.processResolve(err_, timeout, result);
    }
};

pub const CAresNameInfo = struct {
    const log = Output.scoped(.CAresNameInfo, .hidden);

    globalThis: *jsc.JSGlobalObject,
    resolver: ?*Resolver,
    completion: DnsQueryCompletions.Owned,
    poll_ref: bun.Async.KeepAlive,
    allocated: bool = false,
    next: ?*@This() = null,
    name: []const u8,

    pub fn init(resolver: ?*Resolver, globalThis: *jsc.JSGlobalObject, allocator: std.mem.Allocator, name: []const u8, completion: DnsQueryCompletions.Owned) !*@This() {
        const this = try allocator.create(@This());
        if (resolver) |owner| owner.ref();
        var poll_ref = bun.Async.KeepAlive.init();
        poll_ref.ref(globalThis.bunVM());
        this.* = .{
            .globalThis = globalThis,
            .resolver = resolver,
            .completion = completion,
            .poll_ref = poll_ref,
            .allocated = true,
            .name = name,
        };
        return this;
    }

    pub fn processResolve(this: *@This(), err_: ?c_ares.Error, _: i32, result: ?c_ares.struct_nameinfo) void {
        if (err_ orelse if (result == null) c_ares.Error.ENOTFOUND else null) |err| {
            completeDnsError(&this.completion, err, "getnameinfo", this.name);
            this.deinit();
            return;
        }
        var name_info = result.?;
        const value = nameInfoResult(&name_info) catch {
            this.onOutOfMemory();
            return;
        };
        this.onComplete(value);
        return;
    }

    pub fn onComplete(this: *@This(), result: DNSLookupServiceResult) void {
        completeDnsQuery(&this.completion, .{ .lookup_service = result });
        this.deinit();
    }

    pub fn onOutOfMemory(this: *@This()) void {
        this.completion.outOfMemory();
        this.deinit();
    }

    pub fn deinit(this: *@This()) void {
        this.poll_ref.unref(this.globalThis.bunVM());
        bun.default_allocator.free(this.name);
        if (this.resolver) |resolver| {
            resolver.requestCompleted();
            resolver.deref();
        }

        if (this.allocated) {
            this.globalThis.allocator().destroy(this);
        }
    }
};

fn nameInfoResult(name_info: *const c_ares.struct_nameinfo) bun.OOM!DNSLookupServiceResult {
    var node: DNSLookupServiceResult.Element = if (name_info.node != null)
        try bun.bindgen.DOMString.fromUTF8(name_info.node[0..bun.len(name_info.node)])
    else
        null;
    errdefer if (node) |*value| value.deinit();

    var service: DNSLookupServiceResult.Element = if (name_info.service != null)
        try bun.bindgen.DOMString.fromUTF8(name_info.service[0..bun.len(name_info.service)])
    else
        null;
    errdefer if (service) |*value| value.deinit();

    const values = [2]DNSLookupServiceResult.Element{ node, service };
    return DNSLookupServiceResult.fromOwnedSlice(&values);
}

pub const GetNameInfoRequest = struct {
    const log = Output.scoped(@This(), .visible);

    resolver_for_caching: ?*Resolver = null,
    cache: @This().CacheConfig = @This().CacheConfig{},
    head: CAresNameInfo,
    tail: *CAresNameInfo = undefined,

    pub fn init(
        cache: Resolver.LookupCacheHit(@This()),
        resolver: ?*Resolver,
        name: []const u8,
        globalThis: *jsc.JSGlobalObject,
        comptime cache_field: []const u8,
        completion: DnsQueryCompletions.Owned,
    ) !*@This() {
        var request = try globalThis.allocator().create(@This());
        var poll_ref = bun.Async.KeepAlive.init();
        poll_ref.ref(globalThis.bunVM());
        if (resolver) |owner| owner.ref();
        request.* = .{
            .resolver_for_caching = resolver,
            .head = .{ .resolver = resolver, .poll_ref = poll_ref, .globalThis = globalThis, .completion = completion, .allocated = false, .name = name },
        };
        request.tail = &request.head;
        if (cache == .new) {
            const pending_cache = &@field(resolver.?, cache_field);
            request.resolver_for_caching = resolver;
            request.cache = @This().CacheConfig{
                .pending_cache = true,
                .pos_in_pending = @intCast(pending_cache.indexOf(cache.new).?),
            };
            cache.new.lookup = request;
            pending_cache.used.set(request.cache.pos_in_pending);
        }
        return request;
    }

    pub const CacheConfig = PendingCacheConfig;
    pub const PendingCacheKey = NamePendingCacheKey(@This(), CAresNameInfo);

    pub fn onCaresComplete(this: *@This(), raw_error: ?c_ares.Error, timeout: i32, raw_result: ?c_ares.struct_nameinfo) void {
        const scope = Resolver.QueryCompletion.init(this.resolver_for_caching);
        defer scope.deinit();
        const err_ = scope.failure(raw_error);
        const result = if (err_ == null) raw_result else null;
        if (this.resolver_for_caching) |resolver| {
            if (this.cache.pending_cache) {
                resolver.drainPendingNameInfoCares(
                    this.cache.pos_in_pending,
                    err_,
                    timeout,
                    result,
                );
                return;
            }
        }

        var head = this.head;
        bun.default_allocator.destroy(this);

        head.processResolve(err_, timeout, result);
    }
};

pub const GetAddrInfoRequest = struct {
    const log = Output.scoped(.GetAddrInfoRequest, .visible);
    const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
    const ref = RefCount.ref;
    const deref = RefCount.deref;

    ref_count: RefCount = .init(),
    backend: Backend = undefined,
    query: GetAddrInfo.Owned,
    resolver_for_caching: ?*Resolver = null,
    cache: CacheConfig = CacheConfig{},
    head: DNSLookup,
    tail: *DNSLookup = undefined,

    pub fn init(
        cache: Resolver.CacheHit,
        backend: Backend,
        resolver: ?*Resolver,
        query: GetAddrInfo,
        globalThis: *jsc.JSGlobalObject,
        comptime cache_field: []const u8,
        completion: DnsQueryCompletions.Owned,
    ) !*GetAddrInfoRequest {
        log("init", .{});
        var owned_query = try query.clone();
        errdefer owned_query.deinit();
        const request = try bun.default_allocator.create(GetAddrInfoRequest);
        var poll_ref = Async.KeepAlive.init();
        poll_ref.ref(globalThis.bunVM());
        if (resolver) |resolver_| resolver_.ref();
        request.* = .{
            .backend = backend,
            .query = owned_query,
            .resolver_for_caching = resolver,
            .head = .{
                .resolver = resolver,
                .globalThis = globalThis,
                .poll_ref = poll_ref,
                .completion = completion,
                .allocated = false,
            },
        };
        request.tail = &request.head;
        if (cache == .new) {
            const pending_cache = &@field(resolver.?, cache_field);
            request.resolver_for_caching = resolver;
            request.cache = CacheConfig{
                .pending_cache = true,
                .pos_in_pending = @intCast(pending_cache.indexOf(cache.new).?),
            };
            cache.new.* = .init(request.query.view());
            cache.new.lookup = request;
            pending_cache.used.set(request.cache.pos_in_pending);
        }
        return request;
    }

    pub const Task = bun.jsc.WorkTask(GetAddrInfoRequest);

    fn deinit(this: *GetAddrInfoRequest) void {
        this.query.deinit();
        bun.default_allocator.destroy(this);
    }

    pub const CacheConfig = PendingCacheConfig;

    pub const PendingCacheKey = struct {
        hash: u64,
        query: GetAddrInfo,
        lookup: *GetAddrInfoRequest = undefined,

        fn eql(this: PendingCacheKey, other: PendingCacheKey) bool {
            return this.hash == other.hash and this.query.eql(other.query);
        }

        pub fn append(this: *PendingCacheKey, dns_lookup: *DNSLookup) void {
            var tail = this.lookup.tail;
            tail.next = dns_lookup;
            this.lookup.tail = dns_lookup;
        }

        pub fn init(query: GetAddrInfo) PendingCacheKey {
            return PendingCacheKey{
                .hash = query.hash(),
                .query = query,
                .lookup = undefined,
            };
        }
    };

    pub const Backend = union(enum) {
        c_ares: void,
        libc: GetAddrInfo.Result.Outcome,
    };

    pub fn run(this: *GetAddrInfoRequest, task: bun.WorkTaskContext) void {
        bun.assert(this.backend.libc == .pending);
        this.backend.libc = this.query.lookup();
        task.finish();
    }

    pub fn onScheduleError(this: *GetAddrInfoRequest, failure: anyerror) void {
        this.backend.libc = if (failure == error.OutOfMemory) .out_of_memory else .{ .err = .ETIMEOUT };
    }

    pub fn requestCancel(_: *GetAddrInfoRequest) void {
        // The system resolver has no cancellation API; its worker is joined.
    }

    pub fn discard(this: *GetAddrInfoRequest) void {
        bun.assert(this.backend == .libc);
        this.backend.libc.deinit();
        var head = this.takeLookups();
        var pending = head.next;
        head.completion.release();
        head.deinit();
        while (pending) |lookup| {
            pending = lookup.next;
            lookup.completion.release();
            lookup.deinit();
        }
    }

    pub fn then(this: *GetAddrInfoRequest) void {
        log("then", .{});
        var outcome = this.backend.libc;
        this.backend.libc = .pending;
        defer outcome.deinit();
        switch (outcome) {
            .result => |result| {
                var head = this.takeLookups();
                var pending = head.next;
                head.onCompleteNative(result);
                while (pending) |lookup| {
                    pending = lookup.next;
                    lookup.onCompleteNative(result);
                }
            },
            .err => |err| this.completeError(err),
            .out_of_memory => this.onOutOfMemory(),
            .pending => @panic("system DNS request delivered before completion"),
        }
    }

    fn takeLookups(this: *GetAddrInfoRequest) DNSLookup {
        if (this.cache.pending_cache) {
            const resolver = this.resolver_for_caching.?;
            const key = if (this.backend == .c_ares)
                resolver.getKey(this.cache.pos_in_pending, "pending_host_cache_cares", GetAddrInfoRequest)
            else
                resolver.getKey(this.cache.pos_in_pending, "pending_host_cache_native", GetAddrInfoRequest);
            bun.assert(key.lookup == this);
        }
        const head = this.head;
        this.deref();
        return head;
    }

    fn onOutOfMemory(this: *GetAddrInfoRequest) void {
        this.completeError(.ENOMEM);
    }

    fn completeError(this: *GetAddrInfoRequest, err: c_ares.Error) void {
        var head = this.takeLookups();
        var pending = head.next;
        head.onError(err);
        while (pending) |lookup| {
            pending = lookup.next;
            lookup.onError(err);
        }
    }

    pub fn onCaresComplete(this: *GetAddrInfoRequest, raw_error: ?c_ares.Error, timeout: i32, raw_result: ?*c_ares.AddrInfo) void {
        log("onCaresComplete", .{});
        const scope = Resolver.QueryCompletion.init(this.resolver_for_caching);
        defer scope.deinit();
        const err_ = scope.failure(raw_error);
        const result = if (err_ == null) raw_result else null;
        defer {
            if (err_ != null) {
                if (raw_result) |value| value.deinit();
            }
        }
        if (err_ == .ENOMEM) {
            this.onOutOfMemory();
            return;
        }
        if (this.resolver_for_caching) |resolver| {
            if (this.cache.pending_cache) {
                resolver.drainPendingHostCares(
                    this.cache.pos_in_pending,
                    err_,
                    timeout,
                    result,
                );
                return;
            }
        }

        var head = this.head;
        this.deref();

        head.processGetAddrInfo(err_, timeout, result);
    }
};

/// Settled outcome of a resolver-family DNS query, materialized on delivery.
pub const DnsQueryPayload = union(enum) {
    dns_error: DnsError,
    lookup: DNSLookupResults,
    lookup_service: DNSLookupServiceResult,
    addresses: DNSAddressResults,
    strings: DNSStringResults,
    srv: DNSSrvResults,
    txt: DNSTxtResults,
    soa: DNSSoaResult,
    naptr: DNSNaptrResults,
    mx: DNSMxResults,
    caa: DNSCaaResults,
    any: DNSAnyResults,
    consumed: void,

    pub const DnsError = struct {
        errno: c_ares.Error,
        syscall: []const u8,
        hostname: ?bun.bindgen.DOMString,
    };

    pub fn deinit(this: *DnsQueryPayload) void {
        switch (this.*) {
            .dns_error => |*payload| if (payload.hostname) |*hostname| hostname.deinit(),
            .lookup => |*result| bun.bindgen.deinitReturn(DNSLookupSchema, result),
            .lookup_service => |*result| bun.bindgen.deinitReturn(DNSLookupServiceSchema, result),
            .addresses => |*result| bun.bindgen.deinitResult(DNSAddressResultsType, result),
            .strings => |*result| bun.bindgen.deinitReturn(DNSReverseSchema, result),
            .srv => |*result| bun.bindgen.deinitReturn(DNSResolveSrvSchema, result),
            .txt => |*result| bun.bindgen.deinitReturn(DNSResolveTxtSchema, result),
            .soa => |*result| bun.bindgen.deinitReturn(DNSResolveSoaSchema, result),
            .naptr => |*result| bun.bindgen.deinitReturn(DNSResolveNaptrSchema, result),
            .mx => |*result| bun.bindgen.deinitReturn(DNSResolveMxSchema, result),
            .caa => |*result| bun.bindgen.deinitReturn(DNSResolveCaaSchema, result),
            .any => |*result| bun.bindgen.deinitReturn(DNSResolveAnySchema, result),
            .consumed => {},
        }
        this.* = .{ .consumed = {} };
    }
};

fn completeDnsError(completion: *DnsQueryCompletions.Owned, failure: c_ares.Error, syscall: []const u8, hostname: ?[]const u8) void {
    if (failure == .ENOMEM) {
        completion.outOfMemory();
        return;
    }
    const owned_hostname: ?bun.bindgen.DOMString = if (hostname) |name|
        bun.bindgen.DOMString.fromUTF8(name) catch {
            completion.outOfMemory();
            return;
        }
    else
        null;
    completeDnsQuery(completion, .{ .dns_error = .{
        .errno = failure,
        .syscall = syscall,
        .hostname = owned_hostname,
    } });
}

fn takeDnsPayload(comptime field_name: []const u8, payload: *DnsQueryPayload) @FieldType(DnsQueryPayload, field_name) {
    const value = @field(payload.*, field_name);
    payload.* = .{ .consumed = {} };
    return value;
}

const DnsQueryCompletionOps = struct {
    fn dnsErrorRoot(context: anytype, dns_error: DnsQueryPayload.DnsError) bun.JSError!bun.bindgen.Root {
        var code = try bun.bindgen.DOMString.fromUTF8(dns_error.errno.code());
        defer code.deinit();
        var syscall = try bun.bindgen.DOMString.fromUTF8(dns_error.syscall);
        defer syscall.deinit();
        var hostname: ?bun.bindgen.DOMString = if (dns_error.hostname) |value|
            value.clone()
        else
            null;
        defer if (hostname) |*value| value.deinit();

        const message_string = if (dns_error.hostname) |value|
            try bun.String.createFormat("{s} {s} {f}", .{ dns_error.syscall, dns_error.errno.code()[4..], value })
        else
            try bun.String.createFormat("{s} {s}", .{ dns_error.syscall, dns_error.errno.code()[4..] });
        var message = try bun.bindgen.DOMString.fromBunString(message_string);
        defer message.deinit();

        const error_value = try context.engineIn("errors", "dnsErrorToErrorInstance").call(.{ .data = .{
            .errorNumber = @backingInt(dns_error.errno),
            .code = code.operand(),
            .message = message.operand(),
            .syscall = syscall.operand(),
            .hostname = if (hostname) |optional_value| optional_value.operand() else null,
        } });
        return error_value.toRoot();
    }

    pub fn materialize(
        comptime FunctionSchema: type,
        context: bun.bindgen.MaterializationContext(FunctionSchema),
        payload: *DnsQueryPayload,
    ) bun.bindgen.MaterializationError(FunctionSchema)!bun.bindgen.Return(FunctionSchema) {
        switch (payload.*) {
            .dns_error => |dns_error| {
                var error_root = try dnsErrorRoot(context, dns_error);
                return context.reject(&error_root, .{ .attach_async_stack = true });
            },
            else => {},
        }

        const tag = std.meta.activeTag(payload.*);
        if (comptime FunctionSchema == DNSLookupSchema) {
            if (tag != .lookup) @panic("lookup completion received an invalid payload");
            return takeDnsPayload("lookup", payload);
        } else if (comptime FunctionSchema == DNSLookupServiceSchema) {
            if (tag != .lookup_service) @panic("lookupService completion received an invalid payload");
            return takeDnsPayload("lookup_service", payload);
        } else if (comptime FunctionSchema == DNSResolverResolveSchema or FunctionSchema == DNSResolveSchema) {
            return switch (tag) {
                .addresses => .{ .addresses = takeDnsPayload("addresses", payload) },
                .strings => .{ .strings = takeDnsPayload("strings", payload) },
                .mx => .{ .mx = takeDnsPayload("mx", payload) },
                .txt => .{ .txt = takeDnsPayload("txt", payload) },
                .srv => .{ .srv = takeDnsPayload("srv", payload) },
                .naptr => .{ .naptr = takeDnsPayload("naptr", payload) },
                .soa => .{ .soa = takeDnsPayload("soa", payload) },
                .caa => .{ .caa = takeDnsPayload("caa", payload) },
                .any => .{ .any = takeDnsPayload("any", payload) },
                else => @panic("resolve completion received an invalid payload"),
            };
        } else if (comptime FunctionSchema == DNSResolverResolveAnySchema or FunctionSchema == DNSResolveAnySchema) {
            if (tag != .any) @panic("resolveAny completion received an invalid payload");
            return takeDnsPayload("any", payload);
        } else if (comptime FunctionSchema == DNSResolverResolveCaaSchema or FunctionSchema == DNSResolveCaaSchema) {
            if (tag != .caa) @panic("resolveCaa completion received an invalid payload");
            return takeDnsPayload("caa", payload);
        } else if (comptime FunctionSchema == DNSResolverResolveCnameSchema or
            FunctionSchema == DNSResolverResolveNsSchema or
            FunctionSchema == DNSResolverResolvePtrSchema or
            FunctionSchema == DNSResolverReverseSchema or
            FunctionSchema == DNSResolveCnameSchema or
            FunctionSchema == DNSResolveNsSchema or
            FunctionSchema == DNSResolvePtrSchema or
            FunctionSchema == DNSReverseSchema)
        {
            if (tag != .strings) @panic("DNS string completion received an invalid payload");
            return takeDnsPayload("strings", payload);
        } else if (comptime FunctionSchema == DNSResolverResolveMxSchema or FunctionSchema == DNSResolveMxSchema) {
            if (tag != .mx) @panic("resolveMx completion received an invalid payload");
            return takeDnsPayload("mx", payload);
        } else if (comptime FunctionSchema == DNSResolverResolveNaptrSchema or FunctionSchema == DNSResolveNaptrSchema) {
            if (tag != .naptr) @panic("resolveNaptr completion received an invalid payload");
            return takeDnsPayload("naptr", payload);
        } else if (comptime FunctionSchema == DNSResolverResolveSoaSchema or FunctionSchema == DNSResolveSoaSchema) {
            if (tag != .soa) @panic("resolveSoa completion received an invalid payload");
            return takeDnsPayload("soa", payload);
        } else if (comptime FunctionSchema == DNSResolverResolveSrvSchema or FunctionSchema == DNSResolveSrvSchema) {
            if (tag != .srv) @panic("resolveSrv completion received an invalid payload");
            return takeDnsPayload("srv", payload);
        } else if (comptime FunctionSchema == DNSResolverResolveTxtSchema or FunctionSchema == DNSResolveTxtSchema) {
            if (tag != .txt) @panic("resolveTxt completion received an invalid payload");
            return takeDnsPayload("txt", payload);
        } else {
            @compileError("unmapped DNS completion schema");
        }
    }

    pub fn destroyPayload(payload: *DnsQueryPayload) void {
        payload.deinit();
        bun.destroy(payload);
    }
};

pub const DnsQueryCompletions = bun.bindgen.MaterializedCompletionSet(.{
    DNSResolverResolveSchema,
    DNSResolverResolveAnySchema,
    DNSResolverResolveCaaSchema,
    DNSResolverResolveCnameSchema,
    DNSResolverResolveMxSchema,
    DNSResolverResolveNaptrSchema,
    DNSResolverResolveNsSchema,
    DNSResolverResolvePtrSchema,
    DNSResolverResolveSoaSchema,
    DNSResolverResolveSrvSchema,
    DNSResolverResolveTxtSchema,
    DNSResolverReverseSchema,
    DNSResolveSchema,
    DNSResolveSrvSchema,
    DNSResolveTxtSchema,
    DNSResolveSoaSchema,
    DNSResolveNaptrSchema,
    DNSResolveMxSchema,
    DNSResolveCaaSchema,
    DNSResolveNsSchema,
    DNSResolvePtrSchema,
    DNSResolveCnameSchema,
    DNSResolveAnySchema,
    DNSReverseSchema,
    DNSLookupServiceSchema,
    DNSLookupSchema,
}, DnsQueryPayload, DnsQueryCompletionOps);

fn completeDnsQuery(completion: *DnsQueryCompletions.Owned, payload: DnsQueryPayload) void {
    completion.complete(bun.new(DnsQueryPayload, payload));
}

fn appendDnsElement(
    comptime Sequence: type,
    list: *std.ArrayList(Sequence.Element),
    element: Sequence.Element,
) bun.OOM!void {
    var owned = element;
    errdefer Sequence.deinitElement(&owned);
    try list.append(bun.default_allocator, owned);
}

fn deinitDnsElements(comptime Sequence: type, items: []Sequence.Element) void {
    for (items) |*item| Sequence.deinitElement(item);
}

fn dnsString(bytes: []const u8) bun.OOM!bun.bindgen.DOMString {
    return bun.bindgen.DOMString.fromUTF8(bytes);
}

fn dnsCString(value: [*c]u8) bun.OOM!bun.bindgen.DOMString {
    return dnsString(value[0..bun.len(value)]);
}

fn socketAddressString(address: *const SocketAddressValue) bun.OOM!bun.bindgen.DOMString {
    return bun.bindgen.DOMString.fromBunString(try bun.dns.addressToString(address));
}

fn hostentStringResults(hostent: *const c_ares.struct_hostent, comptime lookup_name: []const u8) bun.OOM!DNSStringResults {
    if (comptime strings.eqlComptime(lookup_name, "cname")) {
        const name = hostent.h_name orelse return DNSStringResults.fromUTF8Slices(&[_][]const u8{});
        return DNSStringResults.fromUTF8Slices(&[_][]const u8{name[0..bun.len(name)]});
    }

    const aliases = hostent.h_aliases orelse return DNSStringResults.fromUTF8Slices(&[_][]const u8{});
    var length: usize = 0;
    while (aliases[length] != null) : (length += 1) {}
    var values = try DNSStringResults.Builder.init(length);
    errdefer values.deinit();
    for (aliases[0..length]) |alias| values.appendOwned(try dnsCString(alias.?));
    return values.finish();
}

fn addressResultElement(
    address: *const SocketAddressValue,
    ttl: ?i32,
) bun.OOM!DNSAddressResults.Element {
    return .{
        .address = try socketAddressString(address),
        .ttl = ttl,
    };
}

fn hostentAddressResults(hostent: *const c_ares.hostent_with_ttls) bun.OOM!DNSAddressResults {
    const addresses = hostent.hostent.h_addr_list orelse return DNSAddressResults.fromOwnedSlice(&[_]DNSAddressResults.Element{});
    var length: usize = 0;
    while (addresses[length] != null) : (length += 1) {}
    var values = try DNSAddressResults.Builder.init(length);
    errdefer values.deinit();
    for (addresses[0..length], 0..) |entry, index| {
        const bytes = entry.?;
        const address: SocketAddressValue = if (hostent.hostent.h_addrtype == c_ares.AF.INET6)
            .initIp6(bytes[0..16].*, 0, 0, 0)
        else
            .initIp4(bytes[0..4].*, 0);
        values.appendOwned(try addressResultElement(&address, if (index < hostent.ttls.len) hostent.ttls[index] else null));
    }
    return values.finish();
}

fn lookupResultElement(result: GetAddrInfo.Result) bun.OOM!DNSLookupResults.Element {
    return .{
        .address = try socketAddressString(&result.address),
        .family = switch (result.address.family()) {
            .INET => 4,
            .INET6 => 6,
        },
        .ttl = result.ttl,
    };
}

fn lookupResultsFromNative(result: GetAddrInfo.Result.List) bun.OOM!?DNSLookupResults {
    if (result.items.len == 0) return null;
    var values = try DNSLookupResults.Builder.init(result.items.len);
    errdefer values.deinit();
    for (result.items) |item| values.appendOwned(try lookupResultElement(item));
    return values.finish();
}

fn lookupResultsFromCares(result: *const c_ares.AddrInfo) bun.OOM!DNSLookupResults {
    var values: std.ArrayList(DNSLookupResults.Element) = .empty;
    defer values.deinit(bun.default_allocator);
    errdefer deinitDnsElements(DNSLookupResults, values.items);

    var current = result.node;
    while (current) |node| : (current = node.next) {
        const address = SocketAddressValue.fromPosix(@ptrCast(@alignCast(node.addr orelse continue))) orelse continue;
        try appendDnsElement(DNSLookupResults, &values, try lookupResultElement(.{
            .address = address,
            .ttl = node.ttl,
        }));
    }
    return DNSLookupResults.fromOwnedSlice(values.items);
}

fn srvResultElement(node: *const c_ares.struct_ares_srv_reply) bun.OOM!DNSSrvResults.Element {
    return .{
        .priority = node.priority,
        .weight = node.weight,
        .port = node.port,
        .name = try dnsCString(node.host),
    };
}

fn linkedReplyResults(
    comptime Sequence: type,
    first: anytype,
    comptime element: fn (@TypeOf(first)) bun.OOM!Sequence.Element,
) bun.OOM!Sequence {
    var length: usize = 0;
    var current: ?@TypeOf(first) = first;
    while (current) |node| : (current = node.next) length += 1;
    var values = try Sequence.Builder.init(length);
    errdefer values.deinit();
    current = first;
    while (current) |node| : (current = node.next) {
        values.appendOwned(try element(node));
    }
    return values.finish();
}

fn mxResultElement(node: *const c_ares.struct_ares_mx_reply) bun.OOM!DNSMxResults.Element {
    return .{
        .priority = node.priority,
        .exchange = try dnsCString(node.host),
    };
}

fn naptrResultElement(node: *const c_ares.struct_ares_naptr_reply) bun.OOM!DNSNaptrResults.Element {
    var flags = try dnsCString(node.flags);
    errdefer flags.deinit();
    var service = try dnsCString(node.service);
    errdefer service.deinit();
    var regexp = try dnsCString(node.regexp);
    errdefer regexp.deinit();
    return .{
        .preference = node.preference,
        .order = node.order,
        .flags = flags,
        .service = service,
        .regexp = regexp,
        .replacement = try dnsCString(node.replacement),
    };
}

fn soaResult(node: *const c_ares.struct_ares_soa_reply) bun.OOM!DNSSoaResult {
    var nsname = try dnsCString(node.nsname);
    errdefer nsname.deinit();
    return .{
        .serial = node.serial,
        .refresh = node.refresh,
        .retry = node.retry,
        .expire = node.expire,
        .minttl = node.minttl,
        .nsname = nsname,
        .hostmaster = try dnsCString(node.hostmaster),
    };
}

fn caaResultElement(node: *const c_ares.struct_ares_caa_reply) bun.OOM!DNSCaaResults.Element {
    var property = try dnsString(node.property[0..node.plength]);
    errdefer property.deinit();
    return .{
        .critical = node.critical,
        .property = property,
        .value = try dnsString(node.value[0..node.length]),
    };
}

fn txtResultElement(node: *const c_ares.struct_ares_txt_reply) bun.OOM!DNSTxtResults.Element {
    return DNSTxtResults.Element.fromUTF8Slices(&[_][]const u8{node.txt[0..node.length]});
}

fn appendAnyAddresses(
    values: *std.ArrayList(DNSAnyResults.Element),
    hostent: *const c_ares.hostent_with_ttls,
    comptime ipv6: bool,
) bun.OOM!void {
    const addresses = hostent.hostent.h_addr_list orelse return;
    var index: usize = 0;
    while (addresses[index]) |bytes| : (index += 1) {
        const address: SocketAddressValue = if (ipv6)
            .initIp6(bytes[0..16].*, 0, 0, 0)
        else
            .initIp4(bytes[0..4].*, 0);
        try appendDnsElement(DNSAnyResults, values, .{ .address = .{
            .address = try socketAddressString(&address),
            .ttl = if (index < hostent.ttls.len) hostent.ttls[index] else null,
            .type = if (ipv6) .aaaa else .a,
        } });
    }
}

fn appendAnyHostentStrings(
    values: *std.ArrayList(DNSAnyResults.Element),
    hostent: *const c_ares.struct_hostent,
    comptime ns: bool,
) bun.OOM!void {
    const aliases = hostent.h_aliases orelse return;
    var index: usize = 0;
    while (aliases[index]) |alias| : (index += 1) {
        try appendDnsElement(DNSAnyResults, values, .{ .string = .{
            .value = try dnsString(alias[0..bun.len(alias)]),
            .type = if (ns) .ns else .ptr,
        } });
    }
}

fn anyRecord(comptime tag: std.meta.Tag(DNSAnyResults.Element), value: anytype) DNSAnyResults.Element {
    const Payload = @FieldType(DNSAnyResults.Element, @tagName(tag));
    var payload: Payload = undefined;
    inline for (@typeInfo(Payload).@"struct".field_names) |name| {
        @field(payload, name) = if (comptime strings.eqlComptime(name, "type"))
            @field(@FieldType(Payload, "type"), @tagName(tag))
        else
            @field(value, name);
    }
    return @unionInit(DNSAnyResults.Element, @tagName(tag), payload);
}

fn appendAnyLinked(
    values: *std.ArrayList(DNSAnyResults.Element),
    comptime tag: std.meta.Tag(DNSAnyResults.Element),
    first: anytype,
    comptime convert: anytype,
) bun.OOM!void {
    var current: ?@TypeOf(first) = first;
    while (current) |node| : (current = node.next) {
        try appendDnsElement(DNSAnyResults, values, anyRecord(tag, try convert(node)));
    }
}

fn appendAnyTxt(
    values: *std.ArrayList(DNSAnyResults.Element),
    first: *const c_ares.struct_ares_txt_reply,
) bun.OOM!void {
    try appendDnsElement(DNSAnyResults, values, .{ .txt = .{
        .entries = try linkedReplyResults(DNSStringResults, first, txtString),
        .type = .txt,
    } });
}

fn txtString(node: *const c_ares.struct_ares_txt_reply) bun.OOM!DNSStringResults.Element {
    return dnsString(node.txt[0..node.length]);
}

fn anyResults(result: *const c_ares.struct_any_reply) bun.OOM!DNSAnyResults {
    var values: std.ArrayList(DNSAnyResults.Element) = .empty;
    defer values.deinit(bun.default_allocator);
    errdefer deinitDnsElements(DNSAnyResults, values.items);

    if (result.a_reply) |reply| try appendAnyAddresses(&values, reply, false);
    if (result.aaaa_reply) |reply| try appendAnyAddresses(&values, reply, true);
    if (result.mx_reply) |reply| try appendAnyLinked(&values, .mx, reply, mxResultElement);
    if (result.ns_reply) |reply| try appendAnyHostentStrings(&values, reply, true);
    if (result.txt_reply) |reply| try appendAnyTxt(&values, reply);
    if (result.srv_reply) |reply| try appendAnyLinked(&values, .srv, reply, srvResultElement);
    if (result.ptr_reply) |reply| try appendAnyHostentStrings(&values, reply, false);
    if (result.naptr_reply) |reply| try appendAnyLinked(&values, .naptr, reply, naptrResultElement);
    if (result.soa_reply) |reply| try appendDnsElement(DNSAnyResults, &values, anyRecord(.soa, try soaResult(reply)));
    if (result.caa_reply) |reply| try appendAnyLinked(&values, .caa, reply, caaResultElement);

    return DNSAnyResults.fromOwnedSlice(values.items);
}

fn payloadFromCaresResult(comptime cares_type: type, comptime type_name: []const u8, result: *const cares_type) bun.OOM!DnsQueryPayload {
    if (comptime cares_type == c_ares.hostent_with_ttls) {
        return .{ .addresses = try hostentAddressResults(result) };
    } else if (comptime cares_type == c_ares.struct_hostent) {
        return .{ .strings = try hostentStringResults(result, type_name) };
    } else if (comptime cares_type == c_ares.struct_ares_srv_reply) {
        return .{ .srv = try linkedReplyResults(DNSSrvResults, result, srvResultElement) };
    } else if (comptime cares_type == c_ares.struct_ares_txt_reply) {
        return .{ .txt = try linkedReplyResults(DNSTxtResults, result, txtResultElement) };
    } else if (comptime cares_type == c_ares.struct_ares_soa_reply) {
        return .{ .soa = try soaResult(result) };
    } else if (comptime cares_type == c_ares.struct_ares_naptr_reply) {
        return .{ .naptr = try linkedReplyResults(DNSNaptrResults, result, naptrResultElement) };
    } else if (comptime cares_type == c_ares.struct_ares_mx_reply) {
        return .{ .mx = try linkedReplyResults(DNSMxResults, result, mxResultElement) };
    } else if (comptime cares_type == c_ares.struct_ares_caa_reply) {
        return .{ .caa = try linkedReplyResults(DNSCaaResults, result, caaResultElement) };
    } else if (comptime cares_type == c_ares.struct_any_reply) {
        return .{ .any = try anyResults(result) };
    } else {
        @compileError("unsupported c-ares DNS result type");
    }
}

pub const CAresReverse = struct {
    const log = Output.scoped(.CAresReverse, .visible);

    resolver: ?*Resolver,
    globalThis: *jsc.JSGlobalObject,
    completion: DnsQueryCompletions.Owned,
    poll_ref: Async.KeepAlive,
    allocated: bool = false,
    next: ?*@This() = null,
    name: []const u8,

    pub fn init(resolver: ?*Resolver, globalThis: *jsc.JSGlobalObject, allocator: std.mem.Allocator, name: []const u8, completion: DnsQueryCompletions.Owned) !*@This() {
        const this = try allocator.create(@This());
        if (resolver) |resolver_| {
            resolver_.ref();
        }

        var poll_ref = Async.KeepAlive.init();
        poll_ref.ref(globalThis.bunVM());
        this.* = .{
            .resolver = resolver,
            .globalThis = globalThis,
            .completion = completion,
            .poll_ref = poll_ref,
            .allocated = true,
            .name = name,
        };
        return this;
    }

    pub fn processResolve(this: *@This(), err_: ?c_ares.Error, _: i32, result: ?*const c_ares.struct_hostent) void {
        if (err_ orelse if (result == null) c_ares.Error.ENOTFOUND else null) |err| {
            completeDnsError(&this.completion, err, "getHostByAddr", this.name);
            this.deinit();
            return;
        }
        const value = hostentStringResults(result.?, "reverse") catch {
            this.onOutOfMemory();
            return;
        };
        this.onComplete(value);
        return;
    }

    pub fn onComplete(this: *@This(), result: DNSStringResults) void {
        completeDnsQuery(&this.completion, .{ .strings = result });
        this.deinit();
    }

    pub fn onOutOfMemory(this: *@This()) void {
        this.completion.outOfMemory();
        this.deinit();
    }

    pub fn deinit(this: *@This()) void {
        this.poll_ref.unref(this.globalThis.bunVM());
        bun.default_allocator.free(this.name);

        if (this.resolver) |resolver| {
            resolver.requestCompleted();
            resolver.deref();
        }

        if (this.allocated) {
            this.globalThis.allocator().destroy(this);
        }
    }
};

pub fn CAresLookup(comptime cares_type: type, comptime type_name: []const u8) type {
    const Lookup = struct {
        const log = Output.scoped(.CAresLookup, .hidden);

        resolver: ?*Resolver,
        globalThis: *jsc.JSGlobalObject,
        completion: DnsQueryCompletions.Owned,
        poll_ref: Async.KeepAlive,
        allocated: bool = false,
        next: ?*@This() = null,
        name: []const u8,

        pub fn init(resolver: ?*Resolver, globalThis: *jsc.JSGlobalObject, allocator: std.mem.Allocator, name: []const u8, completion: DnsQueryCompletions.Owned) !*@This() {
            const this = try allocator.create(@This());
            if (resolver) |resolver_| {
                resolver_.ref();
            }

            var poll_ref = Async.KeepAlive.init();
            poll_ref.ref(globalThis.bunVM());
            this.* = .{
                .resolver = resolver,
                .globalThis = globalThis,
                .completion = completion,
                .poll_ref = poll_ref,
                .allocated = true,
                .name = name,
            };
            return this;
        }

        pub fn processResolve(this: *@This(), err_: ?c_ares.Error, _: i32, result: ?*cares_type) void {
            const syscall = comptime "query" ++ &[_]u8{std.ascii.toUpper(type_name[0])} ++ type_name[1..];
            // This path is reached when the pending cache is full (`.disabled`),
            // so we own the c-ares result here. The cached path frees it in
            // `drainPendingCares`; callers from there always pass `null`.
            defer if (result) |r| r.deinit();

            if (err_ orelse if (result == null) c_ares.Error.ENOTFOUND else null) |err| {
                completeDnsError(&this.completion, err, syscall, this.name);
                this.deinit();
                return;
            }

            const payload = payloadFromCaresResult(cares_type, type_name, result.?) catch {
                this.onOutOfMemory();
                return;
            };
            this.onComplete(payload);
            return;
        }

        pub fn onComplete(this: *@This(), payload: DnsQueryPayload) void {
            completeDnsQuery(&this.completion, payload);
            this.deinit();
        }

        pub fn onOutOfMemory(this: *@This()) void {
            this.completion.outOfMemory();
            this.deinit();
        }

        pub fn deinit(this: *@This()) void {
            this.poll_ref.unref(this.globalThis.bunVM());
            bun.default_allocator.free(this.name);

            if (this.resolver) |resolver| {
                resolver.requestCompleted();
                resolver.deref();
            }

            if (this.allocated) {
                this.globalThis.allocator().destroy(this);
            }
        }
    };
    return Lookup;
}

pub const DNSLookup = struct {
    const log = Output.scoped(.DNSLookup, .visible);

    resolver: ?*Resolver,
    globalThis: *jsc.JSGlobalObject = undefined,
    completion: DnsQueryCompletions.Owned,
    allocated: bool = false,
    next: ?*DNSLookup = null,
    poll_ref: Async.KeepAlive,

    pub fn init(resolver: *Resolver, globalThis: *jsc.JSGlobalObject, allocator: std.mem.Allocator, completion: DnsQueryCompletions.Owned) !*DNSLookup {
        log("init", .{});
        const this = try allocator.create(DNSLookup);
        resolver.ref();
        var poll_ref = Async.KeepAlive.init();
        poll_ref.ref(globalThis.bunVM());

        this.* = .{
            .resolver = resolver,
            .globalThis = globalThis,
            .poll_ref = poll_ref,
            .completion = completion,
            .allocated = true,
        };
        return this;
    }

    pub fn onCompleteNative(this: *DNSLookup, result: GetAddrInfo.Result.List) void {
        log("onCompleteNative", .{});
        const value = lookupResultsFromNative(result) catch {
            this.onOutOfMemory();
            return;
        };
        const resolved = value orelse {
            completeDnsError(&this.completion, .ENOTFOUND, "getaddrinfo", null);
            this.deinit();
            return;
        };
        this.onCompleteResults(resolved);
    }

    pub fn onError(this: *DNSLookup, err: c_ares.Error) void {
        if (err == .ENOMEM) return this.onOutOfMemory();
        completeDnsError(&this.completion, err, "getaddrinfo", null);
        this.deinit();
    }

    pub fn processGetAddrInfo(this: *DNSLookup, err_: ?c_ares.Error, _: i32, result: ?*c_ares.AddrInfo) void {
        log("processGetAddrInfo", .{});
        // This path is reached when the pending-host cache is full (`.disabled`),
        // so we own the c-ares result here. The cached path frees it in
        // `drainPendingHostCares`; callers from there always pass `null`.
        defer if (result) |r| r.deinit();

        if (err_ orelse if (result == null or result.?.node == null) c_ares.Error.ENOTFOUND else null) |err| {
            completeDnsError(&this.completion, err, "getaddrinfo", null);
            this.deinit();
            return;
        }
        this.onComplete(result.?);
    }

    pub fn onComplete(this: *DNSLookup, result: *c_ares.AddrInfo) void {
        log("onComplete", .{});

        const value = lookupResultsFromCares(result) catch {
            this.onOutOfMemory();
            return;
        };
        this.onCompleteResults(value);
    }

    pub fn onCompleteResults(this: *DNSLookup, result: DNSLookupResults) void {
        log("onCompleteResults", .{});

        completeDnsQuery(&this.completion, .{ .lookup = result });
        this.deinit();
    }

    pub fn onOutOfMemory(this: *DNSLookup) void {
        this.completion.outOfMemory();
        this.deinit();
    }

    pub fn deinit(this: *DNSLookup) void {
        log("deinit", .{});
        this.poll_ref.unref(this.globalThis.bunVM());

        if (this.resolver) |resolver| {
            resolver.requestCompleted();
            resolver.deref();
        }

        if (this.allocated) {
            this.globalThis.allocator().destroy(this);
        }
    }
};

pub const internal = InternalResolver.Internal;

fn getDNSCacheStats(
    _: bun.bindgen.CallContext(GetCacheStatsSchema),
    _: bun.bindgen.Args(GetCacheStatsSchema),
) bun.JSError!bun.bindgen.Return(GetCacheStatsSchema) {
    const stats = internal.stats();
    return .{
        .cacheHitsCompleted = @floatFromInt(stats.cache_hits_completed),
        .cacheHitsInflight = @floatFromInt(stats.cache_hits_inflight),
        .cacheMisses = @floatFromInt(stats.cache_misses),
        .size = @floatFromInt(stats.size),
        .errors = @floatFromInt(stats.errors),
        .totalCount = @floatFromInt(stats.total_count),
    };
}

fn prefetchFromJS(
    _: bun.bindgen.CallContext(PrefetchSchema),
    args: bun.bindgen.Args(PrefetchSchema),
) bun.JSError!void {
    const hostname_slice = try args.hostname.toUTF8(bun.default_allocator);
    defer hostname_slice.deinit();

    const hostname_z = try bun.default_allocator.dupeSentinel(u8, hostname_slice.slice(), 0);
    defer bun.default_allocator.free(hostname_z);

    try internal.prefetch(jsc.VirtualMachine.get().uwsLoop(), hostname_z, args.port);
}

pub const Resolver = struct {
    const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;

    const log = Output.scoped(.DNSResolver, .visible);

    const GlobalResultOperation = enum {
        new_resolver,
        get_servers,
    };

    const GlobalVoidOperation = enum {
        lookup,
        lookup_service,
        resolve,
        resolve_any,
        resolve_caa,
        resolve_cname,
        resolve_mx,
        resolve_naptr,
        resolve_ns,
        resolve_ptr,
        resolve_soa,
        resolve_srv,
        resolve_txt,
        reverse,
        set_servers,
    };

    ref_count: RefCount,
    channel: ?*c_ares.Channel = null,
    vm: *jsc.VirtualMachine,
    polls: PollsMap = .empty,
    allocator: std.mem.Allocator,
    options: c_ares.ChannelOptions = .{},
    cares_requests: usize = 0,
    poll_failure: ?c_ares.Error = null,
    closed: bool = false,
    registry_previous: ?*Resolver = null,
    registry_next: ?*Resolver = null,

    event_loop_timer: EventLoopTimer = .{
        .next = .epoch,
        .tag = .DNSResolver,
    },

    pending_host_cache_cares: PendingCache,
    pending_host_cache_native: PendingCache,
    pending_srv_cache_cares: SrvPendingCache,
    pending_soa_cache_cares: SoaPendingCache,
    pending_txt_cache_cares: TxtPendingCache,
    pending_naptr_cache_cares: NaptrPendingCache,
    pending_mx_cache_cares: MxPendingCache,
    pending_caa_cache_cares: CaaPendingCache,
    pending_ns_cache_cares: NSPendingCache,
    pending_ptr_cache_cares: PtrPendingCache,
    pending_cname_cache_cares: CnamePendingCache,
    pending_a_cache_cares: APendingCache,
    pending_aaaa_cache_cares: AAAAPendingCache,
    pending_any_cache_cares: AnyPendingCache,
    pending_addr_cache_cares: AddrPendingCache,
    pending_nameinfo_cache_cares: NameInfoPendingCache,

    const PollsMap = std.array_hash_map.Auto(c_ares.ares_socket_t, *PollType);

    const PollType = if (Environment.isWindows)
        UvDnsPoll
    else
        Async.FilePoll;

    const UvDnsPoll = struct {
        pub const destroy = bun.TrivialDeinit(@This());

        parent: *Resolver,
        socket: c_ares.ares_socket_t,
        poll: bun.windows.libuv.uv_poll_t,

        pub fn fromPoll(poll: *bun.windows.libuv.uv_poll_t) *UvDnsPoll {
            return @fieldParentPtr("poll", poll);
        }
    };

    fn setup(allocator: std.mem.Allocator, vm: *jsc.VirtualMachine) Resolver {
        return .{
            .ref_count = .init(),
            .vm = vm,
            .allocator = allocator,
            .pending_host_cache_cares = PendingCache.empty,
            .pending_host_cache_native = PendingCache.empty,
            .pending_srv_cache_cares = SrvPendingCache.empty,
            .pending_soa_cache_cares = SoaPendingCache.empty,
            .pending_txt_cache_cares = TxtPendingCache.empty,
            .pending_naptr_cache_cares = NaptrPendingCache.empty,
            .pending_mx_cache_cares = MxPendingCache.empty,
            .pending_caa_cache_cares = CaaPendingCache.empty,
            .pending_ns_cache_cares = NSPendingCache.empty,
            .pending_ptr_cache_cares = PtrPendingCache.empty,
            .pending_cname_cache_cares = CnamePendingCache.empty,
            .pending_a_cache_cares = APendingCache.empty,
            .pending_aaaa_cache_cares = AAAAPendingCache.empty,
            .pending_any_cache_cares = AnyPendingCache.empty,
            .pending_addr_cache_cares = AddrPendingCache.empty,
            .pending_nameinfo_cache_cares = NameInfoPendingCache.empty,
        };
    }

    pub fn init(allocator: std.mem.Allocator, vm: *jsc.VirtualMachine) bun.OOM!*Resolver {
        log("init", .{});
        const rare = try vm.tryRareData();
        const resolver = try allocator.create(Resolver);
        resolver.* = .setup(allocator, vm);
        resolver.closed = vm.isShuttingDown();
        rare.registerDNSResolver(resolver);
        return resolver;
    }

    pub fn shutdown(this: *Resolver) void {
        if (this.closed) return;
        this.closed = true;
        if (this.channel) |channel| {
            this.channel = null;
            channel.deinit();
        }
        this.poll_failure = null;
        this.removeTimer();
    }

    fn deinit(this: *Resolver) void {
        this.vm.rare_data.?.unregisterDNSResolver(this);
        if (this.channel) |channel| {
            this.channel = null;
            channel.deinit();
        }
        bun.assert(this.polls.count() == 0);
        this.polls.deinit(this.allocator);
        this.allocator.destroy(this);
    }

    pub const Order = enum(u8) {
        verbatim = 0,
        ipv4first = 4,
        ipv6first = 6,

        pub const default = .verbatim;

        pub const map = bun.ComptimeStringMap(Order, .{
            .{ "verbatim", .verbatim },
            .{ "ipv4first", .ipv4first },
            .{ "ipv6first", .ipv6first },
            .{ "0", .verbatim },
            .{ "4", .ipv4first },
            .{ "6", .ipv6first },
        });

        pub fn fromString(order: []const u8) ?Order {
            return Order.map.get(order);
        }

        pub fn fromStringOrDie(order: []const u8) Order {
            return fromString(order) orelse {
                Output.prettyErrorln("<r><red>error<r><d>:<r> Invalid DNS result order.", .{});
                Global.exit(1);
            };
        }
    };

    const PendingCache = bun.HiveArray(GetAddrInfoRequest.PendingCacheKey, 32);
    const SrvPendingCache = bun.HiveArray(ResolveInfoRequest(c_ares.struct_ares_srv_reply, "srv").PendingCacheKey, 32);
    const SoaPendingCache = bun.HiveArray(ResolveInfoRequest(c_ares.struct_ares_soa_reply, "soa").PendingCacheKey, 32);
    const TxtPendingCache = bun.HiveArray(ResolveInfoRequest(c_ares.struct_ares_txt_reply, "txt").PendingCacheKey, 32);
    const NaptrPendingCache = bun.HiveArray(ResolveInfoRequest(c_ares.struct_ares_naptr_reply, "naptr").PendingCacheKey, 32);
    const MxPendingCache = bun.HiveArray(ResolveInfoRequest(c_ares.struct_ares_mx_reply, "mx").PendingCacheKey, 32);
    const CaaPendingCache = bun.HiveArray(ResolveInfoRequest(c_ares.struct_ares_caa_reply, "caa").PendingCacheKey, 32);
    const NSPendingCache = bun.HiveArray(ResolveInfoRequest(c_ares.struct_hostent, "ns").PendingCacheKey, 32);
    const PtrPendingCache = bun.HiveArray(ResolveInfoRequest(c_ares.struct_hostent, "ptr").PendingCacheKey, 32);
    const CnamePendingCache = bun.HiveArray(ResolveInfoRequest(c_ares.struct_hostent, "cname").PendingCacheKey, 32);
    const APendingCache = bun.HiveArray(ResolveInfoRequest(c_ares.hostent_with_ttls, "a").PendingCacheKey, 32);
    const AAAAPendingCache = bun.HiveArray(ResolveInfoRequest(c_ares.hostent_with_ttls, "aaaa").PendingCacheKey, 32);
    const AnyPendingCache = bun.HiveArray(ResolveInfoRequest(c_ares.struct_any_reply, "any").PendingCacheKey, 32);
    const AddrPendingCache = bun.HiveArray(GetHostByAddrInfoRequest.PendingCacheKey, 32);
    const NameInfoPendingCache = bun.HiveArray(GetNameInfoRequest.PendingCacheKey, 32);

    pub fn checkTimeouts(this: *Resolver, now: *const timespec, vm: *jsc.VirtualMachine) void {
        defer {
            vm.timer.incrementTimerRef(-1);
            this.deref();
        }

        this.event_loop_timer.state = .PENDING;
        if (this.closed) return;

        if (this.channel) |channel| {
            if (this.poll_failure != null) {
                c_ares.ares_cancel(channel);
                this.poll_failure = null;
            } else if (this.cares_requests != 0) {
                c_ares.ares_process_fd(channel, c_ares.ARES_SOCKET_BAD, c_ares.ARES_SOCKET_BAD);
            }
        }
        if (this.anyRequestsPending()) _ = this.addTimer(now);
    }

    fn anyRequestsPending(this: *Resolver) bool {
        return this.cares_requests != 0 or this.poll_failure != null;
    }

    fn requestSent(this: *Resolver, _: *jsc.VirtualMachine) void {
        this.cares_requests += 1;
        _ = this.addTimer(null);
    }

    const QueryCompletion = struct {
        resolver: ?*Resolver,

        fn init(resolver: ?*Resolver) QueryCompletion {
            if (resolver) |owner| {
                owner.ref();
                bun.assert(owner.cares_requests > 0);
                owner.cares_requests -= 1;
            }
            return .{ .resolver = resolver };
        }

        fn failure(this: QueryCompletion, reported: ?c_ares.Error) ?c_ares.Error {
            return if (this.resolver) |owner| owner.poll_failure orelse reported else reported;
        }

        fn deinit(this: QueryCompletion) void {
            if (this.resolver) |owner| {
                owner.requestCompleted();
                owner.deref();
            }
        }
    };

    fn failPolling(this: *Resolver, failure: c_ares.Error) void {
        if (this.closed) return;
        if (this.poll_failure != null) {
            if (failure == .ENOMEM) this.poll_failure = failure;
            return;
        }
        this.poll_failure = failure;
        // Socket-state callbacks run inside c-ares. Cancellation must wait
        // until that call unwinds, and scheduling it must not allocate.
        if (this.event_loop_timer.state == .ACTIVE) {
            this.vm.timer.remove(&this.event_loop_timer);
        } else {
            this.ref();
            this.vm.timer.incrementTimerRef(1);
        }
        this.event_loop_timer.next = timespec.now(.force_real_time);
        this.vm.timer.insert(&this.event_loop_timer);
    }

    fn requestCompleted(this: *Resolver) void {
        if (!this.closed and this.anyRequestsPending()) {
            _ = this.addTimer(null);
        } else {
            this.removeTimer();
        }
    }

    fn addTimer(this: *Resolver, now: ?*const timespec) bool {
        if (this.event_loop_timer.state == .ACTIVE) {
            return false;
        }

        this.ref();
        this.event_loop_timer.next = (now orelse &timespec.now(.force_real_time)).addMs(1000);
        this.vm.timer.incrementTimerRef(1);
        this.vm.timer.insert(&this.event_loop_timer);
        return true;
    }

    fn removeTimer(this: *Resolver) void {
        if (this.event_loop_timer.state != .ACTIVE) {
            return;
        }

        // Normally checkTimeouts does this, so we have to be sure to do it ourself if we cancel the timer
        defer {
            this.vm.timer.incrementTimerRef(-1);
            this.deref();
        }

        this.vm.timer.remove(&this.event_loop_timer);
    }

    fn getKey(this: *Resolver, index: u8, comptime cache_name: []const u8, comptime request_type: type) request_type.PendingCacheKey {
        var cache = &@field(this, cache_name);
        bun.assert(cache.used.isSet(index));
        const entry = cache.buffer[index];
        cache.buffer[index] = undefined;

        var used = cache.used;
        used.unset(index);
        cache.used = used;

        return entry;
    }

    pub fn drainPendingCares(this: *Resolver, index: u8, err: ?c_ares.Error, timeout: i32, comptime request_type: type, comptime cares_type: type, comptime lookup_name: []const u8, result: ?*cares_type) void {
        const cache_name = comptime std.fmt.comptimePrint("pending_{s}_cache_cares", .{lookup_name});

        this.ref();
        defer this.deref();

        const key = this.getKey(index, cache_name, request_type);

        var addr: *cares_type = result orelse {
            var pending: ?*CAresLookup(cares_type, lookup_name) = key.lookup.head.next;
            key.lookup.head.processResolve(err, timeout, null);
            bun.default_allocator.destroy(key.lookup);

            while (pending) |value| {
                pending = value.next;
                value.processResolve(err, timeout, null);
            }
            return;
        };

        var pending: ?*CAresLookup(cares_type, lookup_name) = key.lookup.head.next;
        defer addr.deinit();
        const head_payload = payloadFromCaresResult(cares_type, lookup_name, addr) catch {
            key.lookup.head.onOutOfMemory();
            bun.default_allocator.destroy(key.lookup);
            while (pending) |value| {
                pending = value.next;
                value.onOutOfMemory();
            }
            return;
        };
        key.lookup.head.onComplete(head_payload);
        bun.default_allocator.destroy(key.lookup);

        while (pending) |value| {
            pending = value.next;
            const payload = payloadFromCaresResult(cares_type, lookup_name, addr) catch {
                value.onOutOfMemory();
                while (pending) |failed| {
                    pending = failed.next;
                    failed.onOutOfMemory();
                }
                return;
            };
            value.onComplete(payload);
        }
    }

    pub fn drainPendingHostCares(this: *Resolver, index: u8, err: ?c_ares.Error, timeout: i32, result: ?*c_ares.AddrInfo) void {
        const key = this.getKey(index, "pending_host_cache_cares", GetAddrInfoRequest);

        this.ref();
        defer this.deref();

        const addr = result orelse {
            var pending: ?*DNSLookup = key.lookup.head.next;
            key.lookup.head.processGetAddrInfo(err, timeout, null);
            key.lookup.deref();

            while (pending) |value| {
                pending = value.next;
                value.processGetAddrInfo(err, timeout, null);
            }
            return;
        };

        var pending: ?*DNSLookup = key.lookup.head.next;
        defer addr.deinit();
        const head_result = lookupResultsFromCares(addr) catch {
            key.lookup.head.onOutOfMemory();
            key.lookup.deref();
            while (pending) |value| {
                pending = value.next;
                value.onOutOfMemory();
            }
            return;
        };
        key.lookup.head.onCompleteResults(head_result);
        key.lookup.deref();

        while (pending) |value| {
            pending = value.next;
            const result_value = lookupResultsFromCares(addr) catch {
                value.onOutOfMemory();
                while (pending) |failed| {
                    pending = failed.next;
                    failed.onOutOfMemory();
                }
                return;
            };
            value.onCompleteResults(result_value);
        }
    }

    pub fn drainPendingAddrCares(this: *Resolver, index: u8, err: ?c_ares.Error, timeout: i32, result: ?*const c_ares.struct_hostent) void {
        const key = this.getKey(index, "pending_addr_cache_cares", GetHostByAddrInfoRequest);

        this.ref();
        defer this.deref();

        const addr = result orelse {
            var pending: ?*CAresReverse = key.lookup.head.next;
            key.lookup.head.processResolve(err, timeout, null);
            bun.default_allocator.destroy(key.lookup);

            while (pending) |value| {
                pending = value.next;
                value.processResolve(err, timeout, null);
            }
            return;
        };

        var pending: ?*CAresReverse = key.lookup.head.next;
        const head_result = hostentStringResults(addr, "reverse") catch {
            key.lookup.head.onOutOfMemory();
            bun.default_allocator.destroy(key.lookup);
            while (pending) |value| {
                pending = value.next;
                value.onOutOfMemory();
            }
            return;
        };
        key.lookup.head.onComplete(head_result);
        bun.default_allocator.destroy(key.lookup);

        while (pending) |value| {
            pending = value.next;
            const result_value = hostentStringResults(addr, "reverse") catch {
                value.onOutOfMemory();
                while (pending) |failed| {
                    pending = failed.next;
                    failed.onOutOfMemory();
                }
                return;
            };
            value.onComplete(result_value);
        }
    }

    pub fn drainPendingNameInfoCares(this: *Resolver, index: u8, err: ?c_ares.Error, timeout: i32, result: ?c_ares.struct_nameinfo) void {
        const key = this.getKey(index, "pending_nameinfo_cache_cares", GetNameInfoRequest);

        this.ref();
        defer this.deref();

        var name_info = result orelse {
            var pending: ?*CAresNameInfo = key.lookup.head.next;
            key.lookup.head.processResolve(err, timeout, null);
            bun.default_allocator.destroy(key.lookup);

            while (pending) |value| {
                pending = value.next;
                value.processResolve(err, timeout, null);
            }
            return;
        };

        var pending: ?*CAresNameInfo = key.lookup.head.next;
        const head_result = nameInfoResult(&name_info) catch {
            key.lookup.head.onOutOfMemory();
            bun.default_allocator.destroy(key.lookup);
            while (pending) |value| {
                pending = value.next;
                value.onOutOfMemory();
            }
            return;
        };
        key.lookup.head.onComplete(head_result);
        bun.default_allocator.destroy(key.lookup);

        while (pending) |value| {
            pending = value.next;
            const result_value = nameInfoResult(&name_info) catch {
                value.onOutOfMemory();
                while (pending) |failed| {
                    pending = failed.next;
                    failed.onOutOfMemory();
                }
                return;
            };
            value.onComplete(result_value);
        }
    }

    pub const CacheHit = LookupCacheHit(GetAddrInfoRequest);

    pub fn LookupCacheHit(comptime request_type: type) type {
        const Result = union(enum) {
            inflight: *request_type.PendingCacheKey,
            new: *request_type.PendingCacheKey,
            disabled: void,
        };
        return Result;
    }

    pub fn getOrPutIntoResolvePendingCache(
        this: *Resolver,
        comptime request_type: type,
        key: request_type.PendingCacheKey,
        comptime field: []const u8,
    ) LookupCacheHit(request_type) {
        var cache = &@field(this, field);
        var inflight_iter = cache.used.iterator(
            .{
                .kind = .set,
            },
        );

        while (inflight_iter.next()) |index| {
            const entry: *request_type.PendingCacheKey = &cache.buffer[index];
            if (entry.eql(key)) {
                return .{ .inflight = entry };
            }
        }

        // Request initialization commits the slot after all allocations succeed.
        var unused = cache.used.iterator(.{ .kind = .unset });
        if (unused.next()) |index| {
            const new = &cache.buffer[index];
            new.* = key;
            return .{ .new = new };
        }

        return .{ .disabled = {} };
    }

    pub fn getOrPutIntoPendingCache(
        this: *Resolver,
        key: GetAddrInfoRequest.PendingCacheKey,
        comptime field: std.meta.FieldEnum(Resolver),
    ) CacheHit {
        return this.getOrPutIntoResolvePendingCache(GetAddrInfoRequest, key, @tagName(field));
    }

    pub const ChannelResult = union(enum) {
        err: c_ares.Error,
        result: *c_ares.Channel,
    };
    pub fn getChannel(this: *Resolver) ChannelResult {
        if (this.closed) return .{ .err = .EDESTRUCTION };
        if (this.poll_failure) |failure| return .{ .err = failure };
        if (this.channel == null) {
            if (c_ares.Channel.init(Resolver, this, this.options)) |err| {
                return .{ .err = err };
            }
        }

        return .{ .result = this.channel.? };
    }

    fn getChannelFromVM(globalThis: *jsc.JSGlobalObject) bun.JSError!*c_ares.Channel {
        var vm = globalThis.bunVM();
        const resolver = try (try vm.tryRareData()).globalDNSResolver(vm);
        return resolver.getChannelOrError(globalThis);
    }

    pub fn getChannelOrError(this: *Resolver, globalThis: *jsc.JSGlobalObject) bun.JSError!*c_ares.Channel {
        switch (this.getChannel()) {
            .result => |result| return result,
            .err => |err| {
                if (err == .ENOMEM) return error.OutOfMemory;
                const system_error = bun.sys.SystemError{
                    .errno = -1,
                    .code = err.codeString(),
                    .message = err.labelString(),
                };

                return bun.api.SystemErrorBindings.throwSystemError(system_error, globalThis);
            },
        }
    }

    pub fn onDNSPollUv(watcher: [*c]bun.windows.libuv.uv_poll_t, status: c_int, events: c_int) callconv(.c) void {
        const poll = UvDnsPoll.fromPoll(watcher);
        const resolver = poll.parent;
        const vm = resolver.vm;
        vm.eventLoop().enter();
        defer vm.eventLoop().exit();
        resolver.ref();
        defer resolver.deref();
        if (resolver.poll_failure != null) return;
        const channel = resolver.channel orelse return;
        if (status < 0) {
            resolver.failPolling(if (status == bun.windows.libuv.UV_ENOMEM) .ENOMEM else .EFILE);
            return;
        }
        channel.process(
            poll.socket,
            events & bun.windows.libuv.UV_READABLE != 0,
            events & bun.windows.libuv.UV_WRITABLE != 0,
        );
    }

    pub fn onCloseUv(watcher: *anyopaque) callconv(.c) void {
        const poll = UvDnsPoll.fromPoll(@ptrCast(@alignCast(watcher)));
        poll.destroy();
    }

    pub fn onDNSPoll(
        this: *Resolver,
        poll: *Async.FilePoll,
    ) void {
        const vm = this.vm;
        vm.eventLoop().enter();
        defer vm.eventLoop().exit();
        if (this.poll_failure != null) return;
        const channel = this.channel orelse return;

        this.ref();
        defer this.deref();

        channel.process(
            poll.fd.native(),
            poll.isReadable(),
            poll.isWritable(),
        );
    }

    fn removePoll(this: *Resolver, fd: c_ares.ares_socket_t) void {
        const entry = this.polls.fetchOrderedRemove(fd) orelse return;
        if (comptime Environment.isWindows) {
            bun.windows.libuv.uv_close(@ptrCast(&entry.value.poll), onCloseUv);
        } else {
            entry.value.deinitWithVM(this.vm);
        }
    }

    pub fn onDNSSocketState(
        this: *Resolver,
        fd: c_ares.ares_socket_t,
        readable: bool,
        writable: bool,
    ) void {
        if (!readable and !writable) {
            this.removePoll(fd);
            return;
        }
        if (this.poll_failure != null) return;

        const poll_entry = this.polls.getOrPut(this.allocator, fd) catch {
            this.failPolling(.ENOMEM);
            return;
        };
        if (comptime Environment.isWindows) {
            const uv = bun.windows.libuv;
            if (!poll_entry.found_existing) {
                const poll = bun.default_allocator.create(UvDnsPoll) catch {
                    _ = this.polls.swapRemove(fd);
                    this.failPolling(.ENOMEM);
                    return;
                };
                poll.* = .{
                    .parent = this,
                    .socket = fd,
                    .poll = undefined,
                };
                const status = uv.uv_poll_init_socket(this.vm.uwsLoop().uv_loop, &poll.poll, @ptrCast(fd));
                if (status < 0) {
                    poll.destroy();
                    _ = this.polls.swapRemove(fd);
                    this.failPolling(if (status == uv.UV_ENOMEM) .ENOMEM else .EFILE);
                    return;
                }
                poll_entry.value_ptr.* = poll;
            }

            const poll: *UvDnsPoll = poll_entry.value_ptr.*;

            const uv_events = (if (readable) uv.UV_READABLE else 0) | (if (writable) uv.UV_WRITABLE else 0);
            const status = uv.uv_poll_start(&poll.poll, uv_events, onDNSPollUv);
            if (status < 0) {
                this.removePoll(fd);
                this.failPolling(if (status == uv.UV_ENOMEM) .ENOMEM else .EFILE);
            }
        } else {
            const vm = this.vm;
            if (!poll_entry.found_existing) {
                poll_entry.value_ptr.* = Async.FilePoll.create(vm, .fromNative(fd), .{}, Resolver, this) catch {
                    _ = this.polls.swapRemove(fd);
                    this.failPolling(.ENOMEM);
                    return;
                };
            }

            const poll = poll_entry.value_ptr.*;
            const loop = vm.event_loop_handle.?;
            const have_readable = poll.flags.contains(.poll_readable);
            const have_writable = poll.flags.contains(.poll_writable);
            var status: bun.sys.Maybe(void) = .{ .result = {} };
            if ((have_readable and !readable) or (have_writable and !writable)) {
                status = poll.unregister(loop, false);
                if (status == .result and readable) status = poll.register(loop, .readable, false);
                if (status == .result and writable) status = poll.register(loop, .writable, false);
            } else {
                if (readable and !have_readable) status = poll.register(loop, .readable, false);
                if (status == .result and writable and !have_writable) status = poll.register(loop, .writable, false);
            }
            if (status == .err) {
                const failure: c_ares.Error = if (status.err.getErrno() == .NOMEM) .ENOMEM else .EFILE;
                this.removePoll(fd);
                this.failPolling(failure);
            }
        }
    }

    pub const RecordType = enum(c_int) {
        A = 1,
        AAAA = 28,
        CAA = 257,
        CNAME = 5,
        MX = 15,
        NS = 2,
        PTR = 12,
        SOA = 6,
        SRV = 33,
        TXT = 16,
        ANY = 255,
    };

    fn recordType(record: anytype) RecordType {
        return switch (record orelse .A) {
            .A => .A,
            .AAAA => .AAAA,
            .ANY => .ANY,
            .CAA => .CAA,
            .CNAME => .CNAME,
            .MX => .MX,
            .NS => .NS,
            .PTR => .PTR,
            .SOA => .SOA,
            .SRV => .SRV,
            .TXT => .TXT,
        };
    }

    fn ownedUTF8(value: bun.bindgen.DOMStringView) bun.OOM![]const u8 {
        var utf8 = try value.toUTF8(bun.default_allocator);
        return utf8.intoOwnedSlice(bun.default_allocator);
    }

    fn globalResultFromBinding(
        comptime operation: GlobalResultOperation,
        context: anytype,
        args: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
        const globalThis = context.viewToken().globalObject();
        return switch (operation) {
            .new_resolver => newResolverFromBinding(context, args),
            .get_servers => getChannelServers(
                bun.bindgen.Return(@TypeOf(context)),
                try getChannelFromVM(globalThis),
                globalThis,
            ),
        };
    }

    fn globalVoidFromBinding(
        comptime operation: GlobalVoidOperation,
        context: anytype,
        args: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!void {
        const globalThis = context.viewToken().globalObject();
        return switch (operation) {
            .lookup => globalLookupFromBinding(context, args),
            .lookup_service => globalLookupServiceFromBinding(context, args),
            .resolve => globalResolveFromBinding(context, args),
            .resolve_any => resolveGlobal(globalThis, context, args.hostname, c_ares.struct_any_reply, "any"),
            .resolve_caa => resolveGlobal(globalThis, context, args.hostname, c_ares.struct_ares_caa_reply, "caa"),
            .resolve_cname => resolveGlobal(globalThis, context, args.hostname, c_ares.struct_hostent, "cname"),
            .resolve_mx => resolveGlobal(globalThis, context, args.hostname, c_ares.struct_ares_mx_reply, "mx"),
            .resolve_naptr => resolveGlobal(globalThis, context, args.hostname, c_ares.struct_ares_naptr_reply, "naptr"),
            .resolve_ns => resolveGlobal(globalThis, context, args.hostname, c_ares.struct_hostent, "ns"),
            .resolve_ptr => resolveGlobal(globalThis, context, args.hostname, c_ares.struct_hostent, "ptr"),
            .resolve_soa => resolveGlobal(globalThis, context, args.hostname, c_ares.struct_ares_soa_reply, "soa"),
            .resolve_srv => resolveGlobal(globalThis, context, args.hostname, c_ares.struct_ares_srv_reply, "srv"),
            .resolve_txt => resolveGlobal(globalThis, context, args.hostname, c_ares.struct_ares_txt_reply, "txt"),
            .reverse => globalReverseFromBinding(context, args),
            .set_servers => setChannelServers(try getChannelFromVM(globalThis), globalThis, args.servers),
        };
    }

    pub fn globalResolve(
        context: bun.bindgen.CallContext(DNSResolveSchema),
        args: bun.bindgen.Args(DNSResolveSchema),
    ) bun.JSError!void {
        return globalVoidFromBinding(.resolve, context, args);
    }

    fn globalResolveFromBinding(
        context: anytype,
        args: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!void {
        const globalThis = context.viewToken().globalObject();
        const vm = globalThis.bunVM();
        const resolver = try (try vm.tryRareData()).globalDNSResolver(vm);
        var view = context.completion();
        const completion = DnsQueryCompletions.takeForContext(context, &view);
        return resolver.resolve(globalThis, args.name, recordType(args.record), completion);
    }

    pub fn resolve(this: *Resolver, globalThis: *jsc.JSGlobalObject, name_view: bun.bindgen.DOMStringView, record_type: RecordType, completion: DnsQueryCompletions.Owned) bun.JSError!void {
        const name = ownedUTF8(name_view) catch |err| {
            var owned = completion;
            owned.release();
            return err;
        };
        switch (record_type) {
            RecordType.A => {
                return this.doResolveCAres(c_ares.hostent_with_ttls, "a", name, globalThis, completion);
            },
            RecordType.AAAA => {
                return this.doResolveCAres(c_ares.hostent_with_ttls, "aaaa", name, globalThis, completion);
            },
            RecordType.ANY => {
                return this.doResolveCAres(c_ares.struct_any_reply, "any", name, globalThis, completion);
            },
            RecordType.CAA => {
                return this.doResolveCAres(c_ares.struct_ares_caa_reply, "caa", name, globalThis, completion);
            },
            RecordType.CNAME => {
                return this.doResolveCAres(c_ares.struct_hostent, "cname", name, globalThis, completion);
            },
            RecordType.MX => {
                return this.doResolveCAres(c_ares.struct_ares_mx_reply, "mx", name, globalThis, completion);
            },
            RecordType.NS => {
                return this.doResolveCAres(c_ares.struct_hostent, "ns", name, globalThis, completion);
            },
            RecordType.PTR => {
                return this.doResolveCAres(c_ares.struct_hostent, "ptr", name, globalThis, completion);
            },
            RecordType.SOA => {
                return this.doResolveCAres(c_ares.struct_ares_soa_reply, "soa", name, globalThis, completion);
            },
            RecordType.SRV => {
                return this.doResolveCAres(c_ares.struct_ares_srv_reply, "srv", name, globalThis, completion);
            },
            RecordType.TXT => {
                return this.doResolveCAres(c_ares.struct_ares_txt_reply, "txt", name, globalThis, completion);
            },
        }
    }

    pub fn globalReverse(
        context: bun.bindgen.CallContext(DNSReverseSchema),
        args: bun.bindgen.Args(DNSReverseSchema),
    ) bun.JSError!void {
        return globalVoidFromBinding(.reverse, context, args);
    }

    fn globalReverseFromBinding(
        context: anytype,
        args: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!void {
        const globalThis = context.viewToken().globalObject();
        const vm = globalThis.bunVM();
        const resolver = try (try vm.tryRareData()).globalDNSResolver(vm);
        var view = context.completion();
        const completion = DnsQueryCompletions.takeForContext(context, &view);
        return resolver.reverse(globalThis, args.ip, completion);
    }

    pub fn reverse(this: *Resolver, globalThis: *jsc.JSGlobalObject, ip_view: bun.bindgen.DOMStringView, completion: DnsQueryCompletions.Owned) bun.JSError!void {
        const ip = ownedUTF8(ip_view) catch {
            var owned = completion;
            owned.outOfMemory();
            return;
        };
        var owns_ip = true;
        defer if (owns_ip) bun.default_allocator.free(ip);
        const channel: *c_ares.Channel = switch (this.getChannel()) {
            .result => |res| res,
            .err => |err| {
                var owned = completion;
                completeDnsError(&owned, err, "getHostByAddr", ip);
                return;
            },
        };

        const key = GetHostByAddrInfoRequest.PendingCacheKey.init(ip);
        var cache = this.getOrPutIntoResolvePendingCache(
            GetHostByAddrInfoRequest,
            key,
            "pending_addr_cache_cares",
        );
        if (cache == .inflight) {
            const cares_reverse = CAresReverse.init(this, globalThis, globalThis.allocator(), ip, completion) catch {
                var owned = completion;
                owned.outOfMemory();
                return;
            };
            owns_ip = false;
            cache.inflight.append(cares_reverse);
            return;
        }

        const request = GetHostByAddrInfoRequest.init(
            cache,
            this,
            ip,
            globalThis,
            "pending_addr_cache_cares",
            completion,
        ) catch {
            var owned = completion;
            owned.outOfMemory();
            return;
        };
        owns_ip = false;

        this.requestSent(globalThis.bunVM());
        channel.getHostByAddr(
            ip,
            GetHostByAddrInfoRequest,
            request,
            GetHostByAddrInfoRequest.onCaresComplete,
        );
    }

    pub fn globalLookup(
        context: bun.bindgen.CallContext(DNSLookupSchema),
        args: bun.bindgen.Args(DNSLookupSchema),
    ) bun.bindgen.CallError(DNSLookupSchema)!void {
        return globalVoidFromBinding(.lookup, context, args);
    }

    fn globalLookupFromBinding(
        context: anytype,
        args: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!void {
        const globalThis = context.viewToken().globalObject();
        var options = GetAddrInfo.Options{};
        var port: u16 = 0;

        const input_options = if (args.options) |input| switch (input) {
            .options => |value| value,
            .ignored => null,
        } else null;
        if (input_options) |input| {
            if (input.family) |family| options.family = switch (family) {
                .number => |number| switch (number) {
                    0 => .unspecified,
                    4 => .inet,
                    6 => .inet6,
                    else => return context.fail(.invalid_family, {}),
                },
                .name => |name| switch (name) {
                    .unspecified => .unspecified,
                    .inet => .inet,
                    .inet6 => .inet6,
                },
            };
            if (input.socketType) |socket_type| options.socktype = switch (socket_type) {
                .stream => .stream,
                .dgram => .dgram,
            };
            if (input.protocol) |protocol| options.protocol = switch (protocol) {
                .tcp => .tcp,
                .udp => .udp,
            };
            if (input.backend) |backend| options.backend = switch (backend) {
                .c_ares => .c_ares,
                .system => .system,
                .libc => .libc,
            };
            const flags: u32 = @bitCast(input.flags);
            const valid_flags: u32 = @intCast(bun.dns.AI_ADDRCONFIG | bun.dns.AI_ALL | bun.dns.AI_V4MAPPED);
            if (flags & ~valid_flags != 0) {
                return context.fail(.invalid_flags, {});
            }
            options.flags = @bitCast(flags);
            port = input.port;
        }

        const name = try args.hostname.toUTF8(bun.default_allocator);
        defer name.deinit();
        var vm = globalThis.bunVM();
        const resolver = try (try vm.tryRareData()).globalDNSResolver(vm);

        var view = context.completion();
        const completion = DnsQueryCompletions.takeForContext(context, &view);
        return resolver.doLookup(name.slice(), port, options, globalThis, completion);
    }

    pub fn doLookup(this: *Resolver, name: []const u8, port: u16, options: GetAddrInfo.Options, globalThis: *jsc.JSGlobalObject, completion: DnsQueryCompletions.Owned) bun.JSError!void {
        if (std.mem.indexOfScalar(u8, name, 0) != null) {
            var owned = completion;
            completeDnsError(&owned, .ENOTFOUND, "getaddrinfo", name);
            return;
        }

        var opts = options;
        var backend = opts.backend;
        const normalized = normalizeDNSName(name, &backend);
        opts.backend = backend;
        const query = GetAddrInfo{
            .options = opts,
            .port = port,
            .name = normalized,
        };

        return switch (opts.backend) {
            .c_ares => this.c_aresLookupWithNormalizedName(query, globalThis, completion),
            .libc, .system => LibC.lookup(this, query, globalThis, completion),
        };
    }

    fn resolveType(
        this: *Resolver,
        globalThis: *jsc.JSGlobalObject,
        hostname: bun.bindgen.DOMStringView,
        comptime cares_type: type,
        comptime type_name: []const u8,
        completion: DnsQueryCompletions.Owned,
    ) bun.JSError!void {
        const name = ownedUTF8(hostname) catch |err| {
            var owned = completion;
            owned.release();
            return err;
        };
        return this.doResolveCAres(cares_type, type_name, name, globalThis, completion);
    }

    fn resolveGlobal(
        globalThis: *jsc.JSGlobalObject,
        context: anytype,
        hostname: bun.bindgen.DOMStringView,
        comptime cares_type: type,
        comptime type_name: []const u8,
    ) bun.JSError!void {
        const resolver = try (try globalThis.bunVM().tryRareData()).globalDNSResolver(globalThis.bunVM());
        var view = context.completion();
        const completion = DnsQueryCompletions.takeForContext(context, &view);
        return resolver.resolveType(globalThis, hostname, cares_type, type_name, completion);
    }

    pub fn globalResolveSrv(
        context: bun.bindgen.CallContext(DNSResolveSrvSchema),
        args: bun.bindgen.Args(DNSResolveSrvSchema),
    ) bun.JSError!void {
        return globalVoidFromBinding(.resolve_srv, context, args);
    }

    pub fn globalResolveSoa(
        context: bun.bindgen.CallContext(DNSResolveSoaSchema),
        args: bun.bindgen.Args(DNSResolveSoaSchema),
    ) bun.JSError!void {
        return globalVoidFromBinding(.resolve_soa, context, args);
    }

    pub fn globalResolveCaa(
        context: bun.bindgen.CallContext(DNSResolveCaaSchema),
        args: bun.bindgen.Args(DNSResolveCaaSchema),
    ) bun.JSError!void {
        return globalVoidFromBinding(.resolve_caa, context, args);
    }

    pub fn globalResolveNs(
        context: bun.bindgen.CallContext(DNSResolveNsSchema),
        args: bun.bindgen.Args(DNSResolveNsSchema),
    ) bun.JSError!void {
        return globalVoidFromBinding(.resolve_ns, context, args);
    }

    pub fn globalResolvePtr(
        context: bun.bindgen.CallContext(DNSResolvePtrSchema),
        args: bun.bindgen.Args(DNSResolvePtrSchema),
    ) bun.JSError!void {
        return globalVoidFromBinding(.resolve_ptr, context, args);
    }

    pub fn globalResolveCname(
        context: bun.bindgen.CallContext(DNSResolveCnameSchema),
        args: bun.bindgen.Args(DNSResolveCnameSchema),
    ) bun.JSError!void {
        return globalVoidFromBinding(.resolve_cname, context, args);
    }

    pub fn globalResolveMx(
        context: bun.bindgen.CallContext(DNSResolveMxSchema),
        args: bun.bindgen.Args(DNSResolveMxSchema),
    ) bun.JSError!void {
        return globalVoidFromBinding(.resolve_mx, context, args);
    }

    pub fn globalResolveNaptr(
        context: bun.bindgen.CallContext(DNSResolveNaptrSchema),
        args: bun.bindgen.Args(DNSResolveNaptrSchema),
    ) bun.JSError!void {
        return globalVoidFromBinding(.resolve_naptr, context, args);
    }

    pub fn globalResolveTxt(
        context: bun.bindgen.CallContext(DNSResolveTxtSchema),
        args: bun.bindgen.Args(DNSResolveTxtSchema),
    ) bun.JSError!void {
        return globalVoidFromBinding(.resolve_txt, context, args);
    }

    pub fn globalResolveAny(
        context: bun.bindgen.CallContext(DNSResolveAnySchema),
        args: bun.bindgen.Args(DNSResolveAnySchema),
    ) bun.JSError!void {
        return globalVoidFromBinding(.resolve_any, context, args);
    }

    pub fn doResolveCAres(this: *Resolver, comptime cares_type: type, comptime type_name: []const u8, name: []const u8, globalThis: *jsc.JSGlobalObject, completion: DnsQueryCompletions.Owned) bun.JSError!void {
        var owns_name = true;
        defer if (owns_name) bun.default_allocator.free(name);
        const channel: *c_ares.Channel = switch (this.getChannel()) {
            .result => |res| res,
            .err => |err| {
                var owned = completion;
                completeDnsError(&owned, err, "query" ++ &[_]u8{std.ascii.toUpper(type_name[0])} ++ type_name[1..], name);
                return;
            },
        };

        const cache_name = comptime std.fmt.comptimePrint("pending_{s}_cache_cares", .{type_name});

        const key = ResolveInfoRequest(cares_type, type_name).PendingCacheKey.init(name);

        var cache = this.getOrPutIntoResolvePendingCache(ResolveInfoRequest(cares_type, type_name), key, cache_name);
        if (cache == .inflight) {
            const cares_lookup = CAresLookup(cares_type, type_name).init(this, globalThis, globalThis.allocator(), name, completion) catch {
                var owned = completion;
                owned.outOfMemory();
                return;
            };
            owns_name = false;
            cache.inflight.append(cares_lookup);
            return;
        }

        const request = ResolveInfoRequest(cares_type, type_name).init(
            cache,
            this,
            name,
            globalThis,
            cache_name,
            completion,
        ) catch {
            var owned = completion;
            owned.outOfMemory();
            return;
        };
        owns_name = false;

        this.requestSent(globalThis.bunVM());
        channel.resolve(
            name,
            type_name,
            ResolveInfoRequest(cares_type, type_name),
            request,
            cares_type,
            ResolveInfoRequest(cares_type, type_name).onCaresComplete,
        );
    }
    pub fn c_aresLookupWithNormalizedName(this: *Resolver, query: GetAddrInfo, globalThis: *jsc.JSGlobalObject, completion: DnsQueryCompletions.Owned) bun.JSError!void {
        const channel: *c_ares.Channel = switch (this.getChannel()) {
            .result => |res| res,
            .err => |err| {
                var owned = completion;
                completeDnsError(&owned, err, "getaddrinfo", query.name);
                return;
            },
        };

        const key = GetAddrInfoRequest.PendingCacheKey.init(query);

        const cache = this.getOrPutIntoPendingCache(key, .pending_host_cache_cares);
        if (cache == .inflight) {
            const dns_lookup = DNSLookup.init(this, globalThis, globalThis.allocator(), completion) catch {
                var owned = completion;
                owned.outOfMemory();
                return;
            };
            cache.inflight.append(dns_lookup);
            return;
        }

        const request = GetAddrInfoRequest.init(
            cache,
            .{ .c_ares = {} },
            this,
            query,
            globalThis,
            "pending_host_cache_cares",
            completion,
        ) catch {
            var owned = completion;
            owned.outOfMemory();
            return;
        };

        const hints = query.toCAres();
        this.requestSent(globalThis.bunVM());
        // c-ares can complete inline while still borrowing the query name.
        request.ref();
        defer request.deref();
        channel.getAddrInfo(
            request.query.name,
            query.port,
            &hints,
            GetAddrInfoRequest,
            request,
            GetAddrInfoRequest.onCaresComplete,
        );
    }

    fn getChannelServers(
        comptime Result: type,
        channel: *c_ares.Channel,
        globalThis: *jsc.JSGlobalObject,
    ) bun.JSError!Result {
        var servers: ?*c_ares.struct_ares_addr_port_node = null;
        const result = c_ares.ares_get_servers_ports(channel, &servers);
        if (result != c_ares.ARES_SUCCESS) {
            const err = c_ares.Error.get(result).?;
            return globalThis.throw("ares_get_servers_ports error: {s}", .{err.label()});
        }
        defer c_ares.ares_free_data(servers);

        const allocator = bun.default_allocator;
        var values = std.array_list.Managed([]const u8).init(allocator);
        defer {
            for (values.items) |value| allocator.free(value);
            values.deinit();
        }

        var current_server = servers;
        while (current_server) |current| : (current_server = current.next) {
            var buf: [INET6_ADDRSTRLEN + 2 + 6 + 1]u8 = undefined;
            const family = current.family;
            const ip = if (family == std.posix.AF.INET6)
                c_ares.ares_inet_ntop(family, &current.addr.addr6, buf[1..], @sizeOf(@TypeOf(buf)) - 1)
            else
                c_ares.ares_inet_ntop(family, &current.addr.addr4, buf[1..], @sizeOf(@TypeOf(buf)) - 1);
            if (ip == null) {
                return globalThis.throw("ares_inet_ntop error: no more space to convert a network format address", .{});
            }

            var port = current.tcp_port;
            if (port == 0) port = current.udp_port;
            if (port == 0) port = IANA_DNS_PORT;

            const size = bun.len(bun.cast([*:0]u8, buf[1..])) + 1;
            const formatted = if (port == IANA_DNS_PORT)
                buf[1..size]
            else if (family == std.posix.AF.INET6) brk: {
                buf[0] = '[';
                buf[size] = ']';
                const port_slice = std.fmt.bufPrint(buf[size + 1 ..], ":{d}", .{port}) catch unreachable;
                break :brk buf[0 .. size + 1 + port_slice.len];
            } else brk: {
                const port_slice = std.fmt.bufPrint(buf[size..], ":{d}", .{port}) catch unreachable;
                break :brk buf[1 .. size + port_slice.len];
            };

            const owned = try allocator.dupe(u8, formatted);
            values.append(owned) catch |err| {
                allocator.free(owned);
                return err;
            };
        }

        return Result.fromUTF8Slices(values.items);
    }

    pub fn getGlobalServers(
        context: bun.bindgen.CallContext(DNSGetServersSchema),
        args: bun.bindgen.Args(DNSGetServersSchema),
    ) bun.JSError!bun.bindgen.Return(DNSGetServersSchema) {
        return globalResultFromBinding(.get_servers, context, args);
    }

    fn setChannelLocalAddresses(
        channel: *c_ares.Channel,
        globalThis: *jsc.JSGlobalObject,
        first: bun.bindgen.DOMStringView,
        second: ?bun.bindgen.DOMStringView,
    ) bun.JSError!void {
        const first_af = try setChannelLocalAddress(channel, globalThis, first);
        const second_af = try setChannelLocalAddress(channel, globalThis, second orelse return);
        if (first_af != second_af) return;

        switch (first_af) {
            c_ares.AF.INET => return globalThis.throwInvalidArguments("Cannot specify two IPv4 addresses.", .{}),
            c_ares.AF.INET6 => return globalThis.throwInvalidArguments("Cannot specify two IPv6 addresses.", .{}),
            else => unreachable,
        }
    }

    fn setChannelLocalAddress(
        channel: *c_ares.Channel,
        globalThis: *jsc.JSGlobalObject,
        value: bun.bindgen.DOMStringView,
    ) bun.JSError!c_int {
        const slice = try value.toOwnedSliceZ(bun.default_allocator);
        defer bun.default_allocator.free(slice);

        var addr: [16]u8 = undefined;
        if (c_ares.ares_inet_pton(c_ares.AF.INET, slice.ptr, &addr) == 1) {
            const ip = std.mem.readInt(u32, addr[0..4], .big);
            c_ares.ares_set_local_ip4(channel, ip);
            return c_ares.AF.INET;
        }

        if (c_ares.ares_inet_pton(c_ares.AF.INET6, slice.ptr, &addr) == 1) {
            c_ares.ares_set_local_ip6(channel, &addr);
            return c_ares.AF.INET6;
        }

        return globalThis.throwNodeError(.ERR_INVALID_IP_ADDRESS, "Invalid IP address: \"{s}\"", .{slice});
    }

    fn setChannelServers(
        channel: *c_ares.Channel,
        globalThis: *jsc.JSGlobalObject,
        servers: anytype,
    ) bun.JSError!void {
        if (channel != try getChannelFromVM(globalThis) and c_ares.ares_queue_active_queries(channel) != 0) {
            return globalThis.throwNodeError(.ERR_DNS_SET_SERVERS_FAILED, "Failed to set servers: there are pending queries", .{});
        }

        if (servers.len() == 0) {
            const result = c_ares.ares_set_servers_ports(channel, null);
            if (result != c_ares.ARES_SUCCESS) {
                const err = c_ares.Error.get(result).?;
                return globalThis.throw("ares_set_servers_ports error: {s}", .{err.label()});
            }
            return;
        }

        const allocator = bun.default_allocator;
        const entries = try allocator.alloc(c_ares.struct_ares_addr_port_node, servers.len());
        defer allocator.free(entries);

        for (0..servers.len()) |index| {
            const server = servers.at(index).?;
            if (server.family != 4 and server.family != 6) {
                return globalThis.throwInvalidArguments("Invalid address family", .{});
            }

            const address = try server.address.toOwnedSliceZ(allocator);
            defer allocator.free(address);
            const af: c_int = if (server.family == 4) std.posix.AF.INET else std.posix.AF.INET6;
            entries[index] = .{
                .next = null,
                .family = af,
                .addr = undefined,
                .udp_port = server.port,
                .tcp_port = server.port,
            };

            if (c_ares.ares_inet_pton(af, address.ptr, &entries[index].addr) != 1) {
                return globalThis.throwNodeError(.ERR_INVALID_IP_ADDRESS, "Invalid IP address: \"{s}\"", .{address});
            }
            if (index > 0) entries[index - 1].next = &entries[index];
        }

        const result = c_ares.ares_set_servers_ports(channel, entries.ptr);
        if (result != c_ares.ARES_SUCCESS) {
            const err = c_ares.Error.get(result).?;
            return globalThis.throw("ares_set_servers_ports error: {s}", .{err.label()});
        }
    }

    pub fn setGlobalServers(
        context: bun.bindgen.CallContext(DNSSetServersSchema),
        args: bun.bindgen.Args(DNSSetServersSchema),
    ) bun.JSError!void {
        return globalVoidFromBinding(.set_servers, context, args);
    }

    pub fn newResolver(
        context: bun.bindgen.CallContext(NewResolverSchema),
        args: bun.bindgen.Args(NewResolverSchema),
    ) bun.JSError!bun.bindgen.Return(NewResolverSchema) {
        return globalResultFromBinding(.new_resolver, context, args);
    }

    fn newResolverFromBinding(
        context: anytype,
        args: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
        const globalThis = context.viewToken().globalObject();
        const resolver = try Resolver.init(globalThis.allocator(), globalThis.bunVM());
        var resolver_needs_deref = true;
        errdefer if (resolver_needs_deref) resolver.deref();

        if (args.options) |options| {
            if (options.timeout) |timeout| resolver.options.timeout = timeout;
            if (options.tries) |tries| resolver.options.tries = tries;
        }

        const binding = try bun.default_allocator.create(JSBinding);
        binding.* = .{ .resolver = bun.bindgen.RefNative(Resolver, .vm).adopt(resolver) };
        resolver_needs_deref = false;
        return DNSResolverClass.adoptResult(binding, context);
    }

    pub fn cancel(this: *Resolver, globalThis: *jsc.JSGlobalObject) bun.JSError!void {
        const channel = try this.getChannelOrError(globalThis);
        c_ares.ares_cancel(channel);
    }

    pub const JSBinding = struct {
        const VoidOperation = enum {
            cancel,
            resolve,
            resolve_any,
            resolve_caa,
            resolve_cname,
            resolve_mx,
            resolve_naptr,
            resolve_ns,
            resolve_ptr,
            resolve_soa,
            resolve_srv,
            resolve_txt,
            reverse,
            set_local_address,
            set_servers,
        };

        bindgen_state: bun.bindgen.ClassState = .{},
        resolver: bun.bindgen.RefNative(Resolver, .vm),

        pub const destroy = @This().deinit;

        fn deinit(this: *JSBinding) void {
            this.resolver.deinit();
            bun.destroy(this);
        }

        fn getServersFromBinding(
            this: *JSBinding,
            context: anytype,
            _: anytype,
        ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
            const globalThis = context.viewToken().globalObject();
            return getChannelServers(
                bun.bindgen.Return(@TypeOf(context)),
                try this.resolver.get().getChannelOrError(globalThis),
                globalThis,
            );
        }

        fn voidFromBinding(
            this: *JSBinding,
            comptime operation: VoidOperation,
            context: anytype,
            args: anytype,
        ) bun.bindgen.CallError(@TypeOf(context))!void {
            const globalThis = context.viewToken().globalObject();
            return switch (operation) {
                .cancel => this.resolver.get().cancel(globalThis),
                .resolve => this.bindResolveFromBinding(context, args),
                .resolve_any => this.bindResolveTypeFromBinding(context, args.hostname, c_ares.struct_any_reply, "any"),
                .resolve_caa => this.bindResolveTypeFromBinding(context, args.hostname, c_ares.struct_ares_caa_reply, "caa"),
                .resolve_cname => this.bindResolveTypeFromBinding(context, args.hostname, c_ares.struct_hostent, "cname"),
                .resolve_mx => this.bindResolveTypeFromBinding(context, args.hostname, c_ares.struct_ares_mx_reply, "mx"),
                .resolve_naptr => this.bindResolveTypeFromBinding(context, args.hostname, c_ares.struct_ares_naptr_reply, "naptr"),
                .resolve_ns => this.bindResolveTypeFromBinding(context, args.hostname, c_ares.struct_hostent, "ns"),
                .resolve_ptr => this.bindResolveTypeFromBinding(context, args.hostname, c_ares.struct_hostent, "ptr"),
                .resolve_soa => this.bindResolveTypeFromBinding(context, args.hostname, c_ares.struct_ares_soa_reply, "soa"),
                .resolve_srv => this.bindResolveTypeFromBinding(context, args.hostname, c_ares.struct_ares_srv_reply, "srv"),
                .resolve_txt => this.bindResolveTypeFromBinding(context, args.hostname, c_ares.struct_ares_txt_reply, "txt"),
                .reverse => this.bindReverseFromBinding(context, args),
                .set_local_address => setChannelLocalAddresses(
                    try this.resolver.get().getChannelOrError(globalThis),
                    globalThis,
                    args.first,
                    args.second,
                ),
                .set_servers => setChannelServers(
                    try this.resolver.get().getChannelOrError(globalThis),
                    globalThis,
                    args.servers,
                ),
            };
        }

        fn bindResolveTypeFromBinding(
            this: *JSBinding,
            context: anytype,
            hostname: bun.bindgen.DOMStringView,
            comptime cares_type: type,
            comptime type_name: []const u8,
        ) bun.JSError!void {
            const globalThis = context.viewToken().globalObject();
            var view = context.completion();
            const completion = DnsQueryCompletions.takeForContext(context, &view);
            return this.resolver.get().resolveType(globalThis, hostname, cares_type, type_name, completion);
        }

        fn bindResolveFromBinding(
            this: *JSBinding,
            context: anytype,
            args: anytype,
        ) bun.bindgen.CallError(@TypeOf(context))!void {
            const globalThis = context.viewToken().globalObject();
            var view = context.completion();
            const completion = DnsQueryCompletions.takeForContext(context, &view);
            return this.resolver.get().resolve(globalThis, args.name, recordType(args.record), completion);
        }

        fn bindReverseFromBinding(
            this: *JSBinding,
            context: anytype,
            args: anytype,
        ) bun.bindgen.CallError(@TypeOf(context))!void {
            const globalThis = context.viewToken().globalObject();
            var view = context.completion();
            const completion = DnsQueryCompletions.takeForContext(context, &view);
            return this.resolver.get().reverse(globalThis, args.ip, completion);
        }

        pub fn bindCancel(
            this: *JSBinding,
            context: bun.bindgen.CallContext(DNSResolverCancelSchema),
            args: bun.bindgen.Args(DNSResolverCancelSchema),
        ) bun.JSError!void {
            return this.voidFromBinding(.cancel, context, args);
        }

        pub fn bindGetServers(
            this: *JSBinding,
            context: bun.bindgen.CallContext(DNSResolverGetServersSchema),
            args: bun.bindgen.Args(DNSResolverGetServersSchema),
        ) bun.JSError!bun.bindgen.Return(DNSResolverGetServersSchema) {
            return this.getServersFromBinding(context, args);
        }

        pub fn bindResolve(
            this: *JSBinding,
            context: bun.bindgen.CallContext(DNSResolverResolveSchema),
            args: bun.bindgen.Args(DNSResolverResolveSchema),
        ) bun.JSError!void {
            return this.voidFromBinding(.resolve, context, args);
        }

        pub fn bindResolveAny(
            this: *JSBinding,
            context: bun.bindgen.CallContext(DNSResolverResolveAnySchema),
            args: bun.bindgen.Args(DNSResolverResolveAnySchema),
        ) bun.JSError!void {
            return this.voidFromBinding(.resolve_any, context, args);
        }

        pub fn bindResolveCaa(
            this: *JSBinding,
            context: bun.bindgen.CallContext(DNSResolverResolveCaaSchema),
            args: bun.bindgen.Args(DNSResolverResolveCaaSchema),
        ) bun.JSError!void {
            return this.voidFromBinding(.resolve_caa, context, args);
        }

        pub fn bindResolveCname(
            this: *JSBinding,
            context: bun.bindgen.CallContext(DNSResolverResolveCnameSchema),
            args: bun.bindgen.Args(DNSResolverResolveCnameSchema),
        ) bun.JSError!void {
            return this.voidFromBinding(.resolve_cname, context, args);
        }

        pub fn bindResolveMx(
            this: *JSBinding,
            context: bun.bindgen.CallContext(DNSResolverResolveMxSchema),
            args: bun.bindgen.Args(DNSResolverResolveMxSchema),
        ) bun.JSError!void {
            return this.voidFromBinding(.resolve_mx, context, args);
        }

        pub fn bindResolveNaptr(
            this: *JSBinding,
            context: bun.bindgen.CallContext(DNSResolverResolveNaptrSchema),
            args: bun.bindgen.Args(DNSResolverResolveNaptrSchema),
        ) bun.JSError!void {
            return this.voidFromBinding(.resolve_naptr, context, args);
        }

        pub fn bindResolveNs(
            this: *JSBinding,
            context: bun.bindgen.CallContext(DNSResolverResolveNsSchema),
            args: bun.bindgen.Args(DNSResolverResolveNsSchema),
        ) bun.JSError!void {
            return this.voidFromBinding(.resolve_ns, context, args);
        }

        pub fn bindResolvePtr(
            this: *JSBinding,
            context: bun.bindgen.CallContext(DNSResolverResolvePtrSchema),
            args: bun.bindgen.Args(DNSResolverResolvePtrSchema),
        ) bun.JSError!void {
            return this.voidFromBinding(.resolve_ptr, context, args);
        }

        pub fn bindResolveSoa(
            this: *JSBinding,
            context: bun.bindgen.CallContext(DNSResolverResolveSoaSchema),
            args: bun.bindgen.Args(DNSResolverResolveSoaSchema),
        ) bun.JSError!void {
            return this.voidFromBinding(.resolve_soa, context, args);
        }

        pub fn bindResolveSrv(
            this: *JSBinding,
            context: bun.bindgen.CallContext(DNSResolverResolveSrvSchema),
            args: bun.bindgen.Args(DNSResolverResolveSrvSchema),
        ) bun.JSError!void {
            return this.voidFromBinding(.resolve_srv, context, args);
        }

        pub fn bindResolveTxt(
            this: *JSBinding,
            context: bun.bindgen.CallContext(DNSResolverResolveTxtSchema),
            args: bun.bindgen.Args(DNSResolverResolveTxtSchema),
        ) bun.JSError!void {
            return this.voidFromBinding(.resolve_txt, context, args);
        }

        pub fn bindReverse(
            this: *JSBinding,
            context: bun.bindgen.CallContext(DNSResolverReverseSchema),
            args: bun.bindgen.Args(DNSResolverReverseSchema),
        ) bun.JSError!void {
            return this.voidFromBinding(.reverse, context, args);
        }

        pub fn bindSetLocalAddress(
            this: *JSBinding,
            context: bun.bindgen.CallContext(DNSResolverSetLocalAddressSchema),
            args: bun.bindgen.Args(DNSResolverSetLocalAddressSchema),
        ) bun.JSError!void {
            return this.voidFromBinding(.set_local_address, context, args);
        }

        pub fn bindSetServers(
            this: *JSBinding,
            context: bun.bindgen.CallContext(DNSResolverSetServersSchema),
            args: bun.bindgen.Args(DNSResolverSetServersSchema),
        ) bun.JSError!void {
            return this.voidFromBinding(.set_servers, context, args);
        }
    };

    pub fn globalLookupService(
        context: bun.bindgen.CallContext(DNSLookupServiceSchema),
        args: bun.bindgen.Args(DNSLookupServiceSchema),
    ) bun.JSError!void {
        return globalVoidFromBinding(.lookup_service, context, args);
    }

    fn globalLookupServiceFromBinding(
        context: anytype,
        args: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!void {
        const globalThis = context.viewToken().globalObject();
        const address = try args.address.toUTF8(bun.default_allocator);
        defer address.deinit();
        const addr_s = address.slice();
        const port = args.port;

        var sa: std.posix.sockaddr.storage = std.mem.zeroes(std.posix.sockaddr.storage);
        if (c_ares.getSockaddr(addr_s, port, @as(*std.posix.sockaddr, @ptrCast(&sa))) != 0) {
            return globalThis.throwNodeError(.ERR_INVALID_IP_ADDRESS, "Invalid IP address: \"{s}\"", .{addr_s});
        }

        const vm = globalThis.bunVM();
        const resolver = try (try vm.tryRareData()).globalDNSResolver(vm);
        const channel = try resolver.getChannelOrError(globalThis);

        const cache_name = try std.fmt.allocPrint(bun.default_allocator, "{s}|{d}", .{ addr_s, port });
        var owns_name = true;
        defer if (owns_name) bun.default_allocator.free(cache_name);

        const key = GetNameInfoRequest.PendingCacheKey.init(cache_name);
        var cache = resolver.getOrPutIntoResolvePendingCache(
            GetNameInfoRequest,
            key,
            "pending_nameinfo_cache_cares",
        );

        var view = context.completion();
        const completion = DnsQueryCompletions.takeForContext(context, &view);

        if (cache == .inflight) {
            const info = CAresNameInfo.init(resolver, globalThis, globalThis.allocator(), cache_name, completion) catch {
                var owned = completion;
                owned.outOfMemory();
                return;
            };
            owns_name = false;
            cache.inflight.append(info);
            return;
        }

        const request = GetNameInfoRequest.init(
            cache,
            resolver,
            cache_name,
            globalThis,
            "pending_nameinfo_cache_cares",
            completion,
        ) catch {
            var owned = completion;
            owned.outOfMemory();
            return;
        };
        owns_name = false;

        resolver.requestSent(globalThis.bunVM());
        channel.getNameInfo(
            @as(*std.posix.sockaddr, @ptrCast(&sa)),
            GetNameInfoRequest,
            request,
            GetNameInfoRequest.onCaresComplete,
        );
    }

    pub fn getRuntimeDefaultResultOrderOption(
        _: bun.bindgen.CallContext(GetRuntimeDefaultResultOrderOptionSchema),
        _: bun.bindgen.Args(GetRuntimeDefaultResultOrderOptionSchema),
    ) bun.JSError!bun.bindgen.Return(GetRuntimeDefaultResultOrderOptionSchema) {
        return switch (jsc.VirtualMachine.get().dns_result_order) {
            .verbatim => .verbatim,
            .ipv4first => .ipv4first,
            .ipv6first => .ipv6first,
        };
    }
};

const string = []const u8;

const std = @import("std");
const Allocator = std.mem.Allocator;

const bun = @import("bun");
const Async = bun.Async;
const Environment = bun.Environment;
const Global = bun.Global;
const Output = bun.Output;
const c_ares = bun.c_ares;
const default_allocator = bun.default_allocator;
const strings = bun.strings;
const timespec = bun.timespec;
const GetAddrInfo = bun.dns.GetAddrInfo;
const libuv = bun.windows.libuv;
const EventLoopTimer = bun.api.Timer.EventLoopTimer;
const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const SocketAddressValue = @import("../socket/SocketAddressValue.zig");
const InternalResolver = @import("../../dns/InternalResolver.zig");

const DNSResolverBindings = bun.bindgen.Module("DNSResolver");
const DNSResolverClassSchema = DNSResolverBindings.class("DNSResolver");
const DNSResolverClass = bun.bindgen.Class(DNSResolverClassSchema, Resolver.JSBinding);
const DNSResolverCancelSchema = DNSResolverClassSchema.member("cancel");
const DNSResolverGetServersSchema = DNSResolverClassSchema.member("getServers");
const DNSResolverResolveSchema = DNSResolverClassSchema.member("resolve");
const DNSResolverResolveAnySchema = DNSResolverClassSchema.member("resolveAny");
const DNSResolverResolveCaaSchema = DNSResolverClassSchema.member("resolveCaa");
const DNSResolverResolveCnameSchema = DNSResolverClassSchema.member("resolveCname");
const DNSResolverResolveMxSchema = DNSResolverClassSchema.member("resolveMx");
const DNSResolverResolveNaptrSchema = DNSResolverClassSchema.member("resolveNaptr");
const DNSResolverResolveNsSchema = DNSResolverClassSchema.member("resolveNs");
const DNSResolverResolvePtrSchema = DNSResolverClassSchema.member("resolvePtr");
const DNSResolverResolveSoaSchema = DNSResolverClassSchema.member("resolveSoa");
const DNSResolverResolveSrvSchema = DNSResolverClassSchema.member("resolveSrv");
const DNSResolverResolveTxtSchema = DNSResolverClassSchema.member("resolveTxt");
const DNSResolverReverseSchema = DNSResolverClassSchema.member("reverse");
const DNSResolverSetLocalAddressSchema = DNSResolverClassSchema.member("setLocalAddress");
const DNSResolverSetServersSchema = DNSResolverClassSchema.member("setServers");
const NodeDNSBindings = bun.bindgen.Module("NodeDNS");
const GetRuntimeDefaultResultOrderOptionSchema = NodeDNSBindings.function("getRuntimeDefaultResultOrderOption");
const NewResolverSchema = NodeDNSBindings.function("newResolver");
const DNSLookupSchema = NodeDNSBindings.function("lookup");
const DNSResolveSchema = NodeDNSBindings.function("resolve");
const DNSResolveSrvSchema = NodeDNSBindings.function("resolveSrv");
const DNSResolveTxtSchema = NodeDNSBindings.function("resolveTxt");
const DNSResolveSoaSchema = NodeDNSBindings.function("resolveSoa");
const DNSResolveNaptrSchema = NodeDNSBindings.function("resolveNaptr");
const DNSResolveMxSchema = NodeDNSBindings.function("resolveMx");
const DNSResolveCaaSchema = NodeDNSBindings.function("resolveCaa");
const DNSResolveNsSchema = NodeDNSBindings.function("resolveNs");
const DNSResolvePtrSchema = NodeDNSBindings.function("resolvePtr");
const DNSResolveCnameSchema = NodeDNSBindings.function("resolveCname");
const DNSResolveAnySchema = NodeDNSBindings.function("resolveAny");
const DNSGetServersSchema = NodeDNSBindings.function("getServers");
const DNSSetServersSchema = NodeDNSBindings.function("setServers");
const DNSReverseSchema = NodeDNSBindings.function("reverse");
const DNSLookupServiceSchema = NodeDNSBindings.function("lookupService");
const DNSAddressResultsType = bun.bindgen.UnionMemberType(DNSResolveSchema.ReturnType, "addresses");
const DNSAddressResults = bun.bindgen.ResultType(DNSAddressResultsType);
const DNSStringResults = bun.bindgen.Return(DNSReverseSchema);
const DNSSrvResults = bun.bindgen.Return(DNSResolveSrvSchema);
const DNSTxtResults = bun.bindgen.Return(DNSResolveTxtSchema);
const DNSSoaResult = bun.bindgen.Return(DNSResolveSoaSchema);
const DNSNaptrResults = bun.bindgen.Return(DNSResolveNaptrSchema);
const DNSMxResults = bun.bindgen.Return(DNSResolveMxSchema);
const DNSCaaResults = bun.bindgen.Return(DNSResolveCaaSchema);
const DNSAnyResults = bun.bindgen.Return(DNSResolveAnySchema);
const DNSLookupResults = bun.bindgen.Return(DNSLookupSchema);
const DNSLookupServiceResult = bun.bindgen.Return(DNSLookupServiceSchema);
const PrefetchSchema = NodeDNSBindings.function("prefetch");
const GetCacheStatsSchema = NodeDNSBindings.function("getCacheStats");
const GetRuntimeDefaultResultOrderOptionBinding = bun.bindgen.Fn(GetRuntimeDefaultResultOrderOptionSchema, Resolver.getRuntimeDefaultResultOrderOption);
const NewResolverBinding = bun.bindgen.Fn(NewResolverSchema, Resolver.newResolver);
const DNSLookupBinding = bun.bindgen.Fn(DNSLookupSchema, Resolver.globalLookup);
const DNSResolveBinding = bun.bindgen.Fn(DNSResolveSchema, Resolver.globalResolve);
const DNSResolveSrvBinding = bun.bindgen.Fn(DNSResolveSrvSchema, Resolver.globalResolveSrv);
const DNSResolveTxtBinding = bun.bindgen.Fn(DNSResolveTxtSchema, Resolver.globalResolveTxt);
const DNSResolveSoaBinding = bun.bindgen.Fn(DNSResolveSoaSchema, Resolver.globalResolveSoa);
const DNSResolveNaptrBinding = bun.bindgen.Fn(DNSResolveNaptrSchema, Resolver.globalResolveNaptr);
const DNSResolveMxBinding = bun.bindgen.Fn(DNSResolveMxSchema, Resolver.globalResolveMx);
const DNSResolveCaaBinding = bun.bindgen.Fn(DNSResolveCaaSchema, Resolver.globalResolveCaa);
const DNSResolveNsBinding = bun.bindgen.Fn(DNSResolveNsSchema, Resolver.globalResolveNs);
const DNSResolvePtrBinding = bun.bindgen.Fn(DNSResolvePtrSchema, Resolver.globalResolvePtr);
const DNSResolveCnameBinding = bun.bindgen.Fn(DNSResolveCnameSchema, Resolver.globalResolveCname);
const DNSResolveAnyBinding = bun.bindgen.Fn(DNSResolveAnySchema, Resolver.globalResolveAny);
const DNSGetServersBinding = bun.bindgen.Fn(DNSGetServersSchema, Resolver.getGlobalServers);
const DNSSetServersBinding = bun.bindgen.Fn(DNSSetServersSchema, Resolver.setGlobalServers);
const DNSReverseBinding = bun.bindgen.Fn(DNSReverseSchema, Resolver.globalReverse);
const DNSLookupServiceBinding = bun.bindgen.Fn(DNSLookupServiceSchema, Resolver.globalLookupService);
const PrefetchBinding = bun.bindgen.Fn(PrefetchSchema, prefetchFromJS);
const GetCacheStatsBinding = bun.bindgen.Fn(GetCacheStatsSchema, getDNSCacheStats);

comptime {
    _ = DNSResolverClass;
    _ = NewResolverBinding;
    _ = GetRuntimeDefaultResultOrderOptionBinding;
    _ = DNSLookupBinding;
    _ = DNSResolveBinding;
    _ = DNSResolveSrvBinding;
    _ = DNSResolveTxtBinding;
    _ = DNSResolveSoaBinding;
    _ = DNSResolveNaptrBinding;
    _ = DNSResolveMxBinding;
    _ = DNSResolveCaaBinding;
    _ = DNSResolveNsBinding;
    _ = DNSResolvePtrBinding;
    _ = DNSResolveCnameBinding;
    _ = DNSResolveAnyBinding;
    _ = DNSGetServersBinding;
    _ = DNSSetServersBinding;
    _ = DNSReverseBinding;
    _ = DNSLookupServiceBinding;
    _ = PrefetchBinding;
    _ = GetCacheStatsBinding;
}
