pub const VM = opaque {
    pub fn setControlFlowProfiler(vm: *VM, enabled: bool) void {
        bun.bindgen.Engine(SetControlFlowProfilerSchema).call(.{ .vm = @ptrCast(vm), .enabled = enabled });
    }

    pub fn hasExecutionTimeLimit(vm: *VM) bool {
        return bun.bindgen.Engine(HasExecutionTimeLimitSchema).call(.{ .vm = @ptrCast(vm) });
    }

    /// See `JSLock.h` in WebKit for more detail on how the API lock prevents races.
    pub fn getAPILock(vm: *VM) Lock {
        bun.bindgen.Engine(GetAPILockSchema).call(.{ .vm = @ptrCast(vm) });
        return .{ .vm = vm };
    }

    pub const Lock = struct {
        vm: *VM,
        pub fn release(lock: Lock) void {
            bun.bindgen.Engine(ReleaseAPILockSchema).call(.{ .vm = @ptrCast(lock.vm) });
        }
    };

    pub fn reportExtraMemory(this: *VM, size: usize) void {
        bun.bindgen.Engine(ReportExtraMemorySchema).call(.{ .vm = @ptrCast(this), .size = size });
    }

    pub fn shrinkFootprint(
        vm: *VM,
    ) void {
        bun.bindgen.Engine(ShrinkFootprintSchema).call(.{ .vm = @ptrCast(vm) });
    }

    pub fn runGC(vm: *VM, sync: bool) usize {
        return bun.bindgen.Engine(RunGCSchema).call(.{ .vm = @ptrCast(vm), .sync = sync });
    }

    pub fn heapSize(vm: *VM) usize {
        return bun.bindgen.Engine(HeapSizeSchema).call(.{ .vm = @ptrCast(vm) });
    }

    pub fn collectAsync(vm: *VM) void {
        bun.bindgen.Engine(CollectAsyncSchema).call(.{ .vm = @ptrCast(vm) });
    }

    pub fn executionForbidden(vm: *VM) bool {
        return bun.bindgen.Engine(ExecutionForbiddenSchema).call(.{ .vm = @ptrCast(vm) });
    }

    /// Fires NeedTermination Trap. Thread safe. See jsc's "VMTraps.h" for explaination on traps.
    pub fn notifyNeedTermination(vm: *VM) void {
        bun.bindgen.Engine(NotifyNeedTerminationSchema).call(.{ .vm = @ptrCast(vm) });
    }

    pub fn clearHasTerminationRequest(vm: *VM) void {
        bun.bindgen.Engine(ClearHasTerminationRequestSchema).call(.{ .vm = @ptrCast(vm) });
    }

    pub fn releaseWeakRefs(vm: *VM) void {
        bun.bindgen.Engine(ReleaseWeakRefsSchema).call(.{ .vm = @ptrCast(vm) });
    }

    pub fn onBeforeWait(vm: *VM) void {
        bun.bindgen.Engine(OnBeforeWaitSchema).call(.{ .vm = @ptrCast(vm) });
    }

    pub fn drainMicrotasks(
        vm: *VM,
    ) void {
        bun.bindgen.Engine(DrainMicrotasksSchema).call(.{ .vm = @ptrCast(vm) });
    }

    /// `RESOURCE_USAGE` build option in JavaScriptCore is required for this function
    /// This is faster than checking the heap size
    pub fn blockBytesAllocated(vm: *VM) usize {
        return bun.bindgen.Engine(BlockBytesAllocatedSchema).call(.{ .vm = @ptrCast(vm) });
    }
};

const bun = @import("bun");

const VirtualMachineBindings = bun.bindgen.Module("virtual_machine");
const SetControlFlowProfilerSchema = VirtualMachineBindings.engineShim("vmSetControlFlowProfiler");
const HasExecutionTimeLimitSchema = VirtualMachineBindings.engineShim("vmHasExecutionTimeLimit");
const GetAPILockSchema = VirtualMachineBindings.engineShim("vmGetAPILock");
const ReleaseAPILockSchema = VirtualMachineBindings.engineShim("vmReleaseAPILock");
const ReportExtraMemorySchema = VirtualMachineBindings.engineShim("vmReportExtraMemory");
const ShrinkFootprintSchema = VirtualMachineBindings.engineShim("vmShrinkFootprint");
const RunGCSchema = VirtualMachineBindings.engineShim("vmRunGC");
const HeapSizeSchema = VirtualMachineBindings.engineShim("vmHeapSize");
const CollectAsyncSchema = VirtualMachineBindings.engineShim("vmCollectAsync");
const ExecutionForbiddenSchema = VirtualMachineBindings.engineShim("vmExecutionForbidden");
const NotifyNeedTerminationSchema = VirtualMachineBindings.engineShim("vmNotifyNeedTermination");
const ClearHasTerminationRequestSchema = VirtualMachineBindings.engineShim("vmClearHasTerminationRequest");
const ReleaseWeakRefsSchema = VirtualMachineBindings.engineShim("vmReleaseWeakRefs");
const OnBeforeWaitSchema = VirtualMachineBindings.engineShim("vmOnBeforeWait");
const DrainMicrotasksSchema = bun.bindgen.Module("microtasks").engineShim("vmDrainMicrotasks");
const BlockBytesAllocatedSchema = VirtualMachineBindings.engineShim("vmBlockBytesAllocated");
