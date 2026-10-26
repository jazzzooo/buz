const b = @import("bindgen_schema");
const engine_types = @import("binding_schema_engine_types");

const engine_shims = .{
    b.engineShim("teardownThreadJSCVM", .{b.argument("globalObject", engine_types.zig_global_object, .{})}, b.none, .vm_thread_nonthrowing),
};

pub const schema = b.moduleWithEngineShims("jsc_thread_teardown", .{}, engine_shims);
