const PreparedStatement = @This();

pub const PrepareOK = struct {
    status: u8 = 0,
    statement_id: u32,
    num_columns: u16,
    num_params: u16,
    warning_count: u16,

    pub fn decodeInternal(this: *PrepareOK, comptime Context: type, reader: NewReader(Context)) !void {
        this.status = try reader.int(u8);
        if (this.status != 0) {
            return error.InvalidPrepareOKPacket;
        }

        this.statement_id = try reader.int(u32);
        this.num_columns = try reader.int(u16);
        this.num_params = try reader.int(u16);
        _ = try reader.int(u8); // reserved_1
        this.warning_count = try reader.int(u16);
    }

    pub const decode = decoderWrap(PrepareOK, decodeInternal).decode;
};

pub fn Execute(comptime Parameters: type) type {
    return struct {
        const Self = @This();

        /// ID of the prepared statement to execute, returned from COM_STMT_PREPARE
        statement_id: u32,
        /// Execution flags. Currently only CURSOR_TYPE_READ_ONLY (0x01) is supported
        flags: u8 = 0,
        /// Number of times to execute the statement (usually 1)
        iteration_count: u32 = 1,
        /// Parameter values to bind to the prepared statement
        params: *const Parameters,
        /// Types of each parameter in the prepared statement
        param_types: []const Param,
        /// Whether to send parameter types. Set to true for first execution, false for subsequent executions
        new_params_bind_flag: bool,

        fn writeNullBitmap(this: *const Self, comptime Context: type, writer: NewWriter(Context)) AnyMySQLError.Error!void {
            const MYSQL_MAX_PARAMS = (std.math.maxInt(u16) / 8) + 1;

            var null_bitmap_buf: [MYSQL_MAX_PARAMS]u8 = undefined;
            const bitmap_bytes = (this.params.len() + 7) / 8;
            const null_bitmap = null_bitmap_buf[0..bitmap_bytes];
            @memset(null_bitmap, 0);

            for (0..this.params.len()) |i| {
                if (this.params.at(i) == .null_value) {
                    null_bitmap[i >> 3] |= @as(u8, 1) << @as(u3, @truncate(i & 7));
                }
            }

            try writer.write(null_bitmap);
        }

        pub fn writeInternal(this: *const Self, comptime Context: type, writer: NewWriter(Context)) AnyMySQLError.Error!void {
            try writer.int1(@backingInt(CommandType.COM_STMT_EXECUTE));
            try writer.int4(this.statement_id);
            try writer.int1(this.flags);
            try writer.int4(this.iteration_count);

            if (this.params.len() > 0) {
                try this.writeNullBitmap(Context, writer);

                // Write new params bind flag
                try writer.int1(@intFromBool(this.new_params_bind_flag));

                if (this.new_params_bind_flag) {
                    // Write parameter types
                    for (this.param_types) |param_type| {
                        debug("New params bind flag {s} unsigned? {}", .{ @tagName(param_type.type), param_type.flags.UNSIGNED });
                        try writer.int1(@backingInt(param_type.type));
                        try writer.int1(if (param_type.flags.UNSIGNED) 0x80 else 0);
                    }
                }

                // Write parameter values
                for (this.param_types, 0..) |param_type, index| {
                    const value = this.params.at(index);
                    if (value == .null_value or param_type.type == .MYSQL_TYPE_NULL) continue;
                    switch (value) {
                        .null_value => unreachable,
                        .boolean => |boolean| try writer.int1(@intFromBool(boolean)),
                        inline .int16, .uint16, .int32, .uint32, .int64, .uint64 => |number| try writer.write(&std.mem.toBytes(number)),
                        .float32 => |number| try writer.write(&std.mem.toBytes(@as(u32, @bitCast(number)))),
                        .float64 => |number| try writer.write(&std.mem.toBytes(@as(u64, @bitCast(number)))),
                        .text, .bytes => |bytes| try writer.writeLengthEncodedString(bytes),
                        .date => |milliseconds| {
                            if (milliseconds < -62167219200000 or milliseconds > 253402300799999) return error.InvalidBinaryValue;
                            const date = DateTime.fromMilliseconds(milliseconds);
                            var buffer: [13]u8 = undefined;
                            try writer.write(buffer[0..date.toBinary(param_type.type, &buffer)]);
                        },
                        .time => |milliseconds| {
                            const time = Time.fromMilliseconds(milliseconds);
                            var buffer: [13]u8 = undefined;
                            try writer.write(buffer[0..time.toBinary(param_type.type, &buffer)]);
                        },
                        .int32_array => return error.InvalidQueryBinding,
                    }
                }
            }
        }

        pub const write = writeWrap(Self, writeInternal).write;
    };
}

const debug = bun.Output.scoped(.PreparedStatement, .hidden);

const AnyMySQLError = @import("./AnyMySQLError.zig");
const bun = @import("bun");
const std = @import("std");
const DateTime = @import("../DateTime.zig");
const Time = @import("../Time.zig");
const CommandType = @import("./CommandType.zig").CommandType;
const Param = @import("../MySQLParam.zig").Param;
const NewReader = @import("./NewReader.zig").NewReader;
const decoderWrap = @import("./NewReader.zig").decoderWrap;

const NewWriter = @import("./NewWriter.zig").NewWriter;
const writeWrap = @import("./NewWriter.zig").writeWrap;
