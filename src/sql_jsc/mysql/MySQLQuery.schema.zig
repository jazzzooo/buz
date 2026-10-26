const b = @import("bindgen_schema");
const mysql_connection = @import("binding_schema_MySQLConnection");
const sql_errors = @import("binding_schema_SQLErrors");
const sql_types = @import("binding_schema_SQLTypes");

const mysql_query_class = b.class(
    "MySQLQuery",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("cancel", .{}, b.none, .{ .implementation = "doCancel", .length = 0 }),
        b.method("done", .{}, b.none, .{ .implementation = "doDone", .length = 0 }),
        b.method(
            "run",
            .{
                b.argument("connection", b.classRef(mysql_connection.mysql_connection), .{}),
                b.argument("target", b.js_object, .{}),
            },
            b.none,
            .{
                .errors = b.domainErrors(.{sql_errors.mysql_failure}),
                .implementation = "doRun",
                .length = 2,
            },
        ),
        b.method(
            "setMode",
            .{sql_types.queryResultMode("mode")},
            b.none,
            .{ .implementation = "setModeFromJS", .length = 1 },
        ),
        b.method(
            "setPendingValue",
            .{b.argument("value", b.optionalUndefined(sql_types.result_rows), .{ .presence = .optional, .missing = .undefined })},
            b.none,
            .{ .implementation = "setPendingValueFromJS", .length = 1 },
        ),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .any,
        .has_pending_activity = true,
    },
);

pub const schema = b.moduleWithClasses("MySQLQuery", .{}, .{mysql_query_class});
pub const mysql_query = schema.class("MySQLQuery");
