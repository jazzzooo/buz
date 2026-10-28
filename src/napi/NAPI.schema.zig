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

const array_buffer_data = b.nominalHandle("NAPIArrayBufferData", .{
    .cpp_type = .{ .pointer = &.{ .named = "uint8_t" } },
    .cpp_declarations = &.{},
    .raw_pointer_escape = "the external Node-API ABI exposes backing-store memory to addon code",
    .access_thread = .vm,
});
const unsafe_array_buffer_view = b.dictionaryWithOptions("NAPIUnsafeArrayBufferView", .{
    b.dictionaryField("data", b.optional(array_buffer_data), .{ .required = true }),
    b.dictionaryField("length", b.size, .{ .required = true }),
    b.dictionaryField("byte_length", b.size, .{ .required = true }),
    b.dictionaryField("byte_offset", b.size, .{ .required = true }),
    b.dictionaryField("cell_type", b.uint8, .{ .required = true }),
    b.dictionaryField("shared", b.boolean, .{ .required = true }),
    b.dictionaryField("resizable", b.boolean, .{ .required = true }),
}, .{ .cpp_name = "NAPIUnsafeArrayBufferView" });

const engine_shims = .{
    b.engineShim("arrayBufferViewUnsafe", .{b.argument("value", b.engine_value, .{})}, b.optional(unsafe_array_buffer_view), .current_realm_unchecked),
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

pub const schema = b.moduleWithEngineShims("NAPI", .{}, engine_shims);
