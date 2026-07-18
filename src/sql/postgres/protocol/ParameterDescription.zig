const ParameterDescription = @This();

parameters: []int4 = &[_]int4{},

pub fn decode(this: *@This(), reader: PayloadReader) !void {
    const count = try reader.short();
    const parameters = try bun.default_allocator.alloc(int4, count);
    errdefer bun.default_allocator.free(parameters);

    var data = try reader.read(@as(usize, count) * @sizeOf(int4));
    defer data.deinit();
    const input_params: []align(1) const int4 = toInt32Slice(int4, data.slice());
    for (input_params, parameters) |src, *dest| {
        dest.* = @byteSwap(src);
    }
    try reader.expectEnd();

    this.* = .{
        .parameters = parameters,
    };
}

// workaround for zig compiler TODO
fn toInt32Slice(comptime Int: type, slice: []const u8) []align(1) const Int {
    return @as([*]align(1) const Int, @ptrCast(slice.ptr))[0 .. slice.len / @sizeOf((Int))];
}

const bun = @import("bun");
const PayloadReader = @import("./NewReader.zig").PayloadReader;

const types = @import("../PostgresTypes.zig");
const int4 = types.int4;
