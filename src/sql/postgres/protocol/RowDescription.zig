const RowDescription = @This();

fields: []FieldDescription = &[_]FieldDescription{},
pub fn deinit(this: *@This()) void {
    for (this.fields) |*field| {
        field.deinit();
    }

    bun.default_allocator.free(this.fields);
}

pub fn decode(this: *@This(), reader: PayloadReader) !void {
    const field_count = try reader.short();
    var fields = try bun.default_allocator.alloc(
        FieldDescription,
        field_count,
    );
    var remaining = fields;
    errdefer {
        for (fields[0 .. field_count - remaining.len]) |*field| {
            field.deinit();
        }

        bun.default_allocator.free(fields);
    }
    while (remaining.len > 0) {
        try remaining[0].decode(reader);
        remaining = remaining[1..];
    }
    try reader.expectEnd();
    this.* = .{
        .fields = fields,
    };
}

const FieldDescription = @import("./FieldDescription.zig");
const bun = @import("bun");
const PayloadReader = @import("./NewReader.zig").PayloadReader;
