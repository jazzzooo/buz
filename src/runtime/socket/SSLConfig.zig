const SSLConfig = @This();

server_name: ?[:0]const u8 = null,

key_file_name: ?[:0]const u8 = null,
cert_file_name: ?[:0]const u8 = null,

ca_file_name: ?[:0]const u8 = null,
dh_params_file_name: ?[:0]const u8 = null,

passphrase: ?[:0]const u8 = null,

key: ?PEMList = null,
cert: ?PEMList = null,
ca: ?PEMList = null,

secure_options: u32 = 0,
request_cert: i32 = 0,
reject_unauthorized: i32 = 0,
ssl_ciphers: ?[:0]const u8 = null,
protos: ?[]const u8 = null,
client_renegotiation_limit: u32 = 0,
client_renegotiation_window: u32 = 0,
requires_custom_request_ctx: bool = false,
is_using_default_ciphers: bool = true,
low_memory_mode: bool = false,
cached_hash: u64 = 0,
registry_io: ?std.Io = null,

pub const PEMList = struct {
    // Separate pointer and length arrays preserve allocation sizes while exposing
    // the contiguous C-string pointer table required by the TLS library.
    entries: std.MultiArrayList(struct { ptr: [*:0]const u8, len: usize }) = .empty,

    pub fn initCapacity(capacity: usize) bun.OOM!PEMList {
        var result: PEMList = .{};
        try result.entries.ensureTotalCapacity(bun.default_allocator, capacity);
        return result;
    }

    pub fn appendAssumeCapacity(this: *PEMList, value: [:0]const u8) void {
        this.entries.appendAssumeCapacity(.{ .ptr = value.ptr, .len = value.len });
    }

    pub fn reverse(this: *PEMList) void {
        const entries = this.entries.slice();
        for (0..entries.len / 2) |index| entries.swap(index, entries.len - index - 1);
    }

    fn get(this: *const PEMList, index: usize) [:0]const u8 {
        const entry = this.entries.get(index);
        return entry.ptr[0..entry.len :0];
    }

    pub fn deinit(this: *PEMList) void {
        for (0..this.entries.len) |index| bun.freeSensitive(bun.default_allocator, this.get(index));
        this.entries.deinit(bun.default_allocator);
        this.* = .{};
    }

    fn clone(this: *const PEMList) bun.OOM!PEMList {
        var result = try initCapacity(this.entries.len);
        errdefer result.deinit();
        for (0..this.entries.len) |index| {
            result.appendAssumeCapacity(try bun.default_allocator.dupeSentinel(u8, this.get(index), 0));
        }
        return result;
    }
};

/// Atomic shared pointer with weak support. Refcounting and allocation are
/// managed non-intrusively by `bun.ptr.shared`; the SSLConfig struct itself
/// has no refcount field.
pub const SharedPtr = bun.ptr.shared.WithOptions(*SSLConfig, .{
    .atomic = true,
    .allow_weak = true,
});

const WeakPtr = SharedPtr.Weak;

/// Extract the raw `*SSLConfig` from an optional SharedPtr for pointer-equality
/// comparison (interned configs have stable addresses).
pub inline fn rawPtr(maybe_shared: ?SharedPtr) ?*SSLConfig {
    return if (maybe_shared) |s| s.get() else null;
}

pub fn asUSockets(this: *const SSLConfig) uws.SocketContext.BunSocketContextOptions {
    var ctx_opts: uws.SocketContext.BunSocketContextOptions = .{};

    if (this.key_file_name) |value|
        ctx_opts.key_file_name = value.ptr;
    if (this.cert_file_name) |value|
        ctx_opts.cert_file_name = value.ptr;
    if (this.ca_file_name) |value|
        ctx_opts.ca_file_name = value.ptr;
    if (this.dh_params_file_name) |value|
        ctx_opts.dh_params_file_name = value.ptr;
    if (this.passphrase) |value|
        ctx_opts.passphrase = value.ptr;
    ctx_opts.ssl_prefer_low_memory_usage = @intFromBool(this.low_memory_mode);

    if (this.key) |key| {
        ctx_opts.key = key.entries.items(.ptr).ptr;
        ctx_opts.key_count = @intCast(key.entries.len);
    }
    if (this.cert) |cert| {
        ctx_opts.cert = cert.entries.items(.ptr).ptr;
        ctx_opts.cert_count = @intCast(cert.entries.len);
    }
    if (this.ca) |ca| {
        ctx_opts.ca = ca.entries.items(.ptr).ptr;
        ctx_opts.ca_count = @intCast(ca.entries.len);
    }

    if (this.ssl_ciphers) |value| {
        ctx_opts.ssl_ciphers = value.ptr;
    }
    ctx_opts.request_cert = this.request_cert;
    ctx_opts.reject_unauthorized = this.reject_unauthorized;
    ctx_opts.secure_options = this.secure_options;

    return ctx_opts;
}

