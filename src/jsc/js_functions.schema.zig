const b = @import("bindgen_schema");
const engine_types = @import("binding_schema_engine_types");

const function_value = b.brandedValueWithBrand(b.cppDynamicCastBrand("HostFunctionValue", .{
    .type_name = "JSC::JSFunction",
    .header = "JavaScriptCore/JSFunction.h",
}, "Function"), .{});

const ffi_function_value = b.brandedValueWithBrand(b.cppDynamicCastBrand("FFIFunctionValue", .{
    .type_name = "Zig::JSFFIFunction",
    .header = "JSFFIFunction.h",
}, "Function"), .{});

const host_function_data_handle = b.nominalHandle("HostFunctionData", .{
    .cpp_type = .{ .pointer = &.{ .named = "BindNativeHandle" } },
    .cpp_declarations = &.{},
    .access_thread = .vm,
});

const engine_shims = .{
    b.engineShim(
        "jsValueBind",
        .{
            b.argument("function", b.engine_value, .{}),
            b.argument("bindThis", b.engine_value, .{}),
            b.argument("name", b.dom_string, .{}),
            b.argument("length", b.double, .{}),
            b.argument("arguments", b.sequence(b.engine_value), .{}),
        },
        b.js_bound_function,
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsValueCall",
        .{
            b.argument("function", b.brandCast(engine_types.callable_or_async_context_value, .{ .failure = .assert, .input = .engine_value }), .{}),
            b.argument("this_value", b.optional(b.engine_value), .{}),
            b.argument("arguments", b.sequence(b.invocation_any), .{}),
        },
        b.engine_value,
        .current_realm_throwing,
    ),
    b.engineShim(
        "bindingFunctionCreate",
        .{
            b.argument("symbolName", b.dom_string, .{}),
            b.argument("argumentCount", b.uint32, .{}),
            b.argument("function", engine_types.host_function, .{}),
        },
        function_value,
        .current_realm_throwing,
    ),
    b.engineShim(
        "bindingFunctionCreateWithData",
        .{
            b.argument("symbolName", b.dom_string, .{}),
            b.argument("argumentCount", b.uint32, .{}),
            b.argument("function", engine_types.host_function, .{}),
            b.argument("data", host_function_data_handle, .{}),
        },
        ffi_function_value,
        .current_realm_throwing,
    ),
    b.engineShim(
        "bindingFunctionClearData",
        .{b.argument("function", ffi_function_value, .{})},
        b.none,
        .current_realm_unchecked,
    ),
};

pub const schema = b.moduleWithDeclarations("js_functions", .{}, .{}, engine_shims, .{});
