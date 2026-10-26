const BindingEscape = bun.bindgen.Escape(@This());
const bun = @import("bun");
const std = @import("std");
const ArgumentArrayEngine = @import("./ArgumentArrayEngine.zig");
const Core = @import("./Matcher.zig");
const DiffFormatter = @import("../DiffFormatEngine.zig").DiffFormatter;
const capturedValue = @import("./MatcherEngine.zig").capturedValue;

const bindgen = bun.bindgen;
const Expect = bun.jsc.Expect.Expect;
const ExpectBindings = bindgen.Module("Expect");
const JSGlobalObject = bun.jsc.JSGlobalObject;
const JSValue = bindgen.EngineOperand;
const MockFunctionCallsSchema = ExpectBindings.engineShim("mockFunctionCalls");
const MockFunctionReturnsSchema = ExpectBindings.engineShim("mockFunctionReturns");
const Output = bun.Output;

pub fn run(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    args: anytype,
    comptime matcher: Core.Matcher,
) bindgen.CallError(@TypeOf(context))!void {
    return switch (matcher) {
        .toHaveBeenCalled => if (args.unexpected != null)
            context.fail(.unexpected_argument, {})
        else
            runCallCount(global, context, expect, null, matcher),
        .toHaveBeenCalledOnce => runCallCount(global, context, expect, null, matcher),
        .toHaveBeenCalledTimes => runCallCount(global, context, expect, args.expected, matcher),
        .toHaveBeenCalledWith,
        .toHaveBeenLastCalledWith,
        .toHaveBeenNthCalledWith,
        => runCalledWith(global, context, expect, args, matcher),
        .toHaveReturned,
        .toHaveReturnedTimes,
        => runReturnCount(global, context, expect, args, matcher),
        .toHaveReturnedWith => runReturnedWith(global, context, expect, args.expected),
        .toHaveLastReturnedWith,
        .toHaveNthReturnedWith,
        => runSpecificReturnedWith(global, context, expect, args, matcher),
        else => @compileError("non-mock matcher passed to mock matcher engine"),
    };
}

fn runCallCount(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    expected_count: ?u32,
    comptime matcher: Core.Matcher,
) bun.JSError!void {
    const received = try capturedValue(expect, context, matcher.name(), callCountSignature(matcher));
    expect.incrementExpectCallCounter();
    const calls = try mockFunctionCalls(context, received) orelse
        return throwNotMockFunction(global, expect, received, matcher, callCountSignature(matcher));

    const actual_count: u32 = @intCast(try calls.getLength());
    const expectation: Core.CountExpectation = switch (matcher) {
        .toHaveBeenCalled => .{ .at_least = 1 },
        .toHaveBeenCalledOnce => .{ .exactly = 1 },
        .toHaveBeenCalledTimes => .{ .exactly = expected_count.? },
        else => @compileError("non-call-count matcher passed to call counter"),
    };
    if (Core.passes(Core.countMatches(actual_count, expectation), expect.flags.not)) return;

    switch (matcher) {
        .toHaveBeenCalled => if (expect.flags.not) {
            const signature = comptime Expect.getSignature(matcher.name(), "", true);
            return expect.throw(global, signature, "\n\nExpected number of calls: <green>0<r>\nReceived number of calls: <red>{d}<r>\n", .{actual_count});
        } else {
            const signature = comptime Expect.getSignature(matcher.name(), "", false);
            return expect.throw(global, signature, "\n\nExpected number of calls: \\>= <green>1<r>\nReceived number of calls: <red>{d}<r>\n", .{actual_count});
        },
        .toHaveBeenCalledOnce => if (expect.flags.not) {
            const signature = comptime Expect.getSignature(matcher.name(), "", true);
            return expect.throw(global, signature, "\n\nExpected number of calls: not <green>1<r>\nReceived number of calls: <red>{d}<r>\n", .{actual_count});
        } else {
            const signature = comptime Expect.getSignature(matcher.name(), "", false);
            return expect.throw(global, signature, "\n\nExpected number of calls: <green>1<r>\nReceived number of calls: <red>{d}<r>\n", .{actual_count});
        },
        .toHaveBeenCalledTimes => if (expect.flags.not) {
            const signature = comptime Expect.getSignature(matcher.name(), "<green>expected<r>", true);
            return expect.throw(global, signature, "\n\nExpected number of calls: not <green>{d}<r>\nReceived number of calls: <red>{d}<r>\n", .{ expected_count.?, actual_count });
        } else {
            const signature = comptime Expect.getSignature(matcher.name(), "<green>expected<r>", false);
            return expect.throw(global, signature, "\n\nExpected number of calls: <green>{d}<r>\nReceived number of calls: <red>{d}<r>\n", .{ expected_count.?, actual_count });
        },
        else => unreachable,
    }
}

