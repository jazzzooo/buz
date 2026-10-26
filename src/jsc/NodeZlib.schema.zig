const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const crc32_data = b.unionType("NodeZlibCRC32Data", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("view", b.bufferView(.copy)),
}, .{
    .node_error = .{ .type_or_instance = .{
        .expected_type = "string",
        .expected_instances = "Buffer, TypedArray, or DataView",
    } },
});

const crc32_value_range = b.IntegerRange{
    .min = 0,
    .max = 4294967295,
};

const functions = .{
    b.function(
        "crc32",
        .{
            b.argument("data", crc32_data, .{}),
            archetypes.nodeInteger("value", b.uint32, crc32_value_range, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .unsigned = 0 },
            }),
        },
        b.uint32,
        .{ .backend = .zig, .length = 1, .profile = .node },
    ),
};

pub const schema = b.module("NodeZlib", functions);
