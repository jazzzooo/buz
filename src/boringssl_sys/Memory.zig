//! BoringSSL allocator hooks may run during process initialization, thread teardown,
//! and while holding library locks. They use only the native allocator.

pub fn retainSymbols() void {
    if (@import("builtin").is_test) return;
    std.mem.doNotOptimizeAway(&OPENSSL_memory_alloc);
    std.mem.doNotOptimizeAway(&OPENSSL_memory_free);
    std.mem.doNotOptimizeAway(&OPENSSL_memory_get_size);
}

export fn OPENSSL_memory_alloc(size: usize) callconv(.c) ?*anyopaque {
    return bun.mimalloc.mi_malloc(size);
}

export fn OPENSSL_memory_free(ptr: *anyopaque) callconv(.c) void {
    const length = bun.mimalloc.mi_usable_size(ptr);
    const bytes: [*]volatile u8 = @ptrCast(ptr);
    std.crypto.secureZero(u8, bytes[0..length]);
    bun.mimalloc.mi_free(ptr);
}

export fn OPENSSL_memory_get_size(ptr: ?*anyopaque) callconv(.c) usize {
    return bun.mimalloc.mi_usable_size(ptr);
}

const bun = @import("bun");
const std = @import("std");
