const BindingEscape = bun.bindgen.Escape(@This());
pub const TestRunner = @import("./TestRunnerState.zig").TestRunnerState(struct {
    pub const Snapshots = @import("./snapshot.zig").Snapshots;
    pub const TestOptions = bun.cli.Command.TestOptions;
    pub const RegularExpression = jsc.RegularExpression;
    pub const BunTestRoot = bun_test.BunTestRoot;
    pub const CommandLineReporter = @import("../cli/test_command.zig").CommandLineReporter;
});

pub fn removeActiveTimeout(runner: *TestRunner, vm: *jsc.VirtualMachine) void {
    const active_file = runner.bun_test_root.active_file.get() orelse return;
    if (active_file.timer.state != .ACTIVE or active_file.timer.next.eql(&.epoch)) return;
    vm.timer.remove(&active_file.timer);
}

pub fn reportActiveTestException(
    test_file: *bun_test.BunTest,
    global: *JSGlobalObject,
    failure: bun.JSError,
    is_rejection: bool,
    user_data: bun_test.BunTest.RefDataValue,
) void {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    const exception = scope.takeException(failure);
    if (scope.engineIn("errors", "jsValueIsTerminationException").call(.{ .value = exception.operand(&scope).asEngine() })) {
        global.clearTerminationException();
        _ = test_file.prepareUncaughtException(false, is_rejection, user_data);
        return;
    }
    const status = test_file.prepareUncaughtException(true, is_rejection, user_data) orelse return;
    scope.runErrorHandler(exception.operand(&scope).asAny());
    bun_test.BunTest.finishUncaughtException(status);
}

fn reportTestException(
    test_file: *bun_test.BunTest,
    global: *JSGlobalObject,
    exception: JSValue,
    is_rejection: bool,
    user_data: bun_test.BunTest.RefDataValue,
) void {
    const status = test_file.prepareUncaughtException(true, is_rejection, user_data) orelse return;
    global.bunVM().runErrorHandler(exception, null);
    bun_test.BunTest.finishUncaughtException(status);
}

pub const Jest = struct {
    pub var runner: ?*TestRunner = null;

    pub fn call(
        context: bun.bindgen.CallContext(JestFunctionSchema),
        args: bun.bindgen.Args(JestFunctionSchema),
    ) bun.bindgen.CallError(JestFunctionSchema)!bun.bindgen.Return(JestFunctionSchema) {
        const globalThis = context.viewToken().globalObject();
        if (globalThis.bunVM().is_in_preload or runner == null) {
            // in preload, no arguments needed
        } else {
            const filename = args.filename orelse return context.fail(.missing_filename, {});
            const converted_filename = try filename.convert(context);
            const str = try converted_filename.value.toUTF8(bun.default_allocator);
            defer str.deinit();
            const slice = str.slice();

            if (!std.fs.path.isAbsolute(slice)) {
                var message_buffer: [bun.MAX_PATH_BYTES + 64]u8 = undefined;
                const message = std.fmt.bufPrint(&message_buffer, "Bun.jest() expects an absolute file path, got '{s}'", .{slice}) catch
                    "Bun.jest() expects an absolute file path";
                return context.fail(.invalid_path, try bun.bindgen.DOMString.fromUTF8(message));
            }
        }

        return context.engineIn("Expect", "jestTestModuleObject").call(.{});
    }

    fn jsSetDefaultTimeout(
        _: bun.bindgen.CallContext(SetDefaultTimeoutSchema),
        args: bun.bindgen.Args(SetDefaultTimeoutSchema),
    ) bun.JSError!void {
        const timeout_ms: u32 = @intCast(@max(args.timeout, 0));

        if (Jest.runner) |test_runner| {
            test_runner.default_timeout_override = timeout_ms;
        }
    }
};

