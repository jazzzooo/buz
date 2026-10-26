const bun = @import("bun");
const bindgen = bun.bindgen;

const PromiseBindings = bindgen.Module("promises");
const RejectedSchema = PromiseBindings.nativeExport("handleRejectedPromise");
const HandledSchema = PromiseBindings.nativeExport("handleHandledPromise");
const DeliveredSchema = PromiseBindings.nativeExport("deliverHandledPromiseNotification");

pub fn handleRejected(context: anytype, args: bindgen.Args(RejectedSchema)) bun.JSError!void {
    const global = context.viewToken().globalObject();
    const result = (try context.engineIn("promises", "promiseResult").call(.{ .promise = args.promise.operand(context) })) orelse return;
    context.reportUnhandledRejection(result.operand(context).asAny(), args.promise.operand(context).asPromise());
    global.bunVM().autoGarbageCollect();
}

pub fn handleHandled(context: anytype, args: bindgen.Args(HandledSchema)) bun.JSError!void {
    try context.engineIn("promises", "queueHandledPromiseNotification").call(.{ .promise = args.promise.operand(context) });
}

fn deliverHandled(context: bindgen.CallContext(DeliveredSchema), args: bindgen.Args(DeliveredSchema)) bun.JSError!void {
    const global = context.viewToken().globalObject();
    if (global.bunVM().isShuttingDown()) return;
    _ = try context.engineIn("ProcessHost", "processEmitHandledPromiseEvent").call(.{ .promise = args.promise.operand(context) });
}

comptime {
    _ = bindgen.Fn(DeliveredSchema, deliverHandled);
}