fn runReturnCount(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    args: anytype,
    comptime matcher: Core.Matcher,
) bindgen.CallError(@TypeOf(context))!void {
    const received = try capturedValue(expect, context, matcher.name(), returnCountSignature(matcher));
    expect.incrementExpectCallCounter();
    var returns = try mockReturnIterator(context, received);
    defer returns.deinit();
    if (comptime matcher == .toHaveReturned) {
        if (args.unexpected != null) return context.fail(.unexpected_argument, {});
    }

    var successful_count: u32 = 0;
    var call_count: u32 = 0;
    while (try returns.next(context)) |item_result| {
        if (try returnRecordStatus(context, item_result.operand(context)) == .@"return") successful_count += 1;
        call_count += 1;
    }
    const expectation: Core.CountExpectation = switch (matcher) {
        .toHaveReturned => .{ .at_least = 1 },
        .toHaveReturnedTimes => .{ .exactly = args.expected },
        else => @compileError("non-return-count matcher passed to return counter"),
    };
    if (Core.passes(Core.countMatches(successful_count, expectation), expect.flags.not)) return;

    const expected = switch (expectation) {
        .at_least => |minimum| minimum,
        .exactly => |count| count,
    };
    const relation: []const u8 = switch (matcher) {
        .toHaveReturned => if (expect.flags.not) "< " else ">= ",
        .toHaveReturnedTimes => if (expect.flags.not) "!= " else "== ",
        else => unreachable,
    };
    // Inline snapshots depend on this spelling and spacing.
    const alignment = if (relation.len == 2) "" else " ";
    const diagnostic = "\n\nExpected number of succesful returns: {s}<green>{d}<r>\nReceived number of succesful returns:   {s}<red>{d}<r>\nReceived number of calls:               {s}<red>{d}<r>\n";
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature(matcher.name(), returnCountSignature(matcher), true);
        return expect.throw(global, signature, diagnostic, .{ relation, expected, alignment, successful_count, alignment, call_count });
    }
    const signature = comptime Expect.getSignature(matcher.name(), returnCountSignature(matcher), false);
    return expect.throw(global, signature, diagnostic, .{ relation, expected, alignment, successful_count, alignment, call_count });
}

