const b = @import("bindgen_schema");

pub fn queryResultMode(comptime name: []const u8) b.Argument {
    return b.argument(name, b.uint8, .{
        .integer_conversion = .{ .enforce_range = .{ .min = 0, .max = 2 } },
    });
}

fn valueBrand(comptime name: []const u8, comptime matcher: []const u8, comptime ts_type: []const u8) b.Brand {
    return b.cppBrand(name, .{
        .symbol = "Bun::Bindgen::TypePredicates::" ++ matcher,
        .header = "BindgenTypePredicates.h",
    }, ts_type);
}

pub const binding_values = b.brandedValueWithBrand(valueBrand("SQLBindingValues", "isArray", "unknown[]"), .{
    .error_kind = .type,
    .expectation = "an Array",
    .node_requirement = "Array",
});

pub const result_rows = b.brandedValueWithBrand(valueBrand("SQLResultRows", "isArray", "unknown[]"), .{
    .error_kind = .type,
    .expectation = "an Array",
    .node_requirement = "Array",
});

pub const binding_columns = b.brandedValueWithBrand(valueBrand("SQLBindingColumns", "isArray", "unknown[]"), .{
    .error_kind = .type,
    .expectation = "an Array",
    .node_requirement = "Array",
});

const null_value = b.enumerationWithOptions("SQLNullValue", .{
    b.enumerationValue("null_value", "null"),
}, .{ .cpp_name = "SQLNullValue" });

const json_null_value = b.enumerationWithOptions("SQLJSONNullValue", .{
    b.enumerationValue("null_value", "null"),
}, .{ .cpp_name = "SQLJSONNullValue" });

const string_latin1 = b.dictionaryWithOptions("SQLStringLatin1", .{
    b.dictionaryField("units", b.sequence(b.uint8), .{ .required = true }),
}, .{ .cpp_name = "SQLStringLatin1" });

const string_utf16 = b.dictionaryWithOptions("SQLStringUTF16", .{
    b.dictionaryField("units", b.sequence(b.uint16), .{ .required = true }),
}, .{ .cpp_name = "SQLStringUTF16" });

const json_latin1 = b.dictionaryWithOptions("SQLJSONLatin1", .{
    b.dictionaryField("units", b.sequence(b.uint8), .{ .required = true }),
}, .{ .cpp_name = "SQLJSONLatin1" });

const json_utf16 = b.dictionaryWithOptions("SQLJSONUTF16", .{
    b.dictionaryField("units", b.sequence(b.uint16), .{ .required = true }),
}, .{ .cpp_name = "SQLJSONUTF16" });

const typed_array_kind = b.enumerationWithOptions("SQLTypedArrayKind", .{
    b.enumerationValue("int32", "int32"),
    b.enumerationValue("float32", "float32"),
}, .{ .cpp_name = "SQLTypedArrayKind" });

const typed_array = b.dictionaryWithOptions("SQLTypedArray", .{
    b.dictionaryField("kind", typed_array_kind, .{ .required = true }),
    b.dictionaryField("bytes", b.sequence(b.uint8), .{ .required = true }),
    b.dictionaryField("length", b.uint32, .{ .required = true }),
}, .{ .cpp_name = "SQLTypedArray" });

const date_value = b.dictionaryWithOptions("SQLDateValue", .{
    b.dictionaryField("milliseconds", b.double, .{ .required = true }),
}, .{ .cpp_name = "SQLDateValue" });

const date_with_timezone_value = b.dictionaryWithOptions("SQLDateWithTimezoneValue", .{
    b.dictionaryField("milliseconds", b.double, .{ .required = true }),
}, .{ .cpp_name = "SQLDateWithTimezoneValue" });

const bytea_value = b.dictionaryWithOptions("SQLByteaValue", .{
    b.dictionaryField("bytes", b.sequence(b.uint8), .{ .required = true }),
}, .{ .cpp_name = "SQLByteaValue" });

const array_value = b.dictionaryWithOptions("SQLArrayValue", .{
    b.dictionaryField("length", b.uint32, .{ .required = true }),
}, .{ .cpp_name = "SQLArrayValue" });