/// Returns socket options for client-side TLS with manual verification.
/// Sets request_cert=1 (to receive server cert) and reject_unauthorized=0
/// (to handle verification manually in handshake callback).
pub fn asUSocketsForClientVerification(this: *const SSLConfig) uws.SocketContext.BunSocketContextOptions {
    var opts = this.asUSockets();
    opts.request_cert = 1;
    opts.reject_unauthorized = 0;
    return opts;
}

pub fn isSame(this: *const SSLConfig, other: *const SSLConfig) bool {
    const info = @typeInfo(SSLConfig).@"struct";
    inline for (info.field_names, info.field_types) |field_name, FieldType| {
        if (comptime std.mem.eql(u8, field_name, "cached_hash") or
            std.mem.eql(u8, field_name, "registry_io")) continue;
        const first = @field(this, field_name);
        const second = @field(other, field_name);
        switch (FieldType) {
            ?[]const u8, ?[:0]const u8 => {
                if (first) |a| {
                    const b = second orelse return false;
                    if (!std.mem.eql(u8, a, b)) return false;
                } else if (second != null) return false;
            },
            ?PEMList => {
                if (first) |list1| {
                    const list2 = second orelse return false;
                    if (list1.entries.len != list2.entries.len) return false;
                    for (0..list1.entries.len) |index| {
                        if (!std.mem.eql(u8, list1.get(index), list2.get(index))) return false;
                    }
                } else {
                    if (second != null) return false;
                }
            },
            else => if (first != second) return false,
        }
    }
    return true;
}

fn freeStrings(slice: *?PEMList) void {
    if (slice.*) |*inner| inner.deinit();
    slice.* = null;
}

fn freeString(string: *?[:0]const u8) void {
    const inner = string.* orelse return;
    bun.freeSensitive(bun.default_allocator, inner);
    string.* = null;
}

fn freeBytes(bytes: *?[]const u8) void {
    const value = bytes.* orelse return;
    bun.freeSensitive(bun.default_allocator, value);
    bytes.* = null;
}

/// Destructor. Called by `bun.ptr.shared` on strong 1->0 for interned configs,
/// and directly on value-type configs (e.g. `ServerConfig.ssl_config`).
///
/// For interned configs, we MUST remove from the registry before freeing the
/// string fields, since concurrent `intern()` calls may read those fields for
/// content comparison while we're still in the map. For non-interned configs,
/// `remove()` is a cheap no-op (pointer-identity check fails).
pub fn deinit(this: *SSLConfig) void {
    GlobalRegistry.remove(this);
    bun.meta.useAllFields(SSLConfig, .{
        .server_name = freeString(&this.server_name),
        .key_file_name = freeString(&this.key_file_name),
        .cert_file_name = freeString(&this.cert_file_name),
        .ca_file_name = freeString(&this.ca_file_name),
        .dh_params_file_name = freeString(&this.dh_params_file_name),
        .passphrase = freeString(&this.passphrase),
        .key = freeStrings(&this.key),
        .cert = freeStrings(&this.cert),
        .ca = freeStrings(&this.ca),
        .secure_options = {},
        .request_cert = {},
        .reject_unauthorized = {},
        .ssl_ciphers = freeString(&this.ssl_ciphers),
        .protos = freeBytes(&this.protos),
        .client_renegotiation_limit = {},
        .client_renegotiation_window = {},
        .requires_custom_request_ctx = {},
        .is_using_default_ciphers = {},
        .low_memory_mode = {},
        .cached_hash = {},
        .registry_io = {},
    });
}

fn cloneStrings(slice: ?PEMList) bun.OOM!?PEMList {
    const inner = slice orelse return null;
    return try inner.clone();
}

