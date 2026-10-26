pub const ApplyError = error{
    OutOfMemory,
    InvalidEndpoint,
    PageSizeOutOfRange,
    PartSizeOutOfRange,
    QueueSizeOutOfRange,
    RetryOutOfRange,
    InvalidContentDisposition,
    InvalidContentType,
    InvalidContentEncoding,
};

pub const Input = struct {
    access_key_id: ?bun.TextView,
    secret_access_key: ?bun.TextView,
    region: ?bun.TextView,
    endpoint: ?bun.TextView,
    bucket: ?bun.TextView,
    virtual_hosted_style: ?bool,
    session_token: ?bun.TextView,
    page_size: ?i64,
    part_size: ?i64,
    queue_size: ?i32,
    retry: ?i32,
    acl: ?ACL,
    storage_class: ?StorageClass,
    content_disposition: ?bun.TextView,
    content_type: ?bun.TextView,
    content_encoding: ?bun.TextView,
    request_payer: ?bool,
};

pub fn initialize(defaults: S3CredentialsWithOptions, io: std.Io) S3CredentialsWithOptions {
    bun.analytics.Features.s3 += 1;
    var result = defaults;
    result.credentials.io = io;
    return result;
}

pub fn apply(result: *S3CredentialsWithOptions, options: *const Input) ApplyError!void {
    if (options.access_key_id) |value| {
        if (try toUTF8(value)) |slice| {
            result._accessKeyIdSlice = slice;
            result.credentials.accessKeyId = result._accessKeyIdSlice.?.slice();
            result.changed_credentials = true;
        }
    }

    if (options.secret_access_key) |value| {
        if (try toUTF8(value)) |slice| {
            result._secretAccessKeySlice = slice;
            result.credentials.secretAccessKey = result._secretAccessKeySlice.?.slice();
            result.changed_credentials = true;
        }
    }

    if (options.region) |value| {
        if (try toUTF8(value)) |slice| {
            result._regionSlice = slice;
            result.credentials.region = result._regionSlice.?.slice();
            result.changed_credentials = true;
        }
    }

    if (options.endpoint) |value| {
        if (try toUTF8(value)) |slice| {
            result._endpointSlice = slice;
            const endpoint = result._endpointSlice.?.slice();
            const url = bun.URL.parse(endpoint);
            const normalized_endpoint = url.hostWithPath();
            if (normalized_endpoint.len == 0) {
                return error.InvalidEndpoint;
            }
            result.credentials.endpoint = normalized_endpoint;
            result.credentials.insecure_http = url.isHTTP();
            result.changed_credentials = true;
        }
    }

    if (options.bucket) |value| {
        if (try toUTF8(value)) |slice| {
            result._bucketSlice = slice;
            result.credentials.bucket = result._bucketSlice.?.slice();
            result.changed_credentials = true;
        }
    }

    if (options.virtual_hosted_style) |value| {
        result.credentials.virtual_hosted_style = value;
        result.changed_credentials = true;
    }

    if (options.session_token) |value| {
        if (try toUTF8(value)) |slice| {
            result._sessionTokenSlice = slice;
            result.credentials.sessionToken = result._sessionTokenSlice.?.slice();
            result.changed_credentials = true;
        }
    }

    if (options.page_size) |value| {
        result.options.partSize = try partSize(value, error.PageSizeOutOfRange);
    }
    if (options.part_size) |value| {
        result.options.partSize = try partSize(value, error.PartSizeOutOfRange);
    }
    if (options.queue_size) |value| {
        if (value < 1) return error.QueueSizeOutOfRange;
        result.options.queueSize = @intCast(@min(value, std.math.maxInt(u8)));
    }
    if (options.retry) |value| {
        if (value < 0 or value > std.math.maxInt(u8)) return error.RetryOutOfRange;
        result.options.retry = @intCast(value);
    }

    if (options.acl) |value| result.acl = value;
    if (options.storage_class) |value| result.storage_class = value;

    if (options.content_disposition) |value| {
        try applyHeader(value, &result._contentDispositionSlice, &result.content_disposition, error.InvalidContentDisposition);
    }
    if (options.content_type) |value| {
        try applyHeader(value, &result._contentTypeSlice, &result.content_type, error.InvalidContentType);
    }
    if (options.content_encoding) |value| {
        try applyHeader(value, &result._contentEncodingSlice, &result.content_encoding, error.InvalidContentEncoding);
    }
    if (options.request_payer) |value| result.request_payer = value;
}

fn partSize(value: i64, comptime range_error: ApplyError) ApplyError!u64 {
    if (value < MultiPartUploadOptions.MIN_SINGLE_UPLOAD_SIZE or value > MultiPartUploadOptions.MAX_SINGLE_UPLOAD_SIZE) {
        return range_error;
    }
    return @intCast(value);
}

fn applyHeader(
    value: bun.TextView,
    storage: *?bun.String.Slice,
    destination: *?[]const u8,
    comptime invalid_header: ApplyError,
) ApplyError!void {
    const slice = (try toUTF8(value)) orelse return;
    storage.* = slice;
    const bytes = storage.*.?.slice();
    if (containsNewlineOrCR(bytes)) return invalid_header;
    destination.* = bytes;
}

fn toUTF8(value: bun.TextView) bun.OOM!?bun.String.Slice {
    if (value.isEmpty()) return null;
    return try value.toSlice(bun.default_allocator);
}

fn containsNewlineOrCR(value: []const u8) bool {
    return strings.indexOfAny(value, "\r\n") != null;
}

const std = @import("std");
const MultiPartUploadOptions = @import("../../../s3_signing/multipart_options.zig").MultiPartUploadOptions;

const bun = @import("bun");
const strings = bun.strings;

const ACL = bun.S3.ACL;
const S3CredentialsWithOptions = bun.S3.S3CredentialsWithOptions;
const StorageClass = bun.S3.StorageClass;
