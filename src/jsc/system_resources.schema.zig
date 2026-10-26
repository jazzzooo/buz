const b = @import("bindgen_schema");

const engine_shims = .{
    b.engineShim("ramSize", .{}, b.size, .realm_independent),
    b.engineShim("numberOfProcessorCores", .{}, b.int32, .realm_independent),
};

pub const schema = b.moduleWithEngineShims("system_resources", .{}, engine_shims);
