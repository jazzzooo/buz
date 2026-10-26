const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const schema = b.module("NativeModuleHost", .{
    archetypes.lazySurfaceFunction("constructNodeBufferTranscode", archetypes.callable_value),
    archetypes.lazySurfaceFunction("constructBunAppResponse", archetypes.constructor_value),
    archetypes.lazySurfaceFunction("constructNodeStringDecoder", archetypes.constructor_value),
});
