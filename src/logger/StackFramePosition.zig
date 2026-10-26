pub const StackFramePosition = struct {
    line: bun.Ordinal,
    column: bun.Ordinal,
    line_start_byte: c_int,

    pub const invalid = StackFramePosition{
        .line = .invalid,
        .column = .invalid,
        .line_start_byte = -1,
    };

    pub fn isInvalid(this: *const StackFramePosition) bool {
        return std.mem.eql(u8, std.mem.asBytes(this), std.mem.asBytes(&invalid));
    }

    pub fn decode(reader: anytype) !@This() {
        return .{
            .line = bun.Ordinal.fromZeroBased(try reader.readValue(i32)),
            .column = bun.Ordinal.fromZeroBased(try reader.readValue(i32)),
            .line_start_byte = -1,
        };
    }

    pub fn encode(this: *const @This(), writer: anytype) anyerror!void {
        try writer.writeInt(this.line.zeroBased());
        try writer.writeInt(this.column.zeroBased());
    }
};

const bun = @import("bun");
const std = @import("std");
