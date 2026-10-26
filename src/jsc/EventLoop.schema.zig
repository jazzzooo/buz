const b = @import("bindgen_schema");
const engine_types = @import("binding_schema_engine_types");

const cpp_task_handle = b.nominalHandle("CppTask", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::EventLoopTask" } },
    .cpp_declarations = &.{.{ .class = "WebCore::EventLoopTask" }},
    .access_thread = .any,
});

const owned_cpp_task_handle = b.nominalHandle("OwnedCppTask", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::EventLoopTask" } },
    .cpp_declarations = &.{.{ .class = "WebCore::EventLoopTask" }},
    .zig_type = "jsc.CppTask",
    .ownership = .owned,
    .cpp_release = "releaseCppTask",
    .access_thread = .any,
    .destroy_thread = .vm,
});

const jsc_deferred_work_task_handle = b.nominalHandle("JSCDeferredWorkTask", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::JSCDeferredWorkTask" } },
    .cpp_declarations = &.{.{ .class = "Bun::JSCDeferredWorkTask" }},
    .access_thread = .any,
});

const owned_jsc_deferred_work_task_handle = b.nominalHandle("OwnedJSCDeferredWorkTask", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::JSCDeferredWorkTask" } },
    .cpp_declarations = &.{.{ .class = "Bun::JSCDeferredWorkTask" }},
    .zig_type = "jsc.JSCDeferredWorkTask",
    .ownership = .owned,
    .cpp_release = "releaseJSCDeferredWorkTask",
    .access_thread = .any,
    .destroy_thread = .vm,
});

const event_loop_task_no_context_handle = b.nominalHandle("EventLoopTaskNoContext", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::EventLoopTaskNoContext" } },
    .cpp_declarations = &.{.{ .class = "Bun::EventLoopTaskNoContext" }},
    .access_thread = .any,
});

const owned_event_loop_task_no_context_handle = b.nominalHandle("OwnedEventLoopTaskNoContext", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::EventLoopTaskNoContext" } },
    .cpp_declarations = &.{.{ .class = "Bun::EventLoopTaskNoContext" }},
    .zig_type = "jsc.ConcurrentCppTask.EventLoopTaskNoContext",
    .ownership = .owned,
    .cpp_release = "releaseEventLoopTaskNoContext",
    .access_thread = .any,
    .destroy_thread = .any,
});

const native_event_target = b.nominalHandle("NativeEventLoopTarget", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::NativeEventLoopTarget" } },
    .cpp_declarations = &.{.{ .class = "Bun::NativeEventLoopTarget" }},
    .zig_type = "jsc.NativeEventTarget",
    .access_thread = .any,
});
const owned_native_event_target = b.nominalHandle("OwnedNativeEventLoopTarget", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::NativeEventLoopTarget" } },
    .cpp_declarations = &.{.{ .class = "Bun::NativeEventLoopTarget" }},
    .zig_type = "jsc.NativeEventTarget",
    .ownership = .owned,
    .cpp_release = "releaseNativeEventLoopTarget",
    .access_thread = .any,
    .destroy_thread = .any,
});
const native_event_signal = b.nominalHandle("NativeEventLoopSignal", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::NativeEventLoopSignal" } },
    .cpp_declarations = &.{.{ .structure = "Bun::NativeEventLoopSignal" }},
    .zig_type = "jsc.NativeEventSignal",
    .access_thread = .any,
});
const vm_native_event_signal = b.nominalHandle("VMNativeEventLoopSignal", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::NativeEventLoopSignal" } },
    .cpp_declarations = &.{.{ .structure = "Bun::NativeEventLoopSignal" }},
    .zig_type = "jsc.NativeEventSignal",
    .access_thread = .vm,
});
const owned_native_event_signal = b.nominalHandle("OwnedNativeEventLoopSignal", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::NativeEventLoopSignal" } },
    .cpp_declarations = &.{.{ .structure = "Bun::NativeEventLoopSignal" }},
    .zig_type = "jsc.NativeEventSignal",
    .ownership = .owned,
    .cpp_release = "releaseNativeEventLoopSignalOwner",
    .access_thread = .vm,
    .destroy_thread = .vm,
});
const native_event_sender = b.nominalHandle("NativeEventLoopSender", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::NativeEventLoopSignal" } },
    .cpp_declarations = &.{.{ .structure = "Bun::NativeEventLoopSignal" }},
    .zig_type = "jsc.NativeEventSignal",
    .ownership = .owned,
    .cpp_release = "releaseNativeEventLoopSignal",
    .access_thread = .any,
    .destroy_thread = .any,
});

