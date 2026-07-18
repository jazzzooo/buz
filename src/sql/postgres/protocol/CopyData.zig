const CopyData = @This();

data: Data = .{ .empty = {} },

pub fn decode(this: *@This(), reader: PayloadReader) !void {
    this.* = .{
        .data = try reader.read(reader.peek().len),
    };
}

pub fn writeInternal(
    this: *const @This(),
    comptime Context: type,
    writer: NewWriter(Context),
) !void {
    const data = this.data.slice();
    const count: u32 = @sizeOf((u32)) + data.len + 1;
    const header = [_]u8{
        'd',
    } ++ toBytes(Int32(count));
    try writer.write(&header);
    try writer.string(data);
}

pub const write = WriteWrap(@This(), writeInternal).write;

const std = @import("std");
const Data = @import("../../shared/Data.zig").Data;
const Int32 = @import("../types/int_types.zig").Int32;
const NewWriter = @import("./NewWriter.zig").NewWriter;
const PayloadReader = @import("./NewReader.zig").PayloadReader;
const WriteWrap = @import("./WriteWrap.zig").WriteWrap;
const toBytes = std.mem.toBytes;
