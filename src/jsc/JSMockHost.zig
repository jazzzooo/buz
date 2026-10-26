fn jsSpyOn(
    context: bindgen.CallContext(JSSpyOnSchema),
    args: bindgen.Args(JSSpyOnSchema),
) bindgen.CallError(JSSpyOnSchema)!bindgen.Return(JSSpyOnSchema) {
    return context.engineIn("JSMockHost", "spyOn").call(.{
        .target = args.target.operand(context),
        .property = args.property.operand(context).asEngine(),
    });
}

fn clearHistory(
    context: bindgen.CallContext(ClearSchema),
    args: bindgen.Args(ClearSchema),
) bindgen.CallError(ClearSchema)!bindgen.Return(ClearSchema) {
    try context.engineIn("JSMockHost", "clearHistory").call(.{ .mock = args.bindingThis.operand(context) });
    return args.bindingThis.toResult();
}

fn reset(
    context: bindgen.CallContext(ResetSchema),
    args: bindgen.Args(ResetSchema),
) bindgen.CallError(ResetSchema)!bindgen.Return(ResetSchema) {
    try context.engineIn("JSMockHost", "reset").call(.{ .mock = args.bindingThis.operand(context) });
    return args.bindingThis.toResult();
}

fn restore(
    context: bindgen.CallContext(RestoreSchema),
    args: bindgen.Args(RestoreSchema),
) bindgen.CallError(RestoreSchema)!bindgen.Return(RestoreSchema) {
    try context.engineIn("JSMockHost", "restore").call(.{ .mock = args.bindingThis.operand(context) });
    return args.bindingThis.toResult();
}

fn getImplementation(
    context: bindgen.CallContext(GetImplementationSchema),
    args: bindgen.Args(GetImplementationSchema),
) bindgen.CallError(GetImplementationSchema)!bindgen.Return(GetImplementationSchema) {
    return context.engineIn("JSMockHost", "implementation").call(.{ .mock = args.bindingThis.operand(context) });
}

fn getName(
    context: bindgen.CallContext(GetNameSchema),
    args: bindgen.Args(GetNameSchema),
) bindgen.CallError(GetNameSchema)!bindgen.Return(GetNameSchema) {
    return context.engineIn("JSMockHost", "name").call(.{ .mock = args.bindingThis.operand(context) });
}

fn getHistory(
    context: bindgen.CallContext(GetHistorySchema),
    args: bindgen.Args(GetHistorySchema),
) bindgen.CallError(GetHistorySchema)!bindgen.Return(GetHistorySchema) {
    return context.engineIn("JSMockHost", "history").call(.{ .mock = args.bindingThis.operand(context) });
}

fn getPrototypeImplementation(
    context: bindgen.CallContext(GetPrototypeImplementationSchema),
    args: bindgen.Args(GetPrototypeImplementationSchema),
) bindgen.CallError(GetPrototypeImplementationSchema)!bindgen.Return(GetPrototypeImplementationSchema) {
    return context.engineIn("JSMockHost", "implementation").call(.{ .mock = args.bindingThis.operand(context) });
}

fn setName(
    context: bindgen.CallContext(SetNameSchema),
    args: bindgen.Args(SetNameSchema),
) bindgen.CallError(SetNameSchema)!bindgen.Return(SetNameSchema) {
    if (args.name) |name| {
        try context.engineIn("JSMockHost", "setName").call(.{ .mock = args.bindingThis.operand(context), .name = name.operand() });
    }
    return args.bindingThis.toResult();
}

fn setImplementation(
    context: bindgen.CallContext(ImplementationSchema),
    args: bindgen.Args(ImplementationSchema),
) bindgen.CallError(ImplementationSchema)!bindgen.Return(ImplementationSchema) {
    try context.engineIn("JSMockHost", "installImplementation").call(.{
        .mock = args.bindingThis.operand(context),
        .kind = @as(ImplementationKind, if (args.implementation != null) .call else .return_value),
        .once = false,
        .value = if (args.implementation) |value| value.operand(context).asAny() else null,
    });
    return args.bindingThis.toResult();
}

