const std = @import("std");
const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const deferred_password_operand = "password hashing selects and validates the algorithm before converting secret input bytes";
const deferred_password_cost = "the selected password algorithm determines which cost fields are read, and timeCost validation precedes memoryCost access";

const algorithm_name_input = b.unionType("PasswordAlgorithmNameInput", .{
    b.unionMember("name", b.dom_string),
    b.unionMember("null_value", b.null_literal),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const algorithm_number_input = b.unionType("PasswordAlgorithmNumberInput", .{
    b.unionMemberWithOptions("number", b.int32, .{ .integer_conversion = .truncate_saturate }),
    b.unionMember("null_value", b.null_literal),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const hash_algorithm_options = b.dictionary("PasswordHashAlgorithmOptions", .{
    b.dictionaryField("algorithm", algorithm_name_input, .{}),
    b.dictionaryField("cost", b.lazy(algorithm_number_input), .{
        .required = true,
        .missing_required = .convert_undefined,
        .deferred_reason = deferred_password_cost,
    }),
    b.dictionaryField("time_cost", b.lazy(algorithm_number_input), .{
        .js_name = "timeCost",
        .required = true,
        .missing_required = .convert_undefined,
        .deferred_reason = deferred_password_cost,
    }),
    b.dictionaryField("memory_cost", b.lazy(algorithm_number_input), .{
        .js_name = "memoryCost",
        .required = true,
        .missing_required = .convert_undefined,
        .deferred_reason = deferred_password_cost,
    }),
});

const hash_algorithm = b.unionType("PasswordHashAlgorithmInput", .{
    b.unionMember("name", b.dom_string),
    b.unionMember("options", hash_algorithm_options),
    b.unionMember("null_value", b.null_literal),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const verify_algorithm = b.unionType("PasswordVerifyAlgorithmInput", .{
    b.unionMember("name", b.dom_string),
    b.unionMember("null_value", b.null_literal),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const async_input = archetypes.thread_safe_coerced_string_or_copied_buffer;

const sync_input = b.unionType("PasswordSyncInput", .{
    b.unionMember("buffer", b.buffer(.lease)),
    b.unionMember("string", archetypes.string_like_dom_string),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

fn literalError(
    comptime name: []const u8,
    comptime message: []const u8,
) b.DomainError {
    return b.domainError(name, b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = message },
    });
}

fn operationError(
    comptime name: []const u8,
    comptime zig_name: []const u8,
    comptime operation: []const u8,
    comptime code: []const u8,
) b.DomainError {
    return b.domainError(name, b.none, .{
        .class = .generic_error,
        .code = code,
        .message = .{ .literal = "Password " ++ operation ++ " failed with error \"" ++ zig_name ++ "\"" },
    });
}

const hash_runtime_errors = .{
    operationError("authentication_failed", "AuthenticationFailed", "hashing", "PASSWORD_AUTHENTICATION_FAILED"),
    operationError("output_too_long", "OutputTooLong", "hashing", "PASSWORD_OUTPUT_TOO_LONG"),
    operationError("identity_element", "IdentityElement", "hashing", "PASSWORD_IDENTITY_ELEMENT"),
    operationError("invalid_encoding", "InvalidEncoding", "hashing", "PASSWORD_INVALID_ENCODING"),
    operationError("signature_verification_failed", "SignatureVerificationFailed", "hashing", "PASSWORD_SIGNATURE_VERIFICATION_FAILED"),
    operationError("key_mismatch", "KeyMismatch", "hashing", "PASSWORD_KEY_MISMATCH"),
    operationError("non_canonical", "NonCanonical", "hashing", "PASSWORD_NON_CANONICAL"),
    operationError("not_square", "NotSquare", "hashing", "PASSWORD_NOT_SQUARE"),
    operationError("password_verification_failed", "PasswordVerificationFailed", "hashing", "PASSWORD_PASSWORD_VERIFICATION_FAILED"),
    operationError("weak_parameters", "WeakParameters", "hashing", "PASSWORD_WEAK_PARAMETERS"),
    operationError("weak_public_key", "WeakPublicKey", "hashing", "PASSWORD_WEAK_PUBLIC_KEY"),
    operationError("unexpected_subgroup", "UnexpectedSubgroup", "hashing", "PASSWORD_UNEXPECTED_SUBGROUP"),
    operationError("context_too_long", "ContextTooLong", "hashing", "PASSWORD_CONTEXT_TOO_LONG"),
    operationError("thread_quota_exceeded", "ThreadQuotaExceeded", "hashing", "PASSWORD_THREAD_QUOTA_EXCEEDED"),
    operationError("system_resources", "SystemResources", "hashing", "PASSWORD_SYSTEM_RESOURCES"),
    operationError("locked_memory_limit_exceeded", "LockedMemoryLimitExceeded", "hashing", "PASSWORD_LOCKED_MEMORY_LIMIT_EXCEEDED"),
    operationError("unexpected", "Unexpected", "hashing", "PASSWORD_UNEXPECTED"),
    operationError("canceled", "Canceled", "hashing", "PASSWORD_CANCELED"),
    operationError("no_space_left", "NoSpaceLeft", "hashing", "PASSWORD_NO_SPACE_LEFT"),
    operationError("allocator_required", "AllocatorRequired", "hashing", "PASSWORD_ALLOCATOR_REQUIRED"),
    operationError("unsupported_algorithm", "UnsupportedAlgorithm", "hashing", "PASSWORD_UNSUPPORTED_ALGORITHM"),
    operationError("concurrency_unavailable", "ConcurrencyUnavailable", "hashing", "PASSWORD_CONCURRENCY_UNAVAILABLE"),
};

const verify_runtime_errors = .{
    operationError("authentication_failed", "AuthenticationFailed", "verification", "PASSWORD_AUTHENTICATION_FAILED"),
    operationError("output_too_long", "OutputTooLong", "verification", "PASSWORD_OUTPUT_TOO_LONG"),
    operationError("identity_element", "IdentityElement", "verification", "PASSWORD_IDENTITY_ELEMENT"),
    operationError("invalid_encoding", "InvalidEncoding", "verification", "PASSWORD_INVALID_ENCODING"),
    operationError("signature_verification_failed", "SignatureVerificationFailed", "verification", "PASSWORD_SIGNATURE_VERIFICATION_FAILED"),
    operationError("key_mismatch", "KeyMismatch", "verification", "PASSWORD_KEY_MISMATCH"),
    operationError("non_canonical", "NonCanonical", "verification", "PASSWORD_NON_CANONICAL"),
    operationError("not_square", "NotSquare", "verification", "PASSWORD_NOT_SQUARE"),
    operationError("password_verification_failed", "PasswordVerificationFailed", "verification", "PASSWORD_PASSWORD_VERIFICATION_FAILED"),
    operationError("weak_parameters", "WeakParameters", "verification", "PASSWORD_WEAK_PARAMETERS"),
    operationError("weak_public_key", "WeakPublicKey", "verification", "PASSWORD_WEAK_PUBLIC_KEY"),
    operationError("unexpected_subgroup", "UnexpectedSubgroup", "verification", "PASSWORD_UNEXPECTED_SUBGROUP"),
    operationError("context_too_long", "ContextTooLong", "verification", "PASSWORD_CONTEXT_TOO_LONG"),
    operationError("thread_quota_exceeded", "ThreadQuotaExceeded", "verification", "PASSWORD_THREAD_QUOTA_EXCEEDED"),
    operationError("system_resources", "SystemResources", "verification", "PASSWORD_SYSTEM_RESOURCES"),
    operationError("locked_memory_limit_exceeded", "LockedMemoryLimitExceeded", "verification", "PASSWORD_LOCKED_MEMORY_LIMIT_EXCEEDED"),
    operationError("unexpected", "Unexpected", "verification", "PASSWORD_UNEXPECTED"),
    operationError("canceled", "Canceled", "verification", "PASSWORD_CANCELED"),
    operationError("no_space_left", "NoSpaceLeft", "verification", "PASSWORD_NO_SPACE_LEFT"),
    operationError("allocator_required", "AllocatorRequired", "verification", "PASSWORD_ALLOCATOR_REQUIRED"),
    operationError("unsupported_algorithm", "UnsupportedAlgorithm", "verification", "PASSWORD_UNSUPPORTED_ALGORITHM"),
    operationError("concurrency_unavailable", "ConcurrencyUnavailable", "verification", "PASSWORD_CONCURRENCY_UNAVAILABLE"),
};

const hash_errors = b.domainErrors(.{
    literalError("missing_password", "Not enough arguments to 'hash'. Expected 1, got 0."),
    literalError("invalid_password", "Expected password to be a string or TypedArray for 'hash'."),
    literalError("empty_password", "password must not be empty"),
    literalError("invalid_algorithm_type", "Expected algorithm to be a string for 'hash'."),
    literalError("unknown_algorithm", "Expected algorithm to be a unknown algorithm, expected one of: \"bcrypt\", \"argon2id\", \"argon2d\", \"argon2i\" (default is \"argon2id\") for 'hash'."),
    literalError("missing_options_algorithm", "Expected options.algorithm to be a string for 'hash'."),
    literalError("invalid_cost_type", "Expected cost to be a number for 'hash'."),
    literalError("invalid_cost_range", "Rounds must be between 4 and 31"),
    literalError("invalid_time_cost_type", "Expected timeCost to be a number for 'hash'."),
    literalError("invalid_time_cost_range", "Time cost must be greater than 0"),
    literalError("invalid_memory_cost_type", "Expected memoryCost to be a number for 'hash'."),
    literalError("invalid_memory_cost_range", "Memory cost must be greater than 0"),
    literalError("invalid_memory_cost_minimum", "Memory cost must be at least 8"),
} ++ hash_runtime_errors);

const verify_errors = b.domainErrors(.{
    literalError("missing_arguments", "Not enough arguments to 'verify'. Expected 2, got 0."),
    literalError("invalid_password", "Expected password to be a string or TypedArray for 'verify'."),
    literalError("invalid_hash", "Expected hash to be a string or TypedArray for 'verify'."),
    literalError("invalid_algorithm_type", "Expected algorithm to be a string for 'verify'."),
    literalError("unknown_algorithm", "Expected algorithm to be a unknown algorithm, expected one of: \"bcrypt\", \"argon2id\", \"argon2d\", \"argon2i\" (default is \"argon2id\") for 'verify'."),
} ++ verify_runtime_errors);

fn hashFunction(
    comptime name: []const u8,
    comptime input: b.Type,
    comptime async: bool,
) b.Function {
    return b.function(
        name,
        .{
            b.argument("password", b.lazy(input), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_password_operand }),
            b.argument("algorithm", hash_algorithm, .{ .presence = .optional, .missing = .omitted }),
        },
        b.utf8_string,
        .{
            .backend = .zig,
            .length = 2,
            .profile = .exact,
            .errors = hash_errors,
            .completion = if (async) .{
                .retention = .pending_activity,
                .sender_drop = .cancel,
            } else null,
        },
    );
}

fn verifyFunction(
    comptime name: []const u8,
    comptime input: b.Type,
    comptime async: bool,
) b.Function {
    return b.function(
        name,
        .{
            b.argument("password", b.lazy(input), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_password_operand }),
            b.argument("hash", b.lazy(input), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_password_operand }),
            b.argument("algorithm", verify_algorithm, .{ .presence = .optional, .missing = .omitted }),
        },
        b.boolean,
        .{
            .backend = .zig,
            .length = 2,
            .profile = .exact,
            .errors = verify_errors,
            .completion = if (async) .{
                .retention = .pending_activity,
                .sender_drop = .cancel,
            } else null,
        },
    );
}

const functions = .{
    hashFunction("hash", async_input, true),
    hashFunction("hashSync", sync_input, false),
    verifyFunction("verify", async_input, true),
    verifyFunction("verifySync", sync_input, false),
};

pub const schema = b.module("PasswordObject", functions);
