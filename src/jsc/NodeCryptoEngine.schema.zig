const b = @import("bindgen_schema");
const node_crypto = @import("binding_schema_node_crypto_binding");

const hkdf_job_handle = b.nominalHandle("NodeCryptoHkdfJob", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::HkdfJobCtx" } },
    .cpp_declarations = &.{.{ .structure = "Bun::HkdfJobCtx" }},
    .ownership = .owned,
    .cpp_release = "releaseNodeCryptoHkdfJob",
    .access_thread = .any,
    .destroy_thread = .any,
});
const check_prime_job_handle = b.nominalHandle("NodeCryptoCheckPrimeJob", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::CheckPrimeJobCtx" } },
    .cpp_declarations = &.{.{ .structure = "Bun::CheckPrimeJobCtx" }},
    .ownership = .owned,
    .cpp_release = "releaseNodeCryptoCheckPrimeJob",
    .access_thread = .any,
    .destroy_thread = .any,
});
const generate_prime_job_handle = b.nominalHandle("NodeCryptoGeneratePrimeJob", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::GeneratePrimeJobCtx" } },
    .cpp_declarations = &.{.{ .structure = "Bun::GeneratePrimeJobCtx" }},
    .ownership = .owned,
    .cpp_release = "releaseNodeCryptoGeneratePrimeJob",
    .access_thread = .any,
    .destroy_thread = .any,
});
const diffie_hellman_job_handle = b.nominalHandle("NodeCryptoDiffieHellmanJob", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::DhJobCtx" } },
    .cpp_declarations = &.{.{ .structure = "Bun::DhJobCtx" }},
    .ownership = .owned,
    .cpp_release = "releaseNodeCryptoDiffieHellmanJob",
    .access_thread = .any,
    .destroy_thread = .any,
});
const sign_job_handle = b.nominalHandle("NodeCryptoSignJob", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::SignJobCtx" } },
    .cpp_declarations = &.{.{ .structure = "Bun::SignJobCtx" }},
    .ownership = .owned,
    .cpp_release = "releaseNodeCryptoSignJob",
    .access_thread = .any,
    .destroy_thread = .any,
});
const key_pair_job_handle = b.nominalHandle("NodeCryptoKeyPairJob", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::KeyPairJobCtx" } },
    .cpp_declarations = &.{.{ .structure = "Bun::KeyPairJobCtx" }},
    .ownership = .owned,
    .cpp_release = "releaseNodeCryptoKeyPairJob",
    .access_thread = .any,
    .destroy_thread = .any,
});
const generate_prime_status = b.enumeration("NodeCryptoGeneratePrimeStatus", .{
    b.enumerationValue("success", "success"),
    b.enumerationValue("invalid_add", "invalid_add"),
    b.enumerationValue("invalid_rem", "invalid_rem"),
    b.enumerationValue("operation_failed", "operation_failed"),
});

