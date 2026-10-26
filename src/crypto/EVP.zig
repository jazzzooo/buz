const EVP = @This();

ctx: ContextOwner,
algorithm: Algorithm,

const Context = opaque {};
const ContextOwner = bun.bindgen.OwnedNativeWithDestructor(Context, destroyContext, .any);

fn destroyContext(value: *Context) void {
    BoringSSL.EVP_MD_CTX_free(@ptrCast(@alignCast(value)));
}

fn context(this: *const EVP) *BoringSSL.EVP_MD_CTX {
    return @ptrCast(@alignCast(this.ctx.get()));
}

// we do this to avoid asking BoringSSL what the digest name is
// because that API is confusing
pub const Algorithm = enum {
    // @"DSA-SHA",
    // @"DSA-SHA1",
    // @"MD5-SHA1",
    // @"RSA-MD5",
    // @"RSA-RIPEMD160",
    // @"RSA-SHA1",
    // @"RSA-SHA1-2",
    // @"RSA-SHA224",
    // @"RSA-SHA256",
    // @"RSA-SHA384",
    // @"RSA-SHA512",
    // @"ecdsa-with-SHA1",
    blake2b256,
    blake2b512,
    blake2s256,
    md4,
    md5,
    ripemd160,
    sha1,
    sha224,
    sha256,
    sha384,
    sha512,
    @"sha512-224",
    @"sha512-256",

    @"sha3-224",
    @"sha3-256",
    @"sha3-384",
    @"sha3-512",
    shake128,
    shake256,

    pub fn md(this: Algorithm) ?*const BoringSSL.EVP_MD {
        return switch (this) {
            .blake2b256 => BoringSSL.EVP_blake2b256(),
            .blake2b512 => BoringSSL.EVP_blake2b512(),
            .md4 => BoringSSL.EVP_md4(),
            .md5 => BoringSSL.EVP_md5(),
            .ripemd160 => BoringSSL.EVP_ripemd160(),
            .sha1 => BoringSSL.EVP_sha1(),
            .sha224 => BoringSSL.EVP_sha224(),
            .sha256 => BoringSSL.EVP_sha256(),
            .sha384 => BoringSSL.EVP_sha384(),
            .sha512 => BoringSSL.EVP_sha512(),
            .@"sha512-224" => BoringSSL.EVP_sha512_224(),
            .@"sha512-256" => BoringSSL.EVP_sha512_256(),
            .@"sha3-224" => BoringSSL.EVP_sha3_224(),
            .@"sha3-256" => BoringSSL.EVP_sha3_256(),
            .@"sha3-384" => BoringSSL.EVP_sha3_384(),
            .@"sha3-512" => BoringSSL.EVP_sha3_512(),
            else => null,
        };
    }

    pub fn digestSize(this: Algorithm) u16 {
        return switch (this) {
            .md4, .md5 => 16,
            .ripemd160, .sha1 => 20,
            .sha224, .@"sha512-224", .@"sha3-224" => 28,
            .blake2b256, .blake2s256, .sha256, .@"sha512-256", .@"sha3-256", .shake256 => 32,
            .sha384, .@"sha3-384" => 48,
            .blake2b512, .sha512, .@"sha3-512" => 64,
            .shake128 => 16,
        };
    }

    fn initializeNames() void {
        var all = std.EnumArray(Algorithm, bun.String).initUndefined();
        inline for (std.meta.tags(Algorithm)) |algorithm| {
            all.set(algorithm, bun.String.staticTagName(algorithm));
        }
        names_storage = all;
    }

    var names_storage: std.EnumArray(Algorithm, bun.String) = undefined;
    var names_once = bun.threadedOnce(initializeNames);

    pub fn names() *const std.EnumArray(Algorithm, bun.String) {
        names_once.call(.{});
        return &names_storage;
    }

    pub const map = bun.ComptimeStringMap(Algorithm, .{
        .{ "blake2b256", .blake2b256 },
        .{ "blake2b512", .blake2b512 },
        .{ "blake2s256", .blake2s256 },
        .{ "ripemd160", .ripemd160 },
        .{ "rmd160", .ripemd160 },
        .{ "md4", .md4 },
        .{ "md5", .md5 },
        .{ "sha1", .sha1 },
        .{ "sha128", .sha1 },
        .{ "sha224", .sha224 },
        .{ "sha256", .sha256 },
        .{ "sha384", .sha384 },
        .{ "sha512", .sha512 },
        .{ "sha-1", .sha1 },
        .{ "sha-224", .sha224 },
        .{ "sha-256", .sha256 },
        .{ "sha-384", .sha384 },
        .{ "sha-512", .sha512 },
        .{ "sha-512/224", .@"sha512-224" },
        .{ "sha-512_224", .@"sha512-224" },
        .{ "sha-512224", .@"sha512-224" },
        .{ "sha512-224", .@"sha512-224" },
        .{ "sha-512/256", .@"sha512-256" },
        .{ "sha-512_256", .@"sha512-256" },
        .{ "sha-512256", .@"sha512-256" },
        .{ "sha512-256", .@"sha512-256" },
        .{ "sha384", .sha384 },
        .{ "sha3-224", .@"sha3-224" },
        .{ "sha3-256", .@"sha3-256" },
        .{ "sha3-384", .@"sha3-384" },
        .{ "sha3-512", .@"sha3-512" },
        .{ "shake128", .shake128 },
        .{ "shake256", .shake256 },
        // .{ "md5-sha1", .@"MD5-SHA1" },
        // .{ "dsa-sha", .@"DSA-SHA" },
        // .{ "dsa-sha1", .@"DSA-SHA1" },
        // .{ "ecdsa-with-sha1", .@"ecdsa-with-SHA1" },
        // .{ "rsa-md5", .@"RSA-MD5" },
        // .{ "rsa-sha1", .@"RSA-SHA1" },
        // .{ "rsa-sha1-2", .@"RSA-SHA1-2" },
        // .{ "rsa-sha224", .@"RSA-SHA224" },
        // .{ "rsa-sha256", .@"RSA-SHA256" },
        // .{ "rsa-sha384", .@"RSA-SHA384" },
        // .{ "rsa-sha512", .@"RSA-SHA512" },
        // .{ "rsa-ripemd160", .@"RSA-RIPEMD160" },
    });
};

