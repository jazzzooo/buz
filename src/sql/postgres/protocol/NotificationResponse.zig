const NotificationResponse = @This();

pid: int4 = 0,
channel: bun.ByteList = .{},
payload: bun.ByteList = .{},

pub fn deinit(this: *@This()) void {
    this.channel.clearAndFree(bun.default_allocator);
    this.payload.clearAndFree(bun.default_allocator);
}

pub fn decode(this: *@This(), reader: PayloadReader) !void {
    var result: NotificationResponse = .{};
    errdefer result.deinit();
    result.pid = try reader.int4();

    var channel = try reader.readZ();
    defer channel.deinit();
    result.channel = try channel.toOwned();

    var payload = try reader.readZ();
    defer payload.deinit();
    result.payload = try payload.toOwned();

    try reader.expectEnd();
    this.* = result;
}

const bun = @import("bun");
const PayloadReader = @import("./NewReader.zig").PayloadReader;

const types = @import("../PostgresTypes.zig");
const int4 = types.int4;
