const b = @import("bindgen_schema");

pub const mysql_error = b.dictionary("MySQLErrorPayload", .{
    b.dictionaryField("code", b.dom_string, .{ .required = true }),
    b.dictionaryField("error_number", b.uint16, .{ .js_name = "errno" }),
    b.dictionaryField("sql_state", b.dom_string, .{ .js_name = "sqlState" }),
    b.dictionaryField("message", b.dom_string, .{ .required = true }),
});

pub const postgres_error = b.dictionary("PostgresErrorPayload", .{
    b.dictionaryField("code", b.dom_string, .{ .required = true }),
    b.dictionaryField("error_number", b.dom_string, .{ .js_name = "errno" }),
    b.dictionaryField("detail", b.dom_string, .{}),
    b.dictionaryField("hint", b.dom_string, .{}),
    b.dictionaryField("severity", b.dom_string, .{}),
    b.dictionaryField("position", b.dom_string, .{}),
    b.dictionaryField("internal_position", b.dom_string, .{ .js_name = "internalPosition" }),
    b.dictionaryField("internal_query", b.dom_string, .{ .js_name = "internalQuery" }),
    b.dictionaryField("where", b.dom_string, .{}),
    b.dictionaryField("schema", b.dom_string, .{}),
    b.dictionaryField("table", b.dom_string, .{}),
    b.dictionaryField("column", b.dom_string, .{}),
    b.dictionaryField("data_type", b.dom_string, .{ .js_name = "dataType" }),
    b.dictionaryField("constraint", b.dom_string, .{}),
    b.dictionaryField("file", b.dom_string, .{}),
    b.dictionaryField("line", b.dom_string, .{}),
    b.dictionaryField("routine", b.dom_string, .{}),
    b.dictionaryField("message", b.dom_string, .{ .required = true }),
});

pub const mysql_failure = b.builtinError("mysql_failure", mysql_error, .{
    .group = "sqlErrors",
    .function = "createMySQLError",
});

pub const postgres_failure = b.builtinError("postgres_failure", postgres_error, .{
    .group = "sqlErrors",
    .function = "createPostgresError",
});

pub const schema = b.module("SQLErrors", .{});
