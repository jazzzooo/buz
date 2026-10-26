const b = @import("bindgen_schema");

const iterator = b.nominalHandle("JSPropertyIterator", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::JSPropertyIterator" } },
    .cpp_declarations = &.{.{ .class = "Bun::JSPropertyIterator" }},
    .ownership = .owned,
    .cpp_release = "propertyIteratorRelease",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const creation = b.dictionary("PropertyIteratorCreation", .{
    b.dictionaryField("iterator", b.optional(iterator), .{ .required = true }),
    b.dictionaryField("count", b.size, .{ .required = true }),
});

const entry = b.dictionary("PropertyIteratorEntry", .{
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("value", b.engine_value, .{ .required = true }),
});

const console_iterator = b.nominalHandle("ConsolePropertyIterator", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::ConsolePropertyIterator" } },
    .cpp_declarations = &.{.{ .class = "Bun::ConsolePropertyIterator" }},
    .access_thread = .any,
});

const console_iteration_mode = b.enumeration("ConsolePropertyIterationMode", .{
    b.enumerationValue("all", "all"),
    b.enumerationValue("nonIndexed", "nonIndexed"),
    b.enumerationValue("ordered", "ordered"),
});

const console_creation = b.dictionary("ConsolePropertyIteratorCreation", .{
    b.dictionaryField("iterator", b.optional(console_iterator), .{ .required = true }),
    b.dictionaryField("count", b.size, .{ .required = true }),
});

const console_entry = b.dictionary("ConsolePropertyIteratorEntry", .{
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("value", b.engine_value, .{ .required = true }),
    b.dictionaryField("isSymbol", b.boolean, .{ .required = true }),
    b.dictionaryField("isPrivateSymbol", b.boolean, .{ .required = true }),
});

const engine_shims = .{
    b.engineShim(
        "propertyIteratorCreate",
        .{
            b.argument("value", b.brandCast(b.js_object, .{ .failure = .assert, .input = .engine_value }), .{}),
            b.argument("ownPropertiesOnly", b.boolean, .{}),
            b.argument("onlyNonIndexProperties", b.boolean, .{}),
        },
        creation,
        .current_realm_throwing,
    ),
    b.engineShim("propertyIteratorGetLongestPropertyName", .{b.argument("iterator", iterator, .{})}, b.size, .current_realm_unchecked),
    b.engineShim(
        "propertyIteratorGetNameAndValue",
        .{
            b.argument("iterator", iterator, .{}),
            b.argument("object", b.brandCast(b.js_object, .{ .failure = .assert, .input = .engine_value }), .{}),
            b.argument("index", b.size, .{}),
        },
        b.optional(entry),
        .current_realm_throwing,
    ),
    b.engineShim(
        "propertyIteratorGetNameAndValueNonObservable",
        .{
            b.argument("iterator", iterator, .{}),
            b.argument("object", b.brandCast(b.js_object, .{ .failure = .assert, .input = .engine_value }), .{}),
            b.argument("index", b.size, .{}),
        },
        b.optional(entry),
        .current_realm_throwing,
    ),
    b.engineShim(
        "consolePropertyIteratorCreate",
        .{
            b.argument("value", b.engine_value, .{}),
            b.argument("mode", console_iteration_mode, .{}),
        },
        console_creation,
        .current_realm_throwing,
    ),
    b.engineShim(
        "consolePropertyIteratorGetEntry",
        .{
            b.argument("iterator", console_iterator, .{}),
            b.argument("value", b.engine_value, .{}),
            b.argument("index", b.size, .{}),
        },
        b.optional(console_entry),
        .current_realm_throwing,
    ),
    b.engineShim(
        "consolePropertyIteratorDestroy",
        .{b.argument("iterator", console_iterator, .{})},
        b.none,
        .realm_independent,
    ),
};

pub const schema = b.moduleWithDeclarations("property_iterators", .{}, .{}, engine_shims, .{});
