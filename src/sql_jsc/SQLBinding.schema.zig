const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const deferred_sql_tls = "TLS configuration is observed only when sslMode enables TLS";
const mysql_connection = @import("binding_schema_MySQLConnection");
const mysql_query = @import("binding_schema_MySQLQuery");
const postgres_connection = @import("binding_schema_PostgresSQLConnection");
const postgres_query = @import("binding_schema_PostgresSQLQuery");
const sql_errors = @import("binding_schema_SQLErrors");
const sql_types = @import("binding_schema_SQLTypes");
const ssl = @import("binding_schema_SSLConfig");
/// Settles one finished query: `(query, result, commandTag, count, isLast, ...extra)`.
/// MySQL appends `lastInsertRowid` and `affectedRows`; Postgres passes only the common arguments.
const query_command_tag = b.unionType("SQLQueryCommandTag", .{
    b.unionMember("code", b.uint8),
    b.unionMember("name", b.dom_string),
}, .{ .ordered = true });

fn queryResolveCallback(
    comptime name: []const u8,
    comptime extra_arguments: anytype,
) b.Type {
    return b.callback(name, .{
        b.argument("query", b.js_object, .{}),
        b.argument("result", b.optionalUndefined(sql_types.result_rows), .{}),
        b.argument("commandTag", query_command_tag, .{}),
        b.argument("count", b.double, .{}),
        b.argument("isLast", b.boolean, .{}),
    } ++ extra_arguments, b.none, .{ .receiver = null, .profile = .exact });
}

const postgres_query_resolve_callback = queryResolveCallback(
    "PostgresQueryResolveCallback",
    .{},
);
const mysql_query_resolve_callback = queryResolveCallback("MySQLQueryResolveCallback", .{
    b.argument("lastInsertRowid", b.double, .{}),
    b.argument("affectedRows", b.double, .{}),
});

fn queryRejectCallback(
    comptime name: []const u8,
    comptime error_payload: b.Type,
) b.Type {
    return b.callback(name, .{
        b.argument("query", b.js_object, .{}),
        b.argument("original", b.invocation_any, .{}),
        b.argument("payload", b.optionalUndefined(error_payload), .{}),
    }, b.none, .{ .receiver = null, .profile = .exact });
}

const mysql_query_reject_callback = queryRejectCallback(
    "MySQLQueryRejectCallback",
    sql_errors.mysql_error,
);
const postgres_query_reject_callback = queryRejectCallback(
    "PostgresQueryRejectCallback",
    sql_errors.postgres_error,
);

fn initFunction(
    comptime name: []const u8,
    comptime resolve_callback: b.Type,
    comptime reject_callback: b.Type,
) b.Function {
    return b.function(name, .{
        b.argument("onQueryResolve", resolve_callback, .{ .presence = .optional, .missing = .omitted }),
        b.argument("onQueryReject", reject_callback, .{ .presence = .optional, .missing = .omitted }),
    }, b.none, .{
        .backend = .zig,
        .length = 0,
        .profile = .exact,
    });
}
const query_errors = b.domainErrors(.{
    b.domainError("simple_with_parameters", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "simple query cannot have parameters" },
    }),
    b.domainError("query_too_long", b.none, .{
        .class = .range_error,
        .message = .{ .literal = "query is too long" },
    }),
});

const connection_errors = b.domainErrors(.{
    b.domainError("invalid_parameter", b.dom_string, .{
        .class = .type_error,
        .message = .payload,
    }),
} ++ ssl.ssl_config_error_list);

const tls_value = b.unionType("SQLTLSValue", .{
    b.unionMember("enabled", b.boolean),
    b.unionMember("config", ssl.ssl_config),
}, .{ .ordered = true });

fn connectionFunction(
    comptime name: []const u8,
    comptime connection: b.BoundClass,
    comptime on_connect: b.Type,
    comptime on_close: b.Type,
) b.Function {
    return b.function(
        name,
        .{
            b.argument("hostname", archetypes.optional_dom_string, .{}),
            b.argument("port", b.uint16, .{}),
            b.argument("username", b.dom_string, .{}),
            b.argument("password", b.dom_string, .{}),
            b.argument("database", b.dom_string, .{}),
            b.argument("sslMode", b.uint8, .{
                .integer_conversion = .{ .enforce_range = .{ .min = 0, .max = 4 } },
            }),
            b.argument("tls", b.lazy(b.optionalNullish(tls_value)), .{ .deferred_reason = deferred_sql_tls }),
            b.argument("options", b.dom_string, .{}),
            b.argument("path", b.dom_string, .{}),
            b.argument("onConnect", on_connect, .{}),
            b.argument("onClose", on_close, .{}),
            b.argument("idleTimeout", b.uint32, .{}),
            b.argument("connectionTimeout", b.uint32, .{}),
            b.argument("maxLifetime", b.uint32, .{}),
            b.argument("useUnnamedPreparedStatements", b.boolean, .{}),
        },
        b.classRef(connection),
        .{
            .backend = .zig,
            .errors = connection_errors,
            .length = 2,
            .profile = .exact,
        },
    );
}

fn queryFunction(
    comptime name: []const u8,
    comptime query: b.BoundClass,
) b.Function {
    return b.function(
        name,
        .{
            b.argument("query", b.dom_string, .{}),
            b.argument("values", sql_types.binding_values, .{}),
            b.argument("pendingValue", sql_types.result_rows, .{}),
            b.argument("columns", b.optionalUndefined(sql_types.binding_columns), .{}),
            b.argument("bigint", b.boolean, .{
                .presence = .optional,
                .missing = .undefined,
                .boolean_conversion = .strict_true,
            }),
            b.argument("simple", b.boolean, .{
                .presence = .optional,
                .missing = .undefined,
                .boolean_conversion = .strict_true,
            }),
        },
        b.classRef(query),
        .{
            .backend = .zig,
            .errors = query_errors,
            .length = 6,
            .profile = .exact,
        },
    );
}

const functions = .{
    initFunction("mysqlInit", mysql_query_resolve_callback, mysql_query_reject_callback),
    queryFunction("mysqlCreateQuery", mysql_query.mysql_query),
    connectionFunction(
        "mysqlCreateConnection",
        mysql_connection.mysql_connection,
        mysql_connection.on_connect_callback,
        mysql_connection.on_close_callback,
    ),
    initFunction("postgresInit", postgres_query_resolve_callback, postgres_query_reject_callback),
    queryFunction("postgresCreateQuery", postgres_query.postgres_sql_query),
    connectionFunction(
        "postgresCreateConnection",
        postgres_connection.postgres_sql_connection,
        postgres_connection.on_connect_callback,
        postgres_connection.on_close_callback,
    ),
};

pub const schema = b.module("SQLBinding", functions);
