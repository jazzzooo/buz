const RareData = @This();

io: std.Io,

websocket_deflate: ?*WebSocketDeflate.RareData = null,
boring_ssl_engine: ?*BoringSSL.ENGINE = null,
editor_context: EditorContext = EditorContext{},
stderr_store: ?*Blob.Store = null,
stdin_store: ?*Blob.Store = null,
stdout_store: ?*Blob.Store = null,

mysql_context: bun.api.MySQL.MySQLContext = .{},
postgresql_context: bun.api.Postgres.PostgresSQLContext = .{},

entropy_cache: ?*EntropyCache = null,

hot_map: ?HotMap = null,
cron_jobs: std.ArrayListUnmanaged(*bun.api.cron.CronJob) = .empty,

// TODO: make this per JSGlobalObject instead of global
// This does not handle ShadowRealm correctly!
cleanup_hooks: std.ArrayListUnmanaged(CleanupHook) = .empty,
native_completion_registry_head: ?*jsc.NativeCompletionRegistry = null,
native_finalizer_queue: jsc.NativeFinalizerQueue = undefined,
webview_chrome_process: ?*@import("../runtime/webview/ProcessWatcher.zig") = null,
webview_host_process: ?*@import("../runtime/webview/ProcessWatcher.zig") = null,

file_polls_: ?*Async.FilePoll.Store = null,

global_dns_resolver: ?*bun.api.dns.Resolver = null,
dns_resolver_head: ?*bun.api.dns.Resolver = null,

/// Embedded socket groups for kinds that aren't tied to a Listener / server.
/// Lazily linked into the loop on first socket; never separately allocated.
spawn_ipc_group: uws.SocketGroup = .{},
/// `bun test --parallel` IPC channel (worker ↔ coordinator). Survives the
/// per-file isolation swap so the worker keeps its link to the coordinator.
test_parallel_ipc_group: uws.SocketGroup = .{},
/// `Bun.connect` client sockets — one group per VM (not per connection).
bun_connect_group_tcp: uws.SocketGroup = .{},
bun_connect_group_tls: uws.SocketGroup = .{},
/// SQL drivers — TCP and TLS share one group each per VM. STARTTLS adopts
/// from the `_tcp` group into `_tls` without reallocating a context.
postgres_group: uws.SocketGroup = .{},
postgres_tls_group: uws.SocketGroup = .{},
mysql_group: uws.SocketGroup = .{},
mysql_tls_group: uws.SocketGroup = .{},
valkey_group: uws.SocketGroup = .{},
valkey_tls_group: uws.SocketGroup = .{},
/// `new WebSocket(...)` client. Upgrade phase (HTTP handshake) and connected
/// phase (frame I/O) live in separate kinds so the handshake handler doesn't
/// have to runtime-branch on state.
ws_upgrade_group: uws.SocketGroup = .{},
ws_upgrade_tls_group: uws.SocketGroup = .{},
ws_client_group: uws.SocketGroup = .{},
ws_client_tls_group: uws.SocketGroup = .{},
/// Weak digest→`SSL_CTX*` cache. Every JS-thread consumer that turns an
/// `SSLConfig` into an `SSL_CTX*` goes through here so identical configs
/// share one CTX (Postgres pool, Valkey, `Bun.connect`, `tls.connect`, …).
ssl_ctx_cache: api.SSLContextCache,

/// `ssl_ctx_cache.getOrCreate(&.{})` — i.e. the default-trust-store client
/// CTX. Cached separately so the hot `tls:true` / `wss://` path skips even the
/// SHA-256 + map lookup. Ref owned here.
default_client_ssl_ctx: ?*uws.SslCtx = null,

mime_types: ?bun.http.MimeType.Map = null,

fs_watchers_for_isolation: std.ArrayListUnmanaged(*FSWatcher) = .empty,
stat_watchers_for_isolation: std.ArrayListUnmanaged(*StatWatcher) = .empty,

temp_pipe_read_buffer: ?*PipeReadBuffer = null,

default_csrf_secret: []const u8 = "",

valkey_context: ValkeyContext = .{},

tls_default_ciphers: ?[:0]const u8 = null,

// proxy_env_storage moved to VirtualMachine — see comment there on why
// lazy RareData creation raced with worker spawn.

spawn_sync_event_loop: bun.ptr.Owned(?*SpawnSyncEventLoop) = .initNull(),

path_buf: PathBuf = .{},

