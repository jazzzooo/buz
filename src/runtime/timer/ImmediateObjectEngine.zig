const Self = @This();

const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

pub const JSBinding = struct {
    bindgen_state: bindgen.ClassState = .{},
    immediate: bindgen.OwnedNative(Self, .vm),

    const Methods = TimerObjectInternals.BindingMethods(JSBinding, ImmediateSchema, "immediate");
    pub const destroy = Methods.destroy;

    pub const getDestroyed = Methods.getDestroyed;

    pub const dispose = Methods.dispose;

    pub const toPrimitive = Methods.toPrimitive;

    pub fn hasRef(
        this: *JSBinding,
        _: bindgen.CallContext(ImmediateHasRefSchema),
        _: bindgen.Args(ImmediateHasRefSchema),
    ) bun.JSError!bool {
        return this.immediate.get().internals.flags.is_keeping_event_loop_alive;
    }

    pub const doRef = Methods.doRef;

    pub const doUnref = Methods.doUnref;
};

ref_count: RefCount,
event_loop_timer: EventLoopTimer = .{
    .next = .epoch,
    .tag = .ImmediateObject,
},
internals: TimerObjectInternals,

pub fn initFromBinding(
    context: anytype,
    id: i32,
    callback: bindgen.CallbackView(bun.api.Timer.TimerCallbackType),
    arguments: bindgen.AnyRestView,
) bun.JSError!bindgen.ClassRef(ImmediateSchema) {
    const globalThis = context.viewToken().globalObject();
    const immediate = try bun.default_allocator.create(Self);
    immediate.* = .{
        .ref_count = .init(),
        .internals = .{ .flags = .{ .kind = .setImmediate } },
    };
    const binding = bun.default_allocator.create(JSBinding) catch |err| {
        immediate.deref();
        return err;
    };
    binding.* = .{ .immediate = .init(immediate) };
    var reference = try Binding.adoptNativeRef(binding, globalThis);
    errdefer reference.deinit();
    ImmediateCallbackSlot.setCallbackViewOnOwned(&reference, bun.api.Timer.TimerCallbackType, callback);
    try immediate.internals.init(
        context,
        ImmediateSchema,
        &reference,
        globalThis,
        id,
        .setImmediate,
        0,
        arguments,
    );



    return reference;
}

fn deinit(self: *Self) void {
    self.internals.deinit();
    bun.destroy(self);
}

pub fn destroy(self: *Self) void {
    self.internals.finalize();
}

/// returns true if an exception was thrown
pub fn runImmediateTask(self: *Self, vm: *VirtualMachine) bool {
    return self.internals.runImmediateTask(vm);
}

const bun = @import("bun");
const bindgen = bun.bindgen;

const EventLoopTimer = bun.api.Timer.EventLoopTimer;
const TimerObjectInternals = bun.api.Timer.TimerObjectInternals;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const VirtualMachine = jsc.VirtualMachine;

const ImmediateBindingModule = bindgen.Module("Immediate");
const ImmediateSchema = ImmediateBindingModule.class("Immediate");
pub const Binding = bindgen.Class(ImmediateSchema, JSBinding);
const ImmediateHasRefSchema = ImmediateSchema.member("hasRef");
const ImmediateCallbackSlot = Binding.CachedSlot("callback");

comptime {
    _ = Binding;
}
