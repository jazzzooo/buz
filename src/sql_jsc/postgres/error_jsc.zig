const RunSchema = bun.bindgen.Module("PostgresSQLQuery").class("PostgresSQLQuery").member("run");
pub const OwnedPayload = bun.bindgen.DomainErrorPayload(RunSchema, .postgres_failure);

pub fn createPostgresErrorPayload(
    message: []const u8,
    options: PostgresErrorOptions,
) bun.OOM!OwnedPayload {
    var result: OwnedPayload = .{ .code = .empty(), .message = .empty() };
    errdefer deinitPostgresErrorPayload(&result);
    result.code = try bun.bindgen.DOMString.fromUTF8(options.code);
    result.message = try bun.bindgen.DOMString.fromUTF8(message);

    result.error_number = try optionalString(options.errno);
    result.detail = try optionalString(options.detail);
    result.hint = try optionalString(options.hint);
    result.severity = try optionalString(options.severity);
    result.position = try optionalString(options.position);
    result.internal_position = try optionalString(options.internalPosition);
    result.internal_query = try optionalString(options.internalQuery);
    result.where = try optionalString(options.where);
    result.schema = try optionalString(options.schema);
    result.table = try optionalString(options.table);
    result.column = try optionalString(options.column);
    result.data_type = try optionalString(options.dataType);
    result.constraint = try optionalString(options.constraint);
    result.file = try optionalString(options.file);
    result.line = try optionalString(options.line);
    result.routine = try optionalString(options.routine);
    return result;
}

const optionalString = bun.bindgen.DOMString.fromOptionalUTF8;

pub fn deinitPostgresErrorPayload(payload: *OwnedPayload) void {
    bun.bindgen.deinitDomainErrorPayload(RunSchema, .postgres_failure, payload);
}

const PostgresErrorOptions = @import("../../sql/postgres/AnyPostgresError.zig").PostgresErrorOptions;

const bun = @import("bun");
