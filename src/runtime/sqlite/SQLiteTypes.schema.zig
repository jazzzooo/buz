const b = @import("bindgen_schema");

pub const database = b.classRefByNameWithOptions("SQLiteNative", "Database", .{
    .no_match_error = .{ .kind = .type_error, .message = "Invalid database handle" },
});
pub const statement = b.classRefByName("SQLiteNative", "Statement");
pub const control_handle = b.classRefByName("SQLiteNative", "ControlHandle");
pub const control_handle_kind = b.enumerationWithOptions("SQLiteControlHandleKind", .{
    b.enumerationValue("database", "database"),
    b.enumerationValue("journal", "journal"),
    b.enumerationValue("vfs", "vfs"),
    b.enumerationValue("win32", "win32"),
}, .{ .cpp_name = "SQLiteControlHandleKind" });
pub const pointer_callback = b.callback("SQLitePointerCallback", .{
    b.argument("pointer", b.integerRepresentation(b.uint64, .bigint), .{}),
}, b.any, .{ .receiver = null, .profile = .exact });

pub const control_handle_data = b.nominalHandle("SQLiteControlHandleData", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::SQLiteControlHandleData" } },
    .cpp_declarations = &.{.{ .class = "WebCore::SQLiteControlHandleData" }},
    .zig_type = "api.SQLiteNative.ControlHandleData",
    .access_thread = .vm,
});
pub const owned_control_handle_data = b.nominalHandle("OwnedSQLiteControlHandleData", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::SQLiteControlHandleData" } },
    .cpp_declarations = &.{.{ .class = "WebCore::SQLiteControlHandleData" }},
    .zig_type = "api.SQLiteNative.ControlHandleData",
    .ownership = .owned,
    .cpp_release = "releaseSQLiteControlHandleData",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

pub const database_data = b.nominalHandle("SQLiteDatabaseData", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::SQLiteDatabaseData" } },
    .cpp_declarations = &.{.{ .class = "WebCore::SQLiteDatabaseData" }},
    .zig_type = "api.SQLiteNative.DatabaseData",
    .access_thread = .vm,
});
pub const owned_database_data = b.nominalHandle("OwnedSQLiteDatabaseData", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::SQLiteDatabaseData" } },
    .cpp_declarations = &.{.{ .class = "WebCore::SQLiteDatabaseData" }},
    .zig_type = "api.SQLiteNative.DatabaseData",
    .ownership = .owned,
    .cpp_release = "releaseSQLiteDatabaseData",
    .access_thread = .vm,
    .destroy_thread = .vm,
});
pub const statement_data = b.nominalHandle("SQLiteStatementData", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::SQLiteStatementData" } },
    .cpp_declarations = &.{.{ .class = "WebCore::SQLiteStatementData" }},
    .zig_type = "api.SQLiteNative.StatementData",
    .access_thread = .vm,
});
pub const owned_statement_data = b.nominalHandle("OwnedSQLiteStatementData", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::SQLiteStatementData" } },
    .cpp_declarations = &.{.{ .class = "WebCore::SQLiteStatementData" }},
    .zig_type = "api.SQLiteNative.StatementData",
    .ownership = .owned,
    .cpp_release = "releaseSQLiteStatementData",
    .access_thread = .vm,
    .destroy_thread = .vm,
});
pub const database_owner = b.nominalHandle("SQLiteDatabaseOwner", .{
    .cpp_type = .{ .pointer = &.{ .named = "BunBindgen_SQLiteNative_Database_Native" } },
    .cpp_declarations = &.{.{ .structure = "BunBindgen_SQLiteNative_Database_Native" }},
    .zig_type = "api.SQLiteNative.Database",
    .access_thread = .vm,
});

pub const bindings = b.unionType("SQLiteBindingsInput", .{
    b.unionMember("object", b.js_object),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("null_value", b.null_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid", .cpp_name = "SQLiteBindingsInput" });

pub const prototype = b.unionType("SQLitePrototypeMatch", .{
    b.unionMember("object", b.js_object),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid", .cpp_name = "SQLitePrototypeMatch" });

pub const object_or_null = b.unionType("SQLiteStatementObjectOrNullResult", .{
    b.unionMember("object", b.js_object),
    b.unionMember("null_value", b.null_literal),
}, .{ .ordered = true, .cpp_name = "SQLiteStatementObjectOrNull" });

pub const array_or_number_or_undefined = b.unionType("SQLiteStatementArrayOrNumberOrUndefinedResult", .{
    b.unionMember("array", b.js_array),
    b.unionMember("number", b.double),
    b.unionMember("undefined_value", b.undefined_literal),
}, .{ .ordered = true, .cpp_name = "SQLiteStatementArrayOrNumberOrUndefined" });

pub const array_or_number_or_null = b.unionType("SQLiteStatementArrayOrNumberOrNullResult", .{
    b.unionMember("array", b.js_array),
    b.unionMember("number", b.double),
    b.unionMember("null_value", b.null_literal),
}, .{ .ordered = true, .cpp_name = "SQLiteStatementArrayOrNumberOrNull" });

pub const schema = b.module("SQLiteTypes", .{});
