const b = @import("bindgen_schema");

const strong_ref = b.nominalHandle("StrongRef", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::StrongRefStorage" } },
    .cpp_declarations = &.{.{ .class = "Bun::StrongRefStorage" }},
    .ownership = .owned,
    .cpp_release = "strongRefRelease",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const engine_shims = .{
    b.engineShim(
        "strongRefSetAllocationFailureCountdown",
        .{b.argument("countdown", b.int32, .{})},
        b.none,
        .current_realm_unchecked,
    ),
    b.engineShim("strongRefCreate", .{b.argument("value", b.engine_value, .{})}, strong_ref, .{
        .throws = .out_of_memory,
        .realm = .current,
        .affinity = .vm,
    }),
    b.engineShim("strongRefGet", .{b.argument("reference", strong_ref, .{})}, b.engine_value, .current_realm_unchecked),
    b.engineShim("strongRefClone", .{b.argument("reference", strong_ref, .{})}, strong_ref, .current_realm_unchecked),
    b.engineShim("strongRefBelongsToCurrentVM", .{b.argument("reference", strong_ref, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim(
        "strongRefsShareVM",
        .{
            b.argument("left", strong_ref, .{}),
            b.argument("right", strong_ref, .{}),
        },
        b.boolean,
        .current_realm_unchecked,
    ),
};

pub const schema = b.moduleWithDeclarations("strong_references", .{}, .{}, engine_shims, .{});
