const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const heap_dump_value = b.unionType("BunJSCHeapDumpValue", .{
    b.unionMember("string", b.dom_string),
    b.unionMemberWithOptions("truthy", b.boolean, .{ .boolean_conversion = .truthy }),
}, .{
    .ordered = true,
    .fallback_member = "truthy",
    .cpp_name = "BunJSCHeapDumpValue",
});

const heap_dump_options = b.dictionaryWithOptions("BunJSCHeapDumpOptions", .{
    b.dictionaryField("dump", heap_dump_value, .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
}, .{
    .cpp_name = "BunJSCHeapDumpOptions",
    .node_allow_array = true,
    .node_allow_callable = true,
});

const heap_dump_argument = b.unionType("BunJSCHeapDumpArgument", .{
    b.unionMember("options", heap_dump_options),
    b.unionMember("ignored", b.discarded),
}, .{
    .ordered = true,
    .fallback_member = "ignored",
    .cpp_name = "BunJSCHeapDumpArgument",
});

const sampling_directory = b.unionType("BunJSCSamplingDirectory", .{
    b.unionMember("path", b.dom_string),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored", .cpp_name = "BunJSCSamplingDirectory" });

const sampling_interval = b.optionalMatch(b.uint32);

const profile_callback = b.callback(
    "BunJSCProfileCallback",
    .{b.rest("arguments", b.invocation_any)},
    b.engine_value,
    .{ .receiver = null, .profile = .exact },
);

const profile_interval = b.optionalMatch(b.uint32);

const serialize_options_fields = b.dictionaryWithOptions("BunJSCSerializeOptions", .{
    b.dictionaryField("binary_type", archetypes.optional_dom_string, .{
        .required = true,
        .missing_required = .convert_undefined,
        .js_name = "binaryType",
    }),
}, .{
    .cpp_name = "BunJSCSerializeOptions",
    .node_allow_array = true,
    .node_allow_callable = true,
});

const serialize_options = b.unionType("BunJSCSerializeOptionsInput", .{
    b.unionMember("options", serialize_options_fields),
    b.unionMember("ignored", b.discarded),
}, .{
    .ordered = true,
    .fallback_member = "ignored",
    .cpp_name = "BunJSCSerializeOptionsInput",
});

const heap_object_type_counts = b.record(b.dom_string, b.uint32);
const heap_zone_sizes = b.record(b.dom_string, b.size);
const heap_stats = b.dictionaryWithOptions("BunJSCHeapStats", .{
    b.dictionaryField("object_type_counts", heap_object_type_counts, .{ .required = true, .js_name = "objectTypeCounts" }),
    b.dictionaryField("protected_object_type_counts", heap_object_type_counts, .{ .required = true, .js_name = "protectedObjectTypeCounts" }),
    b.dictionaryField("heap_size", b.size, .{ .required = true, .js_name = "heapSize" }),
    b.dictionaryField("heap_capacity", b.size, .{ .required = true, .js_name = "heapCapacity" }),
    b.dictionaryField("extra_memory_size", b.size, .{ .required = true, .js_name = "extraMemorySize" }),
    b.dictionaryField("object_count", b.size, .{ .required = true, .js_name = "objectCount" }),
    b.dictionaryField("protected_object_count", b.size, .{ .required = true, .js_name = "protectedObjectCount" }),
    b.dictionaryField("global_object_count", b.size, .{ .required = true, .js_name = "globalObjectCount" }),
    b.dictionaryField("protected_global_object_count", b.size, .{ .required = true, .js_name = "protectedGlobalObjectCount" }),
    b.dictionaryField("zones", heap_zone_sizes, .{}),
    b.dictionaryField("mimalloc", b.js_object, .{}),
    b.dictionaryField("mimalloc_dump", b.js_object, .{ .js_name = "mimallocDump" }),
}, .{ .cpp_name = "BunJSCHeapStatsDictionary" });

const memory_usage = b.dictionaryWithOptions("BunJSCMemoryUsage", .{
    archetypes.requiredDictionaryField("current", b.size),
    archetypes.requiredDictionaryField("peak", b.size),
    b.dictionaryField("current_commit", b.size, .{ .required = true, .js_name = "currentCommit" }),
    b.dictionaryField("peak_commit", b.size, .{ .required = true, .js_name = "peakCommit" }),
    b.dictionaryField("page_faults", b.size, .{ .required = true, .js_name = "pageFaults" }),
}, .{ .cpp_name = "BunJSCMemoryUsageDictionary" });

const profile_result = b.unionType("BunJSCProfileResult", .{
    b.unionMember("profile", b.js_object),
    b.unionMember("promise", b.js_promise),
}, .{ .ordered = true, .cpp_name = "BunJSCProfile" });

const serialize_result = b.unionType("BunJSCSerializeResult", .{
    b.unionMember("shared_array_buffer", b.js_shared_array_buffer),
    b.unionMember("node_buffer", archetypes.node_buffer_value),
}, .{ .ordered = true, .cpp_name = "BunJSCSerialize" });

const code_coverage_result = b.unionType("BunJSCCodeCoverageResult", .{
    b.unionMember("empty", b.js_array),
    b.unionMember("mapping", b.dom_string),
    b.unionMember("missing", b.null_literal),
}, .{ .ordered = true, .cpp_name = "BunJSCCodeCoverage" });

fn cppFunction(comptime name: []const u8, comptime arguments: anytype, comptime result: b.Type, comptime length: u16) b.Function {
    return b.function(name, arguments, result, .{
        .backend = .cpp,
        .length = length,
        .profile = .exact,
    });
}

const functions = .{
    b.function("callerSourceOrigin", .{}, archetypes.nullable_dom_string, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
        .caller_source_location = true,
    }),
    cppFunction("jscDescribe", .{b.argument("value", b.engine_value, .{ .presence = .optional, .missing = .undefined })}, archetypes.optional_dom_string, 0),
    cppFunction("jscDescribeArray", .{b.argument("value", b.engine_value, .{ .presence = .optional, .missing = .undefined })}, archetypes.optional_dom_string, 0),
    cppFunction("drainMicrotasks", .{}, b.none, 0),
    cppFunction("edenGC", .{}, b.size, 0),
    cppFunction("fullGC", .{}, b.size, 0),
    cppFunction("gcAndSweep", .{}, b.size, 0),
    cppFunction("getRandomSeed", .{}, b.double, 0),
    cppFunction("heapSize", .{}, b.size, 0),
    cppFunction("heapStats", .{b.argument("dump", heap_dump_argument, .{ .presence = .optional, .missing = .undefined })}, heap_stats, 0),
    cppFunction(
        "startSamplingProfiler",
        .{
            b.argument("directory", sampling_directory, .{ .presence = .optional, .missing = .undefined }),
            b.argument("sampleInterval", sampling_interval, .{
                .presence = .optional,
                .missing = .undefined,
                .integer_conversion = .webidl,
            }),
        },
        b.none,
        0,
    ),
    cppFunction("samplingProfilerStackTraces", .{}, b.js_object, 0),
    cppFunction("noInline", .{b.argument("function", b.optionalMatch(archetypes.callable_value), .{})}, b.none, 0),
    cppFunction("isRope", .{b.argument("value", b.optionalMatch(archetypes.string_value), .{})}, b.boolean, 0),
    cppFunction("memoryUsage", .{}, memory_usage, 0),
    cppFunction("noFTL", .{b.argument("function", b.optionalMatch(archetypes.callable_value), .{})}, b.none, 0),
    cppFunction("noOSRExitFuzzing", .{b.argument("function", b.optionalMatch(archetypes.callable_value), .{})}, b.none, 0),
    cppFunction("numberOfDFGCompiles", .{b.argument("function", b.optionalMatch(archetypes.callable_value), .{})}, b.optionalUndefined(b.double), 0),
    cppFunction("optimizeNextInvocation", .{b.argument("function", b.optionalMatch(archetypes.callable_value), .{})}, b.none, 0),
    cppFunction("releaseWeakRefs", .{}, b.none, 0),
    cppFunction("reoptimizationRetryCount", .{b.argument("function", b.optionalMatch(archetypes.callable_value), .{})}, b.optionalUndefined(b.double), 0),
    cppFunction("setRandomSeed", .{b.argument("seed", b.uint32, .{ .integer_conversion = .coerce })}, b.none, 0),
    cppFunction(
        "startRemoteDebugger",
        .{
            b.argument("host", b.dom_string, .{ .presence = .optional, .missing = .undefined }),
            b.argument("port", b.int32, .{
                .presence = .optional,
                .missing = .undefined,
                .integer_conversion = .{ .enforce_range = .{ .min = 1, .max = 65535 } },
            }),
        },
        b.none,
        0,
    ),
    cppFunction("totalCompileTime", .{}, b.double, 0),
    cppFunction("getProtectedObjects", .{}, b.js_array, 0),
    cppFunction("generateHeapSnapshotForDebugging", .{}, b.js_object, 0),
    cppFunction(
        "profile",
        .{
            b.argument("callback", profile_callback, .{}),
            b.argument("sampleInterval", profile_interval, .{
                .presence = .optional,
                .missing = .undefined,
                .integer_conversion = .webidl,
            }),
            b.rest("arguments", b.invocation_any),
        },
        profile_result,
        0,
    ),
    b.function("profileResolve", .{}, b.js_promise, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
    }),
    b.function("profileReject", .{b.argument("error", b.engine_value, .{ .presence = .optional, .missing = .omitted })}, b.none, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
    }),
    cppFunction(
        "codeCoverageForFile",
        .{
            b.argument("filename", archetypes.coerced_dom_string, .{}),
            b.argument("ignoreSourceMap", b.boolean, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .boolean = false },
                .boolean_conversion = .truthy,
            }),
        },
        code_coverage_result,
        0,
    ),
    cppFunction("setTimeZone", .{b.argument("timeZone", b.dom_string, .{})}, b.dom_string, 0),
    cppFunction(
        "serialize",
        .{
            b.argument("value", b.engine_value, .{ .presence = .optional, .missing = .omitted }),
            b.argument("options", serialize_options, .{ .presence = .optional, .missing = .undefined }),
        },
        serialize_result,
        0,
    ),
    cppFunction("deserialize", .{b.argument("input", b.bufferWithOptions(.copy, .{ .allow_detached = false }), .{})}, b.engine_value, 0),
    cppFunction("estimateShallowMemoryUsageOf", .{b.argument("value", b.optionalMatch(b.js_cell), .{})}, b.size, 1),
    cppFunction("percentAvailableMemoryInUse", .{}, b.optionalNullish(b.double), 0),
};

pub const schema = b.module("BunJSCModule", functions);
