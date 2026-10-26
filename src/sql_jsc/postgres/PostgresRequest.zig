fn materialize(values: *const SQLTypes.BindingValues, columns: ?*const SQLTypes.BindingColumns, fields: []const int4) AnyPostgresError!SQLParameters.Batch {
    if (fields.len > max_parameters) return error.TooManyParameters;
    if (SQLParameters.count(values, columns) != fields.len) return error.InvalidQueryBinding;
    const plan = try bun.default_allocator.alloc(SQLParameters.Kind, fields.len);
    defer bun.default_allocator.free(plan);
    for (fields, plan) |field, *kind| {
        kind.* = if (field > std.math.maxInt(short)) .text else switch (@as(types.Tag, @fromBackingInt(@intCast(field)))) {
            .bool => .boolean,
            .int2 => .int16,
            .int4 => .int32,
            .float4 => .float32,
            .float8 => .float64,
            .timestamp, .timestamptz => .date,
            .bytea => .bytes,
            .int4_array => .int32_array,
            .json, .jsonb => .json,
            else => .text,
        };
    }
    return SQLParameters.materializePostgres(values, columns, plan);
}

fn requireConnected(writer: anytype) AnyPostgresError!void {
    if (@hasDecl(@TypeOf(writer.wrapped), "isConnected")) {
        if (!writer.wrapped.isConnected()) return error.ConnectionClosed;
    }
}

pub fn writeQuery(
    query: []const u8,
    name: []const u8,
    params: []const int4,
    comptime Context: type,
    writer: protocol.NewWriter(Context),
) AnyPostgresError!void {
    {
        var q = protocol.Parse{
            .name = name,
            .params = params,
            .query = query,
        };
        try q.writeInternal(Context, writer);
        debug("Parse: {f}", .{bun.fmt.quote(query)});
    }

    {
        var d = protocol.Describe{
            .p = .{
                .prepared_statement = name,
            },
        };
        try d.writeInternal(Context, writer);
        debug("Describe: {f}", .{bun.fmt.quote(name)});
    }
}

pub fn prepareAndQueryWithSignature(
    query: []const u8,
    values: *const SQLTypes.BindingValues,
    comptime Context: type,
    writer: protocol.NewWriter(Context),
    signature: *Signature,
) AnyPostgresError!void {
    var parameters = try materialize(values, null, signature.fields);
    defer parameters.deinit();
    try requireConnected(writer);
    const checkpoint = writer.offset();
    errdefer writer.truncate(checkpoint);
    try writeQuery(query, signature.prepared_statement_name, signature.fields, Context, writer);
    try Bind.write(signature.prepared_statement_name, &parameters, &.{}, writer);
    var exec = protocol.Execute{
        .p = .{
            .prepared_statement = signature.prepared_statement_name,
        },
    };
    try exec.writeInternal(Context, writer);

    try writer.write(&protocol.Flush);
    try writer.write(&protocol.Sync);
}

pub fn bindAndExecute(
    statement: *PostgresSQLStatement,
    values: *const SQLTypes.BindingValues,
    columns: ?*const SQLTypes.BindingColumns,
    comptime Context: type,
    writer: protocol.NewWriter(Context),
) AnyPostgresError!void {
    statement.ref();
    defer statement.deref();
    var parameters = try materialize(values, columns, statement.parameters);
    defer parameters.deinit();
    try requireConnected(writer);
    const checkpoint = writer.offset();
    errdefer writer.truncate(checkpoint);
    try Bind.write(statement.signature.prepared_statement_name, &parameters, statement.fields, writer);
    var exec = protocol.Execute{
        .p = .{
            .prepared_statement = statement.signature.prepared_statement_name,
        },
    };
    try exec.writeInternal(Context, writer);

    try writer.write(&protocol.Flush);
    try writer.write(&protocol.Sync);
}

