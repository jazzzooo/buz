pub fn decode(context: anytype, reader: PayloadReader, comptime forEach: fn (@TypeOf(context), index: u32, bytes: ?*Data) AnyPostgresError!bool) AnyPostgresError!void {
    const remaining_fields = try reader.short();
    var should_emit = true;

    for (0..remaining_fields) |index| {
        const byte_length = try reader.int4();
        switch (byte_length) {
            0 => {
                var empty = Data.Empty;
                if (should_emit) should_emit = try forEach(context, @intCast(index), &empty);
            },
            null_int4 => {
                if (should_emit) should_emit = try forEach(context, @intCast(index), null);
            },
            else => {
                var bytes = try reader.bytes(@intCast(byte_length));
                if (should_emit) should_emit = try forEach(context, @intCast(index), &bytes);
            },
        }
    }
    try reader.expectEnd();
}

pub const null_int4 = 4294967295;

const Data = @import("../../shared/Data.zig").Data;

const AnyPostgresError = @import("../AnyPostgresError.zig").AnyPostgresError;

const PayloadReader = @import("./NewReader.zig").PayloadReader;
