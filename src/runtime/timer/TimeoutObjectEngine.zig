const Self = @This();

const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

pub const JSBinding = struct {
    bindgen_state: bindgen.ClassState = .{},
    timeout: bindgen.OwnedNative(Self, .vm),

    const Methods = TimerObjectInternals.BindingMethods(JSBinding, TimeoutSchema, "timeout");
    pub const destroy = Methods.destroy;

    pub const getDestroyed = Methods.getDestroyed;

    pub const getIdleStart = UndefinedValue(TimeoutSchema.member("_idleStart")).get;
    pub const getIdleTimeout = UndefinedValue(TimeoutSchema.member("_idleTimeout")).get;
    pub const getOnTimeout = UndefinedValue(TimeoutSchema.member("_onTimeout")).get;
    pub const getRepeat = UndefinedValue(TimeoutSchema.member("_repeat")).get;

    fn UndefinedValue(comptime FunctionSchema: type) type {
        return struct {
            pub fn get(_: *JSBinding, context: bindgen.CallContext(FunctionSchema), _: bindgen.Args(FunctionSchema)) bun.JSError!bindgen.Return(FunctionSchema) {
                return .initUndefined(context);
            }
        };
    }

    pub const dispose = Methods.dispose;

    pub const toPrimitive = Methods.toPrimitive;

    pub fn close(
        this: *JSBinding,
        _: bindgen.CallContext(TimeoutCloseSchema),
        args: bindgen.Args(TimeoutCloseSchema),
    ) bun.JSError!bindgen.Return(TimeoutCloseSchema) {
        try this.timeout.get().internals.cancel(VirtualMachine.get());
        return args.bindingThis.toOwned();
    }

    pub fn hasRef(
        this: *JSBinding,
        _: bindgen.CallContext(TimeoutHasRefSchema),
        _: bindgen.Args(TimeoutHasRefSchema),
    ) bun.JSError!bool {
        return this.timeout.get().internals.flags.has_js_ref;
    }

    pub const doRef = Methods.doRef;

    pub fn doRefresh(
        this: *JSBinding,
        context: bindgen.CallContext(TimeoutRefreshSchema),
        args: bindgen.Args(TimeoutRefreshSchema),
    ) bun.JSError!bindgen.Return(TimeoutRefreshSchema) {
        const internals = &this.timeout.get().internals;
        if (internals.canRefresh()) {
            const now = bun.timespec.now(.allow_mocked_time);
            const should_reschedule = context.engineIn("timers", "timerPrepareReschedule").call(.{
                .timer = args.bindingThis.operand(context),
                .isInterval = internals.isInterval(),
                .idleStart = now.msUnsigned(),
            });
            if (should_reschedule) {
                try internals.rescheduleFromRefresh(args.bindingThis, VirtualMachine.get(), now);
            }
        }
        return args.bindingThis.toOwned();
    }

    pub const doUnref = Methods.doUnref;
};

ref_count: RefCount,
event_loop_timer: EventLoopTimer = .{
    .next = .epoch,
    .tag = .TimeoutObject,
},
internals: TimerObjectInternals,
sleep_completion: ?bun.api.Timer.SleepCompletion = null,

pub fn initSleepFromBinding(
    context: anytype,
    id: i32,
    interval: u31,
    completion: bun.api.Timer.SleepCompletion,
) bun.JSError!bindgen.ClassRef(TimeoutSchema) {
    const globalThis = context.viewToken().globalObject();
    const timeout = bun.default_allocator.create(Self) catch |err| {
        var owned_completion = completion;
        owned_completion.release();
        return err;
    };
    timeout.* = .{
        .ref_count = .init(),
        .internals = .{ .flags = .{ .kind = .setTimeout } },
        .sleep_completion = completion,
    };
    var reference = try wrapOwnedTimeout(timeout, globalThis);
    errdefer reference.deinit();
    try timeout.internals.init(
        context,
        TimeoutSchema,
        &reference,
        globalThis,
        id,
        .setTimeout,
        interval,
        null,
    );



    return reference;
}

pub fn initFromBinding(
    context: anytype,
    id: i32,
    kind: Kind,
    interval: u31,
    callback: bindgen.CallbackView(bun.api.Timer.TimerCallbackType),
    arguments: bindgen.AnyRestView,
) bun.JSError!bindgen.ClassRef(TimeoutSchema) {
    const globalThis = context.viewToken().globalObject();
    const timeout = try bun.default_allocator.create(Self);
    timeout.* = .{
        .ref_count = .init(),
        .internals = .{ .flags = .{ .kind = kind } },
    };
    var reference = try wrapOwnedTimeout(timeout, globalThis);
    errdefer reference.deinit();
    TimeoutCallbackSlot.setCallbackViewOnOwned(&reference, bun.api.Timer.TimerCallbackType, callback);
    try timeout.internals.init(
        context,
        TimeoutSchema,
        &reference,
        globalThis,
        id,
        kind,
        interval,
        arguments,
    );



    return reference;
}

fn wrapOwnedTimeout(timeout: *Self, global: *JSGlobalObject) bun.JSError!bindgen.ClassRef(TimeoutSchema) {
    const binding = bun.default_allocator.create(JSBinding) catch |err| {
        timeout.deref();
        return err;
    };
    binding.* = .{ .timeout = .init(timeout) };
    return Binding.adoptNativeRef(binding, global);
}

pub fn hasSleepCompletion(self: *const Self) bool {
    return self.sleep_completion != null;
}

pub fn takeSleepCompletion(self: *Self) ?bun.api.Timer.SleepCompletion {
    const completion = self.sleep_completion orelse return null;
    self.sleep_completion = null;
    return completion;
}

fn deinit(self: *Self) void {
    if (self.sleep_completion) |*completion| completion.release();
    self.internals.deinit();
    bun.destroy(self);
}

pub fn destroy(self: *Self) void {
    self.internals.finalize();
}

const bun = @import("bun");
const bindgen = bun.bindgen;

const EventLoopTimer = bun.api.Timer.EventLoopTimer;
const Kind = bun.api.Timer.Kind;
const TimerObjectInternals = bun.api.Timer.TimerObjectInternals;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const VirtualMachine = jsc.VirtualMachine;

const TimeoutBindingModule = bindgen.Module("Timeout");
const TimeoutSchema = TimeoutBindingModule.class("Timeout");
pub const Binding = bindgen.Class(TimeoutSchema, JSBinding);
const TimeoutCloseSchema = TimeoutSchema.member("close");
const TimeoutHasRefSchema = TimeoutSchema.member("hasRef");
const TimeoutRefreshSchema = TimeoutSchema.member("refresh");
const TimeoutCallbackSlot = Binding.CachedSlot("callback");

comptime {
    _ = Binding;
}
