//! `Bun.CSRF.generate` / `Bun.CSRF.verify` host fns. The pure
//! `generate()`/`verify()` halves stay in `src/csrf/`.

pub fn csrf__generate(
    context: bun.bindgen.CallContext(GenerateSchema),
    args: bun.bindgen.Args(GenerateSchema),
) bun.bindgen.CallError(GenerateSchema)!bun.bindgen.DOMString {
    if (bun.analytics.Features.csrf_generate < std.math.maxInt(usize))
        bun.analytics.Features.csrf_generate += 1;

    const secret = if (args.secret) |value| try value.toUTF8(bun.default_allocator) else null;
    defer if (secret) |value| value.deinit();
    const secret_bytes = if (secret) |value| value.slice() else try bun.current_runtime.defaultCSRFSecret();

    const expires_in = if (args.options) |options| options.expires_in else csrf.DEFAULT_EXPIRATION_MS;
    const encoding = if (args.options) |options| tokenFormat(options.encoding) else csrf.TokenFormat.base64url;
    const algorithm = if (args.options) |options| digestAlgorithm(options.algorithm) else csrf.DEFAULT_ALGORITHM;

    var nonce: [16]u8 = undefined;
    bun.current_runtime.fillEntropy(&nonce);
    var token_buffer: [boring.EVP_MAX_MD_SIZE + 32]u8 = undefined;
    const token_bytes = csrf.generate(.{
        .secret = secret_bytes,
        .expires_in_ms = expires_in,
        .encoding = encoding,
        .algorithm = algorithm,
    }, nonce, &token_buffer) catch return context.fail(.token_creation_failed, {});

    var encoded_buffer: [(boring.EVP_MAX_MD_SIZE + 32) * 2]u8 = undefined;
    return bun.bindgen.DOMString.fromUTF8(encodeToken(encoding, token_bytes, &encoded_buffer));
}

pub fn csrf__verify(
    context: bun.bindgen.CallContext(VerifySchema),
    args: bun.bindgen.Args(VerifySchema),
) bun.bindgen.CallError(VerifySchema)!bool {
    if (bun.analytics.Features.csrf_verify < std.math.maxInt(usize)) {
        bun.analytics.Features.csrf_verify += 1;
    }

    const token = try args.token.toUTF8(bun.default_allocator);
    defer token.deinit();
    if (token.slice().len == 0) return context.fail(.empty_token, {});

    const secret = if (args.options) |options|
        if (options.secret) |value| try value.toUTF8(bun.default_allocator) else null
    else
        null;
    defer if (secret) |value| value.deinit();

    return csrf.verify(.{
        .token = token.slice(),
        .secret = if (secret) |value| value.slice() else try bun.current_runtime.defaultCSRFSecret(),
        .max_age_ms = if (args.options) |options| options.max_age else csrf.DEFAULT_EXPIRATION_MS,
        .encoding = if (args.options) |options| tokenFormat(options.encoding) else .base64url,
        .algorithm = if (args.options) |options| digestAlgorithm(options.algorithm) else csrf.DEFAULT_ALGORITHM,
    });
}

fn tokenFormat(encoding: anytype) csrf.TokenFormat {
    return switch (encoding) {
        .base64 => .base64,
        .base64url => .base64url,
        .hex => .hex,
    };
}

fn digestAlgorithm(algorithm: anytype) EVP.Algorithm {
    return switch (algorithm) {
        .blake2b256 => .blake2b256,
        .blake2b512 => .blake2b512,
        .sha256 => .sha256,
        .sha384 => .sha384,
        .sha512 => .sha512,
        .sha512_256 => .@"sha512-256",
    };
}

fn encodeToken(format: csrf.TokenFormat, token: []const u8, output: []u8) []const u8 {
    return switch (format) {
        .base64 => output[0..bun.base64.encode(output, token)],
        .base64url => output[0..bun.base64.encodeURLSafe(output, token)],
        .hex => encodeHex(token, output),
    };
}

fn encodeHex(input: []const u8, output: []u8) []const u8 {
    const digits = "0123456789abcdef";
    for (input, 0..) |byte, index| {
        output[index * 2] = digits[byte >> 4];
        output[index * 2 + 1] = digits[byte & 0xf];
    }
    return output[0 .. input.len * 2];
}

const csrf = @import("../../csrf/csrf.zig");
const std = @import("std");

const bun = @import("bun");
const boring = bun.BoringSSL.c;
const EVP = @import("../../crypto/EVP.zig");
const CSRFObjectBindings = bun.bindgen.Module("CSRFObject");
const GenerateSchema = CSRFObjectBindings.function("generate");
const VerifySchema = CSRFObjectBindings.function("verify");
pub const GenerateBinding = bun.bindgen.Fn(GenerateSchema, csrf__generate);
pub const VerifyBinding = bun.bindgen.Fn(VerifySchema, csrf__verify);

comptime {
    _ = GenerateBinding;
    _ = VerifyBinding;
}
