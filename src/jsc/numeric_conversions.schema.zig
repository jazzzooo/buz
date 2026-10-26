const b = @import("bindgen_schema");

const engine_shims = .{
    b.engineShim(
        "parseDouble",
        .{b.argument("bytes", b.buffer(.copy), .{})},
        b.optional(b.double),
        .realm_independent,
    ),
    b.engineShim(
        "operationMathPow",
        .{
            b.argument("base", b.double, .{}),
            b.argument("exponent", b.double, .{}),
        },
        b.double,
        .realm_independent,
    ),
};

pub const schema = b.moduleWithDeclarations("numeric_conversions", .{}, .{}, engine_shims, .{});