const engine_shims = .{
    b.engineShim(
        "nodeCryptoExportSecretKey",
        .{b.argument("key", node_crypto.node_secret_key_object_input, .{})},
        b.buffer(.copy),
        .current_realm_throwing,
    ),
    b.engineShim(
        "nodeCryptoResolveDigest",
        .{b.argument("name", b.dom_string, .{})},
        node_crypto.node_crypto_digest_handle,
        .current_realm_throwing,
    ),
    b.engineShim(
        "nodeCryptoDigestSize",
        .{b.argument("digest", node_crypto.node_crypto_digest_handle, .{})},
        b.uint32,
        .realm_independent,
    ),
    b.engineShim(
        "nodeCryptoHkdfCreate",
        .{
            b.argument("digest", node_crypto.node_crypto_digest_handle, .{}),
            b.argument("key", b.buffer(.copy), .{}),
            b.argument("salt", b.buffer(.copy), .{}),
            b.argument("info", b.buffer(.copy), .{}),
            b.argument("length", b.uint32, .{}),
        },
        hkdf_job_handle,
        .realm_independent_allocating,
    ),
    b.engineShim(
        "nodeCryptoHkdfRunTask",
        .{b.argument("job", hkdf_job_handle, .{})},
        b.none,
        .realm_independent,
    ),
    b.engineShim(
        "nodeCryptoHkdfTakeResult",
        .{b.argument("job", hkdf_job_handle, .{})},
        b.optional(b.buffer(.copy)),
        .realm_independent_allocating,
    ),
    b.engineShim(
        "nodeCryptoCheckPrimeCreate",
        .{
            b.argument("candidate", b.buffer(.copy), .{}),
            b.argument("checks", b.int32, .{}),
        },
        check_prime_job_handle,
        .realm_independent_allocating,
    ),
    b.engineShim(
        "nodeCryptoCheckPrimeRunTask",
        .{b.argument("job", check_prime_job_handle, .{})},
        b.none,
        .realm_independent,
    ),
    b.engineShim(
        "nodeCryptoCheckPrimeTakeResult",
        .{b.argument("job", check_prime_job_handle, .{})},
        b.optional(b.boolean),
        .realm_independent_allocating,
    ),
    b.engineShim(
        "nodeCryptoGeneratePrimeCreate",
        .{
            b.argument("size", b.int32, .{}),
            b.argument("safe", b.boolean, .{}),
            b.argument("add", b.optional(b.buffer(.copy)), .{}),
            b.argument("rem", b.optional(b.buffer(.copy)), .{}),
        },
        generate_prime_job_handle,
        .realm_independent_allocating,
    ),
    b.engineShim(
        "nodeCryptoGeneratePrimeStatus",
        .{b.argument("job", generate_prime_job_handle, .{})},
        generate_prime_status,
        .realm_independent,
    ),
    b.engineShim(
        "nodeCryptoGeneratePrimeRunTask",
        .{b.argument("job", generate_prime_job_handle, .{})},
        b.none,
        .realm_independent,
    ),
    b.engineShim(
        "nodeCryptoGeneratePrimeTakeResult",
        .{b.argument("job", generate_prime_job_handle, .{})},
        b.optional(b.buffer(.copy)),
        .realm_independent_allocating,
    ),
    b.engineShim(
        "nodeCryptoDiffieHellmanCreate",
        .{
            b.argument("private_key", node_crypto.key_object, .{}),
            b.argument("public_key", node_crypto.key_object, .{}),
        },
        b.optional(diffie_hellman_job_handle),
        .current_realm_throwing,
    ),
    b.engineShim(
        "nodeCryptoDiffieHellmanRunTask",
        .{b.argument("job", diffie_hellman_job_handle, .{})},
        b.none,
        .realm_independent,
    ),
    b.engineShim(
        "nodeCryptoDiffieHellmanTakeResult",
        .{b.argument("job", diffie_hellman_job_handle, .{})},
        b.optional(b.buffer(.copy)),
        .realm_independent_allocating,
    ),
    b.engineShim(
        "nodeCryptoSignCreate",
        .{
            b.argument("key", node_crypto.node_crypto_asymmetric_key_input, .{}),
            b.argument("digest", b.optional(node_crypto.node_crypto_digest_handle), .{}),
            b.argument("data", b.buffer(.copy), .{}),
        },
        sign_job_handle,
        .current_realm_node_throwing,
    ),
    b.engineShim(
        "nodeCryptoVerifyCreate",
        .{
            b.argument("key", node_crypto.node_crypto_asymmetric_key_input, .{}),
            b.argument("digest", b.optional(node_crypto.node_crypto_digest_handle), .{}),
            b.argument("data", b.buffer(.copy), .{}),
            b.argument("signature", b.buffer(.copy), .{}),
        },
        sign_job_handle,
        .current_realm_node_throwing,
    ),
    b.engineShim(
        "nodeCryptoSignRunTask",
        .{b.argument("job", sign_job_handle, .{})},
        b.none,
        .realm_independent,
    ),
    b.engineShim(
        "nodeCryptoSignTakeResult",
        .{b.argument("job", sign_job_handle, .{})},
        b.optional(b.buffer(.copy)),
        .realm_independent_allocating,
    ),
    b.engineShim(
        "nodeCryptoVerifyTakeResult",
        .{b.argument("job", sign_job_handle, .{})},
        b.optional(b.boolean),
        .realm_independent_allocating,
    ),
    b.engineShim(
        "nodeCryptoKeyPairCreate",
        .{b.argument("request", node_crypto.node_crypto_key_pair_request, .{})},
        key_pair_job_handle,
        .current_realm_node_throwing,
    ),
    b.engineShim(
        "nodeCryptoKeyPairRunTask",
        .{b.argument("job", key_pair_job_handle, .{})},
        b.none,
        .realm_independent_allocating,
    ),
    b.engineShim(
        "nodeCryptoKeyPairResult",
        .{b.argument("job", key_pair_job_handle, .{})},
        node_crypto.node_crypto_key_pair_result,
        .current_realm_throwing,
    ),
};

pub const schema = b.moduleWithDeclarations("node_crypto_engine", .{}, .{}, engine_shims, .{});
