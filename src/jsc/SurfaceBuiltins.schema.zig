const b = @import("bindgen_schema");

fn builtin(comptime name: []const u8, comptime generator: []const u8, comptime result: b.Type, comptime length: u8) b.Function {
    return b.function(name, .{}, result, .{
        .backend = .builtin,
        .builtin = generator,
        .length = length,
        .profile = .exact,
    });
}

pub const schema = b.module("SurfaceBuiltins", .{
    builtin("commonJSMain", "commonJSMainCodeGenerator", b.any, 0),
    builtin("importMetaMain", "importMetaObjectMainCodeGenerator", b.boolean, 0),
    builtin("createFIFO", "streamInternalsCreateFIFOCodeGenerator", b.js_object, 0),
    builtin("requireESM", "commonJSRequireESMCodeGenerator", b.any, 1),
    builtin("loadEsmIntoCjs", "commonJSLoadEsmIntoCjsCodeGenerator", b.any, 1),
    builtin("internalRequire", "commonJSInternalRequireCodeGenerator", b.any, 3),
    builtin("overridableRequire", "commonJSOverridableRequireCodeGenerator", b.any, 1),
    builtin("consoleAsyncIterator", "consoleObjectAsyncIteratorCodeGenerator", b.js_generator_object, 0),
    builtin("consoleWrite", "consoleObjectWriteCodeGenerator", b.double, 1),
    builtin("peek", "peekPeekCodeGenerator", b.any, 1),
    builtin("peekStatus", "peekPeekStatusCodeGenerator", b.dom_string, 1),
});