fn setImplementationOnce(
    context: bindgen.CallContext(ImplementationOnceSchema),
    args: bindgen.Args(ImplementationOnceSchema),
) bindgen.CallError(ImplementationOnceSchema)!bindgen.Return(ImplementationOnceSchema) {
    try context.engineIn("JSMockHost", "installImplementation").call(.{
        .mock = args.bindingThis.operand(context),
        .kind = @as(ImplementationKind, if (args.implementation != null) .call else .return_value),
        .once = true,
        .value = if (args.implementation) |value| value.operand(context).asAny() else null,
    });
    return args.bindingThis.toResult();
}

fn returnThis(
    context: bindgen.CallContext(ReturnThisSchema),
    args: bindgen.Args(ReturnThisSchema),
) bindgen.CallError(ReturnThisSchema)!bindgen.Return(ReturnThisSchema) {
    try context.engineIn("JSMockHost", "installImplementation").call(.{
        .mock = args.bindingThis.operand(context),
        .kind = ImplementationKind.return_this,
        .once = false,
        .value = null,
    });
    return args.bindingThis.toResult();
}

fn returnValue(
    context: bindgen.CallContext(ReturnValueSchema),
    args: bindgen.Args(ReturnValueSchema),
) bindgen.CallError(ReturnValueSchema)!bindgen.Return(ReturnValueSchema) {
    try context.engineIn("JSMockHost", "installImplementation").call(.{
        .mock = args.bindingThis.operand(context),
        .kind = ImplementationKind.return_value,
        .once = false,
        .value = args.value.operand(context),
    });
    return args.bindingThis.toResult();
}

fn returnValueOnce(
    context: bindgen.CallContext(ReturnValueOnceSchema),
    args: bindgen.Args(ReturnValueOnceSchema),
) bindgen.CallError(ReturnValueOnceSchema)!bindgen.Return(ReturnValueOnceSchema) {
    try context.engineIn("JSMockHost", "installImplementation").call(.{
        .mock = args.bindingThis.operand(context),
        .kind = ImplementationKind.return_value,
        .once = true,
        .value = args.value.operand(context),
    });
    return args.bindingThis.toResult();
}

fn rejectValue(
    context: bindgen.CallContext(RejectValueSchema),
    args: bindgen.Args(RejectValueSchema),
) bindgen.CallError(RejectValueSchema)!bindgen.Return(RejectValueSchema) {
    try context.engineIn("JSMockHost", "installImplementation").call(.{
        .mock = args.bindingThis.operand(context),
        .kind = ImplementationKind.rejected,
        .once = false,
        .value = args.value.operand(context),
    });
    return args.bindingThis.toResult();
}

fn rejectValueOnce(
    context: bindgen.CallContext(RejectValueOnceSchema),
    args: bindgen.Args(RejectValueOnceSchema),
) bindgen.CallError(RejectValueOnceSchema)!bindgen.Return(RejectValueOnceSchema) {
    try context.engineIn("JSMockHost", "installImplementation").call(.{
        .mock = args.bindingThis.operand(context),
        .kind = ImplementationKind.rejected,
        .once = true,
        .value = args.value.operand(context),
    });
    return args.bindingThis.toResult();
}

fn resolveValue(
    context: bindgen.CallContext(ResolveValueSchema),
    args: bindgen.Args(ResolveValueSchema),
) bindgen.CallError(ResolveValueSchema)!bindgen.Return(ResolveValueSchema) {
    try context.engineIn("JSMockHost", "installResolvedValue").call(.{
        .mock = args.bindingThis.operand(context),
        .value = args.value.operand(context).asEngine(),
        .once = false,
    });
    return args.bindingThis.toResult();
}

fn resolveValueOnce(
    context: bindgen.CallContext(ResolveValueOnceSchema),
    args: bindgen.Args(ResolveValueOnceSchema),
) bindgen.CallError(ResolveValueOnceSchema)!bindgen.Return(ResolveValueOnceSchema) {
    try context.engineIn("JSMockHost", "installResolvedValue").call(.{
        .mock = args.bindingThis.operand(context),
        .value = args.value.operand(context).asEngine(),
        .once = true,
    });
    return args.bindingThis.toResult();
}

fn invoke(
    context: bindgen.CallContext(InvokeSchema),
    args: bindgen.Args(InvokeSchema),
) bindgen.CallError(InvokeSchema)!bindgen.Return(InvokeSchema) {
    const operation = context.engineIn("JSMockHost", "invoke");
    const Argument = @typeInfo(@FieldType(@TypeOf(operation).Args, "arguments")).pointer.child;
    const arguments = try bun.default_allocator.alloc(Argument, args.arguments.len());
    defer bun.default_allocator.free(arguments);
    for (arguments, 0..) |*argument, index| argument.* = args.arguments.at(index).?.operand(context);
    return operation.call(.{
        .mock = args.bindingCallee.operand(context),
        .receiver = args.bindingThis.operand(context).asEngine(),
        .arguments = arguments,
    });
}

