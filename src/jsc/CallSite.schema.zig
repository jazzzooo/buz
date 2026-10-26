const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const call_site_value = b.brandedValueWithBrand(b.cppDynamicCastBrand("CallSiteValue", .{
    .type_name = "Zig::CallSite",
    .header = "CallSite.h",
}, "object"), .{
    .error_kind = .instance,
    .expectation = "a CallSite object",
    .node_requirement = "CallSite",
});

const call_site_json = b.dictionaryWithOptions("CallSiteJSON", .{
    archetypes.requiredDictionaryField("sourceURL", b.dom_string),
    archetypes.requiredDictionaryField("lineNumber", b.int32),
    archetypes.requiredDictionaryField("columnNumber", b.int32),
    archetypes.requiredDictionaryField("functionName", b.dom_string),
}, .{ .cpp_name = "CallSiteJSONDictionary" });

const callback = b.callback(
    "NativeFrameCallback",
    .{},
    b.engine_value,
    .{ .receiver = null, .profile = .exact },
);

fn callSiteMethod(comptime name: []const u8, comptime result: b.Type) b.Function {
    return b.function(name, .{}, result, .{
        .backend = .cpp,
        .profile = .exact,
        .this_value_type = call_site_value,
    });
}

pub const schema = b.module("CallSite", .{
    b.function(
        "callNativeFrameForTesting",
        .{b.argument("callback", callback, .{})},
        b.engine_value,
        .{ .backend = .cpp, .profile = .exact },
    ),
    callSiteMethod("getThis", b.engine_value),
    callSiteMethod("getTypeName", b.dom_string),
    callSiteMethod("getFunction", b.engine_value),
    callSiteMethod("getFunctionName", b.dom_string),
    callSiteMethod("getMethodName", b.dom_string),
    callSiteMethod("getFileName", b.dom_string),
    callSiteMethod("getLineNumber", b.int32),
    callSiteMethod("getColumnNumber", b.int32),
    callSiteMethod("getEvalOrigin", b.none),
    callSiteMethod("getScriptNameOrSourceURL", b.dom_string),
    callSiteMethod("isToplevel", b.boolean),
    callSiteMethod("isEval", b.boolean),
    callSiteMethod("isNative", b.boolean),
    callSiteMethod("isConstructor", b.boolean),
    callSiteMethod("isAsync", b.boolean),
    callSiteMethod("isPromiseAll", b.boolean),
    callSiteMethod("getPromiseIndex", archetypes.nullable_int32),
    callSiteMethod("toString", b.dom_string),
    callSiteMethod("toJSON", call_site_json),
});