/// Reusable heap buffer for path.resolve, path.relative, and path.toNamespacedPath.
/// Three fixed-size tiers, lazily allocated on first use. Safe because JS is single-threaded.
/// The buffer backs a BufferFirstAllocator, which falls back when it is exhausted.
pub const PathBuf = struct {
    const S = bun.MAX_PATH_BYTES;
    const SmallBuf = [2 * S]u8;
    const MediumBuf = [8 * S]u8;
    const LargeBuf = [32 * S]u8;

    small: ?*SmallBuf = null,
    medium: ?*MediumBuf = null,
    large: ?*LargeBuf = null,

    /// Returns a BufferFirstAllocator backed by the smallest tier that
    /// fits `min_len`, falling back to `fallback` when the buffer is exhausted.
    pub fn get(self: *PathBuf, min_len: usize, fallback: std.mem.Allocator) std.heap.BufferFirstAllocator {
        const buf: []u8 = if (min_len <= 2 * S)
            (self.small orelse blk: {
                self.small = bun.handleOom(bun.default_allocator.create(SmallBuf));
                break :blk self.small.?;
            })
        else if (min_len <= 8 * S)
            (self.medium orelse blk: {
                self.medium = bun.handleOom(bun.default_allocator.create(MediumBuf));
                break :blk self.medium.?;
            })
        else
            (self.large orelse blk: {
                self.large = bun.handleOom(bun.default_allocator.create(LargeBuf));
                break :blk self.large.?;
            });
        return .init(buf, fallback);
    }

    pub fn deinit(self: *PathBuf) void {
        if (self.small) |p| {
            bun.default_allocator.destroy(p);
            self.small = null;
        }
        if (self.medium) |p| {
            bun.default_allocator.destroy(p);
            self.medium = null;
        }
        if (self.large) |p| {
            bun.default_allocator.destroy(p);
            self.large = null;
        }
    }
};

const PipeReadBuffer = [256 * 1024]u8;
pub const ProxyEnvStorage = struct {
    HTTP_PROXY: ?*RefCountedEnvValue = null,
    http_proxy: ?*RefCountedEnvValue = null,
    HTTPS_PROXY: ?*RefCountedEnvValue = null,
    https_proxy: ?*RefCountedEnvValue = null,
    NO_PROXY: ?*RefCountedEnvValue = null,
    no_proxy: ?*RefCountedEnvValue = null,

    /// Held by proxy-environment writes around the slot swap + env.map.put, and by
    /// the worker around cloneFrom + env.map.cloneWithAllocator. This closes
    /// two races: (1) worker's cloneFrom reading a slot pointer concurrently
    /// with the parent's deref → free on the same pointer; (2) the env.map's
    /// backing ArrayHashMap being iterated during clone while the parent's
    /// put() rehashes it.
    lock: std.Io.Mutex = .init,

    pub const Slot = struct {
        /// Static-lifetime field name (e.g. "NO_PROXY") — safe to use as
        /// the env map key without duping.
        key: []const u8,
        ptr: *?*RefCountedEnvValue,
    };

    pub fn slot(self: *ProxyEnvStorage, name: []const u8) ?Slot {
        // On Windows the env.map is case-insensitive (CaseInsensitiveASCII-
        // StringArrayHashMap) — map.put("HTTP_PROXY", ...) and
        // map.put("http_proxy", ...) write the same entry. If we tracked
        // refs in separate case-variant slots, one slot's value would leak
        // and syncInto would replay the stale one into the worker's map.
        // Canonicalize both cases to the uppercase slot on Windows; the
        // lowercase slots stay null. Posix keeps both — its map and its
        // getHttpProxy lookup are case-sensitive.
        const eql = if (comptime bun.Environment.isWindows)
            bun.strings.eqlCaseInsensitiveASCIIICheckLength
        else
            bun.strings.eql;
        const info = @typeInfo(ProxyEnvStorage).@"struct";
        inline for (info.field_names, info.field_types) |field_name, FieldType| {
            if (comptime FieldType == ?*RefCountedEnvValue) {
                // Uppercase fields are declared first. On Windows the
                // case-insensitive eql matches the uppercase field for
                // either input case and returns before reaching lowercase.
                if (eql(name, field_name)) {
                    return .{ .key = field_name, .ptr = &@field(self, field_name) };
                }
            }
        }
        return null;
    }

    /// Bump refcounts on all non-null values so a worker can share the
    /// parent's strings. Caller must hold parent.lock — the pointer load
    /// and ref() are not atomic with respect to a proxy-environment overwrite.
    pub fn cloneFrom(self: *ProxyEnvStorage, parent: *const ProxyEnvStorage) void {
        const info = @typeInfo(ProxyEnvStorage).@"struct";
        inline for (info.field_names, info.field_types) |field_name, FieldType| {
            if (comptime FieldType == ?*RefCountedEnvValue) {
                if (@field(parent, field_name)) |val| {
                    val.ref();
                    @field(self, field_name) = val;
                }
            }
        }
    }

    pub fn deinit(self: *ProxyEnvStorage) void {
        const info = @typeInfo(ProxyEnvStorage).@"struct";
        inline for (info.field_names, info.field_types) |field_name, FieldType| {
            if (comptime FieldType == ?*RefCountedEnvValue) {
                if (@field(self, field_name)) |val| {
                    val.deref();
                    @field(self, field_name) = null;
                }
            }
        }
    }
};

