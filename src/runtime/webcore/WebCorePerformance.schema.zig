const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const webcore_bindings = @import("binding_schema_WebCoreBindings");
const events = @import("binding_schema_WebCoreEvents");
const server_timing = @import("binding_schema_PerformanceServerTiming");
const observer_entry_list = @import("binding_schema_PerformanceObserverEntryList");
const timing = @import("binding_schema_PerformanceTiming");

const performance_entry_json = b.dictionaryWithOptions(
    "PerformanceEntryJSON",
    .{
        archetypes.requiredDictionaryField("name", b.dom_string),
        archetypes.requiredDictionaryField("entryType", b.dom_string),
        archetypes.requiredDictionaryField("startTime", b.double),
        archetypes.requiredDictionaryField("duration", b.double),
    },
    .{ .cpp_name = "PerformanceEntryJSONDictionary" },
);

const performance_entry_class = webcore_bindings.wrapperClass(
    "PerformanceEntry",
    b.illegalConstructor(),
    .{
        b.getter("name", b.dom_string, .{ .configurable = true }),
        b.getter("entryType", b.dom_string, .{ .configurable = true }),
        b.getter("startTime", b.double, .{ .configurable = true }),
        b.getter("duration", b.double, .{ .configurable = true }),
        b.method("toJSON", .{}, performance_entry_json, .{ .length = 0, .configurable = true }),
    },
    .{},
    "WebCore PerformanceEntry polymorphic identity, wrapper cache, and GC tracing",
    .{
        .illegal_constructor_errors = archetypes.illegalConstructorNewSuggestion("PerformanceEntry", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = webcore_bindings.wrapperParent("WebCore::PerformanceEntry"),
        .engine_native = .{
            .cpp_type = "WebCore::PerformanceEntry",
            .header = "PerformanceEntryOwner.h",
            .wrapper_discriminator = "performanceEntryType",
        },
        .identity = .per_realm,
        .final = false,
    },
);

const performance_mark_options = b.dictionaryWithOptions(
    "PerformanceMarkOptions",
    .{
        b.dictionaryField("detail", b.engine_value, .{ .default_value = .undefined }),
        b.dictionaryField("start_time", b.double, .{ .js_name = "startTime" }),
    },
    .{ .cpp_name = "PerformanceMarkOptionsDictionary" },
);

const performance_mark_class = webcore_bindings.wrapperClass(
    "PerformanceMark",
    b.constructor(.{
        b.argument("markName", b.dom_string, .{}),
        b.argument("markOptions", performance_mark_options, .{ .presence = .optional, .missing = .undefined_or_null }),
    }, .{ .length = 1 }),
    .{
        b.getter("detail", b.engine_value, .{ .configurable = true }),
    },
    .{b.cachedSlot("detail", b.engine_value, .{ .exposed = false })},
    "Performance timeline identity with structured-cloned detail that is deserialized and cached per wrapper",
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("PerformanceMark", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = b.parentClass(performance_entry_class),
        .engine_native = .{ .cpp_type = "WebCore::PerformanceMark", .header = "PerformanceEntryOwner.h", .wrapper_tag = "WebCore::PerformanceEntry::Type::Mark" },
        .identity = .per_realm,
    },
);

const performance_measure_class = webcore_bindings.wrapperClass(
    "PerformanceMeasure",
    b.illegalConstructor(),
    .{
        b.getter("detail", b.engine_value, .{ .configurable = true }),
    },
    .{b.cachedSlot("detail", b.engine_value, .{ .exposed = false })},
    "Performance timeline identity with structured-cloned detail that is deserialized and cached per wrapper",
    .{
        .illegal_constructor_errors = archetypes.illegalConstructorNewSuggestion("PerformanceMeasure", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = b.parentClass(performance_entry_class),
        .engine_native = .{ .cpp_type = "WebCore::PerformanceMeasure", .header = "PerformanceEntryOwner.h", .wrapper_tag = "WebCore::PerformanceEntry::Type::Measure" },
        .identity = .per_realm,
    },
);

const performance_mark_or_timestamp = b.unionType("PerformanceMarkOrTimestamp", .{
    b.unionMember("mark", b.dom_string),
    b.unionMember("timestamp", b.double),
}, .{ .cpp_name = "PerformanceMarkOrTimestampValue" });
const performance_measure_options = b.dictionaryWithOptions(
    "PerformanceMeasureOptions",
    .{
        b.dictionaryField("detail", b.engine_value, .{ .default_value = .undefined }),
        b.dictionaryField("start", performance_mark_or_timestamp, .{}),
        b.dictionaryField("duration", b.double, .{}),
        b.dictionaryField("end", performance_mark_or_timestamp, .{}),
    },
    .{ .cpp_name = "PerformanceMeasureOptionsDictionary" },
);
const performance_start_or_measure_options = b.unionType("PerformanceStartOrMeasureOptions", .{
    b.unionMember("mark", b.dom_string),
    b.unionMember("options", performance_measure_options),
}, .{ .cpp_name = "PerformanceStartOrMeasureOptionsValue" });

const performance_resource_timing_json = b.dictionaryWithOptions(
    "PerformanceResourceTimingJSON",
    .{
        archetypes.requiredDictionaryField("name", b.dom_string),
        archetypes.requiredDictionaryField("entryType", b.dom_string),
        archetypes.requiredDictionaryField("startTime", b.double),
        archetypes.requiredDictionaryField("duration", b.double),
        archetypes.requiredDictionaryField("initiatorType", b.dom_string),
        archetypes.requiredDictionaryField("nextHopProtocol", b.dom_string),
        archetypes.requiredDictionaryField("workerStart", b.double),
        archetypes.requiredDictionaryField("redirectStart", b.double),
        archetypes.requiredDictionaryField("redirectEnd", b.double),
        archetypes.requiredDictionaryField("fetchStart", b.double),
        archetypes.requiredDictionaryField("domainLookupStart", b.double),
        archetypes.requiredDictionaryField("domainLookupEnd", b.double),
        archetypes.requiredDictionaryField("connectStart", b.double),
        archetypes.requiredDictionaryField("connectEnd", b.double),
        archetypes.requiredDictionaryField("secureConnectionStart", b.double),
        archetypes.requiredDictionaryField("requestStart", b.double),
        archetypes.requiredDictionaryField("responseStart", b.double),
        archetypes.requiredDictionaryField("responseEnd", b.double),
        archetypes.requiredDictionaryField("transferSize", b.uint64),
        archetypes.requiredDictionaryField("encodedBodySize", b.uint64),
        archetypes.requiredDictionaryField("decodedBodySize", b.uint64),
        archetypes.requiredDictionaryField("serverTiming", b.frozenArray(server_timing.snapshot)),
    },
    .{ .cpp_name = "PerformanceResourceTimingJSONDictionary" },
);
const performance_resource_timing_json_result = performance_resource_timing_json;
const performance_server_timings_result = b.frozenArray(server_timing.snapshot);

fn resourceTimingDoubleGetter(comptime name: []const u8) b.ClassMember {
    return b.getter(name, b.double, .{ .configurable = true });
}

fn resourceTimingSizeGetter(comptime name: []const u8) b.ClassMember {
    return b.getter(name, b.uint64, .{ .configurable = true });
}

const performance_resource_timing_class = webcore_bindings.wrapperClass(
    "PerformanceResourceTiming",
    b.illegalConstructor(),
    .{
        b.getter("initiatorType", b.dom_string, .{ .configurable = true }),
        b.getter("nextHopProtocol", b.dom_string, .{ .configurable = true }),
        resourceTimingDoubleGetter("workerStart"),
        resourceTimingDoubleGetter("redirectStart"),
        resourceTimingDoubleGetter("redirectEnd"),
        resourceTimingDoubleGetter("fetchStart"),
        resourceTimingDoubleGetter("domainLookupStart"),
        resourceTimingDoubleGetter("domainLookupEnd"),
        resourceTimingDoubleGetter("connectStart"),
        resourceTimingDoubleGetter("connectEnd"),
        resourceTimingDoubleGetter("secureConnectionStart"),
        resourceTimingDoubleGetter("requestStart"),
        resourceTimingDoubleGetter("responseStart"),
        resourceTimingDoubleGetter("responseEnd"),
        resourceTimingSizeGetter("transferSize"),
        resourceTimingSizeGetter("encodedBodySize"),
        resourceTimingSizeGetter("decodedBodySize"),
        b.getter("serverTiming", performance_server_timings_result, .{ .configurable = true }),
        b.method("toJSON", .{}, performance_resource_timing_json_result, .{ .length = 0, .configurable = true }),
    },
    .{},
    "WebCore resource-timing entry identity, wrapper cache, and GC tracing",
    .{
        .illegal_constructor_errors = archetypes.illegalConstructorNewSuggestion("PerformanceResourceTiming", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = b.parentClass(performance_entry_class),
        .engine_native = .{ .cpp_type = "WebCore::PerformanceResourceTiming", .header = "PerformanceEntryOwner.h", .wrapper_tag = "WebCore::PerformanceEntry::Type::Resource" },
        .identity = .per_realm,
    },
);

const performance_timing_value = timing.value;
const performance_entry_list_value = b.sequence(b.classRefByName("WebCorePerformance", "PerformanceEntry"));
const performance_mark_value = b.classRefByName("WebCorePerformance", "PerformanceMark");
const performance_measure_value = b.classRefByName("WebCorePerformance", "PerformanceMeasure");
const performance_json_value = b.dictionaryWithOptions(
    "PerformanceJSON",
    .{
        archetypes.requiredDictionaryField("timeOrigin", b.double),
        archetypes.requiredDictionaryField("timing", performance_timing_value),
    },
    .{ .cpp_name = "PerformanceJSONDictionary" },
);
const performance_class = webcore_bindings.wrapperClass(
    "Performance",
    b.illegalConstructor(),
    .{
        b.method("now", .{}, b.double, .{ .length = 0, .configurable = true }),
        b.getter("timeOrigin", b.double, .{ .configurable = true }),
        b.getter("timing", performance_timing_value, .{ .configurable = true, .cache = "timing" }),
        webcore_bindings.eventHandlerGetter("onresourcetimingbufferfull"),
        webcore_bindings.eventHandlerSetter("onresourcetimingbufferfull"),
        b.method("toJSON", .{}, performance_json_value, .{ .length = 0, .configurable = true }),
        b.method("getEntries", .{}, performance_entry_list_value, .{ .length = 0, .configurable = true }),
        b.method("getEntriesByType", .{
            b.argument("type", b.dom_string, .{}),
        }, performance_entry_list_value, .{ .length = 1, .configurable = true }),
        b.method("getEntriesByName", .{
            b.argument("name", b.dom_string, .{}),
            b.argument("type", b.dom_string, .{ .presence = .optional, .missing = .undefined }),
        }, performance_entry_list_value, .{ .length = 1, .configurable = true }),
        b.method("clearResourceTimings", .{}, b.none, .{ .length = 0, .configurable = true }),
        b.method("setResourceTimingBufferSize", .{
            b.argument("maxSize", b.uint32, .{}),
        }, b.none, .{ .length = 1, .configurable = true }),
        b.method("mark", .{
            b.argument("markName", b.dom_string, .{}),
            b.argument("markOptions", performance_mark_options, .{ .presence = .optional, .missing = .undefined_or_null }),
        }, performance_mark_value, .{ .length = 1, .configurable = true }),
        b.method("clearMarks", .{
            b.argument("markName", b.dom_string, .{ .presence = .optional, .missing = .undefined }),
        }, b.none, .{ .length = 0, .configurable = true }),
        b.method("measure", .{
            b.argument("measureName", b.dom_string, .{}),
            b.argument("startOrMeasureOptions", performance_start_or_measure_options, .{ .presence = .optional, .missing = .undefined }),
            b.argument("endMark", b.dom_string, .{ .presence = .optional, .missing = .undefined }),
        }, performance_measure_value, .{ .length = 1, .configurable = true }),
        b.method("clearMeasures", .{
            b.argument("measureName", b.dom_string, .{ .presence = .optional, .missing = .undefined }),
        }, b.none, .{ .length = 0, .configurable = true }),
        b.method("markResourceTiming", .{}, b.none, .{ .profile = .node, .length = 7, .configurable = true }),
    },
    .{b.cachedSlot("timing", performance_timing_value, .{ .exposed = false })},
    "WebCore Performance timeline ownership, event-target identity, and GC tracing",
    .{
        .illegal_constructor_errors = archetypes.illegalConstructorNewSuggestion("Performance", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = b.parentClass(events.event_target_class),
        .engine_native = .{ .cpp_type = "WebCore::Performance", .header = "PerformanceOwner.h", .wrapper_tag = "WebCore::PerformanceEventTargetInterfaceType" },
        .identity = .per_realm,
        .memory_usage = .vm,
    },
);

const performance_observer_init = b.dictionary("PerformanceObserverInit", .{
    b.dictionaryField("buffered", b.boolean, .{ .default_value = .{ .boolean = false } }),
    b.dictionaryField("entry_types", archetypes.dom_strings, .{ .js_name = "entryTypes" }),
    b.dictionaryField("type", b.dom_string, .{}),
});
const performance_observer_callback_shape = b.callback("PerformanceObserverCallbackInput", .{
    b.argument("entries", observer_entry_list.value, .{}),
    b.argument("observer", b.classRefByName("WebCorePerformance", "PerformanceObserver"), .{}),
}, b.none, .{
    .receiver = null,
});

const performance_observer_class = webcore_bindings.wrapperClass(
    "PerformanceObserver",
    b.constructor(.{
        b.argument("callback", performance_observer_callback_shape, .{}),
    }, .{ .length = 1 }),
    .{
        b.method("observe", .{
            b.argument("options", performance_observer_init, .{ .presence = .optional, .missing = .undefined_or_null }),
        }, b.none, .{ .length = 0, .configurable = true }),
        b.method("disconnect", .{}, b.none, .{ .length = 0, .configurable = true }),
        b.method("takeRecords", .{}, performance_entry_list_value, .{ .length = 0, .configurable = true }),
        b.staticGetter("supportedEntryTypes", archetypes.dom_strings, .{ .configurable = true }),
    },
    .{},
    "WebCore PerformanceObserver callback ownership, wrapper identity, and GC tracing",
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("PerformanceObserver", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = webcore_bindings.wrapperParent("WebCore::PerformanceObserver"),
        .engine_native = .{ .cpp_type = "WebCore::PerformanceObserver", .header = "PerformanceObserverOwner.h" },
        .identity = .per_realm,
        .engine_tracing = .additional_children,
    },
);

pub const schema = b.moduleWithClasses("WebCorePerformance", .{
    b.function("createPerformanceTiming", .{}, timing.snapshot, .{ .backend = .cpp, .profile = .exact }),
    b.function("createObserverEntryList", .{
        b.argument("entries", b.js_array, .{}),
    }, observer_entry_list.snapshot, .{ .backend = .cpp, .profile = .exact }),
}, .{
    performance_entry_class,
    performance_mark_class,
    performance_measure_class,
    performance_resource_timing_class,
    performance_class,
    performance_observer_class,
});
pub const performance_entry = schema.class("PerformanceEntry");
pub const performance_mark = schema.class("PerformanceMark");
pub const performance_measure = schema.class("PerformanceMeasure");
pub const PerformanceServerTiming = server_timing.performance_server_timing;
pub const PerformanceTiming = timing.performance_timing;
pub const performance_resource_timing = schema.class("PerformanceResourceTiming");
pub const performance = schema.class("Performance");
pub const PerformanceObserverEntryList = observer_entry_list.performance_observer_entry_list;
pub const performance_observer = schema.class("PerformanceObserver");
