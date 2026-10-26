pub const Digest = bun.bindgen.Return(ResolveDigestSchema);

pub const Hkdf = struct {
    pub const Context = bun.bindgen.Return(CreateSchema);
    pub const Result = bun.bindgen.Return(TakeResultSchema);

    const CreateSchema = EngineBindings.engineShim("nodeCryptoHkdfCreate");
    const TakeResultSchema = EngineBindings.engineShim("nodeCryptoHkdfTakeResult");
};

pub const CheckPrime = struct {
    pub const Context = bun.bindgen.Return(CreateSchema);
    pub const Result = bun.bindgen.Return(TakeResultSchema);

    const CreateSchema = EngineBindings.engineShim("nodeCryptoCheckPrimeCreate");
    const TakeResultSchema = EngineBindings.engineShim("nodeCryptoCheckPrimeTakeResult");
};

pub const GeneratePrime = struct {
    pub const Context = bun.bindgen.Return(CreateSchema);
    pub const Status = bun.bindgen.Return(StatusSchema);
    pub const Result = bun.bindgen.Return(TakeResultSchema);

    const CreateSchema = EngineBindings.engineShim("nodeCryptoGeneratePrimeCreate");
    const StatusSchema = EngineBindings.engineShim("nodeCryptoGeneratePrimeStatus");
    const TakeResultSchema = EngineBindings.engineShim("nodeCryptoGeneratePrimeTakeResult");
};

pub const DiffieHellman = struct {
    const CreateResult = bun.bindgen.Return(CreateSchema);

    pub const Context = @typeInfo(CreateResult).optional.child;
    pub const Result = bun.bindgen.Return(TakeResultSchema);

    const CreateSchema = EngineBindings.engineShim("nodeCryptoDiffieHellmanCreate");
    const TakeResultSchema = EngineBindings.engineShim("nodeCryptoDiffieHellmanTakeResult");
};

pub const Sign = struct {
    pub const Context = bun.bindgen.Return(CreateSchema);
    pub const SignResult = bun.bindgen.Return(TakeSignResultSchema);
    pub const VerifyResult = bun.bindgen.Return(TakeVerifyResultSchema);

    const CreateSchema = EngineBindings.engineShim("nodeCryptoSignCreate");
    const TakeSignResultSchema = EngineBindings.engineShim("nodeCryptoSignTakeResult");
    const TakeVerifyResultSchema = EngineBindings.engineShim("nodeCryptoVerifyTakeResult");
};

pub const KeyPair = struct {
    pub const Context = bun.bindgen.Return(CreateSchema);

    const CreateSchema = EngineBindings.engineShim("nodeCryptoKeyPairCreate");
};

pub const Backend = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        digest_size: *const fn (Digest) u32,
        hkdf_create: *const fn (Digest, []const u8, []const u8, []const u8, u32) bun.OOM!Hkdf.Context,
        hkdf_run: *const fn (*Hkdf.Context) void,
        hkdf_take_result: *const fn (*Hkdf.Context) bun.OOM!Hkdf.Result,
        check_prime_create: *const fn ([]const u8, i32) bun.OOM!CheckPrime.Context,
        check_prime_run: *const fn (*CheckPrime.Context) void,
        check_prime_take_result: *const fn (*CheckPrime.Context) bun.OOM!CheckPrime.Result,
        generate_prime_create: *const fn (i32, bool, ?[]const u8, ?[]const u8) bun.OOM!GeneratePrime.Context,
        generate_prime_status: *const fn (*GeneratePrime.Context) GeneratePrime.Status,
        generate_prime_run: *const fn (*GeneratePrime.Context) void,
        generate_prime_take_result: *const fn (*GeneratePrime.Context) bun.OOM!GeneratePrime.Result,
        diffie_hellman_run: *const fn (*DiffieHellman.Context) void,
        diffie_hellman_take_result: *const fn (*DiffieHellman.Context) bun.OOM!DiffieHellman.Result,
        sign_run: *const fn (*Sign.Context) void,
        sign_take_result: *const fn (*Sign.Context) bun.OOM!Sign.SignResult,
        verify_take_result: *const fn (*Sign.Context) bun.OOM!Sign.VerifyResult,
        key_pair_run: *const fn (*KeyPair.Context) bun.OOM!void,
    };

    pub fn digestSize(backend: Backend, digest: Digest) u32 {
        return backend.vtable.digest_size(digest);
    }

    pub fn createHkdf(backend: Backend, digest: Digest, key: []const u8, salt: []const u8, info: []const u8, length: u32) bun.OOM!Hkdf.Context {
        return backend.vtable.hkdf_create(digest, key, salt, info, length);
    }

    pub fn runHkdf(backend: Backend, context: *Hkdf.Context) void {
        backend.vtable.hkdf_run(context);
    }

    pub fn takeHkdfResult(backend: Backend, context: *Hkdf.Context) bun.OOM!Hkdf.Result {
        return backend.vtable.hkdf_take_result(context);
    }

    pub fn createCheckPrime(backend: Backend, candidate: []const u8, checks: i32) bun.OOM!CheckPrime.Context {
        return backend.vtable.check_prime_create(candidate, checks);
    }

    pub fn runCheckPrime(backend: Backend, context: *CheckPrime.Context) void {
        backend.vtable.check_prime_run(context);
    }

    pub fn takeCheckPrimeResult(backend: Backend, context: *CheckPrime.Context) bun.OOM!CheckPrime.Result {
        return backend.vtable.check_prime_take_result(context);
    }

    pub fn createGeneratePrime(backend: Backend, size: i32, safe: bool, add: ?[]const u8, rem: ?[]const u8) bun.OOM!GeneratePrime.Context {
        return backend.vtable.generate_prime_create(size, safe, add, rem);
    }

    pub fn generatePrimeStatus(backend: Backend, context: *GeneratePrime.Context) GeneratePrime.Status {
        return backend.vtable.generate_prime_status(context);
    }

    pub fn runGeneratePrime(backend: Backend, context: *GeneratePrime.Context) void {
        backend.vtable.generate_prime_run(context);
    }

    pub fn takeGeneratePrimeResult(backend: Backend, context: *GeneratePrime.Context) bun.OOM!GeneratePrime.Result {
        return backend.vtable.generate_prime_take_result(context);
    }

    pub fn runDiffieHellman(backend: Backend, context: *DiffieHellman.Context) void {
        backend.vtable.diffie_hellman_run(context);
    }

    pub fn takeDiffieHellmanResult(backend: Backend, context: *DiffieHellman.Context) bun.OOM!DiffieHellman.Result {
        return backend.vtable.diffie_hellman_take_result(context);
    }

    pub fn runSign(backend: Backend, context: *Sign.Context) void {
        backend.vtable.sign_run(context);
    }

    pub fn takeSignResult(backend: Backend, context: *Sign.Context) bun.OOM!Sign.SignResult {
        return backend.vtable.sign_take_result(context);
    }

    pub fn takeVerifyResult(backend: Backend, context: *Sign.Context) bun.OOM!Sign.VerifyResult {
        return backend.vtable.verify_take_result(context);
    }

    pub fn runKeyPair(backend: Backend, context: *KeyPair.Context) bun.OOM!void {
        return backend.vtable.key_pair_run(context);
    }
};

const bun = @import("bun");
const EngineBindings = bun.bindgen.Module("node_crypto_engine");
const ResolveDigestSchema = EngineBindings.engineShim("nodeCryptoResolveDigest");
