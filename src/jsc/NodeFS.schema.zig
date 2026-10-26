const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const functions = .{
    b.function(
        "assertEncodingValid",
        .{b.argument("encoding", archetypes.node_encoding, .{})},
        b.none,
        .{ .backend = .zig, .length = 1, .profile = .node },
    ),
};

const native_exports = .{
    b.nativeExportWithOptions("mkdirRecursive", .{b.argument("path", b.dom_string, .{})}, b.boolean, .allocating),
};

pub const schema = b.moduleWithNativeExports("NodeFS", functions, native_exports);