fn lastCall(
    context: bindgen.CallContext(LastCallSchema),
    args: bindgen.Args(LastCallSchema),
) bindgen.CallError(LastCallSchema)!bindgen.Return(LastCallSchema) {
    return context.engineIn("JSMockHost", "lastCall").call(.{ .object = if (args.bindingThis) |optional_value| optional_value.operand(context) else null });
}

fn withImplementation(
    context: bindgen.CallContext(WithImplementationSchema),
    args: bindgen.Args(WithImplementationSchema),
) bindgen.CallError(WithImplementationSchema)!bindgen.Return(WithImplementationSchema) {
    return context.engineIn("JSMockHost", "withImplementation").call(.{
        .mock = args.bindingThis.operand(context),
        .implementation = args.implementation.operand(context).asAny(),
        .callback = args.callback.operand(context),
    });
}

fn finishImplementation(
    context: bindgen.CallContext(FinishImplementationSchema),
    args: bindgen.Args(FinishImplementationSchema),
) bindgen.CallError(FinishImplementationSchema)!bindgen.Return(FinishImplementationSchema) {
    try context.engineIn("JSMockHost", "finishImplementation").call(.{ .cleanup = if (args.cleanup) |optional_value| optional_value.operand(context) else null });
}

fn now(
    context: bindgen.CallContext(NowSchema),
    args: bindgen.Args(NowSchema),
) bindgen.CallError(NowSchema)!bindgen.Return(NowSchema) {
    _ = args;
    return context.engineIn("date_time", "currentDateMilliseconds").call(.{});
}

fn setSystemTime(
    context: bindgen.CallContext(SetSystemTimeSchema),
    args: bindgen.Args(SetSystemTimeSchema),
) bindgen.CallError(SetSystemTimeSchema)!bindgen.Return(SetSystemTimeSchema) {
    try context.engineIn("date_time", "setOverriddenDateNow").call(.{ .milliseconds = switch (args.time) {
        .valid => |value| value,
        .invalid => std.math.nan(f64),
    } });
    return args.bindingThis.toResult();
}

fn restoreAll(
    context: bindgen.CallContext(RestoreAllSchema),
    args: bindgen.Args(RestoreAllSchema),
) bindgen.CallError(RestoreAllSchema)!bindgen.Return(RestoreAllSchema) {
    _ = args;
    try context.engineIn("JSMockHost", "restoreAll").call(.{});
}

fn clearAll(
    context: bindgen.CallContext(ClearAllSchema),
    args: bindgen.Args(ClearAllSchema),
) bindgen.CallError(ClearAllSchema)!bindgen.Return(ClearAllSchema) {
    _ = args;
    try context.engineIn("JSMockHost", "clearAll").call(.{});
}

fn create(
    context: bindgen.CallContext(CreateSchema),
    args: bindgen.Args(CreateSchema),
) bindgen.CallError(CreateSchema)!bindgen.Return(CreateSchema) {
    const operation = context.engineIn("JSMockHost", "create");
    const Implementation = @typeInfo(@FieldType(@TypeOf(operation).Args, "implementation")).optional.child;
    return operation.call(.{ .implementation = if (args.implementation) |implementation| switch (implementation) {
        inline else => |value, tag| @unionInit(Implementation, @tagName(tag), value.operand(context)),
    } else null });
}

