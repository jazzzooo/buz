const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const web_worker_handle = b.nominalHandle("WebWorker", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::Worker" } },
    .cpp_declarations = &.{.{ .class = "WebCore::Worker" }},
    .access_thread = .any,
});

pub const web_worker_state_handle = b.nominalHandle("WebWorkerState", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::WebWorkerState" } },
    .cpp_declarations = &.{.{ .structure = "Bun::WebWorkerState" }},
    .zig_type = "jsc.WebWorker",
    .ownership = .owned,
    .cpp_release = "releaseWebWorkerState",
    .access_thread = .any,
    .destroy_thread = .vm,
});

pub const worker_heap_snapshot_task_handle = b.nominalHandle("WorkerHeapSnapshotTask", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::WorkerHeapSnapshotTask" } },
    .cpp_declarations = &.{.{ .structure = "Bun::WorkerHeapSnapshotTask" }},
    .ownership = .owned,
    .cpp_release = "releaseWorkerHeapSnapshotTask",
    .zig_type = "jsc.WebWorker.HeapSnapshotTask",
    .access_thread = .any,
    .destroy_thread = .any,
});

const web_worker_create_result = b.dictionary("WebWorkerCreateResult", .{
    b.dictionaryField("state", b.optional(web_worker_state_handle), .{ .required = true }),
    b.dictionaryField("errorMessage", b.dom_string, .{ .required = true }),
});

const engine_shims = .{
    b.engineShim(
        "webWorkerDispatchExit",
        .{
            b.argument("worker", web_worker_handle, .{}),
            b.argument("exitCode", b.int32, .{}),
        },
        b.none,
        .realm_independent,
    ),
    b.engineShim(
        "webWorkerFinishExit",
        .{
            b.argument("worker", web_worker_handle, .{}),
            b.argument("exitCode", b.int32, .{}),
            b.argument("dispatchEvent", b.boolean, .{}),
        },
        b.none,
        .realm_independent,
    ),
    b.engineShim("webWorkerDispatchOnline", .{b.argument("worker", web_worker_handle, .{})}, b.none, .current_realm_throwing),
    b.engineShim(
        "webWorkerFireEarlyMessages",
        .{b.argument("worker", web_worker_handle, .{})},
        b.none,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "webWorkerDispatchError",
        .{
            b.argument("worker", web_worker_handle, .{}),
            b.argument("message", b.dom_string, .{}),
            b.argument("error", b.engine_value, .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim(
        "webWorkerStartHeapSnapshot",
        .{
            b.argument("worker", web_worker_handle, .{}),
            b.argument("task", worker_heap_snapshot_task_handle, .{ .ownership = .transfer }),
        },
        b.none,
        .realm_independent,
    ),
};

const native_exports = .{
    b.nativeExport(
        "webWorkerCommitStartup",
        .{b.argument("worker", web_worker_state_handle, .{})},
        b.none,
    ),
    b.nativeExport(
        "webWorkerNotifyNeedTermination",
        .{b.argument("worker", web_worker_state_handle, .{})},
        b.none,
    ),
    b.nativeExport(
        "webWorkerSetRef",
        .{
            b.argument("worker", web_worker_state_handle, .{}),
            b.argument("value", b.boolean, .{}),
        },
        b.none,
    ),
    b.nativeExport(
        "webWorkerReleaseParentPollRef",
        .{b.argument("worker", web_worker_state_handle, .{})},
        b.none,
    ),
    b.nativeExport(
        "webWorkerDestroy",
        .{b.argument("worker", web_worker_state_handle, .{})},
        b.none,
    ),
    b.nativeExport(
        "webWorkerHeapSnapshotTaskResolve",
        .{
            b.argument("task", worker_heap_snapshot_task_handle, .{ .ownership = .transfer }),
            b.argument("snapshot", b.thread_safe_dom_string, .{}),
        },
        b.none,
    ),
    b.nativeExport(
        "webWorkerHeapSnapshotTaskRejectNotRunning",
        .{b.argument("task", worker_heap_snapshot_task_handle, .{ .ownership = .transfer })},
        b.none,
    ),
    b.nativeExportWithOptions("webWorkerCreate", .{
        b.argument("worker", web_worker_handle, .{}),
        b.argument("name", b.dom_string, .{}),
        b.argument("url", b.dom_string, .{}),
        b.argument("parentContextID", b.uint32, .{}),
        b.argument("contextID", b.uint32, .{}),
        b.argument("miniMode", b.boolean, .{}),
        b.argument("unrefByDefault", b.boolean, .{}),
        b.argument("evalMode", b.boolean, .{}),
        b.argument("defaultExecArgv", b.boolean, .{}),
        b.argument("argv", archetypes.dom_strings, .{}),
        b.argument("execArgv", archetypes.dom_strings, .{}),
        b.argument("preloadModules", archetypes.dom_strings, .{}),
    }, web_worker_create_result, .current_realm_throwing),
    b.nativeExportWithOptions("webWorkerGetParent", .{}, b.optional(web_worker_handle), .current_realm_nonthrowing),
};

pub const schema = b.moduleWithDeclarations("WebWorkerEngine", .{}, .{}, engine_shims, native_exports);
