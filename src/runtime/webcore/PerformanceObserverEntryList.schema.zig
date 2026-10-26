const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const brand = b.cppBrand("PerformanceObserverEntryList", .{
    .symbol = "Bun::Bindgen::TypePredicates::isPerformanceObserverEntryList",
    .header = "BindgenTypePredicates.h",
}, "PerformanceObserverEntryList");
pub const value = b.brandedValueWithBrand(brand, .{});

const entries = b.sequence(b.classRefByName("WebCorePerformance", "PerformanceEntry"));
const receiver = b.dictionary("PerformanceObserverEntryListReceiver", .{
    b.dictionaryField("entries", entries, .{
        .required = true,
        .private_symbol = "performanceObserverEntries",
        .profile = .exact,
    }),
});

pub const schema = b.moduleWithClasses("PerformanceObserverEntryList", .{}, .{
    b.plainClass(
        "PerformanceObserverEntryList",
        b.illegalConstructor(),
        .{
            b.method("getEntries", .{}, entries, .{ .length = 0, .configurable = true, .this_value_type = receiver }),
            b.method("getEntriesByType", .{
                b.argument("type", b.dom_string, .{}),
            }, entries, .{ .length = 1, .configurable = true, .this_value_type = receiver }),
            b.method("getEntriesByName", .{
                b.argument("name", b.dom_string, .{}),
                b.argument("type", b.dom_string, .{ .presence = .optional, .missing = .undefined }),
            }, entries, .{ .length = 1, .configurable = true, .this_value_type = receiver }),
        },
        .{b.instanceProperty("entries", .{ .value = b.js_array, .private_symbol = "performanceObserverEntries" })},
        .{
            .illegal_constructor_errors = archetypes.illegalConstructorNewSuggestion("PerformanceObserverEntryList", "ERR_ILLEGAL_CONSTRUCTOR"),
            .backend = .cpp,
            .profile = .webidl,
            .representation = .plain,
            .brand = brand,
            .plain_reason = "Each observer delivery owns a JavaScript array of entry references; filtering creates result arrays without native list identity",
        },
    ),
});

pub const performance_observer_entry_list = schema.class("PerformanceObserverEntryList");
pub const snapshot = b.dictionaryWithOptions("PerformanceObserverEntryListSnapshot", .{
    b.dictionaryField("entries", b.js_array, .{ .required = true }),
}, .{ .cpp_name = "PerformanceObserverEntryListSnapshot", .result_class = performance_observer_entry_list });
