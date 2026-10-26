const b = @import("bindgen_schema");
const engine_types = @import("binding_schema_engine_types");
const web_worker = @import("binding_schema_WebWorkerEngine");

const engine_shims = .{
    b.engineShim("globalObjectValue", .{}, b.js_object, .current_realm_unchecked),
    b.engineShim(
        "globalObjectThrowValue",
        .{b.argument("value", b.engine_value, .{})},
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim(
        "scriptExecutionContextExists",
        .{b.argument("identifier", b.uint32, .{})},
        b.boolean,
        .realm_independent,
    ),
    b.engineShim(
        "globalObjectDestructOnExit",
        .{b.argument("globalObject", engine_types.zig_global_object, .{})},
        b.boolean,
        .vm_thread_nonthrowing,
    ),
    b.engineShim("reloadGlobalObject", .{}, b.none, .current_realm_throwing),
    b.engineShim("scriptExecutionContextIdentifier", .{}, b.uint32, .current_realm_nonthrowing),
    b.engineShim(
        "detachBindgenWrappers",
        .{b.argument("global", engine_types.global_object, .{})},
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "globalObjectCreate",
        .{
            b.argument("context_id", b.int32, .{}),
            b.argument("mini_mode", b.boolean, .{}),
            b.argument("eval_mode", b.boolean, .{}),
            b.argument("worker", b.optional(web_worker.web_worker_handle), .{}),
        },
        engine_types.global_object,
        .realm_independent,
    ),
    b.engineShim(
        "globalObjectCreateForTestIsolation",
        .{b.argument("old_global", engine_types.global_object, .{})},
        engine_types.global_object,
        .vm_thread_nonthrowing,
    ),
};

pub const schema = b.moduleWithDeclarations("global_objects", .{}, .{}, engine_shims, .{});
