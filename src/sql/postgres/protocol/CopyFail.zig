const CopyFail = @This();

message: Data = .{ .empty = {} },

pub fn decode(this: *@This(), reader: PayloadReader) !void {
    this.* = .{ .message = try reader.readZ() };
    try reader.expectEnd();
}

pub fn writeInternal(
    this: *@This(),
    comptime Context: type,
    writer: NewWriter(Context),
) !void {
    const message = this.message.slice();
    const count: u32 = @sizeOf((u32)) + message.len + 1;
    const header = [_]u8{
        'f',
    } ++ toBytes(Int32(count));
    try writer.write(&header);
    try writer.string(message);
}

pub const write = WriteWrap(@This(), writeInternal).write;

const std = @import("std");
const Data = @import("../../shared/Data.zig").Data;
const NewWriter = @import("./NewWriter.zig").NewWriter;
const PayloadReader = @import("./NewReader.zig").PayloadReader;
const WriteWrap = @import("./WriteWrap.zig").WriteWrap;
const toBytes = std.mem.toBytes;

const int_types = @import("../types/int_types.zig");
const Int32 = int_types.Int32;
