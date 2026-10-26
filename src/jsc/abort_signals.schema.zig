const b = @import("bindgen_schema");
const engine_types = @import("binding_schema_engine_types");
const dom_exception = @import("binding_schema_WebCoreDOMException");

const common_abort_reason = b.enumerationWithOptions("CommonAbortReason", .{
    b.enumerationValue("Timeout", "timeout"),
    b.enumerationValue("UserAbort", "user-abort"),
    b.enumerationValue("ConnectionClosed", "connection-closed"),
}, .{ .cpp_name = "CommonAbortReason" });

const abort_signal_listener = b.nominalHandle("AbortSignalListener", .{
    .cpp_type = .{ .pointer = &.{ .named = "BunBindgenAbortSignalListener" } },
    .cpp_declarations = &.{.{ .structure = "BunBindgenAbortSignalListener" }},
    .ownership = .borrowed,
    .access_thread = .vm,
});

const abort_signal = b.nominalHandle("AbortSignal", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::AbortSignal" } },
    .cpp_declarations = &.{.{ .class = "WebCore::AbortSignal" }},
    .zig_type = "jsc.WebCore.AbortSignal",
    .access_thread = .vm,
});

const abort_signal_timeout = b.nominalHandle("AbortSignalTimeout", .{
    .cpp_type = .{ .named = "WebCore::AbortSignalTimeout" },
    .cpp_declarations = &.{.{ .alias = .{ .name = "WebCore::AbortSignalTimeout", .type = .{ .pointer = &.void } } }},
    .access_thread = .vm,
});

const engine_shims = .{
    b.engineShim("abortSignalToClassRef", .{b.argument("signal", abort_signal, .{})}, b.classRefByName("WebCoreEvents", "AbortSignal"), .current_realm_throwing),
    b.engineShim("commonAbortReasonToJS", .{b.argument("value", common_abort_reason, .{})}, b.classValue(dom_exception.dom_exception), .current_realm_throwing),
    b.engineShim("abortSignalIsAborted", .{b.argument("signal", abort_signal, .{})}, b.boolean, .vm_thread_nonthrowing),
    b.engineShim(
        "abortSignalAddListener",
        .{
            b.argument("signal", abort_signal, .{}),
            b.argument("listener", abort_signal_listener, .{}),
        },
        abort_signal,
        .current_realm_throwing,
    ),
    b.engineShim("abortSignalReason", .{b.argument("signal", abort_signal, .{})}, b.engine_value, .current_realm_throwing),
    b.engineShim("abortSignalNodeAbortError", .{b.argument("signal", abort_signal, .{})}, b.optional(b.js_error_instance), .current_realm_throwing),
    b.engineShim("abortSignalTimeout", .{b.argument("signal", abort_signal, .{})}, b.optional(abort_signal_timeout), .vm_thread_nonthrowing),
    b.engineShim("abortSignalCancelTimeout", .{b.argument("signal", abort_signal, .{})}, b.none, .vm_thread_nonthrowing),
    b.engineShim("abortSignalRef", .{b.argument("signal", abort_signal, .{})}, abort_signal, .vm_thread_nonthrowing),
    b.engineShim("abortSignalUnref", .{b.argument("signal", abort_signal, .{})}, b.none, .vm_thread_nonthrowing),
    b.engineShim("abortSignalIncrementPendingActivity", .{b.argument("signal", abort_signal, .{})}, b.none, .vm_thread_nonthrowing),
    b.engineShim("abortSignalDecrementPendingActivity", .{b.argument("signal", abort_signal, .{})}, b.none, .vm_thread_nonthrowing),
    b.engineShim("abortSignalNew", .{}, abort_signal, .current_realm_nonthrowing),
    b.engineShim(
        "abortSignalRemoveListener",
        .{
            b.argument("signal", abort_signal, .{}),
            b.argument("listener", abort_signal_listener, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "abortSignalSignal",
        .{
            b.argument("signal", abort_signal, .{}),
            b.argument("reason", b.uint8, .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
};

const native_exports = .{
    b.nativeExport("abortSignalTimeoutCreate", .{
        b.argument("vm", engine_types.bun_vm, .{}),
        b.argument("signal", abort_signal, .{}),
        b.argument("milliseconds", b.uint64, .{}),
    }, abort_signal_timeout),
    b.nativeExport("abortSignalTimeoutDestroy", .{b.argument("timeout", abort_signal_timeout, .{})}, b.none),
    b.nativeExportWithOptions("abortSignalRunListener", .{
        b.argument("listener", abort_signal_listener, .{}),
        b.argument("reason", b.engine_value, .{}),
    }, b.none, .current_realm_nonthrowing),
};

pub const schema = b.moduleWithDeclarations("abort_signals", .{}, .{}, engine_shims, native_exports);