fn runCalledWith(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    args: anytype,
    comptime matcher: Core.Matcher,
) bun.JSError!void {
    const received = try capturedValue(expect, context, matcher.name(), calledWithSignature(matcher));
    expect.incrementExpectCallCounter();
    const calls = try mockFunctionCalls(context, received) orelse
        return throwNotMockFunction(global, expect, received, matcher, calledWithSignature(matcher));

    const expected = args.expected;
    const call_count: u32 = @intCast(try calls.getLength());
    const requested_call: ?u32 = if (comptime matcher == .toHaveBeenNthCalledWith) args.index else null;
    var matched = false;
    var compared_call: ?JSValue = null;

    switch (matcher) {
        .toHaveBeenCalledWith => {
            var index: u32 = 0;
            while (index < call_count) : (index += 1) {
                const call = try calls.getIndex(index);
                if (try callArgumentsMatch(global, context, call, expected)) {
                    matched = true;
                    compared_call = call;
                    break;
                }
            }
        },
        .toHaveBeenLastCalledWith => if (call_count != 0) {
            const call = try calls.getIndex(call_count - 1);
            compared_call = call;
            matched = try callArgumentsMatch(global, context, call, expected);
        },
        .toHaveBeenNthCalledWith => if (call_count >= requested_call.?) {
            const call = try calls.getIndex(requested_call.? - 1);
            compared_call = call;
            matched = try callArgumentsMatch(global, context, call, expected);
        },
        else => @compileError("non-called-with matcher passed to call argument matcher"),
    }

    if (Core.passes(matched, expect.flags.not)) return;
    const expected_array = try createArgumentArray(context, expected);
    expected_array.ensureStillAlive();
    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();

    if (expect.flags.not) {
        const signature = comptime Expect.getSignature(matcher.name(), calledWithSignature(matcher), true);
        return switch (matcher) {
            .toHaveBeenCalledWith => expect.throw(global, signature, "\n\nExpected mock function not to have been called with: <green>{f}<r>\nBut it was.", .{expected_array.toFmt(&formatter)}),
            .toHaveBeenLastCalledWith => expect.throw(global, signature, "\n\nExpected last call not to be with: <green>{f}<r>\nBut it was.", .{expected_array.toFmt(&formatter)}),
            .toHaveBeenNthCalledWith => expect.throw(global, signature, "\n\nExpected call #{d} not to be with: <green>{f}<r>\nBut it was.", .{ requested_call.?, expected_array.toFmt(&formatter) }),
            else => unreachable,
        };
    }

    const signature = comptime Expect.getSignature(matcher.name(), calledWithSignature(matcher), false);
    if (matcher == .toHaveBeenNthCalledWith and call_count < requested_call.?) {
        return expect.throw(global, signature, "\n\nThe mock function was called {d} time{s}, but call {d} was requested.", .{
            call_count,
            if (call_count == 1) "" else "s",
            requested_call.?,
        });
    }
    if (call_count == 0) {
        return expect.throw(global, signature, "\n\nExpected: <green>{f}<r>\nBut it was not called.", .{expected_array.toFmt(&formatter)});
    }
    if (matcher == .toHaveBeenCalledWith and call_count > 1) {
        const list = AllCallsWithArgsFormatter{ .globalThis = global, .calls = calls, .formatter = &formatter };
        const format =
            \\    <green>Expected<r>: {f}
            \\    <red>Received<r>:
            \\{f}
            \\
            \\    Number of calls: {d}
        ;
        switch (Output.enable_ansi_colors_stderr) {
            inline else => |colors| return expect.throw(global, signature, Output.prettyFmt("\n\n" ++ format ++ "\n", colors), .{
                expected_array.toFmt(&formatter),
                list,
                call_count,
            }),
        }
    }

    const diff = DiffFormatter{
        .expected = expected_array,
        .received = compared_call orelse try calls.getIndex(0),
        .globalThis = global,
        .not = false,
    };
    if (matcher == .toHaveBeenNthCalledWith) {
        return expect.throw(global, signature, "\n\nCall #{d}:\n{f}\n", .{ requested_call.?, diff });
    }
    return expect.throw(global, signature, "\n\n{f}\n", .{diff});
}

fn runReturnedWith(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    expected_view: anytype,
) bun.JSError!void {
    const received = try capturedValue(expect, context, "toHaveReturnedWith", "<green>expected<r>");
    const expected = expected_view.operand(context).asEngine();
    expect.incrementExpectCallCounter();
    const returns = try requireMockFunctionReturns(context, received);

    const call_count: u32 = @intCast(try returns.getLength());
    var successful_returns = std.array_list.Managed(bindgen.EngineRoot).init(global.bunVM().allocator);
    defer {
        for (successful_returns.items) |*value| value.deinit();
        successful_returns.deinit();
    }
    var matched = false;
    var has_errors = false;
    var index: u32 = 0;
    while (index < call_count) : (index += 1) {
        switch (try readReturnRecord(context, try returns.getIndex(index))) {
            .returned => |value| {
                try successful_returns.ensureUnusedCapacity(1);
                successful_returns.appendAssumeCapacity(try value.toRoot());
                if (!matched and try value.jestDeepEquals(expected)) matched = true;
            },
            .threw => has_errors = true,
            .incomplete => {},
        }
    }
    if (Core.passes(matched, expect.flags.not)) return;

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature("toHaveReturnedWith", "<green>expected<r>", true);
        return expect.throw(global, signature, "\n\nExpected mock function not to have returned: <green>{f}<r>\n", .{expected.toFmt(&formatter)});
    }
    const signature = comptime Expect.getSignature("toHaveReturnedWith", "<green>expected<r>", false);
    if (call_count == 1 and successful_returns.items.len == 1) {
        return throwReturnDifference(global, expect, signature, expected, successful_returns.items[0].operand(context), null);
    }
    if (has_errors) {
        const list = AllCallsFormatter{ .globalThis = global, .returns = returns, .formatter = &formatter };
        const format =
            \\Some calls errored:
            \\
            \\    Expected: {f}
            \\    Received:
            \\{f}
            \\
            \\    Number of returns: {d}
            \\    Number of calls:   {d}
        ;
        switch (Output.enable_ansi_colors_stderr) {
            inline else => |colors| return expect.throw(global, signature, Output.prettyFmt("\n\n" ++ format ++ "\n", colors), .{
                expected.toFmt(&formatter),
                list,
                successful_returns.items.len,
                call_count,
            }),
        }
    }
    const list = SuccessfulReturnsFormatter{
        .globalThis = global,
        .successful_returns = &successful_returns,
        .formatter = &formatter,
    };
    const format =
        \\    <green>Expected<r>: {f}
        \\    <red>Received<r>:
        \\{f}
        \\
        \\    Number of returns: {d}
    ;
    switch (Output.enable_ansi_colors_stderr) {
        inline else => |colors| return expect.throw(global, signature, Output.prettyFmt("\n\n" ++ format ++ "\n", colors), .{
            expected.toFmt(&formatter),
            list,
            successful_returns.items.len,
        }),
    }
}

