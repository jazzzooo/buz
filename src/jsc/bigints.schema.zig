const b = @import("bindgen_schema");

const comparison_right_value = b.brandedValueWithBrand(b.cppBrand("BigIntComparisonRightValue", .{
    .symbol = "Bun::Bindgen::TypePredicates::isBigIntOrNumber",
    .header = "BindgenTypePredicates.h",
}, "bigint | number"), .{});

const engine_shims = .{
    b.engineShim("jsValueIsBigInt", .{b.argument("value", b.engine_value, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim("jsValueIsBigInt32", .{b.argument("value", b.engine_value, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim(
        "jsValueCompareBigInt",
        .{
            b.argument("left", b.brandCast(b.js_big_int, .{ .failure = .assert, .input = .engine_value }), .{}),
            b.argument("right", b.brandCast(comparison_right_value, .{ .failure = .assert, .input = .engine_value }), .{}),
        },
        b.uint8,
        .current_realm_unchecked,
    ),
};

pub const schema = b.moduleWithDeclarations("bigints", .{}, .{}, engine_shims, .{});
