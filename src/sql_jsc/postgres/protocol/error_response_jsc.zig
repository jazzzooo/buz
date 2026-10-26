pub fn toPayload(this: ErrorResponse) bun.OOM!PostgresErrorJSC.OwnedPayload {
    var fields: std.enums.EnumFieldStruct(FieldType, bun.String, .dead) = .{};
    for (this.messages.items) |msg| {
        switch (msg) {
            inline else => |str, tag| @field(fields, @tagName(tag)) = str,
        }
    }

    var result: PostgresErrorJSC.OwnedPayload = .{ .code = .empty(), .message = .empty() };
    errdefer PostgresErrorJSC.deinitPostgresErrorPayload(&result);
    result.code = try DOMString.fromUTF8(if (fields.code.eqlComptime("42601"))
        "ERR_POSTGRES_SYNTAX_ERROR"
    else
        "ERR_POSTGRES_SERVER_ERROR");

    inline for (@typeInfo(PostgresErrorJSC.OwnedPayload).@"struct".field_names) |name| {
        if (comptime !std.mem.eql(u8, name, "code") and !std.mem.eql(u8, name, "message")) {
            const source = comptime if (std.mem.eql(u8, name, "error_number"))
                "code"
            else if (std.mem.eql(u8, name, "internal_query"))
                "internal"
            else if (std.mem.eql(u8, name, "data_type"))
                "datatype"
            else
                name;
            const str = @field(fields, source);
            if (!str.isEmpty()) @field(result, name) = try DOMString.fromBunString(str.dupeRef());
        }
    }

    if (!fields.message.isEmpty()) {
        result.message = try DOMString.fromBunString(fields.message.dupeRef());
    } else {
        var builder = bun.StringBuilder{};
        defer builder.deinit(bun.default_allocator);
        const fallback = [_]bun.String{ fields.detail, fields.hint };
        for (fallback) |str| {
            const capacity = std.math.add(usize, str.utf8ByteLength(), 1) catch return error.OutOfMemory;
            builder.cap = std.math.add(usize, builder.cap, capacity) catch return error.OutOfMemory;
        }
        try builder.allocate(bun.default_allocator);
        for (fallback) |str| {
            if (str.isEmpty()) continue;
            _ = builder.append(if (builder.len == 0) " " else "\n");
            _ = try builder.appendStr(str);
        }
        result.message = try DOMString.fromUTF8(builder.allocatedSlice()[0..builder.len]);
    }
    return result;
}

const ErrorResponse = @import("../../../sql/postgres/protocol/ErrorResponse.zig");
const FieldType = @import("../../../sql/postgres/protocol/FieldType.zig").FieldType;
const PostgresErrorJSC = @import("../error_jsc.zig");
const bun = @import("bun");
const std = @import("std");
const DOMString = bun.bindgen.DOMString;
