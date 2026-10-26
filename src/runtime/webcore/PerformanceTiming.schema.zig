const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const brand = b.cppBrand("PerformanceTiming", .{
    .symbol = "Bun::Bindgen::TypePredicates::isPerformanceTiming",
    .header = "BindgenTypePredicates.h",
}, "PerformanceTiming");
pub const value = b.brandedValueWithBrand(brand, .{});

const receiver = b.dictionary("PerformanceTimingReceiver", .{
    b.dictionaryField("brand", b.boolean, .{ .required = true, .private_symbol = "performanceTimingBrand", .profile = .exact }),
});

const json = b.dictionaryWithOptions("PerformanceTimingJSON", .{
    b.dictionaryField("navigationStart", b.uint64, .{ .required = true }),
    b.dictionaryField("unloadEventStart", b.uint64, .{ .required = true }),
    b.dictionaryField("unloadEventEnd", b.uint64, .{ .required = true }),
    b.dictionaryField("redirectStart", b.uint64, .{ .required = true }),
    b.dictionaryField("redirectEnd", b.uint64, .{ .required = true }),
    b.dictionaryField("fetchStart", b.uint64, .{ .required = true }),
    b.dictionaryField("domainLookupStart", b.uint64, .{ .required = true }),
    b.dictionaryField("domainLookupEnd", b.uint64, .{ .required = true }),
    b.dictionaryField("connectStart", b.uint64, .{ .required = true }),
    b.dictionaryField("connectEnd", b.uint64, .{ .required = true }),
    b.dictionaryField("secureConnectionStart", b.uint64, .{ .required = true }),
    b.dictionaryField("requestStart", b.uint64, .{ .required = true }),
    b.dictionaryField("responseStart", b.uint64, .{ .required = true }),
    b.dictionaryField("responseEnd", b.uint64, .{ .required = true }),
    b.dictionaryField("domLoading", b.uint64, .{ .required = true }),
    b.dictionaryField("domInteractive", b.uint64, .{ .required = true }),
    b.dictionaryField("domContentLoadedEventStart", b.uint64, .{ .required = true }),
    b.dictionaryField("domContentLoadedEventEnd", b.uint64, .{ .required = true }),
    b.dictionaryField("domComplete", b.uint64, .{ .required = true }),
    b.dictionaryField("loadEventStart", b.uint64, .{ .required = true }),
    b.dictionaryField("loadEventEnd", b.uint64, .{ .required = true }),
}, .{ .cpp_name = "PerformanceTimingJSONDictionary" });

fn getter(comptime name: []const u8) b.ClassMember {
    return b.getter(name, b.uint64, .{ .configurable = true, .this_value_type = receiver });
}

pub const schema = b.moduleWithClasses("PerformanceTiming", .{}, .{
    b.plainClass("PerformanceTiming", b.illegalConstructor(), .{
        getter("navigationStart"),
        getter("unloadEventStart"),
        getter("unloadEventEnd"),
        getter("redirectStart"),
        getter("redirectEnd"),
        getter("fetchStart"),
        getter("domainLookupStart"),
        getter("domainLookupEnd"),
        getter("connectStart"),
        getter("connectEnd"),
        getter("secureConnectionStart"),
        getter("requestStart"),
        getter("responseStart"),
        getter("responseEnd"),
        getter("domLoading"),
        getter("domInteractive"),
        getter("domContentLoadedEventStart"),
        getter("domContentLoadedEventEnd"),
        getter("domComplete"),
        getter("loadEventStart"),
        getter("loadEventEnd"),
        b.method("toJSON", .{}, json, .{ .length = 0, .configurable = true, .this_value_type = receiver }),
    }, .{
        b.instanceProperty("brand", .{ .value = b.boolean, .private_symbol = "performanceTimingBrand" }),
    }, .{
        .illegal_constructor_errors = archetypes.illegalConstructorNewSuggestion("PerformanceTiming", "ERR_ILLEGAL_CONSTRUCTOR"),
        .backend = .cpp,
        .profile = .exact,
        .representation = .plain,
        .brand = brand,
        .plain_reason = "The server runtime has no document navigation timings; this compatibility object exposes constant zero timestamps without native state",
    }),
});

pub const performance_timing = schema.class("PerformanceTiming");
pub const snapshot = b.dictionaryWithOptions("PerformanceTimingSnapshot", .{
    b.dictionaryField("brand", b.boolean, .{ .required = true }),
}, .{ .cpp_name = "PerformanceTimingSnapshot", .result_class = performance_timing });
