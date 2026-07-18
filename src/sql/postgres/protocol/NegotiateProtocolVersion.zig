version: int4 = 0,
unrecognized_options: std.ArrayListUnmanaged(String) = .empty,

pub fn decode(
    this: *@This(),
    reader: PayloadReader,
) !void {
    const version = try reader.int4();
    this.* = .{
        .version = version,
    };

    const unrecognized_options_count: u32 = @intCast(@max(try reader.int4(), 0));
    try this.unrecognized_options.ensureTotalCapacity(bun.default_allocator, unrecognized_options_count);
    errdefer {
        for (this.unrecognized_options.items) |*option| {
            option.deinit();
        }
        this.unrecognized_options.deinit(bun.default_allocator);
    }
    for (0..unrecognized_options_count) |_| {
        var option = try reader.readZ();
        if (option.slice().len == 0) break;
        defer option.deinit();
        this.unrecognized_options.appendAssumeCapacity(
            String.borrowUTF8(option),
        );
    }
    try reader.expectEnd();
}

const std = @import("std");
const PayloadReader = @import("./NewReader.zig").PayloadReader;

const int_types = @import("../types/int_types.zig");
const int4 = int_types.int4;

const bun = @import("bun");
const String = bun.String;
