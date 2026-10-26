const MySQLQuery = @This();

statement: ?*MySQLStatement = null,
query: bun.String,

status: Status,
flags: packed struct(u8) {
    bigint: bool = false,
    simple: bool = false,
    pipelined: bool = false,
    result_mode: SQLQueryResultMode = .objects,
    _padding: u3 = 0,
},

fn bindAndExecute(this: *MySQLQuery, writer: anytype, statement: *MySQLStatement, binding_value: *const SQLTypes.BindingValues, columns_value: ?*const SQLTypes.BindingColumns) AnyMySQLError.Error!void {
    statement.ref();
    defer statement.deref();
    bun.assert(statement.params.len == statement.params_received and statement.statement_id > 0);
    if (statement.signature.fields.len != statement.params.len) return error.WrongNumberOfParametersProvided;

    const fields = statement.signature.fields;
    const plan = try bun.default_allocator.alloc(SQLParameters.Kind, fields.len);
    defer bun.default_allocator.free(plan);
    for (fields, plan) |field, *kind| {
        kind.* = switch (field.type) {
            .MYSQL_TYPE_TINY => .boolean,
            .MYSQL_TYPE_SHORT => if (field.flags.UNSIGNED) .uint16 else .int16,
            .MYSQL_TYPE_LONG => if (field.flags.UNSIGNED) .uint32 else .int32,
            .MYSQL_TYPE_LONGLONG => if (field.flags.UNSIGNED) .uint64 else .int64,
            .MYSQL_TYPE_FLOAT => .float32,
            .MYSQL_TYPE_DOUBLE => .float64,
            .MYSQL_TYPE_TIME, .MYSQL_TYPE_TIME2 => .time,
            .MYSQL_TYPE_DATE, .MYSQL_TYPE_TIMESTAMP, .MYSQL_TYPE_DATETIME => .date,
            .MYSQL_TYPE_TINY_BLOB, .MYSQL_TYPE_MEDIUM_BLOB, .MYSQL_TYPE_LONG_BLOB, .MYSQL_TYPE_BLOB => .bytes,
            .MYSQL_TYPE_JSON => .json,
            else => .text,
        };
    }
    if (SQLParameters.count(binding_value, columns_value) != plan.len) return error.WrongNumberOfParametersProvided;
    var parameters = try SQLParameters.materializeMySQL(binding_value, columns_value, plan);
    defer parameters.deinit();
    if (this.isCompleted() or !writer.wrapped.isConnected()) return error.ConnectionClosed;
    var execute = PreparedStatement.Execute(SQLParameters.Batch){
        .statement_id = statement.statement_id,
        .param_types = fields,
        .new_params_bind_flag = statement.execution_flags.need_to_send_params,
        .params = &parameters,
    };
    var packet = try writer.start(0);
    defer packet.deinit();
    try execute.write(writer);
    try packet.end();
    statement.execution_flags.need_to_send_params = false;
    this.status = .running;
}

fn runSimpleQuery(this: *@This(), connection: anytype) AnyMySQLError.Error!void {
    if (this.status != .pending or !connection.canExecuteQuery()) {
        debug("cannot execute query", .{});
        // cannot execute query
        return;
    }
    var query_str = try this.query.toUTF8(bun.default_allocator);
    defer query_str.deinit();
    const writer = connection.getWriter();
    if (this.statement == null) {
        const stmt = try bun.default_allocator.create(MySQLStatement);
        stmt.* = .{
            .signature = Signature.empty(),
            .status = .parsing,
            .ref_count = .initExactRefs(1),
        };
        this.statement = stmt;
    }
    try MySQLRequest.executeQuery(query_str.slice(), @TypeOf(connection.*).Writer, writer);

    this.status = .running;
}

fn runPreparedQuery(
    this: *@This(),
    connection: anytype,
    columns_value: ?*const SQLTypes.BindingColumns,
    binding_value: *const SQLTypes.BindingValues,
) RunError!RunOutcome {
    var query_str: ?bun.String.Slice = null;
    defer if (query_str) |str| str.deinit();

    if (this.statement == null) {
        const query = try this.query.toUTF8(bun.default_allocator);
        query_str = query;
        var signature = Signature.generate(query.slice(), binding_value, columns_value) catch |err| {
            return runFailure("failed to generate signature", err);
        };
        defer signature.deinit();
        if (this.isCompleted() or connection.isClosed()) return runFailure("connection closed during parameter conversion", error.ConnectionClosed);
        this.statement = connection.acquireStatement(&signature) catch |err| {
            return runFailure("failed to allocate statement", err);
        };
    }
    const stmt = this.statement.?;
    switch (stmt.status) {
        .failed => {
            debug("failed", .{});
            return .cached_statement_failed;
        },
        .prepared => {
            if (connection.canPipeline()) {
                debug("bindAndExecute", .{});
                const writer = connection.getWriter();
                this.bindAndExecute(writer, stmt, binding_value, columns_value) catch |err| {
                    return runFailure("failed to bind and execute query", err);
                };
                this.flags.pipelined = true;
            }
        },
        .parsing => {
            debug("parsing", .{});
        },
        .pending => {
            if (connection.canPrepareQuery()) {
                debug("prepareRequest", .{});
                const writer = connection.getWriter();
                if (query_str == null) query_str = try this.query.toUTF8(bun.default_allocator);
                const query = query_str.?;
                MySQLRequest.prepareRequest(query.slice(), @TypeOf(connection.*).Writer, writer) catch |err| {
                    return runFailure("failed to prepare query", err);
                };
                stmt.status = .parsing;
            }
        },
    }
    return .started;
}

