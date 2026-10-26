const b = @import("bindgen_schema");
const engine_types = @import("binding_schema_engine_types");

const engine_shims = .{
    b.engineShim("globalObjectVM", .{b.argument("global", engine_types.global_object, .{})}, engine_types.jsc_vm, .vm_thread_nonthrowing),
    b.engineShim("globalObjectBunVM", .{b.argument("global", engine_types.global_object, .{})}, engine_types.bun_vm, .vm_thread_nonthrowing),
    b.engineShim(
        "vmSetControlFlowProfiler",
        .{
            b.argument("vm", engine_types.jsc_vm, .{}),
            b.argument("enabled", b.boolean, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim("vmHasExecutionTimeLimit", .{b.argument("vm", engine_types.jsc_vm, .{})}, b.boolean, .realm_independent),
    b.engineShim("vmGetAPILock", .{b.argument("vm", engine_types.jsc_vm, .{})}, b.none, .realm_independent),
    b.engineShim("vmReleaseAPILock", .{b.argument("vm", engine_types.jsc_vm, .{})}, b.none, .realm_independent),
    b.engineShim(
        "vmReportExtraMemory",
        .{
            b.argument("vm", engine_types.jsc_vm, .{}),
            b.argument("size", b.size, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim("vmShrinkFootprint", .{b.argument("vm", engine_types.jsc_vm, .{})}, b.none, .vm_thread_nonthrowing),
    b.engineShim(
        "vmRunGC",
        .{
            b.argument("vm", engine_types.jsc_vm, .{}),
            b.argument("sync", b.boolean, .{}),
        },
        b.size,
        .vm_thread_nonthrowing,
    ),
    b.engineShim("vmHeapSize", .{b.argument("vm", engine_types.jsc_vm, .{})}, b.size, .vm_thread_nonthrowing),
    b.engineShim("vmCollectAsync", .{b.argument("vm", engine_types.jsc_vm, .{})}, b.none, .realm_independent),
    b.engineShim("vmExecutionForbidden", .{b.argument("vm", engine_types.jsc_vm, .{})}, b.boolean, .vm_thread_nonthrowing),
    b.engineShim("vmNotifyNeedTermination", .{b.argument("vm", engine_types.jsc_vm, .{})}, b.none, .realm_independent),
    b.engineShim("vmClearHasTerminationRequest", .{b.argument("vm", engine_types.jsc_vm, .{})}, b.none, .realm_independent),
    b.engineShim("vmReleaseWeakRefs", .{b.argument("vm", engine_types.jsc_vm, .{})}, b.none, .vm_thread_nonthrowing),
    b.engineShim("vmOnBeforeWait", .{b.argument("vm", engine_types.jsc_vm, .{})}, b.none, .vm_thread_nonthrowing),
    b.engineShim("vmBlockBytesAllocated", .{b.argument("vm", engine_types.jsc_vm, .{})}, b.size, .realm_independent),
};

const native_exports = .{
    b.nativeExportWithOptions("virtualMachineUVLoop", .{}, engine_types.native_event_loop, .current_realm_nonthrowing),
    b.nativeExport("getVirtualMachine", .{}, engine_types.bun_vm),
    b.nativeExport(
        "setDefaultGlobalObject",
        .{b.argument("global", engine_types.zig_global_object, .{})},
        b.none,
    ),
    b.nativeExport("getDefaultGlobalObject", .{}, b.optional(engine_types.zig_global_object)),
    b.nativeExport(
        "virtualMachineIsShuttingDown",
        .{b.argument("vm", engine_types.bun_vm, .{})},
        b.boolean,
    ),
    b.nativeExport(
        "readOriginTimer",
        .{b.argument("vm", engine_types.bun_vm, .{})},
        b.uint64,
    ),
    b.nativeExport(
        "readOriginTimerStart",
        .{b.argument("vm", engine_types.bun_vm, .{})},
        b.double,
    ),
    b.nativeExport(
        "readOriginMonotonicNanoseconds",
        .{b.argument("vm", engine_types.bun_vm, .{})},
        b.uint64,
    ),
    b.nativeExport(
        "virtualMachineExitDuringUncaughtException",
        .{b.argument("vm", engine_types.bun_vm, .{})},
        b.none,
    ),
    b.nativeExport(
        "virtualMachineDrainNativeFinalizers",
        .{b.argument("vm", engine_types.bun_vm, .{})},
        b.none,
    ),
    b.nativeExport(
        "virtualMachineCloseNativeFinalizers",
        .{b.argument("vm", engine_types.bun_vm, .{})},
        b.none,
    ),
    b.nativeExport(
        "virtualMachineScriptExecutionStatus",
        .{b.argument("vm", engine_types.bun_vm, .{})},
        b.int32,
    ),
    b.nativeExport(
        "virtualMachineAllowAddons",
        .{b.argument("vm", engine_types.bun_vm, .{})},
        b.boolean,
    ),
    b.nativeExport(
        "virtualMachineAllowRejectionHandledWarning",
        .{b.argument("vm", engine_types.bun_vm, .{})},
        b.boolean,
    ),
    b.nativeExport("currentVirtualMachineIsMainThread", .{}, b.boolean),
    b.nativeExport(
        "virtualMachineGetExitCode",
        .{b.argument("vm", engine_types.bun_vm, .{})},
        b.uint8,
    ),
    b.nativeExport(
        "virtualMachineSetExitCode",
        .{
            b.argument("vm", engine_types.bun_vm, .{}),
            b.argument("code", b.uint8, .{}),
        },
        b.none,
    ),
    b.nativeExport(
        "virtualMachineUseIsolationSourceProviderCache",
        .{b.argument("vm", engine_types.bun_vm, .{})},
        b.boolean,
    ),
};

pub const schema = b.moduleWithDeclarations("virtual_machine", .{}, .{}, engine_shims, native_exports);
