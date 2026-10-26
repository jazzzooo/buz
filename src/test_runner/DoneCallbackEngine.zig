pub const Owned = struct {
    state: bindgen.ClassRef(DoneCallbackSchema),
    callback: bindgen.Root,

    pub fn deinit(this: *Owned) void {
        this.callback.deinit();
        this.state.deinit();
    }

    pub fn get(this: *const Owned) *DoneCallback {
        return this.state.get(DoneCallback);
    }
};

pub fn create(globalThis: *JSGlobalObject) bun.JSError!Owned {
    groupLog.begin(@src());
    defer groupLog.end();

    const done_callback = try bun.default_allocator.create(DoneCallback);
    done_callback.* = .{};
    var state = try DoneCallbackClass.adoptNativeRef(done_callback, globalThis);
    errdefer state.deinit();
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(globalThis);
    defer scope.deinit();
    var function = try DoneCallbackCallBinding.createCallbackValue(&scope);
    defer function.deinit();
    var name = try bindgen.DOMString.fromLatin1("done");
    defer name.deinit();
    var bound = try scope.engineIn("js_functions", "jsValueBind").call(.{
        .function = function.operand(&scope).asEngine(),
        .bindThis = state.operand(&scope).asEngine(),
        .name = name.operand(),
        .length = 1,
        .arguments = &.{},
    });
    defer bound.deinit();
    return .{
        .state = state,
        .callback = try bound.toRoot(),
    };
}

pub fn call(
    context: bindgen.CallContext(DoneCallbackCallSchema),
    args: bindgen.Args(DoneCallbackCallSchema),
) bun.JSError!void {
    const globalThis = context.viewToken().globalObject();
    groupLog.begin(@src());
    defer groupLog.end();

    const this = args.bindingThis.get(DoneCallback);
    const supplied = args.value orelse null;
    const was_error = supplied != null;

    if (!this.called) {
        if (supplied) |value| _ = context.reportUncaughtException(value.operand(context).asAny(), false);
    }
    this.called = true;

    var ref_handle = this.ref orelse return;
    this.ref = null;
    defer ref_handle.deinit();
    const ref_in = ref_handle.get();
    const should_run = ref_in.ref_count.hasOneRef() or was_error;
    if (!should_run) return;

    var strong = ref_in.buntest_weak.upgrade() orelse return;
    defer strong.deinit();
    const buntest = strong.get();
    buntest.addResult(ref_in.phase);
    try BunTest.runNextTick(ref_in.buntest_weak, globalThis, ref_in.phase);
}

const bun = @import("bun");

const jsc = bun.jsc;
const bindgen = bun.bindgen;
const JSGlobalObject = jsc.JSGlobalObject;
const bun_test = jsc.Jest.bun_test;
const BunTest = bun_test.BunTest;
const DoneCallback = bun_test.DoneCallback;
const groupLog = bun_test.debug.group;

const BindingModule = bindgen.Module("DoneCallback");
const DoneCallbackCallSchema = BindingModule.function("done");
const DoneCallbackCallBinding = bindgen.Fn(DoneCallbackCallSchema, call);
const DoneCallbackSchema = BindingModule.class("DoneCallback");
const DoneCallbackClass = bindgen.Class(DoneCallbackSchema, DoneCallback);

comptime {
    _ = DoneCallbackCallBinding;
    _ = DoneCallbackClass;
}
