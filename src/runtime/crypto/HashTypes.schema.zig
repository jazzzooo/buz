const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const hash_seed = b.unionType("HashSeedInput", .{
    b.unionMemberWithOptions("value", archetypes.unsigned_integer_number_or_bigint, .{ .integer_conversion = .modulo }),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

pub fn seed(comptime name: []const u8, comptime options: b.ArgumentOptions) b.Argument {
    return b.argument(name, hash_seed, options);
}

pub fn strictSeed(comptime name: []const u8, comptime options: b.ArgumentOptions) b.Argument {
    var resolved = options;
    resolved.integer_conversion = .modulo;
    return b.argument(name, archetypes.unsigned_integer_number_or_bigint, resolved);
}

pub const output_result = b.unionType("HashOutputResult", .{
    b.unionMember("text", b.dom_string),
    b.unionMember("uint8_array", b.bufferResult(.uint8_array)),
    b.unionMember("node_buffer", b.node_buffer),
    b.unionMember("pass_through", b.any),
}, .{ .ordered = true, .fallback_member = "pass_through" });

pub const invalid_output_encoding_error = b.domainError("invalid_encoding", b.dom_string, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_VALUE",
    .message = .payload,
});

pub const boringssl_error = archetypes.boringSSLError("boringssl_error");

pub const bun_file_unsupported_error = b.domainError("bun_file_unsupported", b.none, .{
    .class = .generic_error,
    .message = .{ .literal = "Bun.file() is not supported here yet (it needs an async version)" },
});

pub const missing_input_error = b.domainError("missing_input", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .{ .literal = "expected blob, string or buffer" },
});

pub const short_output_buffer_error = b.domainError("short_output_buffer", b.dom_string, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .payload,
});

pub const operation_errors = b.domainErrors(.{
    missing_input_error,
    short_output_buffer_error,
    invalid_output_encoding_error,
    bun_file_unsupported_error,
    boringssl_error,
});

pub const schema = b.module("HashTypes", .{});
