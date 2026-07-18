const StackReader = @This();

buffer: []const u8 = "",
offset: *usize,
message_start: *usize,

pub fn markMessageStart(this: @This()) void {
    this.message_start.* = this.offset.*;
}

pub fn init(buffer: []const u8, offset: *usize, message_start: *usize) NewReader(StackReader) {
    return .{
        .wrapped = .{
            .buffer = buffer,
            .offset = offset,
            .message_start = message_start,
        },
    };
}

pub fn peek(this: StackReader) []const u8 {
    return this.buffer[this.offset.*..];
}
pub fn skip(this: StackReader, count: usize) AnyPostgresError!void {
    if (count > this.buffer.len - this.offset.*) return error.ShortRead;
    this.offset.* += count;
}
pub fn read(this: StackReader, count: usize) AnyPostgresError!Data {
    const offset = this.offset.*;
    try this.skip(count);
    return Data{
        .temporary = this.buffer[offset..this.offset.*],
    };
}
pub fn readZ(this: StackReader) AnyPostgresError!Data {
    const remaining = this.peek();
    if (bun.strings.indexOfChar(remaining, 0)) |zero| {
        try this.skip(zero + 1);
        return Data{
            .temporary = remaining[0..zero],
        };
    }

    return error.ShortRead;
}

const bun = @import("bun");
const AnyPostgresError = @import("../AnyPostgresError.zig").AnyPostgresError;
const Data = @import("../../shared/Data.zig").Data;
const NewReader = @import("./NewReader.zig").NewReader;
