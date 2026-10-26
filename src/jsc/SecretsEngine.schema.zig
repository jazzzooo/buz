const b = @import("bindgen_schema");

const job_operation = b.enumeration("SecretsJobOperation", .{
    b.enumerationValue("get", "get"),
    b.enumerationValue("set", "set"),
    b.enumerationValue("delete_op", "delete"),
});
const job_error = b.enumeration("SecretsJobError", .{
    b.enumerationValue("none", "none"),
    b.enumerationValue("not_found", "not-found"),
    b.enumerationValue("access_denied", "access-denied"),
    b.enumerationValue("platform_error", "platform-error"),
});
const job_result = b.dictionary("SecretsJobResult", .{
    b.dictionaryField("error_kind", job_error, .{ .required = true }),
    b.dictionaryField("platform_code", b.int32, .{ .required = true }),
    b.dictionaryField("message", b.thread_safe_dom_string, .{ .required = true }),
    b.dictionaryField("password", b.optional(b.thread_safe_dom_string), .{ .required = true }),
    b.dictionaryField("deleted", b.boolean, .{ .required = true }),
});
const job_options_handle = b.nominalHandle("SecretsJobOptions", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::SecretsJobOptions" } },
    .cpp_declarations = &.{.{ .structure = "Bun::SecretsJobOptions" }},
    .ownership = .owned,
    .cpp_release = "releaseSecretsJobOptions",
    .access_thread = .any,
    .destroy_thread = .any,
});

const engine_shims = .{
    b.engineShim(
        "secretsJobCreate",
        .{
            b.argument("operation", job_operation, .{}),
            b.argument("service", b.thread_safe_dom_string, .{}),
            b.argument("name", b.thread_safe_dom_string, .{}),
            b.argument("password", b.optional(b.thread_safe_dom_string), .{}),
            b.argument("allow_unrestricted_access", b.boolean, .{}),
        },
        job_options_handle,
        .realm_independent,
    ),
    b.engineShim(
        "secretsJobRunTask",
        .{b.argument("options", job_options_handle, .{})},
        b.none,
        .realm_independent,
    ),
    b.engineShim("secretsJobTakeResult", .{b.argument("options", job_options_handle, .{})}, job_result, .realm_independent_allocating),
};

pub const schema = b.moduleWithDeclarations("secrets_engine", .{}, .{}, engine_shims, .{});
