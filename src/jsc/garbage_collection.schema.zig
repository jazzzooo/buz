const b = @import("bindgen_schema");

const functions = .{b.function(
    "jsGc",
    .{},
    b.none,
    .{ .backend = .cpp, .length = 0, .profile = .exact },
)};

const engine_shims = .{
    b.engineShim(
        "setDefaultRemainingRunsUntilSkipReleaseAccess",
        .{b.argument("value", b.int32, .{})},
        b.none,
        .realm_independent,
    ),
    b.engineShim("addGc", .{}, b.none, .current_realm_nonthrowing),
};

const native_exports = .{b.nativeExportWithOptions("garbageCollect", .{b.argument("sync", b.boolean, .{})}, b.size, .current_realm_nonthrowing)};

pub const schema = b.moduleWithDeclarations("garbage_collection", functions, .{}, engine_shims, native_exports);
