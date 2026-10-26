const RunSchema = bun.bindgen.Module("MySQLQuery").class("MySQLQuery").member("run");
pub const OwnedPayload = bun.bindgen.DomainErrorPayload(RunSchema, .mysql_failure);

pub fn createMySQLErrorPayload(
    message: []const u8,
    options: MySQLErrorOptions,
) bun.OOM!OwnedPayload {
    var result: OwnedPayload = .{
        .code = .empty(),
        .error_number = options.errno,
        .message = .empty(),
    };
    errdefer deinitMySQLErrorPayload(&result);
    result.code = try bun.bindgen.DOMString.fromUTF8(options.code);
    result.message = try bun.bindgen.DOMString.fromUTF8(message);

    if (options.sqlState) |state| {
        result.sql_state = try bun.bindgen.DOMString.fromUTF8(&state);
    }
    return result;
}

pub fn deinitMySQLErrorPayload(payload: *OwnedPayload) void {
    bun.bindgen.deinitDomainErrorPayload(RunSchema, .mysql_failure, payload);
}

const bun = @import("bun");

const ErrorPacket = @import("../../../sql/mysql/protocol/ErrorPacket.zig");
const MySQLErrorOptions = ErrorPacket.MySQLErrorOptions;
