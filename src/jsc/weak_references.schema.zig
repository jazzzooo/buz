const b = @import("bindgen_schema");

const weak_ref = b.nominalHandle("WeakRef", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::WeakRef" } },
    .cpp_declarations = &.{.{ .class = "Bun::WeakRef" }},
    .ownership = .owned,
    .cpp_release = "weakRefRelease",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const finalizer = b.nominalHandle("WeakRefFinalizer", .{
    .cpp_type = .{ .pointer = &.{ .named = "BunBindgenWeakRefFinalizer" } },
    .cpp_declarations = &.{.{ .structure = "BunBindgenWeakRefFinalizer" }},
    .ownership = .borrowed,
    .access_thread = .vm,
});

const engine_shims = .{
    b.engineShim("weakRefCreate", .{
        b.argument("value", b.brandCast(b.js_object, .{ .failure = .assert, .input = .engine_value }), .{}),
        b.argument("finalizer", b.optional(finalizer), .{}),
    }, weak_ref, .current_realm_throwing),
    b.engineShim(
        "weakRefGet",
        .{b.argument("reference", weak_ref, .{})},
        b.optional(b.js_object),
        .current_realm_nonthrowing,
    ),
};

const native_exports = .{
    b.nativeExport("weakRefFinalizerRun", .{b.argument("finalizer", finalizer, .{})}, b.none),
};

pub const schema = b.moduleWithDeclarations("weak_references", .{}, .{}, engine_shims, native_exports);