pub fn OperationResult(comptime Value: type) type {
    return union(enum) {
        success: Value,
        failure: u32,
    };
}

pub const ResolveResult = union(enum) {
    success: EVP,
    unsupported,
    failure: u32,
};

fn takeFailureCode() u32 {
    const code: u32 = @truncate(BoringSSL.ERR_get_error());
    BoringSSL.ERR_clear_error();
    return code;
}

pub fn init(algorithm: Algorithm, md: *const BoringSSL.EVP_MD, engine: *BoringSSL.ENGINE) bun.OOM!OperationResult(EVP) {
    bun.BoringSSL.load();

    BoringSSL.ERR_clear_error();
    const ctx = BoringSSL.EVP_MD_CTX_new();
    if (ctx == null) return error.OutOfMemory;
    if (BoringSSL.EVP_DigestInit_ex(ctx, md, engine) != 1) {
        const code = takeFailureCode();
        BoringSSL.EVP_MD_CTX_free(ctx);
        BoringSSL.ERR_clear_error();
        return .{ .failure = code };
    }
    return .{ .success = .{
        .ctx = .init(@ptrCast(ctx)),
        .algorithm = algorithm,
    } };
}

pub fn reset(this: *EVP, engine: *BoringSSL.ENGINE) OperationResult(void) {
    BoringSSL.ERR_clear_error();
    if (BoringSSL.EVP_DigestInit_ex(this.context(), BoringSSL.EVP_MD_CTX_md(this.context()), engine) != 1) {
        return .{ .failure = takeFailureCode() };
    }
    return .{ .success = {} };
}

