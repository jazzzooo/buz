const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const schema = b.module("StreamAlgorithms", .{
    b.function("invokeSize", .{
        b.argument("callback", archetypes.stream_size, .{}),
        b.argument("chunk", b.invocation_any, .{}),
    }, b.double, .{ .profile = .exact }),
});
