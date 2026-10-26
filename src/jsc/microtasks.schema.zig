const b = @import("bindgen_schema");
const engine_types = @import("binding_schema_engine_types");

const native_microtask = b.nominalHandle("NativeMicrotask", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::NativeMicrotask" } },
    .cpp_declarations = &.{.{ .structure = "Bun::NativeMicrotask" }},
    .ownership = .owned,
    .cpp_release = "releaseNativeMicrotask",
    .zig_type = "jsc.NativeMicrotask",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const engine_shims = .{
    b.engineShim(
        "queueMicrotaskJob",
        .{
            b.argument("function", b.brandCast(engine_types.callable_or_async_context_value, .{ .failure = .assert, .input = .engine_value }), .{}),
            b.argument("first", b.optional(b.engine_value), .{}),
            b.argument("second", b.optional(b.engine_value), .{}),
        },
        b.none,
        .current_realm_nonthrowing,
    ),
    b.engineShim(
        "queueMicrotaskTask",
        .{b.argument("task", native_microtask, .{ .ownership = .transfer })},
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim("handleRejectedPromises", .{}, b.none, .current_realm_throwing),
    b.engineShim("drainMicrotasks", .{}, b.none, .current_realm_throwing),
    b.engineShim(
        "vmDrainMicrotasks",
        .{b.argument("vm", engine_types.jsc_vm, .{})},
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "discardQueuedTasks",
        .{b.argument("vm", engine_types.jsc_vm, .{})},
        b.boolean,
        .vm_thread_nonthrowing,
    ),
};

const native_exports = .{
    b.nativeExportWithOptions("runQueuedMicrotask", .{b.argument("task", native_microtask, .{})}, b.none, .current_realm_throwing),
    b.nativeExport("discardQueuedMicrotask", .{b.argument("task", native_microtask, .{ .ownership = .transfer })}, b.none),
};

pub const schema = b.moduleWithDeclarations("microtasks", .{}, .{}, engine_shims, native_exports);
