const b = @import("bindgen_schema");

const engine_shims = .{
    b.engineShim("jscInitialize", .{
        b.argument("environment", b.nativeSlice(.uint8, .read_only), .{}),
        b.argument("evalMode", b.boolean, .{}),
    }, b.optional(b.size), .realm_independent),
};

pub const schema = b.moduleWithDeclarations("jsc_initialization", .{}, .{}, engine_shims, .{});
