const b = @import("bindgen_schema");
const postgres_connection = @import("binding_schema_PostgresSQLConnection");
const sql_errors = @import("binding_schema_SQLErrors");
const sql_types = @import("binding_schema_SQLTypes");

const postgres_sql_query_class = b.class(
    "PostgresSQLQuery",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("cancel", .{}, b.none, .{ .implementation = "doCancel", .length = 0 }),
        b.method("done", .{}, b.none, .{ .implementation = "doDone", .length = 0 }),
        b.method(
            "run",
            .{
                b.argument("connection", b.classRef(postgres_connection.postgres_sql_connection), .{}),
                b.argument("target", b.js_object, .{}),
            },
            b.none,
            .{
                .errors = b.domainErrors(.{sql_errors.postgres_failure}),
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
    },
);

pub const schema = b.moduleWithClasses("PostgresSQLQuery", .{}, .{postgres_sql_query_class});
pub const postgres_sql_query = schema.class("PostgresSQLQuery");
