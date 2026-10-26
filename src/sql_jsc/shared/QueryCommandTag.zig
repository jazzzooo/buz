pub fn init(tag: CommandTag) bun.OOM!Value {
    return switch (tag) {
        .INSERT => .{ .code = 1 },
        .DELETE => .{ .code = 2 },
        .UPDATE => .{ .code = 3 },
        .MERGE => .{ .code = 4 },
        .SELECT => .{ .code = 5 },
        .MOVE => .{ .code = 6 },
        .FETCH => .{ .code = 7 },
        .COPY => .{ .code = 8 },
        .other => |name| .{ .name = try bun.bindgen.DOMString.fromUTF8(name) },
    };
}

pub fn deinit(value: *Value) void {
    switch (value.*) {
        .name => |*name| name.deinit(),
        .code => {},
    }
}

pub fn count(tag: CommandTag) f64 {
    return @floatFromInt(switch (tag) {
        .other => 0,
        inline else => |value| value,
    });
}

const Operand = @FieldType(bun.bindgen.Args(bun.bindgen.CallbackSchema("PostgresQueryResolveCallback")), "commandTag");

pub const Value = union(enum) {
    code: @FieldType(Operand, "code"),
    name: bun.bindgen.DOMString,
};

pub fn operand(value: *const Value) Operand {
    return switch (value.*) {
        .code => |code| .{ .code = code },
        .name => |*name| .{ .name = name.operand() },
    };
}

const bun = @import("bun");
const CommandTag = @import("../../sql/postgres/CommandTag.zig").CommandTag;