fn cloneString(string: ?[:0]const u8) bun.OOM!?[:0]const u8 {
    return try bun.default_allocator.dupeSentinel(u8, string orelse return null, 0);
}

pub fn clone(this: *const SSLConfig) bun.OOM!SSLConfig {
    var result: SSLConfig = .{
        .secure_options = this.secure_options,
        .request_cert = this.request_cert,
        .reject_unauthorized = this.reject_unauthorized,
        .client_renegotiation_limit = this.client_renegotiation_limit,
        .client_renegotiation_window = this.client_renegotiation_window,
        .requires_custom_request_ctx = this.requires_custom_request_ctx,
        .is_using_default_ciphers = this.is_using_default_ciphers,
        .low_memory_mode = this.low_memory_mode,
    };
    errdefer result.deinit();
    result.server_name = try cloneString(this.server_name);
    result.key_file_name = try cloneString(this.key_file_name);
    result.cert_file_name = try cloneString(this.cert_file_name);
    result.ca_file_name = try cloneString(this.ca_file_name);
    result.dh_params_file_name = try cloneString(this.dh_params_file_name);
    result.passphrase = try cloneString(this.passphrase);
    result.key = try cloneStrings(this.key);
    result.cert = try cloneStrings(this.cert);
    result.ca = try cloneStrings(this.ca);
    result.ssl_ciphers = try cloneString(this.ssl_ciphers);
    result.protos = if (this.protos) |bytes| try bun.default_allocator.dupe(u8, bytes) else null;
    return result;
}

pub fn contentHash(this: *SSLConfig) u64 {
    if (this.cached_hash != 0) return this.cached_hash;
    var hasher = std.hash.Wyhash.init(0);
    const info = @typeInfo(SSLConfig).@"struct";
    inline for (info.field_names, info.field_types) |field_name, FieldType| {
        if (comptime std.mem.eql(u8, field_name, "cached_hash") or
            std.mem.eql(u8, field_name, "registry_io")) continue;
        const value = @field(this, field_name);
        switch (FieldType) {
            ?[]const u8, ?[:0]const u8 => {
                if (value) |bytes| hasher.update(bytes);
                hasher.update(&.{0});
            },
            ?PEMList => {
                if (value) |list| {
                    for (0..list.entries.len) |index| {
                        hasher.update(list.get(index));
                        hasher.update(&.{0});
                    }
                }
                hasher.update(&.{0});
            },
            else => {
                hasher.update(std.mem.asBytes(&value));
            },
        }
    }
    const hash = hasher.final();
    // Avoid 0 since it's the sentinel for "not computed"
    this.cached_hash = if (hash == 0) 1 else hash;
    return this.cached_hash;
}

/// Weak dedup cache. Each map entry stores a weak pointer on its key's
/// backing allocation. `upgrade()` on that weak pointer is memory-safe
/// because the weak ref keeps the allocation alive (even if strong==0 and
/// `deinit()` is running on another thread). The mutex only protects map
/// structure and the invariant that entry content is intact while in the map.
pub const GlobalRegistry = struct {
    const MapContext = struct {
        pub fn hash(_: @This(), key: *SSLConfig) u32 {
            return @truncate(key.contentHash());
        }
        pub fn eql(_: @This(), a: *SSLConfig, b: *SSLConfig, _: usize) bool {
            return a.isSame(b);
        }
    };

    var mutex: std.Io.Mutex = .init;
    var configs: std.array_hash_map.Custom(*SSLConfig, WeakPtr, MapContext, true) = .empty;

    /// Moves the configuration into shared storage and returns one strong ref.
    /// The caller retains ownership if allocation fails before the move.
    pub fn intern(io: std.Io, config: *SSLConfig) bun.OOM!SharedPtr {
        const new_shared = try SharedPtr.alloc(config.*);
        config.* = SSLConfig.zero;
        const new_ptr = new_shared.get();
        new_ptr.registry_io = io;

        // Deferred cleanup MUST run after `mutex.unlock()` (deinit re-locks
        // the registry mutex via `SSLConfig.deinit -> remove`).
        var dispose_new: ?SharedPtr = new_shared;
        var dispose_old_weak: ?WeakPtr = null;
        defer if (dispose_new) |*s| s.deinit();
        defer if (dispose_old_weak) |*w| w.deinit();

        mutex.lockUncancelable(io);
        defer mutex.unlock(io);

        const gop = try configs.getOrPutContext(bun.default_allocator, new_ptr, .{});
        if (gop.found_existing) {
            if (gop.value_ptr.upgrade()) |existing_shared| {
                return existing_shared;
            }
            // strong==0: existing is dying. Its `deinit()` is blocked in
            // `remove()` waiting for this mutex, so content is still intact
            // (fields not yet freed). Replace the slot; the dying config's
            // `remove()` will pointer-mismatch and no-op when it runs.
            dispose_old_weak = gop.value_ptr.*;
            gop.key_ptr.* = new_ptr;
        }
        gop.value_ptr.* = new_shared.cloneWeak();
        dispose_new = null;
        return new_shared;
    }

    /// Called from `SSLConfig.deinit()` on strong 1->0. If `intern()` replaced
    /// our slot while we blocked on the mutex, the pointer-identity check
    /// fails and we skip (intern already disposed our weak ref).
    ///
    /// No-op for configs that were never interned.
    fn remove(config: *SSLConfig) void {
        const io = config.registry_io orelse return;
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (configs.count() == 0) return;
        const idx = configs.getIndexContext(config, .{}) orelse return;
        if (configs.keys()[idx] != config) return;
        var weak = configs.values()[idx];
        configs.swapRemoveAt(idx);
        weak.deinit();
    }
};

