const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const engine_types = @import("binding_schema_engine_types");

const async_context_wrappable_value = b.brandedValueWithBrand(b.cppBrand("AsyncContextWrappableValue", .{
    .symbol = "Bun::Bindgen::TypePredicates::isAsyncContextWrappable",
    .header = "AsyncContextFrame.h",
}, "((...args: unknown[]) => unknown) | Promise<unknown>"), .{});

const async_context_frame_value = b.brandedValueWithBrand(b.cppDynamicCastBrand("AsyncContextFrameValue", .{
    .type_name = "AsyncContextFrame",
    .header = "AsyncContextFrame.h",
}, "object"), .{});

const functions = .{
    b.function(
        "setAsyncHooksEnabled",
        .{b.argument("enabled", b.boolean, .{})},
        b.none,
        .{ .backend = .cpp, .profile = .webidl },
    ),
    b.function("cleanupLater", .{}, b.none, .{ .backend = .cpp, .profile = .exact }),
};

const engine_shims = .{
    b.engineShim("callbackIdentityEquals", .{
        b.argument("left", b.brandCast(engine_types.callable_or_async_context_value, .{ .failure = .assert, .input = .engine_value }), .{}),
        b.argument("right", b.brandCast(engine_types.callable_or_async_context_value, .{ .failure = .assert, .input = .engine_value }), .{}),
    }, b.boolean, .current_realm_unchecked),
    b.engineShim(
        "jsValueIsAsyncContextFrame",
        .{b.argument("value", b.engine_value, .{})},
        b.boolean,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "asyncContextFrameWithAsyncContextIfNeeded",
        .{b.argument("value", b.brandCast(async_context_wrappable_value, .{ .failure = .assert, .input = .engine_value }), .{})},
        b.engine_value,
        .current_realm_nonthrowing,
    ),
    b.engineShim(
        "createAsyncContextFrame",
        .{
            b.argument("callback", archetypes.callable_value, .{}),
            b.argument("context", b.engine_value, .{}),
        },
        async_context_frame_value,
        .current_realm_nonthrowing,
    ),
};

pub const schema = b.moduleWithDeclarations("AsyncHooks", functions, .{}, engine_shims, .{});
