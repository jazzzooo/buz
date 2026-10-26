const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const fields = .{
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("duration", b.double, .{ .required = true }),
    b.dictionaryField("description", b.dom_string, .{ .required = true }),
};

const json = b.dictionaryWithOptions("PerformanceServerTimingJSON", fields, .{
    .cpp_name = "PerformanceServerTimingJSONDictionary",
});

const receiver = b.dictionaryWithOptions("PerformanceServerTimingReceiver", .{
    b.dictionaryField("name", b.dom_string, .{ .required = true, .private_symbol = "serverTimingName" }),
    b.dictionaryField("duration", b.double, .{ .required = true, .private_symbol = "serverTimingDuration" }),
    b.dictionaryField("description", b.dom_string, .{ .required = true, .private_symbol = "serverTimingDescription" }),
}, .{ .cpp_name = "PerformanceServerTimingReceiver" });

pub const schema = b.moduleWithClasses("PerformanceServerTiming", .{}, .{
    b.plainClass(
        "PerformanceServerTiming",
        b.illegalConstructor(),
        .{
            b.getter("name", b.dom_string, .{ .configurable = true, .this_value_type = receiver }),
            b.getter("duration", b.double, .{ .configurable = true, .this_value_type = receiver }),
            b.getter("description", b.dom_string, .{ .configurable = true, .this_value_type = receiver }),
            b.method("toJSON", .{}, json, .{ .length = 0, .configurable = true, .this_value_type = receiver }),
        },
        .{
            b.instanceProperty("name", .{ .value = b.dom_string, .private_symbol = "serverTimingName" }),
            b.instanceProperty("duration", .{ .value = b.double, .private_symbol = "serverTimingDuration" }),
            b.instanceProperty("description", .{ .value = b.dom_string, .private_symbol = "serverTimingDescription" }),
        },
        .{
            .illegal_constructor_errors = archetypes.illegalConstructorNewSuggestion("PerformanceServerTiming", "ERR_ILLEGAL_CONSTRUCTOR"),
            .backend = .cpp,
            .profile = .exact,
            .representation = .plain,
            .plain_reason = "Each server-timing read creates immutable metric snapshots with no native identity or lifetime",
        },
    ),
});

pub const performance_server_timing = schema.class("PerformanceServerTiming");
pub const snapshot = b.dictionaryWithOptions("PerformanceServerTimingSnapshot", fields, .{
    .cpp_name = "PerformanceServerTimingSnapshot",
    .result_class = performance_server_timing,
});
