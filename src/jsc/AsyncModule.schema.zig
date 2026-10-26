const b = @import("bindgen_schema");
const module_loader = @import("binding_schema_ModuleLoader");

const error_data = b.dictionary("AsyncModuleErrorData", .{
    b.dictionaryField("message", b.dom_string, .{ .required = true }),
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("url", b.optional(b.dom_string), .{ .required = true }),
    b.dictionaryField("pkg", b.dom_string, .{ .required = true }),
    b.dictionaryField("specifier", b.dom_string, .{ .required = true }),
    b.dictionaryField("source_url", b.dom_string, .{ .required = true }),
    b.dictionaryField("line", b.int32, .{ .required = true }),
    b.dictionaryField("line_text", b.optional(b.dom_string), .{ .required = true }),
    b.dictionaryField("column", b.int32, .{ .required = true }),
    b.dictionaryField("referrer", b.optional(b.dom_string), .{ .required = true }),
});

const engine_shims = .{
    b.engineShim("fulfill", .{
        b.argument("promise", b.js_promise, .{}),
        b.argument("result", module_loader.resolved_source_result, .{ .ownership = .transfer }),
        b.argument("specifier", b.dom_string, .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("createError", .{b.argument("data", error_data, .{})}, b.js_error_instance, .current_realm_throwing),
};

pub const schema = b.moduleWithEngineShims("AsyncModule", .{}, engine_shims);