/// Atomically sends Parse + [Describe] + Bind + Execute + Flush + Sync as a single message batch.
/// This is required for unnamed prepared statements to work correctly with connection poolers
/// like PgBouncer in transaction mode, which may reassign server connections between protocol
/// round-trips. Without this, Parse and Bind+Execute could be routed to different backend
/// connections, causing queries to execute against the wrong prepared statement.
pub fn parseAndBindAndExecute(
    query: []const u8,
    statement: *PostgresSQLStatement,
    values: *const SQLTypes.BindingValues,
    columns: ?*const SQLTypes.BindingColumns,
    include_describe: bool,
    comptime Context: type,
    writer: protocol.NewWriter(Context),
) AnyPostgresError!void {
    statement.ref();
    defer statement.deref();
    const param_fields = if (statement.parameters.len > 0) statement.parameters else statement.signature.fields;
    var parameters = try materialize(values, columns, param_fields);
    defer parameters.deinit();
    try requireConnected(writer);
    const checkpoint = writer.offset();
    errdefer writer.truncate(checkpoint);
    const name = statement.signature.prepared_statement_name;

    // Parse
    {
        var q = protocol.Parse{
            .name = name,
            .params = statement.signature.fields,
            .query = query,
        };
        try q.writeInternal(Context, writer);
        debug("Parse: {f}", .{bun.fmt.quote(query)});
    }

    // Describe (needed on first execution to learn parameter/result types for caching)
    if (include_describe) {
        var d = protocol.Describe{
            .p = .{
                .prepared_statement = name,
            },
        };
        try d.writeInternal(Context, writer);
        debug("Describe: {f}", .{bun.fmt.quote(name)});
    }

    try Bind.write(name, &parameters, statement.fields, writer);

    // Execute
    var exec = protocol.Execute{
        .p = .{
            .prepared_statement = name,
        },
    };
    try exec.writeInternal(Context, writer);

    try writer.write(&protocol.Flush);
    try writer.write(&protocol.Sync);
}

pub fn executeQuery(
    query: []const u8,
    comptime Context: type,
    writer: protocol.NewWriter(Context),
) AnyPostgresError!void {
    try protocol.writeQuery(query, Context, writer);
    try writer.write(&protocol.Flush);
    try writer.write(&protocol.Sync);
}

pub fn onData(
    connection: anytype,
    comptime Context: type,
    reader: protocol.NewReader(Context),
) AnyPostgresError!void {
    while (true) {
        reader.markMessageStart();
        const c = try reader.int(u8);
        debug("read: {c}", .{c});

        if (c == 'S' and connection.tls_status == .message_sent) {
            bun.debugAssert(connection.tls_status.message_sent == 8);
            connection.tls_status = .ssl_ok;
            connection.setupTLS();
            return;
        }

        if (c == 'N' and connection.tls_status == .message_sent) {
            connection.tls_status = .ssl_not_available;
            debug("Server does not support SSL", .{});
            if (connection.ssl_mode == .require) {
                connection.fail("Server does not support SSL", error.TLSNotAvailable);
                return;
            }
            continue;
        }

        var frame = try reader.readFrame();
        defer frame.deinit();
        const payload_reader = frame.reader();

        switch (c) {
            'D' => try connection.on(.DataRow, payload_reader),
            'd' => try connection.on(.CopyData, payload_reader),
            'S' => try connection.on(.ParameterStatus, payload_reader),
            'Z' => try connection.on(.ReadyForQuery, payload_reader),
            'C' => try connection.on(.CommandComplete, payload_reader),
            '2' => try connection.on(.BindComplete, payload_reader),
            '1' => try connection.on(.ParseComplete, payload_reader),
            't' => try connection.on(.ParameterDescription, payload_reader),
            'T' => try connection.on(.RowDescription, payload_reader),
            'R' => try connection.on(.Authentication, payload_reader),
            'n' => try connection.on(.NoData, payload_reader),
            'K' => try connection.on(.BackendKeyData, payload_reader),
            'E' => try connection.on(.ErrorResponse, payload_reader),
            's' => try connection.on(.PortalSuspended, payload_reader),
            '3' => try connection.on(.CloseComplete, payload_reader),
            'G' => try connection.on(.CopyInResponse, payload_reader),
            'N' => try connection.on(.NoticeResponse, payload_reader),
            'I' => try connection.on(.EmptyQueryResponse, payload_reader),
            'H' => try connection.on(.CopyOutResponse, payload_reader),
            'c' => try connection.on(.CopyDone, payload_reader),
            'W' => try connection.on(.CopyBothResponse, payload_reader),
            else => debug("Unknown message: {c}", .{c}),
        }
    }
}

pub fn Queue(comptime Query: type) type {
    return bun.LinearFifo(*Query, .Dynamic);
}

const debug = bun.Output.scoped(.Postgres, .visible);

/// The PostgreSQL wire protocol uses 16-bit integers for parameter and column counts.
const max_parameters = std.math.maxInt(u16);

const PostgresSQLStatement = @import("./PostgresSQLStatement.zig");
const Signature = @import("../../sql_jsc/postgres/Signature.zig");
const protocol = @import("../../sql/postgres/PostgresProtocol.zig");
const std = @import("std");
const SQLParameters = @import("../shared/SQLParameters.zig");
const Bind = @import("../../sql/postgres/protocol/Bind.zig");
const SQLTypes = @import("../shared/SQLTypes.zig");

const types = @import("../../sql/postgres/PostgresTypes.zig");
const AnyPostgresError = @import("../../sql/postgres/PostgresTypes.zig").AnyPostgresError;
const int4 = types.int4;
const short = types.short;

const bun = @import("bun");
