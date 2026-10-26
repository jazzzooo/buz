const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const deferred_eval_specifier = "the specifier is coerced only when an eval entry point is installed";

const native_exports = .{
    b.nativeExportWithOptions("setOverrideModuleRunMain", .{b.argument("isPatched", b.boolean, .{})}, b.none, .current_realm_nonthrowing),
    b.nativeExportWithOptions("setOverrideModuleRunMainPromise", .{b.argument("promise", b.js_promise, .{})}, b.none, .current_realm_throwing),
    b.nativeExportWithOptions("logUnhandledException", .{b.argument("exception", b.engine_value, .{})}, b.none, .current_realm_nonthrowing),
    b.nativeExportWithOptions("isBunMain", .{b.argument("main", b.dom_string, .{})}, b.boolean, .current_realm_nonthrowing),
    b.nativeExportWithOptions("specifierIsEvalEntryPoint", .{b.argument("specifier", b.lazy(archetypes.coerced_dom_string), .{ .deferred_reason = deferred_eval_specifier })}, b.boolean, .current_realm_throwing),
    b.nativeExportWithOptions("setEntryPointEvalResultESM", .{b.argument("result", b.engine_value, .{})}, b.none, .current_realm_throwing),
    b.nativeExportWithOptions("setEntryPointEvalResultCJS", .{b.argument("result", b.engine_value, .{})}, b.none, .current_realm_throwing),
};

pub const schema = b.moduleWithNativeExports("module_run_main", .{}, native_exports);
