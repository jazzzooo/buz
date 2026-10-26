const PostgresQuery = @This();

statement: ?*PostgresSQLStatement = null,
query: bun.String,
status: Status = .pending,
flags: packed struct(u8) {
    binary: bool = false,
    bigint: bool = false,
    simple: bool = false,
    pipelined: bool = false,
    result_mode: SQLQueryResultMode = .objects,
    _padding: u2 = 0,
} = .{},

pub fn init(query: bun.String, bigint: bool, simple: bool) PostgresQuery {
    return .{
        .query = query,
        .flags = .{
            .bigint = bigint,
            .simple = simple,
        },
    };
}

pub fn cleanup(this: *PostgresQuery) void {
    if (this.statement) |statement| {
        statement.deref();
        this.statement = null;
    }
    var query = this.query;
    this.query = bun.String.empty;
    query.deref();
}

pub fn run(
    this: *PostgresQuery,
    owner: anytype,
    connection: anytype,
    binding_value: *const SQLTypes.BindingValues,
    columns_value: ?*const SQLTypes.BindingColumns,
) RunError!RunOutcome {
    var query_string = try this.query.toUTF8(bun.default_allocator);
    defer query_string.deinit();
    var writer = connection.writer();

    if (this.flags.simple) {
        const statement = bun.default_allocator.create(PostgresSQLStatement) catch return error.OutOfMemory;
        statement.* = .{
            .signature = Signature.empty(),
            .status = .parsing,
        };
        this.statement = statement;

        const did_write = !connection.hasQueryRunning();
        if (did_write) {
            PostgresRequest.executeQuery(query_string.slice(), @TypeOf(connection.*).Writer, writer) catch |err| {
                this.statement = null;
                bun.default_allocator.destroy(statement);
                return runFailure("failed to execute query", err);
            };
            connection.flags.is_ready_for_query = false;
            connection.nonpipelinable_requests += 1;
            this.status = .running;
        }
        connection.requests.writeItem(owner) catch {
            this.statement = null;
            bun.default_allocator.destroy(statement);
            return error.OutOfMemory;
        };
        return .{ .started = did_write };
    }

    var signature = Signature.generate(
        query_string.slice(),
        binding_value,
        columns_value,
        connection.prepared_statement_id,
        connection.flags.use_unnamed_prepared_statements,
    ) catch |err| return runFailure("failed to generate signature", err);

    if (this.status == .success or this.status == .fail or connection.status == .disconnected or connection.status == .failed) {
        signature.deinit();
        return runFailure("connection closed during parameter conversion", error.ConnectionClosed);
    }
    const has_params = signature.fields.len > 0;
    var did_write = false;
    enqueue: {
        var connection_entry_value: ?**PostgresSQLStatement = null;
        const signature_hash = bun.hash(signature.name);
        if (!connection.flags.use_unnamed_prepared_statements) {
            const entry = connection.statements.getOrPut(bun.default_allocator, signature_hash) catch {
                signature.deinit();
                return error.OutOfMemory;
            };
            connection_entry_value = entry.value_ptr;
            if (entry.found_existing) {
                const statement = entry.value_ptr.*;
                this.statement = statement;
                statement.ref();
                signature.deinit();

                switch (statement.status) {
                    .failed => return .cached_statement_failed,
                    .prepared => {
                        if (!connection.hasQueryRunning() or connection.canPipeline()) {
                            this.flags.binary = statement.fields.len > 0;
                            PostgresRequest.bindAndExecute(
                                statement,
                                binding_value,
                                columns_value,
                                @TypeOf(connection.*).Writer,
                                writer,
                            ) catch |err| {
                                this.statement = null;
                                statement.deref();
                                return runFailure("failed to bind and execute query", err);
                            };
                            connection.flags.is_ready_for_query = false;
                            this.status = .binding;
                            this.flags.pipelined = true;
                            connection.pipelined_requests += 1;
                            did_write = true;
                        }
                    },
                    .parsing, .pending => {},
                }
                break :enqueue;
            }
        }

        if (!connection.hasQueryRunning()) {
            if (!has_params) {
                PostgresRequest.prepareAndQueryWithSignature(
                    query_string.slice(),
                    binding_value,
                    @TypeOf(connection.*).Writer,
                    writer,
                    &signature,
                ) catch |err| {
                    if (connection_entry_value != null) _ = connection.statements.remove(signature_hash);
                    signature.deinit();
                    if (this.statement) |statement| {
                        this.statement = null;
                        statement.deref();
                    }
                    return runFailure("failed to prepare and query", err);
                };
                connection.flags.is_ready_for_query = false;
                this.status = .binding;
                did_write = true;
                connection.flags.waiting_to_prepare = true;
            } else if (!connection.flags.use_unnamed_prepared_statements) {
                PostgresRequest.writeQuery(
                    query_string.slice(),
                    signature.prepared_statement_name,
                    signature.fields,
                    @TypeOf(connection.*).Writer,
                    writer,
                ) catch |err| {
                    if (connection_entry_value != null) _ = connection.statements.remove(signature_hash);
                    signature.deinit();
                    if (this.statement) |statement| {
                        this.statement = null;
                        statement.deref();
                    }
                    return runFailure("failed to write query", err);
                };
                writer.write(&protocol.Sync) catch |err| {
                    if (connection_entry_value != null) _ = connection.statements.remove(signature_hash);
                    signature.deinit();
                    return runFailure("failed to flush", err);
                };
                connection.flags.is_ready_for_query = false;
                did_write = true;
                connection.flags.waiting_to_prepare = true;
            }
        }

        const statement = bun.default_allocator.create(PostgresSQLStatement) catch {
            if (connection_entry_value != null) _ = connection.statements.remove(signature_hash);
            signature.deinit();
            return error.OutOfMemory;
        };
        if (connection_entry_value) |entry_value| {
            connection.prepared_statement_id += 1;
            statement.* = .{
                .signature = signature,
                .ref_count = .initExactRefs(2),
                .status = if (did_write) .parsing else .pending,
            };
            entry_value.* = statement;
        } else {
            statement.* = .{
                .signature = signature,
                .status = if (did_write) .parsing else .pending,
            };
        }
        this.statement = statement;
    }

    connection.requests.writeItem(owner) catch return error.OutOfMemory;
    return .{ .started = did_write };
}

