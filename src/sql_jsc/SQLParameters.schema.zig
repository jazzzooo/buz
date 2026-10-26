const b = @import("bindgen_schema");
const sql = @import("binding_schema_SQLTypes");

const mysql_type_hint = b.enumerationWithOptions("SQLMySQLTypeHint", .{
    b.enumerationValue("null_value", "null"),
    b.enumerationValue("string", "string"),
    b.enumerationValue("datetime", "datetime"),
    b.enumerationValue("blob", "blob"),
    b.enumerationValue("signed_longlong", "signed_longlong"),
    b.enumerationValue("unsigned_longlong", "unsigned_longlong"),
    b.enumerationValue("signed_long", "signed_long"),
    b.enumerationValue("unsigned_long", "unsigned_long"),
    b.enumerationValue("double_value", "double"),
    b.enumerationValue("boolean", "boolean"),
    b.enumerationValue("json", "json"),
    b.enumerationValue("varchar", "varchar"),
}, .{ .cpp_name = "SQLMySQLTypeHint" });

const postgres_type_hint = b.enumerationWithOptions("SQLPostgresTypeHint", .{
    b.enumerationValue("null_value", "null"),
    b.enumerationValue("numeric", "numeric"),
    b.enumerationValue("text", "text"),
    b.enumerationValue("timestamptz", "timestamptz"),
    b.enumerationValue("int4_array", "int4_array"),
    b.enumerationValue("bytea", "bytea"),
    b.enumerationValue("int8", "int8"),
    b.enumerationValue("json", "json"),
    b.enumerationValue("int4", "int4"),
    b.enumerationValue("float8", "float8"),
    b.enumerationValue("boolean", "boolean"),
}, .{ .cpp_name = "SQLPostgresTypeHint" });

const parameter_kind = b.enumerationWithOptions("SQLParameterKind", .{
    b.enumerationValue("boolean", "boolean"),
    b.enumerationValue("int16", "int16"),
    b.enumerationValue("uint16", "uint16"),
    b.enumerationValue("int32", "int32"),
    b.enumerationValue("uint32", "uint32"),
    b.enumerationValue("int64", "int64"),
    b.enumerationValue("uint64", "uint64"),
    b.enumerationValue("float32", "float32"),
    b.enumerationValue("float64", "float64"),
    b.enumerationValue("date", "date"),
    b.enumerationValue("time", "time"),
    b.enumerationValue("bytes", "bytes"),
    b.enumerationValue("int32_array", "int32_array"),
    b.enumerationValue("json", "json"),
    b.enumerationValue("text", "text"),
}, .{ .cpp_name = "SQLParameterKind" });

const null_value = b.enumerationWithOptions("SQLParameterNull", .{
    b.enumerationValue("null_value", "null"),
}, .{ .cpp_name = "SQLParameterNull" });

const parameter = b.unionType("SQLParameter", .{
    b.unionMember("null_value", null_value),
    b.unionMember("boolean", b.boolean),
    b.unionMember("int16", b.int16),
    b.unionMember("uint16", b.uint16),
    b.unionMember("int32", b.int32),
    b.unionMember("uint32", b.uint32),
    b.unionMember("int64", b.int64),
    b.unionMember("uint64", b.uint64),
    b.unionMember("float32", b.double),
    b.unionMember("float64", b.double),
    b.unionMember("date", b.double),
    b.unionMember("time", b.double),
    b.unionMember("text", b.buffer(.copy)),
    b.unionMember("bytes", b.buffer(.copy)),
    b.unionMember("int32_array", b.buffer(.copy)),
}, .{ .input_tag = .{ .tag_property = "kind", .value_property = "value" }, .cpp_name = "SQLParameter" });

fn operation(comptime name: []const u8, comptime materialize: bool, comptime result: b.Type) b.EngineShim {
    const inputs = .{
        b.argument("values", sql.binding_values, .{}),
        b.argument("columns", b.optional(sql.binding_columns), .{}),
    };
    return b.engineShim(name, if (materialize)
        inputs ++ .{b.argument("plan", b.sequence(parameter_kind), .{})}
    else
        inputs, b.sequence(result), .current_realm_throwing);
}

pub const schema = b.moduleWithDeclarations("SQLParameters", .{}, .{}, .{
    b.engineShim("count", .{
        b.argument("values", sql.binding_values, .{}),
        b.argument("columns", b.optional(sql.binding_columns), .{}),
    }, b.uint64, .current_realm_unchecked),
    operation("inferMySQL", false, mysql_type_hint),
    operation("inferPostgres", false, postgres_type_hint),
    operation("materializeMySQL", true, parameter),
    operation("materializePostgres", true, parameter),
}, .{});
