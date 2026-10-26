const bun = @import("bun");
const bindgen = bun.bindgen;
const VirtualMachine = bun.jsc.VirtualMachine;

pub const Result = union(enum) {
    thrown: bindgen.EngineValueResult,
    returned: bindgen.EngineValueResult,
};

pub fn invoke(scope: anytype, value: bindgen.EngineValueView, accept_non_function: bool) bun.JSError!Result {
    const global = scope.viewToken().globalObject();
    if (!scope.engineIn("js_value_inspection", "jsValueIsCallable").call(.{ .value = value.operand(scope).asEngine() })) {
        if (accept_non_function) return .{ .thrown = value.toResult() };
        return global.throw("Expected value must be a function", .{});
    }

    return callAndCapture(scope, value);
}

fn callAndCapture(scope: anytype, value: bindgen.EngineValueView) bun.JSError!Result {
    const vm = scope.viewToken().globalObject().bunVM();
    try scope.engineIn("microtasks", "handleRejectedPromises").call(.{});

    var captured_rejection: VirtualMachine.UnhandledRejectionCapture = .{};
    defer captured_rejection.deinit();
    var previous_handler = vm.unhandledRejectionScope();
    defer previous_handler.apply(vm);
    const previous_capture = vm.unhandled_pending_rejection_to_capture;
    defer vm.unhandled_pending_rejection_to_capture = previous_capture;
    vm.unhandled_pending_rejection_to_capture = &captured_rejection;
    vm.onUnhandledRejection = &VirtualMachine.onQuietUnhandledRejectionHandlerCaptureValue;

    const called: Result = call: {
        const returned = scope.engineIn("js_functions", "jsValueCall").call(.{
            .function = value.operand(scope).asEngine(),
            .this_value = bindgen.EngineValueResult.initUndefined(scope).operand(scope).asEngine(),
            .arguments = &.{},
        }) catch |failure| {
            if (failure == error.JSTerminated) return failure;
            break :call .{ .thrown = try scope.takeThrownException(failure) };
        };
        break :call .{ .returned = returned };
    };
    if (captured_rejection.failure) |failure| return failure;

    var result = called;
    switch (called) {
        .thrown => {},
        .returned => |returned| if (try scope.engineIn("promises", "jsValueAsPromise").call(.{ .value = returned.operand(scope).asEngine() })) |promise_result| {
            // Waiting drains microtasks, so rejection capture must cover settlement too.
            if (try scope.waitForPromiseRejection(promise_result.operand(scope).asPromise())) |reason| {
                result = .{ .thrown = reason };
            }
        },
    }
    try scope.engineIn("microtasks", "handleRejectedPromises").call(.{});
    if (captured_rejection.failure) |failure| return failure;
    if (called == .thrown) return called;
    if (try captured_rejection.root.engineView(scope)) |reason| {
        const operand = reason.operand(scope).asEngine();
        if (operand.isException()) {
            return .{ .thrown = scope.engineIn("errors", "exceptionThrownValue").call(.{ .exception = operand }) };
        }
        return .{ .thrown = reason.toResult() };
    }
    return result;
}

pub fn messageOrUndefined(scope: anytype, value: bindgen.EngineValueView, accept_non_function: bool) bun.JSError!?bindgen.EngineValueResult {
    const thrown = switch (try invoke(scope, value, accept_non_function)) {
        .thrown => |thrown| thrown,
        .returned => return null,
    };
    if (!scope.engineIn("errors", "jsValueIsAnyError").call(.{ .value = thrown.operand(scope).asEngine() }))
        return bindgen.EngineValueResult.initUndefined(scope);
    return (try scope.engineIn("property_accessors", "jsValueFastGet").call(.{
        .value = thrown.operand(scope).asEngine(),
        .builtinId = .message,
    })) orelse bindgen.EngineValueResult.initUndefined(scope);
}