pub const on_unhandled_rejection = struct {
    pub fn onUnhandledRejection(jsc_vm: *VirtualMachine, globalObject: *JSGlobalObject, rejection: JSValue) void {
        if (bun.jsc.Jest.bun_test.cloneActiveStrong()) |buntest_strong_| {
            var buntest_strong = buntest_strong_;
            defer buntest_strong.deinit();

            const buntest = buntest_strong.get();
            var current_state_data = buntest.getCurrentStateData(); // mark unhandled errors as belonging to the currently active test. note that this can be misleading.
            if (current_state_data.entry(buntest)) |entry| {
                if (current_state_data.sequence(buntest)) |sequence| {
                    if (entry != sequence.test_entry) {
                        current_state_data = .start; // mark errors in hooks as 'unhandled error between tests'
                    }
                }
            }
            reportTestException(buntest, globalObject, rejection, true, current_state_data);
            buntest.addResult(current_state_data);
            bun_test.BunTest.run(buntest_strong, globalObject) catch |e| {
                globalObject.reportUncaughtExceptionFromError(e);
            };
            return;
        }

        jsc_vm.runErrorHandler(rejection, jsc_vm.onUnhandledRejectionExceptionList);
    }
};

fn consumeArg(
    should_write: bool,
    str_idx: *usize,
    args_idx: *usize,
    array_list: *std.Io.Writer.Allocating,
    arg: *const bun.bindgen.EngineOperand,
    fallback: []const u8,
) !void {
    if (should_write) {
        const owned_slice = try arg.toSliceOrNull();
        defer owned_slice.deinit();
        array_list.writer.writeAll(owned_slice.slice()) catch return error.OutOfMemory;
    } else {
        array_list.writer.writeAll(fallback) catch return error.OutOfMemory;
    }
    str_idx.* += 1;
    args_idx.* += 1;
}

// Generate test label by positionally injecting parameters with printf formatting
pub fn formatLabel(globalThis: *JSGlobalObject, label: string, function_args: []const bun.bindgen.Root, test_idx: usize, allocator: std.mem.Allocator) !string {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(globalThis);
    defer scope.deinit();
    const first_arg = if (function_args.len > 0) BindingEscape.borrowEngineValue(&scope, BindingEscape.rootValue(&scope, &function_args[0])) else null;
    var idx: usize = 0;
    var args_idx: usize = 0;
    var list = try std.Io.Writer.Allocating.initCapacity(allocator, label.len);
    defer list.deinit();

    while (idx < label.len) {
        const char = label[idx];

        if (char == '$' and idx + 1 < label.len and function_args.len > 0 and first_arg.?.isObject()) {
            const var_start = idx + 1;
            var var_end = var_start;

            if (bun.js_lexer.isIdentifierStart(label[var_end])) {
                var_end += 1;

                while (var_end < label.len) {
                    const c = label[var_end];
                    if (c == '.') {
                        if (var_end + 1 < label.len and bun.js_lexer.isIdentifierContinue(label[var_end + 1])) {
                            var_end += 1;
                        } else {
                            break;
                        }
                    } else if (bun.js_lexer.isIdentifierContinue(c)) {
                        var_end += 1;
                    } else {
                        break;
                    }
                }

                const var_path = label[var_start..var_end];
                var path = try bun.bindgen.DOMString.fromUTF8(var_path);
                defer path.deinit();
                const path_value = try scope.engineIn("js_strings", "stringToJS").call(.{ .value = path.operand() });
                if (try scope.engineIn("property_accessors", "jsValueGetIfPropertyExistsFromPath").call(.{
                    .value = first_arg.?,
                    .path = .{ .string = path_value.operand(&scope).asEngine() },
                })) |value| {
                    const is_null = scope.engineIn("js_value_inspection", "jsValueEqual").call(.{ .operands = .{ .left = value.operand(&scope), .right = bun.bindgen.EngineValueResult.initNull(&scope).operand(&scope) } });
                    const is_undefined = scope.engineIn("js_value_inspection", "jsValueEqual").call(.{ .operands = .{ .left = value.operand(&scope), .right = bun.bindgen.EngineValueResult.initUndefined(&scope).operand(&scope) } });
                    if (!is_null and !is_undefined) {
                        // For primitive strings, use toString() to avoid adding quotes
                        // This matches Jest's behavior (https://github.com/jestjs/jest/issues/7689)
                        const value_type: JSValue.JSType = @fromBackingInt(scope.engineIn("js_value_inspection", "jsValueType").call(.{ .value = value.operand(&scope) }));
                        if (value_type.isStringLike()) {
                            var text = try scope.engineIn("js_strings", "stringFromJS").call(.{ .value = value.operand(&scope) });
                            defer text.deinit();
                            const owned_slice = try text.toUTF8(allocator);
                            defer owned_slice.deinit();
                            list.writer.writeAll(owned_slice.slice()) catch return error.OutOfMemory;
                        } else {
                            var formatter = jsc.ConsoleObject.Formatter{ .globalThis = globalThis, .quote_strings = true };
                            defer formatter.deinit();
                            list.writer.print("{f}", .{formatter.toScopedFmt(&scope, value.operand(&scope).engineView())}) catch return formatFailure(globalThis);
                        }
                        idx = var_end;
                        continue;
                    }
                }
            } else {
                while (var_end < label.len and (bun.js_lexer.isIdentifierContinue(label[var_end]) and label[var_end] != '$')) {
                    var_end += 1;
                }
            }

            list.writer.writeByte('$') catch return error.OutOfMemory;
            list.writer.writeAll(label[var_start..var_end]) catch return error.OutOfMemory;
            idx = var_end;
        } else if (char == '%' and (idx + 1 < label.len) and !(args_idx >= function_args.len)) {
            const current_arg = if (args_idx == 0) first_arg.? else BindingEscape.borrowEngineValue(&scope, BindingEscape.rootValue(&scope, &function_args[args_idx]));

            switch (label[idx + 1]) {
                's' => {
                    try consumeArg(current_arg.jsType().isString(), &idx, &args_idx, &list, &current_arg, "%s");
                },
                'i' => {
                    try consumeArg(current_arg.isAnyInt(), &idx, &args_idx, &list, &current_arg, "%i");
                },
                'd' => {
                    try consumeArg(current_arg.isNumber(), &idx, &args_idx, &list, &current_arg, "%d");
                },
                'f' => {
                    try consumeArg(current_arg.isNumber(), &idx, &args_idx, &list, &current_arg, "%f");
                },
                'j', 'o' => {
                    if (try current_arg.jsonStringifyFast()) |result| {
                        var str = result;
                        defer str.deinit();
                        const text = try str.toUTF8(allocator);
                        defer text.deinit();
                        list.writer.writeAll(text.slice()) catch return error.OutOfMemory;
                    } else {
                        list.writer.writeAll("undefined") catch return error.OutOfMemory;
                    }
                    idx += 1;
                    args_idx += 1;
                },
                'p' => {
                    var formatter = jsc.ConsoleObject.Formatter{ .globalThis = globalThis, .quote_strings = true };
                    defer formatter.deinit();
                    const value_fmt = current_arg.toFmt(&formatter);
                    list.writer.print("{f}", .{value_fmt}) catch return formatFailure(globalThis);
                    idx += 1;
                    args_idx += 1;
                },
                '#' => {
                    list.writer.print("{d}", .{test_idx}) catch return error.OutOfMemory;
                    idx += 1;
                },
                '%' => {
                    list.writer.writeByte('%') catch return error.OutOfMemory;
                    idx += 1;
                },
                else => {
                    // ignore unrecognized fmt
                },
            }
        } else list.writer.writeByte(char) catch return error.OutOfMemory;
        idx += 1;
    }

    return list.toOwnedSlice();
}