fn runSpecificReturnedWith(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    args: anytype,
    comptime matcher: Core.Matcher,
) bun.JSError!void {
    const received = try capturedValue(expect, context, matcher.name(), returnedWithSignature(matcher));
    const expected = args.expected.operand(context).asEngine();
    expect.incrementExpectCallCounter();
    const returns = try requireMockFunctionReturns(context, received);

    const call_count: u32 = @intCast(try returns.getLength());
    const requested_call: ?u32 = if (comptime matcher == .toHaveNthReturnedWith) args.index else null;
    const index: ?u32 = switch (matcher) {
        .toHaveLastReturnedWith => if (call_count == 0) null else call_count - 1,
        .toHaveNthReturnedWith => if (requested_call.? > call_count) null else requested_call.? - 1,
        else => @compileError("non-specific-return matcher passed to return matcher"),
    };
    const record: ?ReturnRecord = if (index) |i|
        try readReturnRecord(context, try returns.getIndex(i))
    else
        null;
    const matched = if (record) |result| switch (result) {
        .returned => |value| try value.jestDeepEquals(expected),
        .threw, .incomplete => false,
    } else false;
    if (Core.passes(matched, expect.flags.not)) return;

    if (expect.flags.not) {
        const signature = comptime Expect.getSignature(matcher.name(), returnedWithSignature(matcher), true);
        var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
        defer formatter.deinit();
        return switch (matcher) {
            .toHaveLastReturnedWith => expect.throw(global, signature, "\n\nExpected mock function not to have last returned: <green>{f}<r>\nBut it did.\n", .{expected.toFmt(&formatter)}),
            .toHaveNthReturnedWith => expect.throw(global, signature, "\n\nExpected mock function not to have returned on call {d}: <green>{f}<r>\nBut it did.\n", .{ requested_call.?, expected.toFmt(&formatter) }),
            else => unreachable,
        };
    }

    const signature = comptime Expect.getSignature(matcher.name(), returnedWithSignature(matcher), false);
    if (record == null) {
        if (matcher == .toHaveLastReturnedWith) {
            return expect.throw(global, signature, "\n\nThe mock function was not called.", .{});
        }
        return expect.throw(global, signature, "\n\nThe mock function was called {d} time{s}, but call {d} was requested.\n", .{
            call_count,
            if (call_count == 1) "" else "s",
            requested_call.?,
        });
    }
    switch (record.?) {
        .threw => |value| {
            var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
            defer formatter.deinit();
            if (matcher == .toHaveLastReturnedWith) {
                return expect.throw(global, signature, "\n\nThe last call threw an error: <red>{f}<r>\n", .{value.toFmt(&formatter)});
            }
            return expect.throw(global, signature, "\n\nCall {d} threw an error: <red>{f}<r>\n", .{ requested_call.?, value.toFmt(&formatter) });
        },
        .incomplete => {
            if (matcher == .toHaveLastReturnedWith) {
                return expect.throw(global, signature, "\n\nThe last call has not completed.\n", .{});
            }
            return expect.throw(global, signature, "\n\nCall {d} has not completed.\n", .{requested_call.?});
        },
        .returned => |value| return throwReturnDifference(
            global,
            expect,
            signature,
            expected,
            value,
            if (matcher == .toHaveNthReturnedWith) requested_call else null,
        ),
    }
}

fn callArgumentsMatch(
    global: *JSGlobalObject,
    context: anytype,
    call: JSValue,
    expected: anytype,
) bun.JSError!bool {
    if (!call.jsType().isArray()) {
        return global.throw("Internal error: expected mock call item to be an array of arguments.", .{});
    }
    if (try call.getLength() != expected.len()) return false;
    for (0..expected.len()) |index| {
        const actual = try call.getIndex(@intCast(index));
        const wanted = expected.at(index).?.operand(context).asEngine();
        if (!try actual.jestDeepEquals(wanted)) return false;
    }
    return true;
}

