pub fn resolveOptions(context: anytype, defaults: bun.S3.S3CredentialsWithOptions, options: anytype, global: *jsc.JSGlobalObject) bun.bindgen.CallError(@TypeOf(context))!bun.S3.S3CredentialsWithOptions {
    var result = CredentialsOptions.initialize(defaults, global.bunVM().io);
    errdefer result.deinit();
    if (options) |value| switch (value) {
        .nulled, .undefined => {},
        .invalid => return context.fail(.invalid_s3_options, {}),
        .options => |*resolved| {
            const input = normalizeOptions(resolved);
            CredentialsOptions.apply(&result, &input) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidEndpoint => failFormatted(context, .invalid_s3_endpoint, "The \"endpoint\" argument must contain a host. Received {f}", .{bun.fmt.formatJSONStringUTF8(result._endpointSlice.?.slice(), .{})}),
                error.PageSizeOutOfRange => failFormatted(context, .s3_option_out_of_range, "{f}", .{bun.fmt.outOfRange(input.page_size.?, partSizeRange("pageSize"))}),
                error.PartSizeOutOfRange => failFormatted(context, .s3_option_out_of_range, "{f}", .{bun.fmt.outOfRange(input.part_size.?, partSizeRange("partSize"))}),
                error.QueueSizeOutOfRange => failFormatted(context, .s3_option_out_of_range, "{f}", .{bun.fmt.outOfRange(input.queue_size.?, .{ .min = 1, .field_name = "queueSize" })}),
                error.RetryOutOfRange => failFormatted(context, .s3_option_out_of_range, "{f}", .{bun.fmt.outOfRange(input.retry.?, .{ .min = 0, .max = 255, .field_name = "retry" })}),
                error.InvalidContentDisposition => failFormatted(context, .invalid_s3_header, "contentDisposition must not contain newline characters (CR/LF)", .{}),
                error.InvalidContentType => failFormatted(context, .invalid_s3_header, "type must not contain newline characters (CR/LF)", .{}),
                error.InvalidContentEncoding => failFormatted(context, .invalid_s3_header, "contentEncoding must not contain newline characters (CR/LF)", .{}),
            };
        },
    };
    return result;
}

fn failFormatted(context: anytype, comptime tag: @EnumLiteral(), comptime fmt: []const u8, args: anytype) bun.bindgen.CallError(@TypeOf(context)) {
    const message = try std.fmt.allocPrint(bun.default_allocator, fmt, args);
    defer bun.default_allocator.free(message);
    return context.fail(tag, try bun.bindgen.ThreadSafeDOMString.fromUTF8(message));
}

pub fn getCredentialsWithDefaults(
    credentials: S3Credentials,
    default_options: MultiPartUploadOptions,
    default_acl: ?ACL,
    default_storage_class: ?StorageClass,
    default_request_payer: bool,
    global: *jsc.JSGlobalObject,
) S3CredentialsWithOptions {
    return CredentialsOptions.initialize(.{
        .credentials = credentials,
        .options = default_options,
        .acl = default_acl,
        .storage_class = default_storage_class,
        .request_payer = default_request_payer,
    }, global.bunVM().io);
}

pub fn getCredentialsWithBindingOptions(
    credentials: S3Credentials,
    default_options: MultiPartUploadOptions,
    options: anytype,
    default_acl: ?ACL,
    default_storage_class: ?StorageClass,
    default_request_payer: bool,
    global: *jsc.JSGlobalObject,
) bun.JSError!S3CredentialsWithOptions {
    var result = CredentialsOptions.initialize(.{
        .credentials = credentials,
        .options = default_options,
        .acl = default_acl,
        .storage_class = default_storage_class,
        .request_payer = default_request_payer,
    }, global.bunVM().io);
    errdefer result.deinit();

    if (options) |value| switch (value) {
        .nulled, .undefined => {},
        .invalid => return global.throwInvalidArgumentType("S3", "options", "object"),
        .options => |*resolved| {
            const input = normalizeOptions(resolved);
            CredentialsOptions.apply(&result, &input) catch |err| {
                return throwApplyError(global, &result, &input, err);
            };
        },
    };

    return result;
}

