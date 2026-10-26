const b = @import("bindgen_schema");

const value_pair = b.dictionaryWithOptions("JSValuePair", .{
    b.dictionaryField("left", b.engine_value, .{ .required = true }),
    b.dictionaryField("right", b.engine_value, .{ .required = true }),
}, .{ .cpp_name = "JSValuePair" });

const deep_match_arguments = b.dictionaryWithOptions("JSValueDeepMatchArguments", .{
    b.dictionaryField("value", b.engine_value, .{ .required = true }),
    b.dictionaryField("subset", b.engine_value, .{ .required = true }),
    b.dictionaryField("replaceProperties", b.boolean, .{ .required = true }),
}, .{ .cpp_name = "JSValueDeepMatchArguments" });

const instance_of_arguments = b.dictionaryWithOptions("JSValueInstanceOfArguments", .{
    b.dictionaryField("value", b.engine_value, .{ .required = true }),
    b.dictionaryField("constructor", b.engine_value, .{ .required = true }),
}, .{ .cpp_name = "JSValueInstanceOfArguments" });

const proxy_object_value = b.brandedValueWithBrand(b.cppDynamicCastBrand("ProxyObjectValue", .{
    .type_name = "JSC::ProxyObject",
    .header = "JavaScriptCore/ProxyObject.h",
}, "object"), .{});

const engine_shims = .{
    b.engineShim("jsValueIsAnyInt", .{b.argument("value", b.engine_value, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim("jsValueIsCallable", .{b.argument("value", b.engine_value, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim("jsValueIsConstructor", .{b.argument("value", b.engine_value, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim("jsValueIsInt32AsAnyInt", .{b.argument("value", b.engine_value, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim("jsValueIsPrimitive", .{b.argument("value", b.engine_value, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim("jsValueIsSymbol", .{b.argument("value", b.engine_value, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim("jsValueType", .{b.argument("value", b.engine_value, .{})}, b.uint8, .current_realm_unchecked),
    b.engineShim("jsValueProxyTarget", .{b.argument("value", b.engine_value, .{})}, b.optional(b.engine_value), .current_realm_nonthrowing),
    b.engineShim("jsValueIsClass", .{b.argument("value", b.engine_value, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim("jsValueGetPrototype", .{b.argument("value", b.engine_value, .{})}, b.engine_value, .current_realm_throwing),
    b.engineShim("jsValueIsInstanceOf", .{b.argument("input", instance_of_arguments, .{})}, b.boolean, .current_realm_throwing),
    b.engineShim("jsValueIsIterable", .{b.argument("value", b.engine_value, .{})}, b.boolean, .current_realm_throwing),
    b.engineShim("determineSpecificType", .{b.argument("value", b.engine_value, .{})}, b.dom_string, .current_realm_throwing),
    b.engineShim("jsValueGetName", .{b.argument("value", b.engine_value, .{})}, b.dom_string, .current_realm_throwing),
    b.engineShim("jsValueGetDeclaredName", .{b.argument("value", b.engine_value, .{})}, b.dom_string, .current_realm_throwing),
    b.engineShim("jsValueIsConstructorPrototype", .{b.argument("value", b.engine_value, .{})}, b.boolean, .current_realm_throwing),
    b.engineShim("jsValueClassName", .{b.argument("value", b.engine_value, .{})}, b.dom_string, .current_realm_throwing),
    b.engineShim("jsValueClassInfoName", .{b.argument("value", b.engine_value, .{})}, b.optional(b.dom_string), .current_realm_nonthrowing),
    b.engineShim("jsTypeStringForValue", .{b.argument("value", b.engine_value, .{})}, b.dom_string, .current_realm_nonthrowing),
    b.engineShim(
        "proxyObjectGetInternalField",
        .{
            b.argument("value", b.brandCast(proxy_object_value, .{ .failure = .assert, .input = .engine_value }), .{}),
            b.argument("field", b.uint32, .{}),
        },
        b.optional(b.engine_value),
        .current_realm_nonthrowing,
    ),
    b.engineShim("jsValueStrictEqual", .{b.argument("operands", value_pair, .{})}, b.boolean, .current_realm_throwing),
    b.engineShim("jsValueSameValue", .{b.argument("operands", value_pair, .{})}, b.boolean, .current_realm_throwing),
    b.engineShim("jsValueEqual", .{b.argument("operands", value_pair, .{})}, b.boolean, .current_realm_unchecked),
    b.engineShim("jsValueDeepEquals", .{b.argument("input", value_pair, .{})}, b.boolean, .current_realm_throwing),
    b.engineShim("jsValueJestDeepEquals", .{b.argument("input", value_pair, .{})}, b.boolean, .current_realm_throwing),
    b.engineShim("jsValueStrictDeepEquals", .{b.argument("input", value_pair, .{})}, b.boolean, .current_realm_throwing),
    b.engineShim("jsValueJestStrictDeepEquals", .{b.argument("input", value_pair, .{})}, b.boolean, .current_realm_throwing),
    b.engineShim("jsValueJestDeepMatch", .{b.argument("input", deep_match_arguments, .{})}, b.boolean, .current_realm_throwing),
    b.engineShim("jsValueLengthIfPropertyExists", .{b.argument("value", b.engine_value, .{})}, b.optional(b.double), .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("js_value_inspection", .{}, .{}, engine_shims, .{});