fn createArgumentArray(
    context: anytype,
    expected: anytype,
) bun.JSError!JSValue {
    const result = try ArgumentArrayEngine.create(context, expected);
    return result.operand(context).asEngine();
}

fn mockFunctionCalls(context: anytype, value: JSValue) bun.JSError!?JSValue {
    return mockFunctionField(context, value, MockFunctionCallsSchema);
}

fn mockFunctionReturns(context: anytype, value: JSValue) bun.JSError!?JSValue {
    return mockFunctionField(context, value, MockFunctionReturnsSchema);
}

fn mockFunctionField(context: anytype, value: JSValue, comptime Schema: type) bun.JSError!?JSValue {
    const result = (try context.engineIn(Schema.module_name, Schema.shim_name).call(.{ .value = value })) orelse return null;
    return result.operand(context).asEngine();
}

fn mockReturnIterator(context: anytype, value: JSValue) bun.JSError!bun.jsc.JSArrayIterator {
    return (try requireMockFunctionReturns(context, value)).arrayIterator();
}

fn requireMockFunctionReturns(context: anytype, value: JSValue) bun.JSError!JSValue {
    const global = context.viewToken().globalObject();
    if (try mockFunctionReturns(context, value)) |returns| return returns;

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    return global.throw("Expected value must be a mock function: {f}", .{value.toFmt(&formatter)});
}

const ReturnStatus = enum {
    throw,
    @"return",
    incomplete,

    const Map = bun.ComptimeEnumMap(ReturnStatus);
};

fn returnRecordStatus(context: anytype, value: bindgen.EngineOperand) bun.JSError!ReturnStatus {
    const global = context.viewToken().globalObject();
    const kind: JSValue.JSType = @fromBackingInt(context.engineIn("js_value_inspection", "jsValueType").call(.{ .value = value }));
    if (kind.isObject()) {
        if (try context.engineIn("property_accessors", "jsValueFastGet").call(.{ .value = value, .builtinId = .type })) |type_string| {
            const type_kind: JSValue.JSType = @fromBackingInt(context.engineIn("js_value_inspection", "jsValueType").call(.{ .value = type_string.operand(context) }));
            if (type_kind.isStringLike()) {
                var text_result = try context.engineIn("js_strings", "stringFromJS").call(.{ .value = type_string.operand(context) });
                const text = text_result.takeBunString();
                defer text.deref();
                if (ReturnStatus.Map.fromString(text)) |status| return status;
            }
        }
    }
    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    return global.throw("Expected value must be a mock function with returns: {f}", .{formatter.toScopedFmt(context, value.engineView())});
}

fn returnRecordValue(context: anytype, value: JSValue) bun.JSError!JSValue {
    return (try value.get("value")) orelse BindingEscape.borrowEngineValue(context, .js_undefined);
}

const AllCallsWithArgsFormatter = struct {
    globalThis: *JSGlobalObject,
    calls: JSValue,
    formatter: *bun.jsc.ConsoleObject.Formatter,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const calls_count: u32 = @intCast(self.calls.getLength() catch |err| return self.globalThis.formatErrorToWriterError(err));
        if (calls_count == 0) {
            try writer.writeAll("(no calls)");
            return;
        }

        for (0..calls_count) |index| {
            if (index != 0) try writer.writeByte('\n');
            try writer.print("           {d: >4}: ", .{index + 1});
            const call_args = self.calls.getIndex(@intCast(index)) catch |err| return self.globalThis.formatErrorToWriterError(err);
            try writer.print("{f}", .{call_args.toFmt(self.formatter)});
        }
    }
};