fn nativeExport(
    comptime name: []const u8,
    comptime arguments: anytype,
) b.NativeExport {
    return b.nativeExportWithOptions(name, arguments, b.none, .current_realm_nonthrowing);
}

const engine_shims = .{
    b.engineShim("retainNativeEventTarget", .{b.argument("target", native_event_target, .{})}, owned_native_event_target, .realm_independent),
    b.engineShim("stopNativeEventTarget", .{b.argument("target", native_event_target, .{})}, b.none, .vm_thread_nonthrowing),
    b.engineShim("runNativeEventTarget", .{b.argument("target", native_event_target, .{})}, b.none, .current_realm_throwing),
    b.engineShim("eventLoopTaskNoContextPerform", .{b.argument("task", event_loop_task_no_context_handle, .{})}, b.none, .realm_independent),
    b.engineShim("eventLoopTaskNoContextCreatedInBunVM", .{b.argument("task", event_loop_task_no_context_handle, .{})}, b.optional(engine_types.bun_vm), .realm_independent),
    b.engineShim("performTask", .{b.argument("task", cpp_task_handle, .{})}, b.none, .current_realm_throwing),
    b.engineShim("runJSCDeferredWork", .{b.argument("task", jsc_deferred_work_task_handle, .{})}, b.none, .current_realm_throwing),
};

const native_exports = .{
    b.nativeExportWithOptions("createNativeEventSignal", .{b.argument("target", native_event_target, .{})}, b.optional(owned_native_event_signal), .current_realm_throwing),
    b.nativeExport("notifyNativeEventSignal", .{b.argument("signal", native_event_signal, .{})}, b.boolean),
    b.nativeExport("retainNativeEventSignal", .{b.argument("signal", native_event_signal, .{})}, native_event_sender),
    b.nativeExport("closeNativeEventSignal", .{b.argument("signal", vm_native_event_signal, .{})}, b.none),
    b.nativeExport("releaseNativeEventSignal", .{b.argument("signal", native_event_signal, .{})}, b.none),
    nativeExport("enter", .{}),
    nativeExport("exit", .{}),
    b.nativeExportWithOptions("concurrentCppTaskCreateAndRun", .{b.argument("task", owned_event_loop_task_no_context_handle, .{ .ownership = .transfer })}, b.none, .allocating),
    b.nativeExportWithOptions("tickEventLoop", .{}, b.none, .current_realm_throwing),
    b.nativeExport(
        "eventLoopRefConcurrently",
        .{b.argument("vm", engine_types.bun_vm, .{})},
        b.none,
    ),
    b.nativeExport(
        "eventLoopUnrefConcurrently",
        .{b.argument("vm", engine_types.bun_vm, .{})},
        b.none,
    ),
    b.nativeExport(
        "queueJSCDeferredWorkTaskConcurrently",
        .{
            b.argument("vm", engine_types.bun_vm, .{}),
            b.argument("task", owned_jsc_deferred_work_task_handle, .{ .ownership = .transfer }),
        },
        b.none,
    ),
    b.nativeExport(
        "queueTask",
        .{
            b.argument("global", engine_types.global_object, .{}),
            b.argument("task", owned_cpp_task_handle, .{ .ownership = .transfer }),
        },
        b.none,
    ),
    b.nativeExport(
        "queueTaskConcurrently",
        .{
            b.argument("global", engine_types.global_object, .{}),
            b.argument("task", owned_cpp_task_handle, .{ .ownership = .transfer }),
        },
        b.none,
    ),
};

pub const schema = b.moduleWithDeclarations("EventLoop", .{}, .{}, engine_shims, native_exports);
