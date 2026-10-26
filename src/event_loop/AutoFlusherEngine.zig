pub fn register(comptime Owner: type, owner: *Owner, state: *AutoFlusher, vm: *jsc.VirtualMachine) void {
    if (state.isRegistered()) return;
    registerUnchecked(Owner, owner, state, vm);
}

pub fn unregister(comptime Owner: type, owner: *Owner, state: *AutoFlusher, vm: *jsc.VirtualMachine) void {
    if (!state.isRegistered()) return;
    unregisterUnchecked(Owner, owner, state, vm);
}

pub fn unregisterUnchecked(comptime Owner: type, _: *Owner, state: *AutoFlusher, _: *jsc.VirtualMachine) void {
    bun.assert(state.isRegistered());
    state.task.cancel();
}

pub fn registerUnchecked(comptime Owner: type, owner: *Owner, state: *AutoFlusher, vm: *jsc.VirtualMachine) void {
    const Adapter = struct {
        fn run(context: bun.bindgen.NativeCallbackContext(.vm)) bool {
            const target = context.get(*Owner);
            return target.onAutoFlush();
        }

        fn retain(context: bun.bindgen.NativeCallbackContext(.vm)) void {
            const target = context.get(*Owner);
            target.ref();
        }

        fn release(context: bun.bindgen.NativeCallbackContext(.vm)) void {
            const target = context.get(*Owner);
            target.deref();
        }

        const callbacks: AutoFlusher.Task.Callbacks = .{
            .run = run,
            .retain = retain,
            .release = release,
        };
    };
    bun.assert(!state.isRegistered());
    vm.eventLoop().deferred_tasks.postTask(&state.task, .init(owner), &Adapter.callbacks);
}

const bun = @import("bun");
const jsc = bun.jsc;
const AutoFlusher = @import("./AutoFlusher.zig");
