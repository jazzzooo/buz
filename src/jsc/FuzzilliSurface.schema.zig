const b = @import("bindgen_schema");
const runtime = @import("binding_schema_RuntimeFunctions");

const global = b.objectSurface("FuzzilliGlobal", .{
    b.surfaceFunction("fuzzilli", runtime.schema.function("jsFunctionFuzzilli"), .{
        .attributes = .{ .enumerable = false, .configurable = false },
    }),
    b.surfaceFunction("resetCoverage", runtime.schema.function("jsResetCoverage"), .{
        .attributes = .{ .enumerable = false, .configurable = false },
    }),
}, .{ .installation = .direct });

pub const schema = b.moduleWithSurfaces("FuzzilliSurface", .{global});
