const b = @import("bindgen_schema");

const engine_shims = .{
    b.engineShim("releaseFastMallocFreeMemory", .{}, b.none, .realm_independent),
    b.engineShim("releaseFastMallocFreeMemoryForThisThread", .{}, b.none, .realm_independent),
    b.engineShim("prepareForThreadExit", .{}, b.none, .realm_independent),
    b.engineShim("stackCheckInitialize", .{}, b.none, .realm_independent),
    b.engineShim("stackCheckGetEnd", .{}, b.optional(b.size), .realm_independent),
};

pub const schema = b.moduleWithEngineShims("wtf_threading", .{}, engine_shims);
