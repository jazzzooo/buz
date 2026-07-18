const CommandComplete = @This();

command_tag: Data = .{ .empty = {} },

pub fn deinit(this: *@This()) void {
    this.command_tag.deinit();
}

pub fn decode(this: *@This(), reader: PayloadReader) !void {
    var result: CommandComplete = .{};
    errdefer result.deinit();
    result.command_tag = try reader.readZ();
    try reader.expectEnd();
    this.* = result;
}

const Data = @import("../../shared/Data.zig").Data;
const PayloadReader = @import("./NewReader.zig").PayloadReader;