const AllCallsFormatter = struct {
    globalThis: *JSGlobalObject,
    returns: JSValue,
    formatter: *bun.jsc.ConsoleObject.Formatter,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var calls_count: u32 = 0;
        var iterator = self.returns.arrayIterator() catch |err| return self.globalThis.formatErrorToWriterError(err);
        defer iterator.deinit();
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(self.globalThis);
        defer scope.deinit();
        while (iterator.next(&scope) catch |err| return self.globalThis.formatErrorToWriterError(err)) |item_result| {
            const item = item_result.operand(&scope).asEngine();
            if (calls_count != 0) try writer.writeByte('\n');
            calls_count += 1;
            try writer.print("           {d: >2}: ", .{calls_count});

            switch (readReturnRecord(&scope, item) catch |err| return self.globalThis.formatErrorToWriterError(err)) {
                .returned => |value| {
                    try writer.print("{f}", .{value.toFmt(self.formatter)});
                },
                .threw => |value| try writer.print("function call threw an error: {f}", .{value.toFmt(self.formatter)}),
                .incomplete => try writer.writeAll("<incomplete call>"),
            }
        }
    }
};

const SuccessfulReturnsFormatter = struct {
    globalThis: *JSGlobalObject,
    successful_returns: *const std.array_list.Managed(bindgen.EngineRoot),
    formatter: *bun.jsc.ConsoleObject.Formatter,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(self.globalThis);
        defer scope.deinit();
        for (self.successful_returns.items, 1..) |*root, index| {
            const value = root.operand(&scope);
            if (index != 1) try writer.writeByte('\n');
            try writer.print("           {d: >4}: {f}", .{ index, value.toFmt(self.formatter) });
        }
    }
};

const ReturnRecord = union(enum) {
    returned: JSValue,
    threw: JSValue,
    incomplete,
};

fn readReturnRecord(context: anytype, result: JSValue) bun.JSError!ReturnRecord {
    return switch (try returnRecordStatus(context, result)) {
        .@"return" => .{ .returned = try returnRecordValue(context, result) },
        .throw => .{ .threw = try returnRecordValue(context, result) },
        .incomplete => .incomplete,
    };
}

fn throwReturnDifference(
    global: *JSGlobalObject,
    expect: *Expect,
    comptime signature: []const u8,
    expected: JSValue,
    received: JSValue,
    call_number: ?u32,
) bun.JSError {
    if (expected.isString() and received.isString()) {
        const diff = DiffFormatter{ .expected = expected, .received = received, .globalThis = global, .not = false };
        if (call_number) |number| return expect.throw(global, signature, "\n\nCall {d}:\n{f}\n", .{ number, diff });
        return expect.throw(global, signature, "\n\n{f}\n", .{diff});
    }
    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    if (call_number) |number| {
        return expect.throw(global, signature, "\n\nCall {d}:\nExpected: <green>{f}<r>\nReceived: <red>{f}<r>", .{
            number,
            expected.toFmt(&formatter),
            received.toFmt(&formatter),
        });
    }
    return expect.throw(global, signature, "\n\nExpected: <green>{f}<r>\nReceived: <red>{f}<r>", .{
        expected.toFmt(&formatter),
        received.toFmt(&formatter),
    });
}

fn throwNotMockFunction(
    global: *JSGlobalObject,
    expect: *Expect,
    received: JSValue,
    comptime matcher: Core.Matcher,
    comptime arguments: []const u8,
) bun.JSError {
    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const signature = comptime Expect.getSignature(matcher.name(), arguments, false);
    return expect.throw(global, signature, "\n\nMatcher error: <red>received<r> value must be a mock function\nReceived: {f}", .{received.toFmt(&formatter)});
}

fn callCountSignature(comptime matcher: Core.Matcher) []const u8 {
    return switch (matcher) {
        .toHaveBeenCalled, .toHaveBeenCalledOnce => "",
        .toHaveBeenCalledTimes => "<green>expected<r>",
        else => @compileError("non-call-count matcher has no call count signature"),
    };
}

fn returnCountSignature(comptime matcher: Core.Matcher) []const u8 {
    return switch (matcher) {
        .toHaveReturned, .toHaveReturnedTimes => "<green>expected<r>",
        else => @compileError("non-return-count matcher has no return count signature"),
    };
}

fn calledWithSignature(comptime matcher: Core.Matcher) []const u8 {
    return switch (matcher) {
        .toHaveBeenCalledWith, .toHaveBeenLastCalledWith => "<green>...expected<r>",
        .toHaveBeenNthCalledWith => "<green>n<r>, <green>...expected<r>",
        else => @compileError("non-called-with matcher has no call signature"),
    };
}

fn returnedWithSignature(comptime matcher: Core.Matcher) []const u8 {
    return switch (matcher) {
        .toHaveLastReturnedWith => "<green>expected<r>",
        .toHaveNthReturnedWith => "<green>n<r>, <green>expected<r>",
        else => @compileError("non-returned-with matcher has no return signature"),
    };
}