pub const zero = SSLConfig{};

pub fn takeProtos(this: *SSLConfig) ?[]const u8 {
    bun.assert(this.registry_io == null);
    this.cached_hash = 0;
    return bun.take(&this.protos);
}

pub fn takeServerName(this: *SSLConfig) ?[:0]const u8 {
    bun.assert(this.registry_io == null);
    this.cached_hash = 0;
    return bun.take(&this.server_name);
}

test "ALPN identity and cloning preserve zero bytes in protocol names" {
    var first: SSLConfig = .{ .protos = try bun.default_allocator.dupe(u8, "\x03a\x00b") };
    defer first.deinit();
    var second: SSLConfig = .{ .protos = try bun.default_allocator.dupe(u8, "\x03a\x00c") };
    defer second.deinit();
    try std.testing.expect(!first.isSame(&second));
    try std.testing.expect(first.contentHash() != second.contentHash());
    var copy = try first.clone();
    defer copy.deinit();
    try std.testing.expect(first.isSame(&copy));
    const protocols = copy.takeProtos().?;
    defer bun.default_allocator.free(protocols);
    try std.testing.expectEqualSlices(u8, "\x03a\x00b", protocols);
    try std.testing.expect(copy.protos == null);
}

test "TLS string owners preserve allocation lengths through cloning and C projection" {
    var original: SSLConfig = .{
        .server_name = try bun.default_allocator.dupeSentinel(u8, "host\x00suffix", 0),
        .secure_options = 0x40000000,
    };
    defer original.deinit();
    original.key = try PEMList.initCapacity(2);
    original.key.?.appendAssumeCapacity(try bun.default_allocator.dupeSentinel(u8, "first\x00key", 0));
    original.key.?.appendAssumeCapacity(try bun.default_allocator.dupeSentinel(u8, "second", 0));
    var copy = try original.clone();
    defer copy.deinit();
    try std.testing.expect(original.isSame(&copy));
    try std.testing.expectEqual(original.contentHash(), copy.contentHash());
    try std.testing.expectEqualSlices(u8, "first\x00key", copy.key.?.get(0));
    const options = copy.asUSockets();
    try std.testing.expectEqual(@as(u32, 2), options.key_count);
    try std.testing.expectEqual(copy.key.?.get(0).ptr, options.key.?[0].?);
    try std.testing.expectEqual(original.secure_options, options.secure_options);
    const server_name = copy.takeServerName().?;
    defer bun.default_allocator.free(server_name);
    try std.testing.expectEqualSlices(u8, "host\x00suffix", server_name);
    try std.testing.expect(copy.server_name == null);
    try std.testing.expect(!original.isSame(&copy));
    try std.testing.expect(original.contentHash() != copy.contentHash());
    copy.key.?.reverse();
    try std.testing.expectEqualSlices(u8, "second", copy.key.?.get(0));
    try std.testing.expectEqualSlices(u8, "first\x00key", copy.key.?.get(1));
}

const std = @import("std");

const bun = @import("bun");
const uws = bun.uws;
