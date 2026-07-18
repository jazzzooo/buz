const ParameterStatus = @This();

name: Data = .{ .empty = {} },
value: Data = .{ .empty = {} },

pub fn deinit(this: *@This()) void {
    this.name.deinit();
    this.value.deinit();
}

pub fn decode(this: *@This(), reader: PayloadReader) !void {
    var result: ParameterStatus = .{};
    errdefer result.deinit();
    result.name = try reader.readZ();
    result.value = try reader.readZ();
    try reader.expectEnd();
    this.* = result;
}

const Data = @import("../../shared/Data.zig").Data;
const PayloadReader = @import("./NewReader.zig").PayloadReader;
