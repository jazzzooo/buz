const b = @import("bindgen_schema");
const engine_types = @import("binding_schema_engine_types");

const napi_env = b.nominalHandle("NapiEnv", .{
    .cpp_type = .{ .named = "napi_env" },
    .cpp_declarations = &.{ .{ .structure = "NapiEnv" }, .{ .alias = .{ .name = "napi_env", .type = .{ .pointer = &.{ .named = "NapiEnv" } } } } },
    .access_thread = .vm,
});

const napi_handle_scope = b.nominalHandle("NapiHandleScope", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::NapiHandleScopeImpl" } },
    .cpp_declarations = &.{.{ .class = "Bun::NapiHandleScopeImpl" }},
    .access_thread = .vm,
});

const engine_shims = .{
    b.engineShim(
        "napiEnvGlobalObject",
        .{b.argument("env", napi_env, .{})},
        engine_types.global_object,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "napiEnvCheckException",
        .{b.argument("env", napi_env, .{})},
        b.boolean,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "napiEnvGetAndClearPendingException",
        .{b.argument("env", napi_env, .{})},
        b.optional(b.engine_value),
        .current_realm_unchecked,
    ),
    b.engineShim(
        "napiHandleScopeAppend",
        .{
            b.argument("env", napi_env, .{}),
            b.argument("value", b.engine_value, .{}),
        },
        b.none,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "napiHandleScopeEscape",
        .{
            b.argument("scope", napi_handle_scope, .{}),
            b.argument("value", b.engine_value, .{}),
        },
        b.boolean,
        .current_realm_unchecked,
    ),
};

const native_exports = .{
    b.nativeExportWithOptions("pollCleanupHooks", .{}, b.none, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("NAPI", .{}, .{}, engine_shims, native_exports);
