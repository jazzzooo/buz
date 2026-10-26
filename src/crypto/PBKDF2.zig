pub fn resolveDigest(algorithm: Algorithm) ?*const BoringSSL.EVP_MD {
    return switch (algorithm) {
        .shake128, .shake256 => null,
        else => algorithm.md() orelse BoringSSL.EVP_get_digestbyname(@tagName(algorithm)),
    };
}

pub fn run(
    output: []u8,
    password: []const u8,
    salt: []const u8,
    iteration_count: u32,
    digest: *const BoringSSL.EVP_MD,
) bool {
    BoringSSL.ERR_clear_error();
    if (output.len == 0) return false;

    @memset(output, 0);
    assert(output.len <= std.math.maxInt(i32));
    const rc = BoringSSL.PKCS5_PBKDF2_HMAC(
        if (password.len > 0) password.ptr else null,
        @intCast(password.len),
        salt.ptr,
        @intCast(salt.len),
        @intCast(iteration_count),
        digest,
        @intCast(output.len),
        output.ptr,
    );
    return rc > 0;
}

pub fn pbkdf2(
    output: []u8,
    password: []const u8,
    salt: []const u8,
    iteration_count: u32,
    algorithm: Algorithm,
) ?[]const u8 {
    const digest = resolveDigest(algorithm) orelse return null;
    if (!run(output, password, salt, iteration_count, digest)) return null;
    return output;
}

const std = @import("std");

const bun = @import("bun");
const assert = bun.assert;
const BoringSSL = bun.BoringSSL.c;

const EVP = @import("./EVP.zig");
const Algorithm = EVP.Algorithm;
