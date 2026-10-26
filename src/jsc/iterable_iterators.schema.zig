const b = @import("bindgen_schema");

const iterator = b.nominalHandle("IterableIterator", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::Bindgen::Engine::IterableIterator" } },
    .cpp_declarations = &.{.{ .class = "Bun::Bindgen::Engine::IterableIterator" }},
    .access_thread = .vm,
});

const engine_shims = .{
    b.engineShim(
        "iterableIteratorCreate",
        .{b.argument("value", b.engine_value, .{})},
        b.optional(iterator),
        .current_realm_throwing,
    ),
    b.engineShim(
        "iterableIteratorNext",
        .{b.argument("iterator", iterator, .{})},
        b.optional(b.engine_value),
        .current_realm_throwing,
    ),
    b.engineShim(
        "iterableIteratorClose",
        .{b.argument("iterator", iterator, .{})},
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim(
        "iterableIteratorDestroy",
        .{b.argument("iterator", iterator, .{})},
        b.none,
        .vm_thread_nonthrowing,
    ),
};

pub const schema = b.moduleWithDeclarations("iterable_iterators", .{}, .{}, engine_shims, .{});
