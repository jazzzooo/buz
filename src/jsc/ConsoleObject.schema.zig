const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const format_options = formatOptions("ConsoleFormatOptions", b.dictionaryField("depth", b.optionalNullish(b.uint16), .{
    .default_value = .null,
    .integer_conversion = .{ .clamp = .{ .min = 0, .max = 65535 } },
}));

const invalid_inspect_depth: b.ConversionFailure = .{
    .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
    .message = "expected depth to be a non-negative integer",
};
const inspect_depth = b.unionType("InspectDepth", .{
    b.unionMemberWithOptions("number", b.uint16, .{ .integer_conversion = .{ .bounded_integer = .{
        .range = .{ .min = 0, .max = 65535 },
        .above = .saturate,
        .allow_infinity = true,
        .invalid = invalid_inspect_depth,
        .out_of_range = invalid_inspect_depth,
    } } }),
    b.unionMember("ignored", b.discardAny(.ignored)),
}, .{ .ordered = true, .fallback_member = "ignored" });
pub const inspect_format_options = formatOptions("InspectFormatOptions", b.dictionaryField("depth", inspect_depth, .{}));

fn formatOptions(comptime name: []const u8, comptime depth_field: b.DictionaryField) b.Type {
    return b.dictionaryWithOptions(name, .{
        depth_field,
        b.dictionaryField("colors", b.boolean, .{ .boolean_conversion = .truthy }),
        b.dictionaryField("sorted", b.boolean, .{ .boolean_conversion = .truthy }),
        b.dictionaryField("compact", b.boolean, .{ .boolean_conversion = .truthy }),
    }, .{ .user_facing_name = "inspect options" });
}

pub const inspect_arguments = .{
    b.argument("depth", archetypes.int32_or_ignored, .{
        .presence = .default_value,
        .default_value = .null,
        .missing = .undefined_or_null,
        .integer_conversion = .{ .matching = .{ .min = -2147483648, .max = 2147483647 } },
    }),
    b.argument("options", format_options, .{ .presence = .optional, .missing = .omitted }),
};

pub const native_inspect = b.method("inspectCustom", inspect_arguments, b.dom_string, .{
    .backend = .zig,
    .symbol = .inspect_custom,
    .enumerable = false,
    .length = 2,
    .this_value_type = b.this_class_ref,
});

const functions = .{
    b.function("callCustomInspect", .{
        b.argument("callback", b.any, .{}),
        b.argument("depth", b.int32, .{}),
        b.argument("maxDepth", b.uint32, .{}),
        b.argument("colors", b.boolean, .{}),
        b.argument("sorted", b.boolean, .{}),
        b.argument("compact", b.boolean, .{}),
        b.argument("inspect", b.any, .{}),
        b.argument("stylize", b.any, .{}),
    }, b.any, .{
        .backend = .builtin,
        .builtin = "utilInspectCallCustomInspectCodeGenerator",
        .profile = .exact,
        .length = 8,
    }),
};

const engine_shims = .{
    b.engineShim("callCustomInspectFunction", .{
        b.argument("function", b.brandCast(archetypes.callable_value, .{ .failure = .assert, .input = .engine_value }), .{}),
        b.argument("thisValue", b.engine_value, .{}),
        b.argument("depth", b.int32, .{}),
        b.argument("maxDepth", b.uint32, .{}),
        b.argument("colors", b.boolean, .{}),
        b.argument("sorted", b.boolean, .{}),
        b.argument("compact", b.boolean, .{}),
    }, b.engine_value, .current_realm_throwing),
};

const native_exports = .{
    b.nativeExportWithOptions("consoleCount", .{b.argument("label", b.dom_string, .{})}, b.none, .current_realm_throwing),
    b.nativeExportWithOptions("consoleCountReset", .{b.argument("label", b.dom_string, .{})}, b.none, .current_realm_nonthrowing),
    b.nativeExportWithOptions("consoleTime", .{b.argument("label", b.dom_string, .{})}, b.none, .current_realm_throwing),
    b.nativeExportWithOptions("consoleTimeEnd", .{b.argument("label", b.dom_string, .{})}, b.none, .current_realm_throwing),
    b.nativeExportWithOptions("consoleTakeHeapSnapshot", .{b.argument("label", b.dom_string, .{})}, b.none, .current_realm_nonthrowing),
    b.nativeExportWithOptions("inspectSingleLine", .{b.argument("value", b.engine_value, .{})}, b.dom_string, .current_realm_throwing),
    b.nativeExportWithOptions("inspectValueForErrorMessage", .{b.argument("value", b.engine_value, .{})}, b.dom_string, .current_realm_throwing),
    b.nativeExportWithOptions("messageWithTypeAndLevel", .{
        b.argument("messageType", b.uint32, .{}),
        b.argument("messageLevel", b.uint32, .{}),
        b.argument("values", b.sequence(b.engine_value), .{}),
    }, b.none, .current_realm_throwing),
    b.nativeExportWithOptions("timeLog", .{
        b.argument("label", b.dom_string, .{}),
        b.argument("values", b.sequence(b.engine_value), .{}),
    }, b.none, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("ConsoleObject", functions, .{}, engine_shims, native_exports);
