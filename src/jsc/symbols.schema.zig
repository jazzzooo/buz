const b = @import("bindgen_schema");

const engine_shims = .{
    b.engineShim(
        "symbolFor",
        .{b.argument("key", b.dom_string, .{})},
        b.js_symbol,
        .current_realm_nonthrowing,
    ),
    b.engineShim(
        "jsValueSymbolDescription",
        .{b.argument("value", b.engine_value, .{})},
        b.dom_string,
        .current_realm_nonthrowing,
    ),
};

pub const schema = b.moduleWithDeclarations("symbols", .{}, .{}, engine_shims, .{});
