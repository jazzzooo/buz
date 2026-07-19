const ReadyForQuery = @This();

status: TransactionStatusIndicator = .I,
pub fn decode(this: *@This(), reader: PayloadReader) !void {
    try reader.expectLength(1);

    const status = try reader.int(u8);
    this.* = .{
        .status = @fromBackingInt(@intCast(status)),
    };
}

const PayloadReader = @import("./NewReader.zig").PayloadReader;
const TransactionStatusIndicator = @import("./TransactionStatusIndicator.zig").TransactionStatusIndicator;
