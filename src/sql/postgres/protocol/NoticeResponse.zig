const NoticeResponse = @This();

messages: std.ArrayListUnmanaged(FieldMessage) = .empty,
pub fn deinit(this: *NoticeResponse) void {
    for (this.messages.items) |*message| {
        message.deinit();
    }
    this.messages.deinit(bun.default_allocator);
}
pub fn decode(this: *@This(), reader: PayloadReader) !void {
    var result: NoticeResponse = .{
        .messages = try FieldMessage.decodeList(reader),
    };
    errdefer result.deinit();
    try reader.expectEnd();
    this.* = result;
}
pub const toJS = @import("../../../sql_jsc/postgres/protocol/notice_response_jsc.zig").toJS;

const bun = @import("bun");
const std = @import("std");
const FieldMessage = @import("./FieldMessage.zig").FieldMessage;
const PayloadReader = @import("./NewReader.zig").PayloadReader;
