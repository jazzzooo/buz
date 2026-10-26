const HMAC = @This();

ctx: ContextOwner,
algorithm: EVP.Algorithm,

const Context = opaque {};
const ContextOwner = bun.bindgen.OwnedNativeWithDestructor(Context, destroyContext, .any);

fn destroyContext(value: *Context) void {
    BoringSSL.HMAC_CTX_free(@ptrCast(@alignCast(value)));
}

fn context(this: *const HMAC) *BoringSSL.HMAC_CTX {
    return @ptrCast(@alignCast(this.ctx.get()));
}

pub const InitResult = union(enum) {
    success: HMAC,
    unsupported,
    failure: u32,
};

fn takeFailureCode() u32 {
    const code: u32 = @truncate(BoringSSL.ERR_get_error());
    BoringSSL.ERR_clear_error();
    return code;
}

pub fn init(algorithm: EVP.Algorithm, key: []const u8) bun.OOM!InitResult {
    const md = algorithm.md() orelse return .unsupported;
    BoringSSL.ERR_clear_error();
    const ctx = BoringSSL.HMAC_CTX_new();
    if (ctx == null) return error.OutOfMemory;
    if (BoringSSL.HMAC_Init_ex(ctx, key.ptr, @intCast(key.len), md, null) != 1) {
        const code = takeFailureCode();
        BoringSSL.HMAC_CTX_free(ctx);
        BoringSSL.ERR_clear_error();
        return .{ .failure = code };
    }
    return .{ .success = .{
        .ctx = .init(@ptrCast(ctx)),
        .algorithm = algorithm,
    } };
}

pub fn update(this: *HMAC, data: []const u8) EVP.OperationResult(void) {
    BoringSSL.ERR_clear_error();
    if (BoringSSL.HMAC_Update(this.context(), data.ptr, data.len) != 1) {
        return .{ .failure = takeFailureCode() };
    }
    return .{ .success = {} };
}

pub fn size(this: *const HMAC) usize {
    return BoringSSL.HMAC_size(this.context());
}

pub fn copy(this: *HMAC) bun.OOM!EVP.OperationResult(HMAC) {
    BoringSSL.ERR_clear_error();
    const ctx = BoringSSL.HMAC_CTX_new();
    if (ctx == null) return error.OutOfMemory;
    if (BoringSSL.HMAC_CTX_copy(ctx, this.context()) != 1) {
        const code = takeFailureCode();
        BoringSSL.HMAC_CTX_free(ctx);
        BoringSSL.ERR_clear_error();
        return .{ .failure = code };
    }
    return .{ .success = .{
        .ctx = .init(@ptrCast(ctx)),
        .algorithm = this.algorithm,
    } };
}

pub fn final(this: *HMAC, out: []u8) EVP.OperationResult([]u8) {
    bun.assert(out.len >= this.size());
    BoringSSL.ERR_clear_error();
    var outlen: c_uint = undefined;
    if (BoringSSL.HMAC_Final(this.context(), out.ptr, &outlen) != 1) {
        return .{ .failure = takeFailureCode() };
    }
    return .{ .success = out[0..outlen] };
}

pub fn deinit(this: *HMAC) void {
    this.ctx.deinit();
}

const bun = @import("bun");
const BoringSSL = bun.BoringSSL.c;
const EVP = @import("./EVP.zig");
