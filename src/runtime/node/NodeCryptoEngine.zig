pub const Digest = BackendModule.Digest;

pub fn digestSize(digest: Digest) u32 {
    return bun.bindgen.Engine(DigestSizeSchema).call(.{ .digest = digest });
}

pub const Hkdf = struct {
    pub const Context = BackendModule.Hkdf.Context;
    pub const Result = BackendModule.Hkdf.Result;

    pub fn create(
        digest: Digest,
        key: []const u8,
        salt: []const u8,
        info: []const u8,
        length: u32,
    ) bun.OOM!Context {
        return bun.bindgen.Engine(CreateSchema).call(.{
            .digest = digest,
            .key = bun.bindgen.BytesOperand.fromSlice(key),
            .salt = bun.bindgen.BytesOperand.fromSlice(salt),
            .info = bun.bindgen.BytesOperand.fromSlice(info),
            .length = length,
        });
    }

    pub const run = JobOperation(Context, RunSchema, void).call;

    pub const takeResult = JobOperation(Context, TakeResultSchema, bun.OOM!Result).call;

    const CreateSchema = EngineBindings.engineShim("nodeCryptoHkdfCreate");
    const RunSchema = EngineBindings.engineShim("nodeCryptoHkdfRunTask");
    const TakeResultSchema = EngineBindings.engineShim("nodeCryptoHkdfTakeResult");
};

pub const CheckPrime = struct {
    pub const Context = BackendModule.CheckPrime.Context;
    pub const Result = BackendModule.CheckPrime.Result;

    pub fn create(candidate: []const u8, checks: i32) bun.OOM!Context {
        return bun.bindgen.Engine(CreateSchema).call(.{
            .candidate = bun.bindgen.BytesOperand.fromSlice(candidate),
            .checks = checks,
        });
    }

    pub const run = JobOperation(Context, RunSchema, void).call;

    pub const takeResult = JobOperation(Context, TakeResultSchema, bun.OOM!Result).call;

    const CreateSchema = EngineBindings.engineShim("nodeCryptoCheckPrimeCreate");
    const RunSchema = EngineBindings.engineShim("nodeCryptoCheckPrimeRunTask");
    const TakeResultSchema = EngineBindings.engineShim("nodeCryptoCheckPrimeTakeResult");
};

pub const GeneratePrime = struct {
    pub const Context = BackendModule.GeneratePrime.Context;
    pub const Status = BackendModule.GeneratePrime.Status;
    pub const Result = BackendModule.GeneratePrime.Result;

    pub fn create(size: i32, safe: bool, add: ?[]const u8, rem: ?[]const u8) bun.OOM!Context {
        return bun.bindgen.Engine(CreateSchema).call(.{
            .size = size,
            .safe = safe,
            .add = if (add) |bytes| bun.bindgen.BytesOperand.fromSlice(bytes) else null,
            .rem = if (rem) |bytes| bun.bindgen.BytesOperand.fromSlice(bytes) else null,
        });
    }

    pub const status = JobOperation(Context, StatusSchema, Status).call;

    pub const run = JobOperation(Context, RunSchema, void).call;

    pub const takeResult = JobOperation(Context, TakeResultSchema, bun.OOM!Result).call;

    const CreateSchema = EngineBindings.engineShim("nodeCryptoGeneratePrimeCreate");
    const StatusSchema = EngineBindings.engineShim("nodeCryptoGeneratePrimeStatus");
    const RunSchema = EngineBindings.engineShim("nodeCryptoGeneratePrimeRunTask");
    const TakeResultSchema = EngineBindings.engineShim("nodeCryptoGeneratePrimeTakeResult");
};

pub const DiffieHellman = struct {
    pub const Context = BackendModule.DiffieHellman.Context;
    pub const Result = BackendModule.DiffieHellman.Result;

    pub const run = JobOperation(Context, RunSchema, void).call;

    pub const takeResult = JobOperation(Context, TakeResultSchema, bun.OOM!Result).call;

    const RunSchema = EngineBindings.engineShim("nodeCryptoDiffieHellmanRunTask");
    const TakeResultSchema = EngineBindings.engineShim("nodeCryptoDiffieHellmanTakeResult");
};

pub const Sign = struct {
    pub const Context = BackendModule.Sign.Context;
    pub const SignResult = BackendModule.Sign.SignResult;
    pub const VerifyResult = BackendModule.Sign.VerifyResult;

    pub const run = JobOperation(Context, RunSchema, void).call;

    pub const takeSignResult = JobOperation(Context, TakeSignResultSchema, bun.OOM!SignResult).call;

    pub const takeVerifyResult = JobOperation(Context, TakeVerifyResultSchema, bun.OOM!VerifyResult).call;

    const RunSchema = EngineBindings.engineShim("nodeCryptoSignRunTask");
    const TakeSignResultSchema = EngineBindings.engineShim("nodeCryptoSignTakeResult");
    const TakeVerifyResultSchema = EngineBindings.engineShim("nodeCryptoVerifyTakeResult");
};

pub const KeyPair = struct {
    pub const Context = BackendModule.KeyPair.Context;

    pub const run = JobOperation(Context, RunSchema, bun.OOM!void).call;

    const RunSchema = EngineBindings.engineShim("nodeCryptoKeyPairRunTask");
};

fn JobOperation(comptime Context: type, comptime Schema: type, comptime Result: type) type {
    return struct {
        pub fn call(context: *Context) Result {
            return bun.bindgen.Engine(Schema).call(.{ .job = context });
        }
    };
}

const backend_vtable: BackendModule.Backend.VTable = .{
    .digest_size = digestSize,
    .hkdf_create = Hkdf.create,
    .hkdf_run = Hkdf.run,
    .hkdf_take_result = Hkdf.takeResult,
    .check_prime_create = CheckPrime.create,
    .check_prime_run = CheckPrime.run,
    .check_prime_take_result = CheckPrime.takeResult,
    .generate_prime_create = GeneratePrime.create,
    .generate_prime_status = GeneratePrime.status,
    .generate_prime_run = GeneratePrime.run,
    .generate_prime_take_result = GeneratePrime.takeResult,
    .diffie_hellman_run = DiffieHellman.run,
    .diffie_hellman_take_result = DiffieHellman.takeResult,
    .sign_run = Sign.run,
    .sign_take_result = Sign.takeSignResult,
    .verify_take_result = Sign.takeVerifyResult,
    .key_pair_run = KeyPair.run,
};

pub fn backend() BackendModule.Backend {
    return .{ .vtable = &backend_vtable };
}

const bun = @import("bun");
const BackendModule = @import("./NodeCryptoBackend.zig");
const EngineBindings = bun.bindgen.Module("node_crypto_engine");
const DigestSizeSchema = EngineBindings.engineShim("nodeCryptoDigestSize");
