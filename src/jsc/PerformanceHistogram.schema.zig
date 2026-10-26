const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

fn positiveInt64OrBigInt(comptime name: []const u8, comptime options: b.ArgumentOptions) b.Argument {
    return b.argument(name, archetypes.node_positive_int64, options);
}

const histogram_match = b.brandedValueWithBrand(b.cppDynamicCastBrand("PerformanceHistogramValue", .{
    .type_name = "Bun::JSNodePerformanceHooksHistogram",
    .header = "JSNodePerformanceHooksHistogram.h",
}, "object"), .{
    .expectation = "a Histogram",
    .node_requirement = "Histogram",
});

fn histogramReceiver(comptime name: []const u8) b.Type {
    _ = name;
    return histogram_match;
}

const event_loop_histogram = histogram_match;
const histogram_addend = histogram_match;
const bigint_int64 = b.integerRepresentation(b.int64, .bigint);
const bigint_uint64 = b.integerRepresentation(b.uint64, .bigint);

fn cppMethod(
    comptime name: []const u8,
    comptime arguments: anytype,
    comptime result: b.Type,
    comptime length: u16,
) b.Function {
    return b.function(
        name,
        arguments,
        result,
        .{ .backend = .cpp, .length = length, .profile = .node, .this_value_type = histogramReceiver(name) },
    );
}

fn cppGetter(comptime name: []const u8, comptime result: b.Type) b.Function {
    return b.function(
        name,
        .{},
        result,
        .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = histogramReceiver(name) },
    );
}

const functions = .{
    b.function(
        "histogramConstructorCall",
        .{},
        b.none,
        .{ .backend = .cpp, .length = 0, .profile = .exact },
    ),
    b.function(
        "histogramConstructorConstruct",
        .{
            positiveInt64OrBigInt("lowest", .{ .presence = .optional, .missing = .undefined }),
            positiveInt64OrBigInt("highest", .{ .presence = .optional, .missing = .undefined }),
            archetypes.nodeInteger("figures", b.int32, .{ .min = 1, .max = 5 }, .{ .presence = .optional, .missing = .undefined }),
        },
        histogram_match,
        .{ .backend = .cpp, .length = 3, .profile = .node },
    ),
    b.function(
        "createHistogram",
        .{
            positiveInt64OrBigInt("lowest", .{ .presence = .optional, .missing = .undefined }),
            positiveInt64OrBigInt("highest", .{ .presence = .optional, .missing = .undefined }),
            archetypes.nodeInteger("figures", b.int32, .{ .min = 1, .max = 5 }, .{ .presence = .optional, .missing = .undefined }),
        },
        histogram_match,
        .{ .backend = .cpp, .length = 3, .profile = .node },
    ),
    b.function(
        "monitorEventLoopDelay",
        .{archetypes.nodeInteger("resolution", b.int32, .{ .min = 1, .max = 2147483647 }, .{
            .presence = .optional,
            .missing = .omitted,
        })},
        histogram_match,
        .{ .backend = .cpp, .length = 1, .profile = .node },
    ),
    b.function(
        "enableEventLoopDelay",
        .{
            b.argument("histogram", event_loop_histogram, .{}),
            archetypes.nodeInteger("resolution", b.int32, .{ .min = 1, .max = 2147483647 }, .{}),
        },
        b.none,
        .{ .backend = .cpp, .length = 2, .profile = .node },
    ),
    b.function(
        "disableEventLoopDelay",
        .{b.argument("histogram", event_loop_histogram, .{})},
        b.none,
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
    cppMethod("histogramRecord", .{positiveInt64OrBigInt("value", .{})}, b.none, 1),
    cppMethod("histogramRecordDelta", .{}, b.none, 0),
    cppMethod("histogramAdd", .{b.argument("other", histogram_addend, .{})}, b.double, 1),
    cppMethod("histogramReset", .{}, b.none, 0),
    cppMethod("histogramPercentile", .{b.argument("percentile", b.double, .{})}, b.double, 1),
    cppMethod("histogramPercentileBigInt", .{b.argument("percentile", b.double, .{})}, bigint_int64, 1),
    cppGetter("count", b.double),
    cppGetter("countBigInt", bigint_uint64),
    cppGetter("min", b.double),
    cppGetter("minBigInt", bigint_int64),
    cppGetter("max", b.double),
    cppGetter("maxBigInt", bigint_int64),
    cppGetter("mean", b.double),
    cppGetter("stddev", b.double),
    cppGetter("exceeds", b.double),
    cppGetter("exceedsBigInt", bigint_uint64),
    cppGetter("percentiles", b.js_map),
    cppGetter("percentilesBigInt", b.js_map),
};

const engine_shims = .{
    b.engineShim("recordDelay", .{
        b.argument("histogram", histogram_match, .{}),
        b.argument("delay", b.int64, .{}),
    }, b.none, .current_realm_nonthrowing),
};

const native_exports = .{
    b.nativeExportWithOptions("enableEventLoopDelayMonitoring", .{
        b.argument("histogram", histogram_match, .{}),
        b.argument("resolution", b.int32, .{}),
    }, b.none, .current_realm_throwing),
    b.nativeExportWithOptions("disableEventLoopDelayMonitoring", .{}, b.none, .current_realm_nonthrowing),
};

pub const schema = b.moduleWithDeclarations("PerformanceHistogram", functions, .{}, engine_shims, native_exports);