const std = @import("std");
const bun = @import("bun");
const bindgen = bun.bindgen;
const JSMockHostBindings = bindgen.Module("JSMockHost");
const JSSpyOnSchema = JSMockHostBindings.function("JSMock__jsSpyOn");
const ImplementationKind = bindgen.EngineArgumentType(JSMockHostBindings.engineShim("installImplementation"), "kind");
const ClearSchema = JSMockHostBindings.function("jsMockFunctionMockClear");
const ResetSchema = JSMockHostBindings.function("jsMockFunctionMockReset");
const RestoreSchema = JSMockHostBindings.function("jsMockFunctionMockRestore");
const GetImplementationSchema = JSMockHostBindings.function("jsMockFunctionGetMockImplementation");
const GetNameSchema = JSMockHostBindings.function("jsMockFunctionGetMockName");
const GetHistorySchema = JSMockHostBindings.function("jsMockFunctionGetter_mock");
const GetPrototypeImplementationSchema = JSMockHostBindings.function("jsMockFunctionGetter_protoImpl");
const SetNameSchema = JSMockHostBindings.function("jsMockFunctionMockName");
const ImplementationSchema = JSMockHostBindings.function("jsMockFunctionMockImplementation");
const ImplementationOnceSchema = JSMockHostBindings.function("jsMockFunctionMockImplementationOnce");
const ReturnThisSchema = JSMockHostBindings.function("jsMockFunctionMockReturnThis");
const ReturnValueSchema = JSMockHostBindings.function("jsMockFunctionMockReturnValue");
const ReturnValueOnceSchema = JSMockHostBindings.function("jsMockFunctionMockReturnValueOnce");
const RejectValueSchema = JSMockHostBindings.function("jsMockFunctionMockRejectedValue");
const RejectValueOnceSchema = JSMockHostBindings.function("jsMockFunctionMockRejectedValueOnce");
const ResolveValueSchema = JSMockHostBindings.function("jsMockFunctionMockResolvedValue");
const ResolveValueOnceSchema = JSMockHostBindings.function("jsMockFunctionMockResolvedValueOnce");

const InvokeSchema = JSMockHostBindings.function("jsMockFunctionCall");
const LastCallSchema = JSMockHostBindings.function("jsMockFunctionGetter_mockGetLastCall");
const WithImplementationSchema = JSMockHostBindings.function("jsMockFunctionWithImplementation");
const FinishImplementationSchema = JSMockHostBindings.function("jsMockFunctionWithImplementationCleanup");
const NowSchema = JSMockHostBindings.function("JSMock__jsNow");
const SetSystemTimeSchema = JSMockHostBindings.function("JSMock__jsSetSystemTime");
const RestoreAllSchema = JSMockHostBindings.function("JSMock__jsRestoreAllMocks");
const ClearAllSchema = JSMockHostBindings.function("JSMock__jsClearAllMocks");
const CreateSchema = JSMockHostBindings.function("JSMock__jsMockFn");

comptime {
    _ = bindgen.Fn(JSSpyOnSchema, jsSpyOn);
    _ = bindgen.Fn(ClearSchema, clearHistory);
    _ = bindgen.Fn(ResetSchema, reset);
    _ = bindgen.Fn(RestoreSchema, restore);
    _ = bindgen.Fn(GetImplementationSchema, getImplementation);
    _ = bindgen.Fn(GetNameSchema, getName);
    _ = bindgen.Fn(GetHistorySchema, getHistory);
    _ = bindgen.Fn(GetPrototypeImplementationSchema, getPrototypeImplementation);
    _ = bindgen.Fn(SetNameSchema, setName);
    _ = bindgen.Fn(ImplementationSchema, setImplementation);
    _ = bindgen.Fn(ImplementationOnceSchema, setImplementationOnce);
    _ = bindgen.Fn(ReturnThisSchema, returnThis);
    _ = bindgen.Fn(ReturnValueSchema, returnValue);
    _ = bindgen.Fn(ReturnValueOnceSchema, returnValueOnce);
    _ = bindgen.Fn(RejectValueSchema, rejectValue);
    _ = bindgen.Fn(RejectValueOnceSchema, rejectValueOnce);
    _ = bindgen.Fn(ResolveValueSchema, resolveValue);
    _ = bindgen.Fn(ResolveValueOnceSchema, resolveValueOnce);
    _ = bindgen.Fn(InvokeSchema, invoke);
    _ = bindgen.Fn(LastCallSchema, lastCall);
    _ = bindgen.Fn(WithImplementationSchema, withImplementation);
    _ = bindgen.Fn(FinishImplementationSchema, finishImplementation);
    _ = bindgen.Fn(NowSchema, now);
    _ = bindgen.Fn(SetSystemTimeSchema, setSystemTime);
    _ = bindgen.Fn(RestoreAllSchema, restoreAll);
    _ = bindgen.Fn(ClearAllSchema, clearAll);
    _ = bindgen.Fn(CreateSchema, create);
}
