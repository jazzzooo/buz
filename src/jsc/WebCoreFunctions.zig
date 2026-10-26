fn initializeWorkerData(
    context: bindgen.CallContext(InitializeWorkerDataSchema),
    _: bindgen.Args(InitializeWorkerDataSchema),
) bindgen.CallError(InitializeWorkerDataSchema)!bindgen.Return(InitializeWorkerDataSchema) {
    return context.engineIn("WebCoreFunctions", "initializeWorkerData").call(.{});
}

fn structuredCloneForStream(
    context: bindgen.CallContext(StructuredCloneForStreamSchema),
    args: bindgen.Args(StructuredCloneForStreamSchema),
) bindgen.CallError(StructuredCloneForStreamSchema)!bindgen.Return(StructuredCloneForStreamSchema) {
    return context.engineIn("WebCoreFunctions", "structuredCloneForStream").call(.{ .value = args.value.operand(context).asEngine() });
}

fn jsFunctionStructuredClone(
    context: bindgen.CallContext(JSFunctionStructuredCloneSchema),
    args: bindgen.Args(JSFunctionStructuredCloneSchema),
) bindgen.CallError(JSFunctionStructuredCloneSchema)!bindgen.Return(JSFunctionStructuredCloneSchema) {
    const value = args.value orelse return context.fail(.missing_value, {});
    if (args.options) |options_input| {
        const options = try options_input.convert(context);
        const operation = context.engineIn("WebCoreFunctions", "structuredClone");
        return operation.call(.{ .value = value.operand(context), .options = try operation.argument("options", options.value) });
    }
    return context.engineIn("WebCoreFunctions", "structuredClone").call(.{
        .value = value.operand(context).asEngine(),
        .options = null,
    });
}

fn jsReceiveMessageOnPort(
    context: bindgen.CallContext(JSReceiveMessageOnPortSchema),
    args: bindgen.Args(JSReceiveMessageOnPortSchema),
) bindgen.CallError(JSReceiveMessageOnPortSchema)!bindgen.Return(JSReceiveMessageOnPortSchema) {
    const port = args.port orelse return context.fail(.missing_port, {});
    const operation = context.engineIn("WebCoreFunctions", "receiveMessageOnPort");
    const message = (try operation.call(.{ .port = operation.argument("port", port) })) orelse return null;
    return .{ .message = message };
}

fn jsFunctionPostMessage(
    context: bindgen.CallContext(JSFunctionPostMessageSchema),
    args: bindgen.Args(JSFunctionPostMessageSchema),
) bindgen.CallError(JSFunctionPostMessageSchema)!bindgen.Return(JSFunctionPostMessageSchema) {
    const operation = context.engineIn("WebCoreFunctions", "postMessage");
    return operation.call(.{ .value = args.value.operand(context), .transfer = try operation.argument("transfer", args.transfer) });
}

const bun = @import("bun");
const bindgen = bun.bindgen;

const WebCoreFunctionsBindings = bindgen.Module("WebCoreFunctions");
const InitializeWorkerDataSchema = WebCoreFunctionsBindings.function("initializeWorkerData");
const StructuredCloneForStreamSchema = WebCoreFunctionsBindings.function("structuredCloneForStream");
const JSFunctionStructuredCloneSchema = WebCoreFunctionsBindings.function("jsFunctionStructuredClone");
const JSReceiveMessageOnPortSchema = WebCoreFunctionsBindings.function("jsReceiveMessageOnPort");
const JSFunctionPostMessageSchema = WebCoreFunctionsBindings.function("jsFunctionPostMessage");

const InitializeWorkerDataBinding = bindgen.Fn(InitializeWorkerDataSchema, initializeWorkerData);
const StructuredCloneForStreamBinding = bindgen.Fn(StructuredCloneForStreamSchema, structuredCloneForStream);
const JSFunctionStructuredCloneBinding = bindgen.Fn(JSFunctionStructuredCloneSchema, jsFunctionStructuredClone);
const JSReceiveMessageOnPortBinding = bindgen.Fn(JSReceiveMessageOnPortSchema, jsReceiveMessageOnPort);
const JSFunctionPostMessageBinding = bindgen.Fn(JSFunctionPostMessageSchema, jsFunctionPostMessage);

comptime {
    _ = InitializeWorkerDataBinding;
    _ = StructuredCloneForStreamBinding;
    _ = JSFunctionStructuredCloneBinding;
    _ = JSReceiveMessageOnPortBinding;
    _ = JSFunctionPostMessageBinding;
}
