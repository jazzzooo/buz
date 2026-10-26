const b = @import("bindgen_schema");

const functions = .{
    b.function(
        "gcAggressionLevel",
        .{b.argument("value", b.int32, .{
            .presence = .optional,
            .missing = .undefined_or_null,
            .integer_conversion = .coerce,
        })},
        b.int32,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "arrayBufferToString",
        .{b.argument("value", b.buffer(.lease), .{})},
        b.dom_string,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
    b.function(
        "mimallocDump",
        .{},
        b.none,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
        },
    ),
};

const engine_shims = .{
    b.engineShim("dumpMallocZoneStats", .{}, b.none, .realm_independent),
};

pub const schema = b.moduleWithDeclarations("UnsafeObject", functions, .{}, engine_shims, .{});
