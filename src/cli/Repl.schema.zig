const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const evaluation = b.dictionary("REPLEvaluation", .{
    b.dictionaryField("result", b.engine_value, .{ .required = true }),
    b.dictionaryField("exception", b.optional(b.engine_value), .{ .required = true }),
});

const engine_shims = .{
    b.engineShim("evaluate", .{
        b.argument("source", b.dom_string, .{}),
        b.argument("filename", b.dom_string, .{}),
    }, evaluation, .current_realm_throwing),
    b.engineShim("getCompletions", .{b.argument("prefix", b.dom_string, .{})}, archetypes.dom_strings, .current_realm_throwing),
    b.engineShim("setLastResult", .{b.argument("value", b.engine_value, .{})}, b.none, .current_realm_throwing),
    b.engineShim("setLastError", .{b.argument("value", b.engine_value, .{})}, b.none, .current_realm_throwing),
};

pub const schema = b.moduleWithEngineShims("Repl", .{}, engine_shims);
