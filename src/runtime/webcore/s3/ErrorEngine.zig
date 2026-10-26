pub const S3Error = s3_error.S3Error;

fn signErrorArguments(err: anyerror) bun.OOM!struct {
    code: bun.bindgen.EngineArgumentType(CreateErrorSchema, "code"),
    message: bun.bindgen.DOMString,
} {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{
        .code = switch (err) {
            error.MissingCredentials => .ERR_S3_MISSING_CREDENTIALS,
            error.InvalidMethod => .ERR_S3_INVALID_METHOD,
            error.InvalidPath => .ERR_S3_INVALID_PATH,
            error.InvalidEndpoint => .ERR_S3_INVALID_ENDPOINT,
            error.InvalidSessionToken => .ERR_S3_INVALID_SESSION_TOKEN,
            else => .ERR_S3_INVALID_SIGNATURE,
        },
        .message = try bun.bindgen.DOMString.fromUTF8(s3_error.getSignErrorCodeAndMessage(err).message),
    };
}

pub fn getSignError(context: anytype, err: anyerror) bun.JSError!bun.bindgen.BrandedValueResult(CreateErrorSchema.ReturnType) {
    var args = try signErrorArguments(err);
    defer args.message.deinit();
    return context.engineIn("ErrorCode", "create").call(.{ .code = args.code, .message = args.message.operand() });
}

pub fn throwSignError(err: anyerror, globalThis: *jsc.JSGlobalObject) bun.JSError {
    var args = try signErrorArguments(err);
    defer args.message.deinit();
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(globalThis);
    defer scope.deinit();
    scope.engineIn("ErrorCode", "throw").call(.{ .code = args.code, .message = args.message.operand() }) catch |failure| return failure;
    @panic("throwing a signing error returned without an exception");
}

pub fn retainServiceError(err: *const S3Error, global: *jsc.JSGlobalObject, path: ?[]const u8) bun.JSError!bun.bindgen.Root {
    var code: ?bun.bindgen.DOMString = if (err.code.len > 0) try bun.bindgen.DOMString.fromUTF8(err.code) else null;
    defer if (code) |*value| value.deinit();
    var message = try bun.bindgen.DOMString.fromUTF8(err.message);
    defer message.deinit();
    var owned_path: ?bun.bindgen.DOMString = if (path) |value|
        if (value.len > 0) try bun.bindgen.DOMString.fromUTF8(value) else null
    else
        null;
    defer if (owned_path) |*value| value.deinit();
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    var value = try scope.engineIn("errors", "s3ErrorToErrorInstance").call(.{ .data = .{
        .code = if (code) |optional_value| optional_value.operand() else null,
        .message = message.operand(),
        .path = if (owned_path) |path_value| path_value.operand() else null,
    } });
    defer value.deinit();
    return value.toRoot();
}

const s3_error = @import("../../../s3_signing/error.zig");

const bun = @import("bun");
const jsc = bun.jsc;

const CreateErrorSchema = bun.bindgen.Module("ErrorCode").engineShim("create");
