const BackendKeyData = @This();

process_id: u32 = 0,
secret_key: u32 = 0,

pub fn decode(this: *@This(), reader: PayloadReader) !void {
    if (reader.peek().len != 8) return error.InvalidBackendKeyData;

    this.* = .{
        .process_id = @bitCast(try reader.int4()),
        .secret_key = @bitCast(try reader.int4()),
    };
}

const PayloadReader = @import("./NewReader.zig").PayloadReader;