fn throwApplyError(
    global: *jsc.JSGlobalObject,
    result: *const S3CredentialsWithOptions,
    options: *const CredentialsOptions.Input,
    err: CredentialsOptions.ApplyError,
) bun.JSError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidEndpoint => invalid_endpoint: {
            const endpoint = result._endpointSlice orelse unreachable;
            break :invalid_endpoint global.throwNodeError(.ERR_INVALID_ARG_VALUE, "The \"endpoint\" argument must contain a host. Received {f}", .{
                bun.fmt.formatJSONStringUTF8(endpoint.slice(), .{}),
            });
        },
        error.PageSizeOutOfRange => global.throwRangeError(options.page_size.?, partSizeRange("pageSize")),
        error.PartSizeOutOfRange => global.throwRangeError(options.part_size.?, partSizeRange("partSize")),
        error.QueueSizeOutOfRange => global.throwRangeError(options.queue_size.?, .{ .min = 1, .field_name = "queueSize" }),
        error.RetryOutOfRange => global.throwRangeError(options.retry.?, .{ .min = 0, .max = std.math.maxInt(u8), .field_name = "retry" }),
        error.InvalidContentDisposition => global.throwInvalidArguments("contentDisposition must not contain newline characters (CR/LF)", .{}),
        error.InvalidContentType => global.throwInvalidArguments("type must not contain newline characters (CR/LF)", .{}),
        error.InvalidContentEncoding => global.throwInvalidArguments("contentEncoding must not contain newline characters (CR/LF)", .{}),
    };
}

pub fn normalizeOptions(options: anytype) CredentialsOptions.Input {
    return .{
        .access_key_id = normalizeString(&options.access_key_id),
        .secret_access_key = normalizeString(&options.secret_access_key),
        .region = normalizeString(&options.region),
        .endpoint = normalizeString(&options.endpoint),
        .bucket = normalizeString(&options.bucket),
        .virtual_hosted_style = options.virtual_hosted_style,
        .session_token = normalizeString(&options.session_token),
        .page_size = options.page_size,
        .part_size = options.part_size,
        .queue_size = options.queue_size,
        .retry = options.retry,
        .acl = if (options.acl) |value| switch (value) {
            .Private => .private,
            .public_read => .public_read,
            .public_read_write => .public_read_write,
            .aws_exec_read => .aws_exec_read,
            .authenticated_read => .authenticated_read,
            .bucket_owner_read => .bucket_owner_read,
            .bucket_owner_full_control => .bucket_owner_full_control,
            .log_delivery_write => .log_delivery_write,
        } else null,
        .storage_class = if (options.storage_class) |value| switch (value) {
            .STANDARD => .STANDARD,
            .STANDARD_IA => .STANDARD_IA,
            .INTELLIGENT_TIERING => .INTELLIGENT_TIERING,
            .EXPRESS_ONEZONE => .EXPRESS_ONEZONE,
            .ONEZONE_IA => .ONEZONE_IA,
            .GLACIER => .GLACIER,
            .GLACIER_IR => .GLACIER_IR,
            .REDUCED_REDUNDANCY => .REDUCED_REDUNDANCY,
            .OUTPOSTS => .OUTPOSTS,
            .DEEP_ARCHIVE => .DEEP_ARCHIVE,
            .SNOW => .SNOW,
        } else null,
        .content_disposition = normalizeString(&options.content_disposition),
        .content_type = normalizeString(&options.content_type),
        .content_encoding = normalizeString(&options.content_encoding),
        .request_payer = options.request_payer,
    };
}

fn normalizeString(optional: anytype) ?bun.TextView {
    if (optional.*) |*value| {
        return value.unsafePtr("the option string's owner remains alive until credential application copies it").textView();
    }
    return null;
}

pub fn partSizeRange(comptime name: []const u8) bun.fmt.OutOfRangeOptions {
    return .{
        .min = @intCast(MultiPartUploadOptions.MIN_SINGLE_UPLOAD_SIZE),
        .max = @intCast(MultiPartUploadOptions.MAX_SINGLE_UPLOAD_SIZE),
        .field_name = name,
    };
}

const CredentialsOptions = @import("./CredentialsOptions.zig");
const MultiPartUploadOptions = @import("../../../s3_signing/multipart_options.zig").MultiPartUploadOptions;

const std = @import("std");
const bun = @import("bun");
const jsc = bun.jsc;

const ACL = bun.S3.ACL;
const S3Credentials = bun.S3.S3Credentials;
const S3CredentialsWithOptions = bun.S3.S3CredentialsWithOptions;
const StorageClass = bun.S3.StorageClass;