const raw_value = b.dictionaryWithOptions("SQLRawValue", .{
    b.dictionaryField("bytes", b.sequence(b.uint8), .{ .required = true }),
}, .{ .cpp_name = "SQLRawValue" });

const data_cell_node = b.unionType("SQLDataCellNode", .{
    b.unionMember("null_value", null_value),
    b.unionMember("string_latin1", string_latin1),
    b.unionMember("string_utf16", string_utf16),
    b.unionMember("double_value", b.double),
    b.unionMember("int32", b.int32),
    b.unionMember("int64", b.int64),
    b.unionMember("boolean", b.boolean),
    b.unionMember("date", date_value),
    b.unionMember("date_with_timezone", date_with_timezone_value),
    b.unionMember("bytea", bytea_value),
    b.unionMember("json_null", json_null_value),
    b.unionMember("json_latin1", json_latin1),
    b.unionMember("json_utf16", json_utf16),
    b.unionMember("array", array_value),
    b.unionMember("typed_array", typed_array),
    b.unionMember("raw", raw_value),
    b.unionMember("uint32", b.uint32),
    b.unionMember("uint64", b.uint64),
}, .{ .ordered = true, .cpp_name = "SQLDataCellNode" });

const result_column_index = b.dictionaryWithOptions("SQLResultColumnIndex", .{
    b.dictionaryField("value", b.uint32, .{ .required = true }),
}, .{ .cpp_name = "SQLResultColumnIndex" });

const result_column_offset = b.dictionaryWithOptions("SQLResultColumnOffset", .{
    b.dictionaryField("value", b.uint32, .{ .required = true }),
}, .{ .cpp_name = "SQLResultColumnOffset" });

const result_column_slot = b.unionType("SQLResultColumnSlot", .{
    b.unionMember("duplicate", null_value),
    b.unionMember("indexed", result_column_index),
    b.unionMember("named_latin1", b.sequence(b.uint8)),
    b.unionMember("named_utf16", b.sequence(b.uint16)),
    b.unionMember("named_offset", result_column_offset),
}, .{ .ordered = true, .cpp_name = "SQLResultColumnSlot" });

const result_layout_flags = b.dictionaryWithOptions("SQLResultLayoutFlags", .{
    b.dictionaryField("has_indexed_columns", b.boolean, .{ .required = true }),
    b.dictionaryField("has_named_columns", b.boolean, .{ .required = true }),
    b.dictionaryField("has_duplicate_columns", b.boolean, .{ .required = true }),
}, .{ .cpp_name = "SQLResultLayoutFlags" });

const result_mode = b.enumerationWithOptions("SQLResultMode", .{
    b.enumerationValue("objects", "objects"),
    b.enumerationValue("values", "values"),
    b.enumerationValue("raw", "raw"),
}, .{ .cpp_name = "SQLResultMode" });

const engine_shims = .{
    b.engineShim("bindingValuesLength", .{b.argument("values", binding_values, .{})}, b.uint32, .current_realm_unchecked),
    b.engineShim("createObjectStructure", .{
        b.argument("values", binding_values, .{}),
        b.argument("slots", b.sequence(result_column_slot), .{}),
    }, b.optional(b.js_structure), .current_realm_nonthrowing),
    b.engineShim(
        "appendResultRow",
        .{
            b.argument("rows", result_rows, .{}),
            b.argument("structure", b.optional(b.js_structure), .{}),
            b.argument("nodes", b.sequence(data_cell_node), .{}),
            b.argument("count", b.uint32, .{}),
            b.argument("flags", result_layout_flags, .{}),
            b.argument("resultMode", result_mode, .{}),
            b.argument("slots", b.sequence(result_column_slot), .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim(
        "createResultRows",
        .{
            b.argument("values", binding_values, .{}),
            b.argument("structure", b.optional(b.js_structure), .{}),
            b.argument("nodes", b.sequence(data_cell_node), .{}),
            b.argument("count", b.uint32, .{}),
            b.argument("flags", result_layout_flags, .{}),
            b.argument("resultMode", result_mode, .{}),
            b.argument("slots", b.sequence(result_column_slot), .{}),
        },
        result_rows,
        .current_realm_throwing,
    ),
};

pub const schema = b.moduleWithDeclarations("SQLTypes", .{}, .{}, engine_shims, .{});
