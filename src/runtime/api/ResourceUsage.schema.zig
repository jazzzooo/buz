const b = @import("bindgen_schema");

const resource_usage_context_switches = b.dictionary("ResourceUsageContextSwitches", .{
    b.dictionaryField("voluntary", b.double, .{ .required = true }),
    b.dictionaryField("involuntary", b.double, .{ .required = true }),
});

const resource_usage_ops = b.dictionary("ResourceUsageOps", .{
    b.dictionaryField("input", b.double, .{ .required = true, .js_name = "in" }),
    b.dictionaryField("output", b.double, .{ .required = true, .js_name = "out" }),
});

const resource_usage_messages = b.dictionary("ResourceUsageMessages", .{
    b.dictionaryField("sent", b.double, .{ .required = true }),
    b.dictionaryField("received", b.double, .{ .required = true }),
});

const bigint_i64 = b.integerRepresentation(b.int64, .bigint);

const resource_usage_cpu_time = b.dictionary("ResourceUsageCPUTime", .{
    b.dictionaryField("user", bigint_i64, .{ .required = true }),
    b.dictionaryField("system", bigint_i64, .{ .required = true }),
    b.dictionaryField("total", bigint_i64, .{ .required = true }),
});

const resource_usage_class = b.class(
    "ResourceUsage",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.getter("contextSwitches", resource_usage_context_switches, .{ .implementation = "getContextSwitches", .cache = "contextSwitches" }),
        b.getter("cpuTime", resource_usage_cpu_time, .{ .implementation = "getCPUTime", .cache = "cpuTime" }),
        b.getter("maxRSS", b.double, .{ .implementation = "getMaxRSS" }),
        b.getter("messages", resource_usage_messages, .{ .implementation = "getMessages" }),
        b.getter("ops", resource_usage_ops, .{ .implementation = "getOps", .cache = "ops" }),
        b.getter("shmSize", b.double, .{ .implementation = "getSharedMemorySize" }),
        b.getter("signalCount", b.double, .{ .implementation = "getSignalCount" }),
        b.getter("swapCount", b.double, .{ .implementation = "getSwapCount" }),
    },
    .{
        b.cachedSlot("contextSwitches", resource_usage_context_switches, .{}),
        b.cachedSlot("cpuTime", resource_usage_cpu_time, .{}),
        b.cachedSlot("ops", resource_usage_ops, .{}),
    },
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
    },
);

pub const schema = b.moduleWithClasses("ResourceUsage", .{}, .{resource_usage_class});
pub const resource_usage = schema.class("ResourceUsage");
