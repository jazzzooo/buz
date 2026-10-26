const b = @import("bindgen_schema");

pub const payload = b.dictionary("S3Failure", .{
    b.dictionaryField("code", b.thread_safe_dom_string, .{}),
    b.dictionaryField("message", b.thread_safe_dom_string, .{ .required = true }),
    b.dictionaryField("path", b.thread_safe_dom_string, .{}),
});

pub const service_failure = b.builtinError("s3", payload, .{
    .group = "s3Errors",
    .function = "createS3Error",
});

pub const option_errors = .{
    b.domainError("invalid_s3_options", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected options to be a object for 'S3'." },
    }),
    b.domainError("invalid_s3_endpoint", b.thread_safe_dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .payload,
    }),
    b.domainError("s3_option_out_of_range", b.thread_safe_dom_string, .{
        .class = .range_error,
        .code = "ERR_OUT_OF_RANGE",
        .message = .payload,
    }),
    b.domainError("invalid_s3_header", b.thread_safe_dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .payload,
    }),
};

pub const signing_errors = .{
    signingError("s3_missing_credentials", "ERR_S3_MISSING_CREDENTIALS", "Missing S3 credentials. 'accessKeyId', 'secretAccessKey', 'bucket', and 'endpoint' are required"),
    signingError("s3_invalid_method", "ERR_S3_INVALID_METHOD", "Method must be GET, PUT, DELETE or HEAD when using s3:// protocol"),
    signingError("s3_invalid_path", "ERR_S3_INVALID_PATH", "Invalid S3 bucket, key combination"),
    signingError("s3_invalid_endpoint", "ERR_S3_INVALID_ENDPOINT", "Invalid S3 endpoint"),
    signingError("s3_invalid_session_token", "ERR_S3_INVALID_SESSION_TOKEN", "Invalid session token"),
    signingError("s3_invalid_signature", "ERR_S3_INVALID_SIGNATURE", "Failed to retrieve S3 content. Are the credentials correct?"),
};

fn signingError(comptime name: []const u8, comptime code: []const u8, comptime message: []const u8) b.DomainError {
    return b.domainError(name, b.none, .{ .class = .generic_error, .code = code, .message = .{ .literal = message } });
}

pub const schema = b.module("S3Errors", .{
    b.function("createS3Error", .{b.argument("data", payload, .{})}, b.js_error_instance, .{
        .backend = .cpp,
        .profile = .exact,
    }),
});
