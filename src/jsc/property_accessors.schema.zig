const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const custom_getter_setter = b.brandedValueWithBrand(b.cppDynamicCastBrand("CustomGetterSetter", .{
    .type_name = "JSC::CustomGetterSetter",
    .header = "JavaScriptCore/CustomGetterSetter.h",
}, "unknown"), .{});

const getter_setter = b.brandedValueWithBrand(b.cppDynamicCastBrand("GetterSetter", .{
    .type_name = "JSC::GetterSetter",
    .header = "JavaScriptCore/GetterSetter.h",
}, "unknown"), .{});

const accessor_presence = b.dictionary("AccessorPresence", .{
    b.dictionaryField("getter", b.boolean, .{ .required = true }),
    b.dictionaryField("setter", b.boolean, .{ .required = true }),
});

const builtin_name = b.enumeration("BuiltinName", .{
    b.enumerationValue("method", "method"),
    b.enumerationValue("headers", "headers"),
    b.enumerationValue("status", "status"),
    b.enumerationValue("statusText", "statusText"),
    b.enumerationValue("url", "url"),
    b.enumerationValue("body", "body"),
    b.enumerationValue("data", "data"),
    b.enumerationValue("toString", "toString"),
    b.enumerationValue("redirect", "redirect"),
    b.enumerationValue("inspectCustom", "inspectCustom"),
    b.enumerationValue("highWaterMark", "highWaterMark"),
    b.enumerationValue("path", "path"),
    b.enumerationValue("stream", "stream"),
    b.enumerationValue("asyncIterator", "asyncIterator"),
    b.enumerationValue("name", "name"),
    b.enumerationValue("message", "message"),
    b.enumerationValue("error", "error"),
    b.enumerationValue("defaultKeyword", "default"),
    b.enumerationValue("encoding", "encoding"),
    b.enumerationValue("fatal", "fatal"),
    b.enumerationValue("ignoreBOM", "ignoreBOM"),
    b.enumerationValue("type", "type"),
    b.enumerationValue("signal", "signal"),
    b.enumerationValue("cmd", "cmd"),
});

const engine_shims = .{
    b.engineShim(
        "inspectCustomGetterSetter",
        .{b.argument("value", b.brandCast(custom_getter_setter, .{ .failure = .assert, .input = .engine_value }), .{})},
        accessor_presence,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "inspectGetterSetter",
        .{b.argument("value", b.brandCast(getter_setter, .{ .failure = .assert, .input = .engine_value }), .{})},
        accessor_presence,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "jsValueFastGet",
        .{
            b.argument("value", b.brandCast(b.js_object, .{ .failure = .assert, .input = .engine_value }), .{}),
            b.argument("builtinId", builtin_name, .{}),
        },
        b.optional(b.engine_value),
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsValueHasOwnProperty",
        .{
            b.argument("object", b.brandCast(b.js_object, .{ .failure = .assert, .input = .engine_value }), .{}),
            b.argument("key", b.engine_value, .{}),
        },
        b.boolean,
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsValueGetOwnString",
        .{
            b.argument("value", b.engine_value, .{}),
            b.argument("key", b.dom_string, .{}),
        },
        b.optional(b.engine_value),
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsValueGetIfPropertyExistsFromPath",
        .{
            b.argument("value", b.engine_value, .{}),
            b.argument("path", b.unionType("EnginePropertyPath", .{
                b.unionMember("string", b.brandCast(archetypes.string_value, .{ .failure = .assert, .input = .engine_value })),
                b.unionMember("array", b.brandCast(b.js_array, .{ .failure = .assert, .input = .engine_value })),
            }, .{ .ordered = true }), .{}),
        },
        b.optional(b.engine_value),
        .current_realm_throwing,
    ),
    b.engineShim(
        "getIfPropertyExists",
        .{
            b.argument("target", b.brandCast(b.js_object, .{ .failure = .assert, .input = .engine_value }), .{}),
            b.argument("property", b.dom_string, .{}),
        },
        b.optional(b.engine_value),
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsValueGetIndexedLength",
        .{b.argument("value", b.engine_value, .{})},
        b.uint64,
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsValueGetIndex",
        .{
            b.argument("value", b.engine_value, .{}),
            b.argument("index", b.uint64, .{}),
        },
        b.engine_value,
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsValueKeys",
        .{b.argument("value", b.engine_value, .{})},
        b.js_array,
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsObjectGetOwnIndex",
        .{
            b.argument("object", b.brandCast(b.js_object, .{ .failure = .assert, .input = .engine_value }), .{}),
            b.argument("index", b.uint64, .{}),
        },
        b.optional(b.engine_value),
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsValueValues",
        .{b.argument("value", b.engine_value, .{})},
        b.js_array,
        .current_realm_throwing,
    ),
};

pub const schema = b.moduleWithDeclarations("property_accessors", .{}, .{}, engine_shims, .{});
