const b = @import("bindgen_schema");
const engine_types = @import("binding_schema_engine_types");

const cpu_profiler_result = b.dictionary("CPUProfilerResult", .{
    b.dictionaryField("json", b.dom_string, .{}),
    b.dictionaryField("text", b.dom_string, .{}),
});

const functions = .{
    b.function("startCPUProfiler", .{}, b.none, .{ .backend = .cpp, .profile = .exact }),
    b.function("stopCPUProfiler", .{}, b.dom_string, .{ .backend = .cpp, .profile = .exact }),
    b.function(
        "setCPUSamplingInterval",
        .{b.argument("interval", b.int32, .{
            .integer_conversion = .{ .node_validate = .{ .min = 1, .max = 2147483647 } },
        })},
        b.none,
        .{ .backend = .cpp, .profile = .node },
    ),
    b.function("isCPUProfilerRunning", .{}, b.boolean, .{ .backend = .cpp, .profile = .exact }),
};

const engine_shims = .{
    b.engineShim(
        "setCPUProfilerSamplingInterval",
        .{b.argument("intervalMicroseconds", b.int32, .{})},
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "startCPUProfiler",
        .{b.argument("vm", engine_types.jsc_vm, .{})},
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "stopCPUProfiler",
        .{
            b.argument("vm", engine_types.jsc_vm, .{}),
            b.argument("includeJSON", b.boolean, .{}),
            b.argument("includeText", b.boolean, .{}),
        },
        cpu_profiler_result,
        .vm_thread_nonthrowing,
    ),
};

pub const schema = b.moduleWithDeclarations("InspectorProfiler", functions, .{}, engine_shims, .{});