/// A ref-counted heap-allocated byte slice. The env map stores borrowed
/// `.bytes` slices; as long as any VM holds a ref, the bytes stay valid.
pub const RefCountedEnvValue = struct {
    const RefCount = bun.ptr.ThreadSafeRefCount(@This(), "ref_count", RefCountedEnvValue.destroy, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;

    ref_count: RefCount,
    bytes: []const u8,

    pub fn create(value: []const u8) bun.OOM!*RefCountedEnvValue {
        const bytes = try bun.default_allocator.dupe(u8, value);
        errdefer bun.default_allocator.free(bytes);
        const result = try bun.default_allocator.create(RefCountedEnvValue);
        result.* = .{
            .ref_count = .init(),
            .bytes = bytes,
        };
        return result;
    }

    fn destroy(this: *RefCountedEnvValue) void {
        bun.default_allocator.free(this.bytes);
        bun.default_allocator.destroy(this);
    }
};

pub fn pipeReadBuffer(this: *RareData) *PipeReadBuffer {
    return this.temp_pipe_read_buffer orelse {
        this.temp_pipe_read_buffer = bun.handleOom(default_allocator.create(PipeReadBuffer));
        return this.temp_pipe_read_buffer.?;
    };
}

pub fn addFSWatcherForIsolation(this: *RareData, watcher: *FSWatcher) bun.OOM!void {
    try this.fs_watchers_for_isolation.append(bun.default_allocator, watcher);
}

pub fn removeFSWatcherForIsolation(this: *RareData, watcher: *FSWatcher) void {
    if (std.mem.indexOfScalar(*FSWatcher, this.fs_watchers_for_isolation.items, watcher)) |i| {
        _ = this.fs_watchers_for_isolation.swapRemove(i);
    }
}

pub fn addStatWatcherForIsolation(this: *RareData, watcher: *StatWatcher) bun.OOM!void {
    try this.stat_watchers_for_isolation.append(bun.default_allocator, watcher);
}

pub fn removeStatWatcherForIsolation(this: *RareData, watcher: *StatWatcher) void {
    if (std.mem.indexOfScalar(*StatWatcher, this.stat_watchers_for_isolation.items, watcher)) |i| {
        _ = this.stat_watchers_for_isolation.swapRemove(i);
    }
}

pub fn closeAllWatchersForIsolation(this: *RareData) void {
    while (this.fs_watchers_for_isolation.pop()) |watcher| {
        watcher.closeWithoutEmit();
    }
    while (this.stat_watchers_for_isolation.pop()) |watcher| {
        watcher.close();
    }
}

pub fn hotMap(this: *RareData, allocator: std.mem.Allocator) *HotMap {
    if (this.hot_map == null) {
        this.hot_map = HotMap.init(allocator);
    }

    return &this.hot_map.?;
}

pub fn mimeTypeFromString(this: *RareData, allocator: std.mem.Allocator, str: []const u8) ?bun.http.MimeType {
    if (this.mime_types == null) {
        this.mime_types = bun.http.MimeType.createHashTable(
            allocator,
        ) catch |err| bun.handleOom(err);
    }

    if (this.mime_types.?.get(str)) |entry| {
        return bun.http.MimeType.Compact.from(entry).toMimeType();
    }

    return null;
}

pub const HotMap = struct {
    _map: bun.StringArrayHashMap(Entry) = .empty,
    allocator: std.mem.Allocator,

    const HTTPServer = jsc.API.HTTPServer;
    const HTTPSServer = jsc.API.HTTPSServer;
    const TCPSocket = jsc.API.TCPSocket;
    const TLSSocket = jsc.API.TLSSocket;
    const Listener = jsc.API.Listener;
    const Entry = bun.TaggedPointerUnion(.{
        HTTPServer,
        HTTPSServer,
        TCPSocket,
        TLSSocket,
        Listener,
    });

    pub fn init(allocator: std.mem.Allocator) HotMap {
        return .{ .allocator = allocator };
    }

    pub fn get(this: *HotMap, key: []const u8, comptime Type: type) ?*Type {
        var entry = this._map.get(key) orelse return null;
        return entry.get(Type);
    }

    pub fn getEntry(this: *HotMap, key: []const u8) ?Entry {
        return this._map.get(key) orelse return null;
    }

    pub fn insert(this: *HotMap, key: []const u8, ptr: anytype) bun.OOM!void {
        const owned_key = try this.allocator.dupe(u8, key);
        errdefer this.allocator.free(owned_key);
        const entry = try this._map.getOrPut(this.allocator, owned_key);
        if (entry.found_existing) {
            @panic("HotMap already contains key");
        }

        entry.key_ptr.* = owned_key;
        entry.value_ptr.* = Entry.init(ptr);
    }

    pub fn remove(this: *HotMap, key: []const u8) void {
        const entry = this._map.getEntry(key) orelse return;
        const key_to_free = entry.key_ptr.*;
        const is_same_slice = key_to_free.ptr == key.ptr and key_to_free.len == key.len;
        _ = this._map.orderedRemove(key);
        bun.debugAssert(!is_same_slice);
        this.allocator.free(key_to_free);
    }
};

pub fn filePolls(this: *RareData, vm: *jsc.VirtualMachine) *Async.FilePoll.Store {
    return bun.handleOom(this.tryFilePolls(vm));
}

pub fn tryFilePolls(this: *RareData, vm: *jsc.VirtualMachine) bun.OOM!*Async.FilePoll.Store {
    return this.file_polls_ orelse {
        this.file_polls_ = try vm.allocator.create(Async.FilePoll.Store);
        this.file_polls_.?.* = Async.FilePoll.Store.init();
        return this.file_polls_.?;
    };
}

pub fn nextUUID(this: *RareData) UUID {
    if (this.entropy_cache == null) {
        this.entropy_cache = default_allocator.create(EntropyCache) catch unreachable;
        this.entropy_cache.?.init();
    }

    const bytes = this.entropy_cache.?.get();
    return UUID.initWith(&bytes);
}

pub fn entropySlice(this: *RareData, len: usize) []u8 {
    if (this.entropy_cache == null) {
        this.entropy_cache = default_allocator.create(EntropyCache) catch unreachable;
        this.entropy_cache.?.init();
    }

    return this.entropy_cache.?.slice(len);
}

pub fn fillEntropy(this: *RareData, destination: []u8) void {
    switch (destination.len) {
        0 => {},
        1...EntropyCache.size / 8 => bun.copy(u8, destination, this.entropySlice(destination.len)),
        else => bun.csprng(destination),
    }
}

pub const EntropyCache = struct {
    pub const buffered_uuids_count = 16;
    pub const size = buffered_uuids_count * 128;

    cache: [size]u8 = undefined,
    index: usize = 0,

    pub fn init(instance: *EntropyCache) void {
        instance.fill();
    }

    pub fn fill(this: *EntropyCache) void {
        bun.csprng(&this.cache);
        this.index = 0;
    }

    pub fn slice(this: *EntropyCache, len: usize) []u8 {
        if (len > this.cache.len) {
            return &[_]u8{};
        }

        if (this.index + len > this.cache.len) {
            this.fill();
        }
        const result = this.cache[this.index..][0..len];
        this.index += len;
        return result;
    }

    pub fn get(this: *EntropyCache) [16]u8 {
        if (this.index + 16 > this.cache.len) {
            this.fill();
        }
        const result = this.cache[this.index..][0..16].*;
        this.index += 16;
        return result;
    }
};

pub const CleanupHook = struct {
    ctx: ?*anyopaque,
    func: Function,
    globalThis: *jsc.JSGlobalObject,

    pub fn eql(self: CleanupHook, other: CleanupHook) bool {
        return self.ctx == other.ctx and self.func == other.func and self.globalThis == other.globalThis;
    }

    pub fn execute(self: CleanupHook) void {
        self.func(self.ctx);
    }

    pub fn init(
        globalThis: *jsc.JSGlobalObject,
        ctx: ?*anyopaque,
        func: CleanupHook.Function,
    ) CleanupHook {
        return .{
            .ctx = ctx,
            .func = func,
            .globalThis = globalThis,
        };
    }

    pub const Function = *const fn (?*anyopaque) callconv(.c) void;
};

pub fn pushCleanupHook(
    this: *RareData,
    globalThis: *jsc.JSGlobalObject,
    ctx: ?*anyopaque,
    func: CleanupHook.Function,
) void {
    bun.handleOom(this.cleanup_hooks.append(bun.default_allocator, CleanupHook.init(globalThis, ctx, func)));
}

pub fn nativeCompletionRegistry(
    this: *RareData,
    vm: *jsc.VirtualMachine,
) bun.OOM!*jsc.NativeCompletionRegistry {
    return this.nativeCompletionRegistryForLoop(vm, vm.eventLoop());
}

pub fn nativeCompletionRegistryForLoop(
    this: *RareData,
    vm: *jsc.VirtualMachine,
    loop: *jsc.EventLoop,
) bun.OOM!*jsc.NativeCompletionRegistry {
    bun.assert(loop.virtual_machine == vm);
    const registry = loop.native_completion_registry orelse create: {
        const value = try @import("./NativeCompletionRegistryEngine.zig").create(loop);
        value.registry_next = this.native_completion_registry_head;
        if (this.native_completion_registry_head) |head| head.registry_previous = value;
        this.native_completion_registry_head = value;
        loop.native_completion_registry = value;
        break :create value;
    };
    if (vm.isShuttingDown()) this.closeNativeCompletions();
    return registry;
}

pub fn closeNativeCompletions(this: *RareData) void {
    var current = this.native_completion_registry_head;
    while (current) |registry| {
        current = registry.registry_next;
        registry.beginClose();
    }
    current = this.native_completion_registry_head;
    while (current) |registry| {
        current = registry.registry_next;
        registry.close();
    }
}

pub fn resetNativeCompletions(this: *RareData) void {
    var current = this.native_completion_registry_head;
    while (current) |registry| {
        current = registry.registry_next;
        registry.beginReset();
    }
    current = this.native_completion_registry_head;
    while (current) |registry| {
        current = registry.registry_next;
        registry.finishReset();
    }
}

pub fn unregisterNativeCompletionRegistry(this: *RareData, registry: *jsc.NativeCompletionRegistry) void {
    if (registry.registry_previous) |previous| {
        previous.registry_next = registry.registry_next;
    } else {
        bun.assert(this.native_completion_registry_head == registry);
        this.native_completion_registry_head = registry.registry_next;
    }
    if (registry.registry_next) |next| next.registry_previous = registry.registry_previous;
    registry.registry_previous = null;
    registry.registry_next = null;
}

pub fn nativeFinalizerQueue(this: *RareData) *jsc.NativeFinalizerQueue {
    return &this.native_finalizer_queue;
}

pub fn drainNativeFinalizers(this: *RareData) void {
    this.native_finalizer_queue.drain();
}

pub fn closeNativeFinalizers(this: *RareData) void {
    this.native_finalizer_queue.close();
}

pub fn boringEngine(rare: *RareData) *BoringSSL.ENGINE {
    return rare.boring_ssl_engine orelse brk: {
        rare.boring_ssl_engine = BoringSSL.ENGINE_new();
        break :brk rare.boring_ssl_engine.?;
    };
}

pub fn stdio(rare: *RareData, kind: bun.FD.Stdio) bun.OOM!*Blob.Store {
    const cache = switch (kind) {
        .std_in => blk: {
            bun.analytics.Features.@"Bun.stdin" += 1;
            break :blk &rare.stdin_store;
        },
        .std_out => blk: {
            bun.analytics.Features.@"Bun.stdout" += 1;
            break :blk &rare.stdout_store;
        },
        .std_err => blk: {
            bun.analytics.Features.@"Bun.stderr" += 1;
            break :blk &rare.stderr_store;
        },
    };
    if (cache.*) |store| return store;
    const fd = kind.fd();
    const is_atty = switch (kind) {
        .std_in => if (fd.unwrapValid()) |valid| bun.sys.isatty(valid) else false,
        .std_out => Output.stdout_descriptor_type == .terminal,
        .std_err => Output.stderr_descriptor_type == .terminal,
    };
    const store = try Blob.Store.initStdio(fd, is_atty);
    cache.* = store;
    return store;
}

pub fn spawnIPCGroup(rare: *RareData, vm: *jsc.VirtualMachine) *uws.SocketGroup {
    if (rare.spawn_ipc_group.loop == null) {
        rare.spawn_ipc_group.init(vm.uwsLoop(), socket_vtable.make(SocketHandlers.SpawnIPC), null);
    }
    return &rare.spawn_ipc_group;
}

const SocketHandlers = @import("../runtime/socket/UwsHandlersEngine.zig");
const socket_vtable = @import("../uws_sys/vtable.zig");

pub fn testParallelIPCGroup(rare: *RareData, vm: *jsc.VirtualMachine, vtable: *const uws.SocketGroup.VTable) *uws.SocketGroup {
    if (rare.test_parallel_ipc_group.loop == null) {
        rare.test_parallel_ipc_group.init(vm.uwsLoop(), vtable, null);
    }
    bun.assert(rare.test_parallel_ipc_group.vtable == vtable);
    return &rare.test_parallel_ipc_group;
}

/// One shared group per (VM, ssl) for every `Bun.connect` / `tls.connect`
/// client socket. Replaces the old per-connection `us_socket_context_t`
/// allocation that was the root of the SSL_CTX-per-connect leak.
pub fn bunConnectGroup(rare: *RareData, vm: *jsc.VirtualMachine, comptime ssl: bool) *uws.SocketGroup {
    const g = if (ssl) &rare.bun_connect_group_tls else &rare.bun_connect_group_tcp;
    if (g.loop == null) g.init(vm.uwsLoop(), SocketHandlers.socketCallbacks(ssl), null);
    return g;
}

inline fn lazyGroup(rare: *RareData, vm: *jsc.VirtualMachine, comptime field: []const u8, comptime Handler: type) *uws.SocketGroup {
    const g = &@field(rare, field);
    if (g.loop == null) g.init(vm.uwsLoop(), socket_vtable.make(Handler), null);
    return g;
}

pub fn postgresGroup(rare: *RareData, vm: *jsc.VirtualMachine, comptime ssl: bool) *uws.SocketGroup {
    return rare.lazyGroup(vm, if (ssl) "postgres_tls_group" else "postgres_group", SocketHandlers.Postgres(ssl));
}
pub fn mysqlGroup(rare: *RareData, vm: *jsc.VirtualMachine, comptime ssl: bool) *uws.SocketGroup {
    return rare.lazyGroup(vm, if (ssl) "mysql_tls_group" else "mysql_group", SocketHandlers.MySQL(ssl));
}
pub fn valkeyGroup(rare: *RareData, vm: *jsc.VirtualMachine, comptime ssl: bool) *uws.SocketGroup {
    return rare.lazyGroup(vm, if (ssl) "valkey_tls_group" else "valkey_group", SocketHandlers.Valkey(ssl));
}
pub fn wsUpgradeGroup(rare: *RareData, vm: *jsc.VirtualMachine, comptime ssl: bool) *uws.SocketGroup {
    return rare.lazyGroup(vm, if (ssl) "ws_upgrade_tls_group" else "ws_upgrade_group", SocketHandlers.WSUpgrade(ssl));
}
pub fn wsClientGroup(rare: *RareData, vm: *jsc.VirtualMachine, comptime ssl: bool) *uws.SocketGroup {
    return rare.lazyGroup(vm, if (ssl) "ws_client_tls_group" else "ws_client_group", SocketHandlers.WSClient(ssl));
}

pub fn sslCtxCache(rare: *RareData) *api.SSLContextCache {
    return &rare.ssl_ctx_cache;
}

/// The VM owns the reference returned to clients without a custom TLS configuration.
pub fn defaultClientSslCtx(rare: *RareData, failure: *uws.TLSContextFailure) ?*uws.SslCtx {
    failure.* = .{};
    if (rare.default_client_ssl_ctx == null) {
        // Mode-neutral CTX (VERIFY_NONE). `us_internal_ssl_attach` overrides
        // each client SSL to VERIFY_PEER + the shared bundled-root store, so
        // `new WebSocket("wss://…")` (which shares this CTX and defaults to
        // rejectUnauthorized:true) verifies real servers. Route through the
        // context cache so a `tls.connect()` with default options later resolves
        // to the same CTX rather than building a second one with the same
        // digest. This reference remains owned by the VM even if the cache evicts its entry.
        rare.default_client_ssl_ctx = rare.ssl_ctx_cache.getOrCreateOpts(.{}, failure) orelse return null;
    }
    return rare.default_client_ssl_ctx.?;
}

pub fn globalDNSResolver(rare: *RareData, vm: *jsc.VirtualMachine) bun.OOM!*api.dns.Resolver {
    if (rare.global_dns_resolver) |resolver| return resolver;
    const resolver = try api.dns.Resolver.init(vm.allocator, vm);
    rare.global_dns_resolver = resolver;
    return resolver;
}

pub fn registerDNSResolver(this: *RareData, resolver: *api.dns.Resolver) void {
    resolver.registry_previous = null;
    resolver.registry_next = this.dns_resolver_head;
    if (this.dns_resolver_head) |head| head.registry_previous = resolver;
    this.dns_resolver_head = resolver;
}

pub fn unregisterDNSResolver(this: *RareData, resolver: *api.dns.Resolver) void {
    if (resolver.registry_previous) |previous| {
        previous.registry_next = resolver.registry_next;
    } else {
        bun.assert(this.dns_resolver_head == resolver);
        this.dns_resolver_head = resolver.registry_next;
    }
    if (resolver.registry_next) |next| next.registry_previous = resolver.registry_previous;
    resolver.registry_previous = null;
    resolver.registry_next = null;
}

pub fn closeDNSResolvers(this: *RareData) void {
    var current = this.dns_resolver_head;
    if (current) |resolver| resolver.ref();
    while (current) |resolver| {
        const next = resolver.registry_next;
        if (next) |value| value.ref();
        resolver.shutdown();
        resolver.deref();
        current = next;
    }
    if (this.global_dns_resolver) |resolver| {
        this.global_dns_resolver = null;
        resolver.deref();
    }
}

pub fn tlsDefaultCiphers(this: *RareData) ?[:0]const u8 {
    return this.tls_default_ciphers orelse null;
}

pub fn setTLSDefaultCiphers(this: *RareData, ciphers: []const u8) void {
    if (this.tls_default_ciphers) |old_ciphers| {
        bun.default_allocator.free(old_ciphers);
    }
    this.tls_default_ciphers = bun.handleOom(bun.default_allocator.dupeSentinel(u8, ciphers, 0));
}

pub fn defaultCSRFSecret(this: *RareData) bun.OOM![]const u8 {
    if (this.default_csrf_secret.len == 0) {
        const secret = try bun.default_allocator.alloc(u8, 16);
        bun.csprng(secret);
        this.default_csrf_secret = secret;
    }
    return this.default_csrf_secret;
}

pub fn deinit(this: *RareData) void {
    bun.assert(this.global_dns_resolver == null);
    inline for (.{ "stdin_store", "stdout_store", "stderr_store" }) |field| {
        if (@field(this, field)) |store| {
            @field(this, field) = null;
            store.deref();
        }
    }
    bun.debugAssert(this.native_finalizer_queue.isClosed());
    this.closeNativeFinalizers();
    if (this.temp_pipe_read_buffer) |pipe| {
        this.temp_pipe_read_buffer = null;
        bun.default_allocator.destroy(pipe);
    }

    this.spawn_sync_event_loop.deinit();
    bun.assert(this.native_completion_registry_head == null);
    if (this.boring_ssl_engine) |engine| {
        _ = bun.BoringSSL.c.ENGINE_free(engine);
    }
    if (this.default_csrf_secret.len > 0) {
        bun.default_allocator.free(this.default_csrf_secret);
    }

    this.cleanup_hooks.clearAndFree(bun.default_allocator);
    bun.debugAssert(this.cron_jobs.items.len == 0);
    this.cron_jobs.deinit(bun.default_allocator);
    this.editor_context.deinit();
    this.path_buf.deinit();

    if (this.websocket_deflate) |deflate| {
        this.websocket_deflate = null;
        deflate.deinit();
    }

    if (this.tls_default_ciphers) |ciphers| {
        this.tls_default_ciphers = null;
        bun.default_allocator.free(ciphers);
    }

    this.valkey_context.deinit();

    if (this.default_client_ssl_ctx) |s| bun.BoringSSL.c.SSL_CTX_free(s);
    // After the default-ctx free so the tombstone callback still finds a live
    // map; deinit then clears every remaining entry's ex_data so any later
    // SSL_CTX_free (from sockets that survive RareData) doesn't deref freed
    // Entries.
    this.ssl_ctx_cache.deinit();
    // closeAllSocketGroups() must have already run (before JSC teardown) so
    // these are empty; deinit() asserts that in debug.
    inline for (socket_group_fields) |f| @field(this, f).deinit();
}

const socket_group_fields = .{
    "bun_connect_group_tcp", "bun_connect_group_tls",
    "spawn_ipc_group",       "test_parallel_ipc_group",
    "postgres_group",        "postgres_tls_group",
    "mysql_group",           "mysql_tls_group",
    "valkey_group",          "valkey_tls_group",
    "ws_upgrade_group",      "ws_upgrade_tls_group",
    "ws_client_group",       "ws_client_tls_group",
};

/// Drain every embedded socket group. Must run BEFORE JSC teardown — closeAll
/// fires on_close → JS callbacks → needs a live VM. RareData.deinit() runs
/// after the worker JSC teardown (web_worker.zig), so doing the closeAll
/// there would dispatch into freed JSC heap.
pub fn closeAllSocketGroups(this: *RareData, vm: *jsc.VirtualMachine) void {
    // closeAll() dispatches on_close into JS while the VM is still alive, so a
    // handler can call Bun.connect/postgres/etc. and re-populate a group we
    // just drained. Loop until every group is observed empty in the same pass
    // (bounded — each retry only happens if a JS callback opened a *new*
    // socket, and the cap stops a deliberately-spinning on_close from wedging
    // teardown; the post-close force-drain in close_all handles whatever's
    // left after the cap).
    // Walk the loop's linked-group list rather than just our 14 embedded
    // fields: Listener/uWS-App groups own their own SocketGroup, and accepted
    // sockets land *there*, not in RareData. Iterating only `socket_group_fields`
    // missed those, leaking one 88-byte us_socket_t per still-open accepted
    // connection at process.exit() (the LSAN cluster on #29932 build 49245).
    _ = this;
    const loop = vm.uwsLoop();
    var rounds: u8 = 0;
    while (rounds < 8) : (rounds += 1) {
        if (!loop.closeAllGroups()) break;
    }
    // us_socket_close pushes to loop->data.closed_head; loop_post() normally
    // frees it on the next tick. We're past the last tick, so drain it now —
    // every us_socket_t is libc-allocated and otherwise becomes an LSAN leak
    // (the only pointer into it lives in mimalloc-backed RareData, which LSAN
    // can't trace once we unregister the root region).
    vm.uwsLoop().drainClosedSockets();
}

pub fn websocketDeflate(this: *RareData) *WebSocketDeflate.RareData {
    return this.websocket_deflate orelse brk: {
        this.websocket_deflate = bun.new(WebSocketDeflate.RareData, .{});
        break :brk this.websocket_deflate.?;
    };
}

pub const SpawnSyncEventLoop = @import("../event_loop/SpawnSyncEventLoopEngine.zig");

pub const SpawnSyncLoopResult = union(enum) { loop: *SpawnSyncEventLoop, failed: bun.uws.PollFailure };

pub fn spawnSyncEventLoop(this: *RareData, vm: *jsc.VirtualMachine) bun.OOM!SpawnSyncLoopResult {
    if (this.spawn_sync_event_loop.get()) |loop| return .{ .loop = loop };
    var owner = try @TypeOf(this.spawn_sync_event_loop).alloc(undefined);
    const ptr: *SpawnSyncEventLoop = owner.get().?;
    if (ptr.init(vm)) |failure| {
        owner.deinitShallow();
        return .{ .failed = failure };
    }
    this.spawn_sync_event_loop = owner;
    return .{ .loop = ptr };
}

const UUID = @import("../bun_core/UUID.zig");
const WebSocketDeflate = @import("../http_jsc/websocket_client/WebSocketDeflate.zig");
const std = @import("std");
const EditorContext = @import("../cli/open.zig").EditorContext;
const FSWatcher = @import("../runtime/node/FSWatcherEngine.zig").FSWatcher;
const ValkeyContext = @import("../runtime/valkey_jsc/valkey.zig").ValkeyContext;

const StatWatcher = @import("../runtime/node/StatWatcherEngine.zig").StatWatcher;
const bun = @import("bun");
const Async = bun.Async;
const Output = bun.Output;
const api = bun.api;
const default_allocator = bun.default_allocator;
const jsc = bun.jsc;
const uws = bun.uws;
const BoringSSL = bun.BoringSSL.c;
const Blob = jsc.WebCore.Blob;
