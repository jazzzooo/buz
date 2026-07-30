/// A task created from C++ code, usually via ScriptExecutionContext.
pub const CppTask = opaque {
    pub fn run(this: *CppTask, global: *jsc.JSGlobalObject) bun.JSError!void {
        jsc.markBinding(@src());
        return bun.cpp.Bun__performTask(global, this);
    }
};

/// A task created from C++ code that runs inside the workpool, usually via ScriptExecutionContext.
pub const ConcurrentCppTask = struct {
    pub const new = bun.TrivialNew(@This());

    cpp_task: *EventLoopTaskNoContext,
    workpool_task: jsc.BackgroundTask = .{ .callback = &runFromWorkpool },

    const EventLoopTaskNoContext = opaque {
        extern fn Bun__EventLoopTaskNoContext__performTask(task: *EventLoopTaskNoContext) void;
        extern fn Bun__EventLoopTaskNoContext__createdInBunVm(task: *const EventLoopTaskNoContext) ?*VirtualMachine;

        /// Deallocates `this`
        pub fn run(this: *EventLoopTaskNoContext) void {
            Bun__EventLoopTaskNoContext__performTask(this);
        }

        /// Get the VM that created this task
        pub fn getVM(this: *const EventLoopTaskNoContext) ?*VirtualMachine {
            return Bun__EventLoopTaskNoContext__createdInBunVm(this);
        }
    };

    pub fn runFromWorkpool(task: *jsc.BackgroundTask) void {
        const this: *ConcurrentCppTask = @fieldParentPtr("workpool_task", task);
        // Extract all the info we need from `this` and `cpp_task` before we call functions that
        // free them
        const cpp_task = this.cpp_task;
        const maybe_vm = cpp_task.getVM();
        bun.destroy(this);
        cpp_task.run();
        if (maybe_vm) |vm| {
            vm.event_loop.unrefConcurrently();
        }
    }

    pub export fn ConcurrentCppTask__createAndRun(cpp_task: *EventLoopTaskNoContext) void {
        jsc.markBinding(@src());
        const vm = cpp_task.getVM() orelse {
            cpp_task.run();
            return;
        };
        vm.event_loop.refConcurrently();
        const cpp = ConcurrentCppTask.new(.{ .cpp_task = cpp_task });
        jsc.BackgroundWork.schedule(&vm.background_tasks, &cpp.workpool_task) catch {
            runFromWorkpool(&cpp.workpool_task);
        };
    }
};

comptime {
    _ = ConcurrentCppTask.ConcurrentCppTask__createAndRun;
}

const bun = @import("bun");

const jsc = bun.jsc;
const VirtualMachine = jsc.VirtualMachine;
