const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const crypto = @import("binding_schema_node_crypto_binding");

const key_material = b.unionType("NodeHmacKeyMaterial", .{
    b.unionMember("buffer", b.buffer(.copy)),
    b.unionMember("string", b.dom_string),
    b.unionMember("key_object", crypto.node_secret_key_object_input),
}, .{
    .ordered = true,
    .node_error = .{ .expected_type = "string or an instance of ArrayBuffer, Buffer, TypedArray, DataView, KeyObject, or CryptoKey" },
});
const options = b.dictionaryWithOptions("NodeCryptoHmacOptions", .{
    b.dictionaryField("encoding", b.optionalNullish(archetypes.node_string_encoding), .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
}, .{ .user_facing_name = "options", .node_allow_array = true, .node_allow_callable = true });
const options_or_ignored = b.unionType("NodeCryptoHmacOptionsOrIgnored", .{
    b.unionMember("options", options),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const update_errors = b.domainErrors(.{
    b.domainError("finalized", b.none, .{
        .class = .generic_error,
        .code = "ERR_CRYPTO_HASH_FINALIZED",
        .message = .{ .literal = "Digest already called" },
    }),
    b.domainError("missing_input", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "The \"data\" argument must be of type string or an instance of Buffer, TypedArray, or DataView. Received undefined" },
    }),
    b.domainError("update_failed", b.none, .{
        .class = .generic_error,
        .code = "ERR_CRYPTO_HASH_UPDATE_FAILED",
        .message = .{ .literal = "Hash update failed" },
    }),
});

const hmac = b.class("Hmac", b.constructor(.{
    b.argument("hmac", b.dom_string, .{}),
    b.argument("key", b.lazy(key_material), .{ .deferred_reason = "Hmac reads encoding options before converting or exporting the key" }),
    b.argument("options", b.lazy(options_or_ignored), .{ .presence = .optional, .missing = .omitted, .deferred_reason = "Hmac validates the algorithm argument before reading options" }),
}, .{ .length = 2, .missing_required_arguments = .convert_undefined }), .{
    b.method("update", .{
        b.argument("data", b.lazy(archetypes.node_string_or_copied_buffer), .{
            .presence = .optional,
            .missing = .omitted,
            .deferred_reason = "Hmac rejects updates after digest before validating or copying the input",
        }),
        archetypes.lazyOptionalNodeStringEncoding("encoding", "Hmac checks finalized state and missing input before using encoding for a string input"),
    }, b.none, .{ .length = 1, .configurable = true, .errors = update_errors }),
    b.method("digest", .{archetypes.optionalNodeDigestEncoding("encoding")}, crypto.node_crypto_encoded_output, .{ .length = 1, .configurable = true }),
}, .{}, .{
    .profile = .node,
    .ownership = .unique,
    .memory_usage = .vm,
});

const native_context = b.nominalHandle("NodeHmacContext", .{
    .cpp_type = .{ .pointer = &.{ .named = "HMAC_CTX" } },
    .cpp_declarations = &.{ .{ .structure = "hmac_ctx_st" }, .{ .alias = .{ .name = "HMAC_CTX", .type = .{ .named = "hmac_ctx_st" } } } },
    .cpp_header = "openssl/hmac.h",
    .ownership = .owned,
    .cpp_release = "releaseHmacContext",
    .access_thread = .vm,
    .destroy_thread = .vm,
});
const input = b.unionType("NodeHmacInput", .{
    b.unionMember("buffer", b.buffer(.copy)),
    b.unionMember("string", b.dom_string),
}, .{ .ordered = true });

pub const schema = b.moduleWithClassesAndEngineShims("NodeCryptoHmac", .{}, .{hmac}, .{
    b.engineShim("create", .{
        b.argument("algorithm", b.dom_string, .{}),
        b.argument("key", key_material, .{}),
        b.argument("encoding", b.optional(archetypes.node_string_encoding), .{}),
    }, native_context, .current_realm_node_throwing),
    b.engineShim("update", .{
        b.argument("hmac", native_context, .{}),
        b.argument("input", input, .{}),
        b.argument("encoding", b.optional(archetypes.node_string_encoding), .{}),
    }, b.none, .current_realm_node_throwing),
    b.engineShim("digest", .{
        b.argument("hmac", b.optional(native_context), .{}),
        b.argument("encoding", b.optional(archetypes.node_digest_encoding), .{}),
    }, crypto.node_crypto_encoded_output, .current_realm_node_throwing),
    b.engineShim("contextSize", .{}, b.uint64, .realm_independent),
});