fn formatFailure(global: *JSGlobalObject) bun.JSError {
    return switch (global.pendingExceptionKind()) {
        .none => error.OutOfMemory,
        .other => error.JSError,
        .termination => error.JSTerminated,
    };
}

pub fn captureTestLineNumber(caller_source_location: bun.bindgen.CallerSourceLocationView) bun.JSError!u32 {
    if (Jest.runner) |runner| {
        if (runner.test_options.reporters.junit) {
            return try caller_source_location.lineNumber();
        }
    }
    return 0;
}

const string = []const u8;

pub const bun_test = @import("./bun_test.zig");

const std = @import("std");

const bun = @import("bun");

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = jsc.JSValue;
const VirtualMachine = jsc.VirtualMachine;

const BunObjectBindings = bun.bindgen.Module("BunObject");
const BunTestBindings = bun.bindgen.Module("BunTest");
const JestFunctionSchema = BunObjectBindings.function("jest");
const JestFunctionBinding = bun.bindgen.Fn(JestFunctionSchema, Jest.call);
const SetDefaultTimeoutSchema = BunTestBindings.function("setDefaultTimeout");
const SetDefaultTimeoutBinding = bun.bindgen.Fn(SetDefaultTimeoutSchema, Jest.jsSetDefaultTimeout);

comptime {
    _ = JestFunctionBinding;
    _ = SetDefaultTimeoutBinding;
}
