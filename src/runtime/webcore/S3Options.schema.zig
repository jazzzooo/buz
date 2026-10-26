const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const acl = b.enumerationWithOptions("S3ACL", .{
    b.enumerationValue("Private", "private"),
    b.enumerationValue("public_read", "public-read"),
    b.enumerationValue("public_read_write", "public-read-write"),
    b.enumerationValue("aws_exec_read", "aws-exec-read"),
    b.enumerationValue("authenticated_read", "authenticated-read"),
    b.enumerationValue("bucket_owner_read", "bucket-owner-read"),
    b.enumerationValue("bucket_owner_full_control", "bucket-owner-full-control"),
    b.enumerationValue("log_delivery_write", "log-delivery-write"),
}, .{ .invalid_value_error = .type });

pub const storage_class = b.enumerationWithOptions("S3StorageClass", .{
    b.enumerationValue("STANDARD", "STANDARD"),
    b.enumerationValue("STANDARD_IA", "STANDARD_IA"),
    b.enumerationValue("INTELLIGENT_TIERING", "INTELLIGENT_TIERING"),
    b.enumerationValue("EXPRESS_ONEZONE", "EXPRESS_ONEZONE"),
    b.enumerationValue("ONEZONE_IA", "ONEZONE_IA"),
    b.enumerationValue("GLACIER", "GLACIER"),
    b.enumerationValue("GLACIER_IR", "GLACIER_IR"),
    b.enumerationValue("REDUCED_REDUNDANCY", "REDUCED_REDUNDANCY"),
    b.enumerationValue("OUTPOSTS", "OUTPOSTS"),
    b.enumerationValue("DEEP_ARCHIVE", "DEEP_ARCHIVE"),
    b.enumerationValue("SNOW", "SNOW"),
}, .{ .invalid_value_error = .type });

pub const presign_method = b.enumerationWithOptions("S3PresignMethod", archetypes.http_method.enumeration.values, .{
    .ascii_case_insensitive = true,
    .strict_errors = .{
        .invalid_type = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "method must be GET, PUT, DELETE or HEAD when using s3 protocol" },
        .invalid_value = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "method must be GET, PUT, DELETE or HEAD when using s3 protocol" },
    },
});

pub const fields = .{
    b.dictionaryField("access_key_id", archetypes.nullable_dom_string, .{ .default_value = .null, .js_name = "accessKeyId" }),
    b.dictionaryField("secret_access_key", archetypes.nullable_dom_string, .{ .default_value = .null, .js_name = "secretAccessKey" }),
    b.dictionaryField("region", archetypes.nullable_dom_string, .{ .default_value = .null }),
    b.dictionaryField("endpoint", archetypes.nullable_dom_string, .{ .default_value = .null }),
    b.dictionaryField("bucket", archetypes.nullable_dom_string, .{ .default_value = .null }),
    b.dictionaryField("virtual_hosted_style", archetypes.optional_boolean, .{ .default_value = .null, .js_name = "virtualHostedStyle" }),
    b.dictionaryField("session_token", archetypes.nullable_dom_string, .{ .default_value = .null, .js_name = "sessionToken" }),
    b.dictionaryField("page_size", b.optionalNullish(b.int64), .{ .default_value = .null, .integer_conversion = .coerce, .js_name = "pageSize" }),
    b.dictionaryField("part_size", b.optionalNullish(b.int64), .{ .default_value = .null, .integer_conversion = .coerce, .js_name = "partSize" }),
    b.dictionaryField("queue_size", archetypes.nullable_int32, .{ .default_value = .null, .integer_conversion = .coerce, .js_name = "queueSize" }),
    b.dictionaryField("retry", archetypes.nullable_int32, .{ .default_value = .null, .integer_conversion = .coerce }),
    b.dictionaryField("acl", b.optionalNullish(acl), .{ .default_value = .null }),
    b.dictionaryField("storage_class", b.optionalNullish(storage_class), .{ .default_value = .null, .js_name = "storageClass" }),
    b.dictionaryField("content_disposition", archetypes.nullable_dom_string, .{ .default_value = .null, .js_name = "contentDisposition" }),
    b.dictionaryField("content_type", archetypes.nullable_dom_string, .{ .default_value = .null, .js_name = "type" }),
    b.dictionaryField("content_encoding", archetypes.nullable_dom_string, .{ .default_value = .null, .js_name = "contentEncoding" }),
    b.dictionaryField("request_payer", archetypes.optional_boolean, .{ .default_value = .null, .js_name = "requestPayer" }),
    b.dictionaryField("method", b.optionalNullish(presign_method), .{ .default_value = .null }),
    b.dictionaryField("expires_in", archetypes.nullable_int32, .{ .default_value = .null, .integer_conversion = .coerce, .js_name = "expiresIn" }),
};

pub const options = b.dictionary("S3Options", fields);

pub const input = b.unionType("S3OptionsInput", .{
    b.unionMember("options", options),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("undefined", b.undefined_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

pub fn optional(comptime name: []const u8) b.Argument {
    return b.argument(name, input, .{ .presence = .optional, .missing = .omitted });
}

pub const schema = b.module("S3Options", .{});
