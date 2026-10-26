const b = @import("bindgen_schema");
const garbage_collection = @import("binding_schema_garbage_collection");

const global = b.objectSurface("GarbageCollectionGlobal", .{
    b.surfaceFunction("gc", garbage_collection.schema.function("jsGc"), .{
        .attributes = .{ .enumerable = false },
    }),
}, .{ .installation = .direct });

pub const schema = b.moduleWithSurfaces("GarbageCollectionSurface", .{global});