/// Takes ownership of `query` (caller must have already ref'd it, e.g. via
/// `JSValue.toBunString`). `cleanup()` will deref it exactly once.
pub fn init(query: bun.String, bigint: bool, simple: bool) @This() {
    return .{
        .query = query,
        .status = .pending,
        .flags = .{
            .bigint = bigint,
            .simple = simple,
        },
    };
}

pub fn runQuery(this: *@This(), connection: anytype, columns_value: ?*const SQLTypes.BindingColumns, binding_value: *const SQLTypes.BindingValues) RunError!RunOutcome {
    if (this.flags.simple) {
        debug("runSimpleQuery", .{});
        this.runSimpleQuery(connection) catch |err| {
            return runFailure("failed to execute query", err);
        };
        return .started;
    }
    debug("runPreparedQuery", .{});
    return this.runPreparedQuery(connection, columns_value, binding_value);
}

fn runFailure(message: []const u8, err: AnyMySQLError.Error) RunError!RunOutcome {
    return switch (err) {
        error.JSError => error.JSError,
        error.JSTerminated => error.JSTerminated,
        error.OutOfMemory => error.OutOfMemory,
        error.ShortRead => bun.unreachablePanic("Assertion failed: ShortRead should be handled by the caller in mysql", .{}),
        else => .{ .failed = .{ .message = message, .err = err } },
    };
}

pub inline fn setResultMode(this: *@This(), result_mode: SQLQueryResultMode) void {
    this.flags.result_mode = result_mode;
}

pub inline fn result(this: *@This(), is_last_result: bool) bool {
    if (this.status == .success or this.status == .fail) return false;
    this.status = if (is_last_result) .success else .partial_response;

    return true;
}
pub fn fail(this: *@This()) bool {
    if (this.status == .fail or this.status == .success) return false;
    this.status = .fail;

    return true;
}

pub fn cleanup(this: *@This()) void {
    if (this.statement) |statement| {
        statement.deref();
        this.statement = null;
    }
    var query = this.query;
    defer query.deref();
    this.query = bun.String.empty;
}

pub inline fn isCompleted(this: *const @This()) bool {
    return this.status == .success or this.status == .fail;
}
pub inline fn isRunning(this: *const @This()) bool {
    switch (this.status) {
        .running, .binding, .partial_response => return true,
        .success, .fail, .pending => return false,
    }
}
pub inline fn isPending(this: *const @This()) bool {
    return this.status == .pending;
}

pub inline fn isBeingPrepared(this: *@This()) bool {
    return this.status == .pending and this.statement != null and this.statement.?.status == .parsing;
}

pub inline fn isPipelined(this: *const @This()) bool {
    return this.flags.pipelined;
}
pub inline fn isSimple(this: *const @This()) bool {
    return this.flags.simple;
}
pub inline fn isBigintSupported(this: *const @This()) bool {
    return this.flags.bigint;
}
pub inline fn getResultMode(this: *const @This()) SQLQueryResultMode {
    return this.flags.result_mode;
}
pub inline fn markAsPrepared(this: *@This()) void {
    if (this.status == .pending) {
        if (this.statement) |statement| {
            if (statement.status == .parsing and
                statement.params.len == statement.params_received and
                statement.statement_id > 0)
            {
                statement.status = .prepared;
            }
        }
    }
}
pub inline fn getStatement(this: *const @This()) ?*MySQLStatement {
    return this.statement;
}

const debug = bun.Output.scoped(.MySQLQuery, .visible);

const AnyMySQLError = @import("../../sql/mysql/protocol/AnyMySQLError.zig");
const MySQLRequest = @import("../../sql/mysql/MySQLRequest.zig");
const MySQLStatement = @import("./MySQLStatement.zig");
const PreparedStatement = @import("../../sql/mysql/protocol/PreparedStatement.zig");
const Signature = @import("../../sql_jsc/mysql/protocol/Signature.zig");
const bun = @import("bun");
const SQLParameters = @import("../shared/SQLParameters.zig");
const SQLQueryResultMode = @import("../../sql/shared/SQLQueryResultMode.zig").SQLQueryResultMode;
const SQLTypes = @import("../shared/SQLTypes.zig");
const mysql_domain = @import("mysql_domain");
const Status = mysql_domain.QueryStatus;

pub const RunError = error{ JSError, JSTerminated, OutOfMemory };

pub const RunOutcome = union(enum) {
    started,
    cached_statement_failed,
    failed: struct {
        message: []const u8,
        err: AnyMySQLError.Error,
    },
};
