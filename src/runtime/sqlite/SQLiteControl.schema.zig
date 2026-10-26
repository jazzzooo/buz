const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const types = @import("binding_schema_SQLiteTypes");

const output_buffer = b.writableBufferViewWithOptions(.lease, .{
    .allow_detached = false,
    .allow_shared = false,
});

const integer32 = b.unionType("SQLiteControlInt32", .{
    b.unionMemberWithOptions("number", b.int32, .{ .integer_conversion = .{ .node_validate = .{ .min = -2147483648, .max = 2147483647 } } }),
    b.unionMember("buffer", output_buffer),
}, .{ .ordered = true, .cpp_name = "SQLiteControlInt32" });

const integer64 = b.unionType("SQLiteControlInt64", .{
    b.unionMemberWithOptions("number", b.int64, .{ .integer_conversion = .{ .node_validate = .{ .min = -9007199254740991, .max = 9007199254740991 } } }),
    b.unionMember("bigint", b.integerRepresentation(b.int64, .bigint)),
    b.unionMember("buffer", output_buffer),
}, .{ .ordered = true, .cpp_name = "SQLiteControlInt64" });

const retry_options = b.dictionaryWithOptions("SQLiteControlRetryOptions", .{
    b.dictionaryField("retries", b.int32, .{}),
    b.dictionaryField("delay", b.int32, .{}),
}, .{ .cpp_name = "SQLiteControlRetryOptions" });
const retry_input = b.unionType("SQLiteControlRetryInput", .{
    b.unionMember("buffer", output_buffer),
    b.unionMember("options", retry_options),
}, .{ .ordered = true, .cpp_name = "SQLiteControlRetryInput" });
const retry_value = b.dictionaryWithOptions("SQLiteControlRetryValue", .{
    b.dictionaryField("retries", b.int32, .{ .required = true }),
    b.dictionaryField("delay", b.int32, .{ .required = true }),
}, .{ .cpp_name = "SQLiteControlRetryValue" });

const pragma = b.dictionaryWithOptions("SQLiteControlPragma", .{
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("value", b.dom_string, .{}),
}, .{ .cpp_name = "SQLiteControlPragma" });

const result_value = b.unionType("SQLiteControlValue", .{
    b.unionMember("number", b.double),
    b.unionMember("integer", b.integerRepresentation(b.int64, .bigint)),
    b.unionMember("text", b.dom_string),
    b.unionMember("retry", retry_value),
    b.unionMember("handle", types.control_handle),
    b.unionMember("null_value", b.null_literal),
}, .{ .ordered = true, .cpp_name = "SQLiteControlValue" });

const result = b.dictionaryWithOptions("SQLiteFileControl", .{
    b.dictionaryField("statusCode", b.int32, .{ .required = true }),
    b.dictionaryField("value", result_value, .{ .required = true }),
}, .{ .cpp_name = "SQLiteFileControl" });

fn control(comptime name: []const u8, comptime argument: b.Type) b.Function {
    return b.function(name, .{
        b.argument("database", types.database, .{}),
        b.argument("databaseName", archetypes.nullable_dom_string, .{}),
        b.argument("operation", b.int32, .{}),
        b.argument("argument", b.lazy(argument), .{
            .deferred_reason = "SQLite validates the connection and file-control operation before converting its payload",
        }),
    }, result, .{
        .backend = .cpp,
        .profile = .node,
        .missing_required_arguments = .convert_undefined,
    });
}

pub const schema = b.module("SQLiteControl", .{
    control("int32", b.optionalNullish(integer32)),
    control("int64", b.optionalNullish(integer64)),
    control("retry", b.optionalNullish(retry_input)),
    control("string", archetypes.nullable_dom_string),
    control("pragma", pragma),
    control("query", b.optionalNullish(b.undefined_literal)),
    control("notify", b.optionalNullish(b.undefined_literal)),
});