pub fn hash(this: *EVP, engine: *BoringSSL.ENGINE, input: []const u8, output: []u8) OperationResult([]u8) {
    bun.assert(output.len >= this.size());
    BoringSSL.ERR_clear_error();
    var outsize: c_uint = @min(@as(u16, @truncate(output.len)), this.size());
    if (BoringSSL.EVP_Digest(input.ptr, input.len, output.ptr, &outsize, BoringSSL.EVP_MD_CTX_md(this.context()), engine) != 1) {
        return .{ .failure = takeFailureCode() };
    }

    return .{ .success = output[0..outsize] };
}

pub fn final(this: *EVP, output: []u8) OperationResult([]u8) {
    bun.assert(output.len >= this.size());
    BoringSSL.ERR_clear_error();
    var outsize: u32 = @min(@as(u16, @truncate(output.len)), this.size());
    if (BoringSSL.EVP_DigestFinal_ex(
        this.context(),
        output.ptr,
        &outsize,
    ) != 1) {
        return .{ .failure = takeFailureCode() };
    }

    return .{ .success = output[0..outsize] };
}

pub fn finalAndReset(this: *EVP, engine: *BoringSSL.ENGINE, output: []u8) OperationResult([]u8) {
    const digest = switch (this.final(output)) {
        .success => |digest| digest,
        .failure => |code| return .{ .failure = code },
    };
    switch (this.reset(engine)) {
        .success => {},
        .failure => |code| return .{ .failure = code },
    }
    return .{ .success = digest };
}

pub fn update(this: *EVP, input: []const u8) OperationResult(void) {
    BoringSSL.ERR_clear_error();
    if (BoringSSL.EVP_DigestUpdate(this.context(), input.ptr, input.len) != 1) {
        return .{ .failure = takeFailureCode() };
    }
    return .{ .success = {} };
}

pub fn size(this: *const EVP) u16 {
    return @as(u16, @truncate(BoringSSL.EVP_MD_CTX_size(this.context())));
}

pub fn copy(this: *const EVP, engine: *BoringSSL.ENGINE) bun.OOM!OperationResult(EVP) {
    var new = switch (try init(this.algorithm, BoringSSL.EVP_MD_CTX_md(this.context()).?, engine)) {
        .success => |initialized| initialized,
        .failure => |code| return .{ .failure = code },
    };
    BoringSSL.ERR_clear_error();
    if (BoringSSL.EVP_MD_CTX_copy_ex(new.context(), this.context()) == 0) {
        const code = takeFailureCode();
        new.deinit();
        return .{ .failure = code };
    }
    return .{ .success = new };
}

pub fn resolveByName(engine: *BoringSSL.ENGINE, name: []const u8) bun.OOM!ResolveResult {
    if (Algorithm.map.getWithEql(name, strings.eqlCaseInsensitiveASCIIIgnoreLength)) |algorithm| {
        if (algorithm.md()) |md| {
            return switch (try EVP.init(algorithm, md, engine)) {
                .success => |initialized| .{ .success = initialized },
                .failure => |code| .{ .failure = code },
            };
        }

        if (BoringSSL.EVP_get_digestbyname(@tagName(algorithm))) |md| {
            return switch (try EVP.init(algorithm, md, engine)) {
                .success => |initialized| .{ .success = initialized },
                .failure => |code| .{ .failure = code },
            };
        }
    }

    return .unsupported;
}

pub fn deinit(this: *EVP) void {
    this.ctx.deinit();
}

pub const Digest = [BoringSSL.EVP_MAX_MD_SIZE]u8;
pub const PBKDF2 = @import("./PBKDF2.zig");
pub const pbkdf2 = PBKDF2.pbkdf2;

const std = @import("std");

const bun = @import("bun");
const strings = bun.strings;
const BoringSSL = bun.BoringSSL.c;
