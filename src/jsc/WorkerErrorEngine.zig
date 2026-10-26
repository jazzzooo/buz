const BindingEscape = bun.bindgen.Escape(@This());
const std = @import("std");
const bun = @import("bun");
const jsc = bun.jsc;
const bindgen = bun.bindgen;
const LoggerEngine = @import("../logger_jsc/LoggerEngine.zig");
const DispatchErrorSchema = bindgen.Module("WebWorkerEngine").engineShim("webWorkerDispatchError");
const WorkerHandle = bindgen.EngineArgumentType(DispatchErrorSchema, "worker");

pub fn install(vm: *jsc.VirtualMachine) void {
    vm.onUnhandledRejection = onUnhandledRejection;
}

pub fn reportFailure(global: *jsc.JSGlobalObject, failure: bun.JSError) void {
    global.reportActiveExceptionAsUnhandled(failure);
}

pub fn describeLog(global: *jsc.JSGlobalObject, log: *const bun.logger.Log, message: []const u8) bun.JSError!bun.String {
    var value = try LoggerEngine.logToRoot(log, global, message);
    defer value.deinit();
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    var text = try scope.engineIn("js_strings", "stringFromJS").call(.{ .value = value.operand(&scope).asEngine() });
    defer text.deinit();
    return text.takeBunString();
}

pub fn flushLogs(vm: *jsc.VirtualMachine, worker: WorkerHandle) bun.JSError!void {
    if (vm.log.msgs.items.len == 0) return;
    var value = try LoggerEngine.logToRoot(vm.log, vm.global, "Error in worker");
    defer value.deinit();
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(vm.global);
    defer scope.deinit();
    var message = try scope.engineIn("js_strings", "stringFromJS").call(.{ .value = value.operand(&scope).asEngine() });
    defer message.deinit();
    try scope.engine(DispatchErrorSchema).call(.{
        .worker = worker,
        .message = message.operand(),
        .@"error" = value.operand(&scope).asEngine(),
    });
}

fn dispatchError(scope: *bindgen.FocusedEngineScope, worker: WorkerHandle, message: bindgen.DOMString, value: bindgen.EngineOperand) bun.JSError!void {
    try scope.engine(DispatchErrorSchema).call(.{
        .worker = worker,
        .message = message.operand(),
        .@"error" = value,
    });
}

fn onUnhandledRejection(vm: *jsc.VirtualMachine, global: *jsc.JSGlobalObject, value: jsc.JSValue) void {
    vm.onUnhandledRejection = &jsc.VirtualMachine.onQuietUnhandledRejectionHandlerCaptureValue;
    const worker = vm.worker orelse @panic("worker error handler has no worker");
    defer worker.requestTermination();
    reportUnhandledRejection(global, @ptrCast(worker.cpp_worker), value) catch |err| reportFailure(global, err);
}

fn reportUnhandledRejection(global: *jsc.JSGlobalObject, worker: WorkerHandle, value: jsc.JSValue) bun.JSError!void {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    const error_result = scope.engineIn("errors", "jsValueToError").call(.{ .value = BindingEscape.borrowEngineValue(&scope, value) });
    const error_value = if (error_result) |result| result.operand(&scope) else BindingEscape.borrowEngineValue(&scope, value);
    var output = std.Io.Writer.Allocating.init(bun.default_allocator);
    defer output.deinit();
    jsc.ConsoleObject.formatScopedValue(&scope, error_value.engineView(), .Debug, &output.writer, .{
        .enable_colors = false,
        .add_newline = false,
        .flush = false,
        .max_depth = 32,
    }) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.JSError => {
            const formatting_error = try scope.takeThrownException(error.JSError);
            var message = try bindgen.DOMString.fromUTF8("Failed to format worker error");
            defer message.deinit();
            return dispatchError(&scope, worker, message, formatting_error.operand(&scope));
        },
        else => |failure| return failure,
    };
    output.writer.flush() catch return error.OutOfMemory;
    var message = try bindgen.DOMString.fromUTF8(output.written());
    defer message.deinit();
    try dispatchError(&scope, worker, message, error_value);
}
