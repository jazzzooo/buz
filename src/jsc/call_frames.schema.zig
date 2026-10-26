const b = @import("bindgen_schema");
const engine_types = @import("binding_schema_engine_types");

const caller_source_location = b.dictionary("CallerSourceLocation", .{
    b.dictionaryField("sourceURL", b.dom_string, .{ .required = true }),
    b.dictionaryField("line", b.uint32, .{ .required = true }),
    b.dictionaryField("column", b.uint32, .{ .required = true }),
});

const engine_shims = .{
    b.engineShim("callFrameGetCallerSourceLocation", .{b.argument("callFrame", engine_types.call_frame, .{})}, caller_source_location, .current_realm_nonthrowing),
    b.engineShim("callFrameGetLineNumber", .{b.argument("callFrame", engine_types.call_frame, .{})}, b.uint32, .current_realm_nonthrowing),
};

pub const schema = b.moduleWithDeclarations("call_frames", .{}, .{}, engine_shims, .{});
