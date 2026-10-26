/// Owns callback delivery on the VM thread; detachment clears the native operation's callback.
pub fn NativeIOEndpoint(comptime Operation: type, comptime Result: type) type {
    const Impl = struct {
        vm: *jsc.VirtualMachine,
        ref: bun.Async.KeepAlive = .{},
        registry: *jsc.NativeCompletionRegistry,
        entry: jsc.NativeCompletionRegistry.Entry,
        operation: ?*Operation = null,
        result: ?Result = null,
        context: *anyopaque,
        callback: *const fn (*anyopaque, Result) void,

        const Self = @This();

        pub fn create(vm: *jsc.VirtualMachine, context: *anyopaque, callback: *const fn (*anyopaque, Result) void) bun.OOM!*Self {
            const registry = try (try vm.tryRareData()).nativeCompletionRegistry(vm);
            const this = try bun.default_allocator.create(Self);
            registry.retain();
            this.* = .{
                .vm = vm,
                .registry = registry,
                .context = context,
                .callback = callback,
                .entry = .{ .context = this, .deliver = deliver, .detach = detach },
            };
            return this;
        }

        pub fn deinitUnstarted(this: *Self) void {
            bun.assert(this.operation == null and this.result == null and !this.entry.registered);
            this.destroy();
        }

        pub fn start(this: *Self, operation: *Operation) void {
            bun.assert(this.operation == null and this.result == null);
            this.operation = operation;
            this.ref.ref(this.vm);
            if (!this.registry.register(&this.entry)) {
                detach(this);
                return;
            }
            operation.start();
        }

        pub fn receive(context: *anyopaque, result: Result) void {
            const this: *Self = @ptrCast(@alignCast(context));
            bun.assert(this.operation != null and this.result == null);
            this.operation = null;
            this.result = result;
            _ = this.registry.submit(&this.entry);
        }

        fn deliver(context: *anyopaque) void {
            const this: *Self = @ptrCast(@alignCast(context));
            bun.assert(this.operation == null);
            const result = this.result.?;
            const callback = this.callback;
            const target = this.context;
            this.destroy();
            callback(target, result);
        }

        fn detach(context: *anyopaque) void {
            const this: *Self = @ptrCast(@alignCast(context));
            if (this.operation) |operation| operation.detach();
            if (this.result) |*result| result.deinit();
            const callback = this.callback;
            const target = this.context;
            this.destroy();
            callback(target, .cancelled);
        }

        fn destroy(this: *Self) void {
            this.ref.unref(this.vm);
            this.registry.release();
            bun.default_allocator.destroy(this);
        }
    };
    return Impl;
}

const bun = @import("bun");
const jsc = bun.jsc;