pub fn result(this: *PostgresQuery, is_last: bool) bool {
    if (this.status == .success or this.status == .fail) return false;
    this.status = if (is_last) .success else .partial_response;
    return true;
}

pub fn fail(this: *PostgresQuery) bool {
    if (this.status == .success or this.status == .fail) return false;
    this.status = .fail;
    return true;
}

pub fn getStatus(this: *const PostgresQuery) Status {
    return this.status;
}

pub fn setStatus(this: *PostgresQuery, status: Status) void {
    this.status = status;
}

pub fn getStatement(this: *const PostgresQuery) ?*PostgresSQLStatement {
    return this.statement;
}

pub fn text(this: *const PostgresQuery) bun.String {
    return this.query;
}

pub fn isSimple(this: *const PostgresQuery) bool {
    return this.flags.simple;
}

pub fn isPipelined(this: *const PostgresQuery) bool {
    return this.flags.pipelined;
}

pub fn setPipelined(this: *PostgresQuery, value: bool) void {
    this.flags.pipelined = value;
}

pub fn isBinary(this: *const PostgresQuery) bool {
    return this.flags.binary;
}

pub fn setBinary(this: *PostgresQuery, value: bool) void {
    this.flags.binary = value;
}

pub fn isBigintSupported(this: *const PostgresQuery) bool {
    return this.flags.bigint;
}

pub fn getResultMode(this: *const PostgresQuery) SQLQueryResultMode {
    return this.flags.result_mode;
}

pub fn setResultMode(this: *PostgresQuery, mode: SQLQueryResultMode) void {
    this.flags.result_mode = mode;
}

fn runFailure(message: []const u8, err: AnyPostgresError) RunError!RunOutcome {
    return switch (err) {
        error.JSError => error.JSError,
        error.JSTerminated => error.JSTerminated,
        error.OutOfMemory => error.OutOfMemory,
        error.ShortRead => bun.unreachablePanic("Assertion failed: ShortRead should be handled by the caller in postgres", .{}),
        else => .{ .failed = .{ .message = message, .err = err } },
    };
}

pub const Status = enum(u8) {
    pending,
    binding,
    running,
    partial_response,
    success,
    fail,
};

pub const RunError = error{ JSError, JSTerminated, OutOfMemory };

pub const RunOutcome = union(enum) {
    started: bool,
    cached_statement_failed,
    failed: struct {
        message: []const u8,
        err: AnyPostgresError,
    },
};

const PostgresRequest = @import("./PostgresRequest.zig");
const PostgresSQLStatement = @import("./PostgresSQLStatement.zig");
const Signature = @import("./Signature.zig");
const protocol = @import("../../sql/postgres/PostgresProtocol.zig");
const SQLTypes = @import("../shared/SQLTypes.zig");
const SQLQueryResultMode = @import("../../sql/shared/SQLQueryResultMode.zig").SQLQueryResultMode;
const AnyPostgresError = @import("../../sql/postgres/AnyPostgresError.zig").AnyPostgresError;
const bun = @import("bun");
