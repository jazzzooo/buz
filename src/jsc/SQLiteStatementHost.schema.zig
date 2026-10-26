const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const types = @import("binding_schema_SQLiteTypes");

fn hostFunction(
    comptime name: []const u8,
    comptime arguments: anytype,
    comptime result: b.Type,
    comptime length: u16,
) b.Function {
    return b.function(name, arguments, result, .{
        .backend = .cpp,
        .length = length,
        .profile = .exact,
        .missing_required_arguments = .convert_undefined,
    });
}

pub const schema = b.module("SQLiteStatementHost", .{
    b.function(
        "createInternalFieldTuple",
        .{},
        b.js_internal_field_tuple,
        .{ .backend = .cpp, .profile = .exact },
    ),
    hostFunction("jsSQLStatementSetCustomSQLite", .{
        b.argument("path", archetypes.strict_dom_string_or_ignored, .{
            .presence = .optional,
            .missing = .omitted,
        }),
    }, b.boolean, 1),
    hostFunction("jsSQLStatementDeserialize", .{
        b.argument("buffer", b.optionalMatch(b.js_array_buffer_view), .{}),
        b.argument("openFlags", b.int32, .{
            .presence = .optional,
            .missing = .omitted,
            .integer_conversion = .coerce,
        }),
        b.argument("deserializeFlags", b.int32, .{
            .presence = .optional,
            .missing = .omitted,
            .integer_conversion = .coerce,
        }),
        b.argumentProjection("bytes", "buffer", b.bufferWithOptions(.copy, .{ .allow_detached = false }), "SQLite snapshots the serialized bytes after flag coercion and database-library setup"),
    }, types.database, 2),
    hostFunction("jsSQLStatementSerialize", .{
        b.argument("database", types.database, .{}),
        b.argument("attachedName", b.lazy(archetypes.coerced_dom_string), .{ .deferred_reason = "SQLite validates the connection and serialization support before coercing the attached database name" }),
    }, archetypes.node_buffer_value, 1),
    hostFunction("jsSQLStatementLoadExtensionFunction", .{
        b.argument("database", types.database, .{}),
        b.argument("extension", archetypes.strict_dom_string_or_ignored, .{}),
        b.argument("entryPoint", archetypes.strict_dom_string_or_ignored, .{}),
    }, b.none, 2),
    hostFunction("jsSQLStatementExecuteFunction", .{
        b.argument("database", types.database, .{
            .presence = .optional,
            .missing = .omitted,
        }),
        b.argument("internalFlags", archetypes.int32_or_ignored, .{
            .presence = .optional,
            .missing = .omitted,
        }),
        b.argument("diff", b.optionalMatch(b.js_internal_field_tuple), .{
            .presence = .optional,
            .missing = .omitted,
        }),
        b.argument("sql", archetypes.strict_dom_string_or_ignored, .{
            .presence = .optional,
            .missing = .omitted,
        }),
        b.argument("bindings", types.bindings, .{
            .presence = .optional,
            .missing = .omitted,
        }),
    }, b.none, 3),
    hostFunction("jsSQLStatementIsInTransactionFunction", .{
        b.argument("database", types.database, .{}),
    }, b.boolean, 1),
    hostFunction("jsSQLStatementPrepareStatementFunction", .{
        b.argument("database", types.database, .{}),
        b.argument("sql", archetypes.strict_dom_string_or_ignored, .{}),
        b.argument("bindings", types.bindings, .{}),
        b.argument("prepareFlags", archetypes.number_to_int32_or_ignored, .{}),
        b.argument("internalFlags", archetypes.int32_or_ignored, .{}),
    }, types.statement, 2),
    hostFunction("jsSQLStatementOpenStatementFunction", .{
        b.argument("path", archetypes.strict_dom_string_or_ignored, .{
            .presence = .optional,
            .missing = .omitted,
        }),
        b.argument("flags", archetypes.number_to_int32_or_ignored, .{
            .presence = .optional,
            .missing = .omitted,
        }),
    }, types.database, 2),
    hostFunction("jsSQLStatementCloseStatementFunction", .{
        b.argument("database", types.database, .{}),
        b.argument("throwOnError", b.boolean, .{ .boolean_conversion = .truthy }),
    }, b.none, 1),
});
