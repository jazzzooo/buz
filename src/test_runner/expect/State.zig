pub const Flags = packed struct(u8) {
    promise: Promise = .none,
    not: bool = false,
    asymmetric_matcher_constructor_type: AsymmetricMatcherConstructorType = .none,

    pub const Promise = enum(u2) {
        none = 0,
        resolves = 1,
        rejects = 2,
    };

    pub const AsymmetricMatcherConstructorType = enum(u5) {
        none = 0,
        Symbol = 1,
        String = 2,
        Object = 3,
        Array = 4,
        BigInt = 5,
        Boolean = 6,
        Number = 7,
        Promise = 8,
        InstanceOf = 9,
    };

    pub const Wire = u8;

    comptime {
        if (@bitSizeOf(Flags) != @bitSizeOf(Wire)) @compileError("Expect flags must fit their wire representation");
    }

    pub inline fn encode(flags: Flags) Wire {
        return @bitCast(flags);
    }

    pub inline fn decode(bits: Wire) Flags {
        return @bitCast(bits);
    }
};

pub fn signature(comptime matcher_name: []const u8, comptime arguments: []const u8, comptime negated: bool) [:0]const u8 {
    const received = "<d>expect(<r><red>received<r><d>).<r>";
    if (negated) return received ++ "not<d>.<r>" ++ matcher_name ++ "<d>(<r>" ++ arguments ++ "<d>)<r>";
    return received ++ matcher_name ++ "<d>(<r>" ++ arguments ++ "<d>)<r>";
}

test "flags use one byte" {
    const flags = Flags{ .promise = .rejects, .not = true, .asymmetric_matcher_constructor_type = .InstanceOf };
    try @import("std").testing.expectEqual(flags, Flags.decode(flags.encode()));
}
