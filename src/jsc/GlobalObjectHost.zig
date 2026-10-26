const bun = @import("bun");
const bindgen = bun.bindgen;
const Bindings = bindgen.Module("GlobalObjectHost");
const Status = Bindings.function("jsBunPeekPromiseStatus");
const SettledValue = Bindings.function("jsBunPeekPromiseSettledValue");
const SetHandled = Bindings.function("jsBunPokePromiseAsHandled");
const IsAbortSignal = Bindings.function("isAbortSignal");
const ReportError = Bindings.function("functionReportError");

fn promiseStatus(context: bindgen.CallContext(Status), args: bindgen.Args(Status)) bindgen.CallError(Status)!u8 {
    const promise = args.promise orelse return 0;
    return switch (context.engineIn("promises", "promiseStatus").call(.{ .promise = promise.operand(context) })) {
        .pending => 0,
        .fulfilled => 1,
        .rejected => 2,
    };
}

fn promiseSettledValue(context: bindgen.CallContext(SettledValue), args: bindgen.Args(SettledValue)) bindgen.CallError(SettledValue)!bindgen.Return(SettledValue) {
    const promise = args.promise orelse return .initUndefined(context);
    const result = (try context.engineIn("promises", "promiseResult").call(.{ .promise = promise.operand(context) })) orelse return .initUndefined(context);
    return result.asAny(context);
}

fn promiseSetHandled(context: bindgen.CallContext(SetHandled), args: bindgen.Args(SetHandled)) bindgen.CallError(SetHandled)!void {
    if (args.promise) |promise|
        context.engineIn("promises", "promiseSetHandled").call(.{ .promise = promise.operand(context) });
}

fn isAbortSignal(_: bindgen.CallContext(IsAbortSignal), args: bindgen.Args(IsAbortSignal)) bindgen.CallError(IsAbortSignal)!bool {
    return args.signal != null;
}

fn reportError(context: bindgen.CallContext(ReportError), args: bindgen.Args(ReportError)) bindgen.CallError(ReportError)!void {
    const value = args.@"error" orelse return;
    if (!context.engineIn("errors", "jsValueIsTerminationException").call(.{ .value = value.operand(context).asEngine() }))
        _ = context.reportUncaughtException(value.operand(context).asAny(), false);
}

comptime {
    _ = bindgen.Fn(Status, promiseStatus);
    _ = bindgen.Fn(SettledValue, promiseSettledValue);
    _ = bindgen.Fn(SetHandled, promiseSetHandled);
    _ = bindgen.Fn(IsAbortSignal, isAbortSignal);
    _ = bindgen.Fn(ReportError, reportError);
}
