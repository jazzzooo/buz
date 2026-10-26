pub fn construct(
    context: bindgen.CallContext(SecureContextConstructorSchema),
    args: bindgen.Args(SecureContextConstructorSchema),
) bindgen.CallError(SecureContextConstructorSchema)!*SecureContext {
    var config = try parseConfig(context, args.options);
    defer config.deinit();
    const options = config.asUSockets();
    var failure: uws.TLSContextFailure = .{};
    const native = options.createSSLContext(&failure) orelse return failCreate(context, failure);
    return SecureContext.create(native, options.digest(), options.approxCertBytes() + ssl_ctx_base_cost);
}

pub fn intern(
    context: bindgen.CallContext(InternSecureContextSchema),
    args: bindgen.Args(InternSecureContextSchema),
) bindgen.CallError(InternSecureContextSchema)!bindgen.Return(InternSecureContextSchema) {
    var config = try parseConfig(context, args.options);
    defer config.deinit();

    const options = config.asUSockets();
    const digest = options.digest();
    const key = std.mem.readInt(u64, digest[0..8], .little);

    if (try context.engineIn("SecureContext", "secureContextCacheGet").call(.{ .key = key })) |cached| {
        if (bun.strings.eqlLong(&cached.get(SecureContext).digest, &digest, false)) {
            return cached.toOwned();
        }
    }

    const secure_context = try createWithDigest(context.viewToken().globalObject(), context, options, digest);
    var reference = try SecureContext.Binding.adoptResult(secure_context, context);
    errdefer reference.deinit();
    try context.engineIn("SecureContext", "secureContextCacheSet").call(.{
        .key = key,
        .value = reference.operand(context),
    });
    return reference;
}

fn parseConfig(context: anytype, options: anytype) bindgen.CallError(@TypeOf(context))!SSLConfig {
    return if (options) |*value|
        (try SSLConfigEngine.parse(context, value)) orelse SSLConfig.zero
    else
        SSLConfig.zero;
}

fn createWithDigest(
    globalThis: *jsc.JSGlobalObject,
    context: anytype,
    options: uws.SocketContext.BunSocketContextOptions,
    digest: [32]u8,
) bindgen.CallError(@TypeOf(context))!*SecureContext {
    const rare_data = try globalThis.bunVM().tryRareData();
    var failure: uws.TLSContextFailure = .{};
    const ctx = rare_data.sslCtxCache().getOrCreateDigest(options, digest, &failure) orelse
        return failCreate(context, failure);
    return SecureContext.create(ctx, digest, options.approxCertBytes() + ssl_ctx_base_cost);
}

fn failCreate(context: anytype, failure: uws.TLSContextFailure) bindgen.CallError(@TypeOf(context)) {
    var buffer: ["BoringSSL ".len + 129]u8 = undefined;
    const message = switch (failure.kind) {
        .out_of_memory => return error.OutOfMemory,
        .none => if (failure.boring_ssl_code != 0)
            formatBoringSSLError(failure.boring_ssl_code, &buffer)
        else
            "Failed to create SSL context",
        else => failure.message().?,
    };
    return context.fail(.boringssl_error, try bindgen.DOMString.fromUTF8(message));
}

fn formatBoringSSLError(error_code: u32, buffer: *["BoringSSL ".len + 129]u8) []const u8 {
    @memset(buffer, 0);
    buffer[0.."BoringSSL ".len].* = "BoringSSL ".*;
    const message_buffer = buffer["BoringSSL ".len..];
    _ = BoringSSL.ERR_error_string_n(error_code, message_buffer, message_buffer.len);
    const message = std.mem.sliceTo(buffer[0..], 0);
    if (message.len != "BoringSSL ".len) return message;
    return std.fmt.bufPrint(buffer, "An unknown BoringSSL error occurred: {d}", .{error_code}) catch unreachable;
}

const ssl_ctx_base_cost: usize = 50 * 1024;

const std = @import("std");
const SecureContextModule = @import("./SecureContext.zig");
const SecureContext = SecureContextModule;
const InternSecureContextSchema = SecureContextModule.InternSecureContextSchema;
const SecureContextConstructorSchema = SecureContextModule.SecureContextConstructorSchema;
const SSLConfig = @import("../../socket/SSLConfig.zig");
const SSLConfigEngine = @import("../../socket/SSLConfigEngine.zig");

const bun = @import("bun");
const bindgen = bun.bindgen;
const jsc = bun.jsc;
const uws = bun.uws;
const BoringSSL = bun.BoringSSL.c;
