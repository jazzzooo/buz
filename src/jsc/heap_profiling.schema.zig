const b = @import("bindgen_schema");

const engine_shims = .{
    b.engineShim("generateHeapProfile", .{}, b.dom_string, .current_realm_nonthrowing),
    b.engineShim("generateHeapSnapshotV8", .{}, b.dom_string, .current_realm_nonthrowing),
    b.engineShim("generateHeapSnapshot", .{}, b.js_object, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("heap_profiling", .{}, .{}, engine_shims, .{});
