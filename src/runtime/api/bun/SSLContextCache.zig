//! A bounded native TLS context cache. Each entry and each caller hold separate
//! BoringSSL references; eviction and teardown release only the cache's reference.

const SSLContextCache = @This();

io: std.Io,
mutex: std.Io.Mutex = .init,
entries: [capacity]Entry = undefined,
length: usize = 0,
closed: bool = false,

const capacity = 32;
pub const Digest = [32]u8;

const Entry = struct {
    digest: Digest,
    context: *BoringSSL.SSL_CTX,
};

pub fn init(io: std.Io) SSLContextCache {
    return .{ .io = io };
}

/// Returns a reference owned by the caller.
pub fn getOrCreate(self: *SSLContextCache, config: *const SSLConfig, err: *uws.TLSContextFailure) ?*BoringSSL.SSL_CTX {
    return self.getOrCreateOpts(config.asUSockets(), err);
}

pub fn getOrCreateOpts(self: *SSLContextCache, options: uws.SocketContext.BunSocketContextOptions, err: *uws.TLSContextFailure) ?*BoringSSL.SSL_CTX {
    return self.getOrCreateDigest(options, options.digest(), err);
}

pub fn getOrCreateDigest(self: *SSLContextCache, options: uws.SocketContext.BunSocketContextOptions, digest: Digest, err: *uws.TLSContextFailure) ?*BoringSSL.SSL_CTX {
    err.* = .{};
    self.mutex.lockUncancelable(self.io);
    const cached = self.findLocked(digest);
    self.mutex.unlock(self.io);
    if (cached) |context| return context;

    const created = options.createSSLContext(err) orelse return null;
    self.mutex.lockUncancelable(self.io);
    if (self.findLocked(digest)) |existing| {
        self.mutex.unlock(self.io);
        BoringSSL.SSL_CTX_free(created);
        return existing;
    }
    if (self.closed) {
        self.mutex.unlock(self.io);
        return created;
    }
    const evicted = if (self.length == capacity) self.entries[capacity - 1].context else null;
    const shifted = @min(self.length, capacity - 1);
    std.mem.copyBackwards(Entry, self.entries[1..][0..shifted], self.entries[0..shifted]);
    _ = BoringSSL.SSL_CTX_up_ref(created);
    self.entries[0] = .{ .digest = digest, .context = created };
    self.length = @min(self.length + 1, capacity);
    self.mutex.unlock(self.io);
    // Context teardown can run library callbacks, so it never holds the cache lock.
    if (evicted) |context| BoringSSL.SSL_CTX_free(context);
    return created;
}

fn findLocked(self: *SSLContextCache, digest: Digest) ?*BoringSSL.SSL_CTX {
    for (self.entries[0..self.length], 0..) |entry, index| {
        if (!std.mem.eql(u8, &entry.digest, &digest)) continue;
        std.mem.copyBackwards(Entry, self.entries[1..][0..index], self.entries[0..index]);
        self.entries[0] = entry;
        _ = BoringSSL.SSL_CTX_up_ref(entry.context);
        return entry.context;
    }
    return null;
}

pub fn deinit(self: *SSLContextCache) void {
    var contexts: [capacity]*BoringSSL.SSL_CTX = undefined;
    self.mutex.lockUncancelable(self.io);
    const count = self.length;
    for (self.entries[0..count], 0..) |entry, index| contexts[index] = entry.context;
    self.length = 0;
    self.closed = true;
    self.mutex.unlock(self.io);
    for (contexts[0..count]) |context| BoringSSL.SSL_CTX_free(context);
}

const std = @import("std");
const bun = @import("bun");
const uws = bun.uws;
const BoringSSL = bun.BoringSSL.c;
const SSLConfig = @import("../../socket/SSLConfig.zig");
