const BindingEscape = bun.bindgen.Escape(@This());
const bun = @import("bun");
const Core = @import("./Matcher.zig");
const ThrownValueEngine = @import("./ThrownValueEngine.zig");

const bindgen = bun.bindgen;
const Expect = bun.jsc.Expect.Expect;
const ExpectAny = bun.jsc.Expect.ExpectAny;
const JSGlobalObject = bun.jsc.JSGlobalObject;
const JSValue = bindgen.EngineOperand;

fn isAsymmetricMatcher(value: JSValue) bool {
    const matchers = bun.jsc.Expect;
    inline for (.{
        matchers.ExpectCustomAsymmetricMatcher,
        matchers.ExpectAny,
        matchers.ExpectAnything,
        matchers.ExpectStringMatching,
        matchers.ExpectCloseTo,
        matchers.ExpectObjectContaining,
        matchers.ExpectStringContaining,
        matchers.ExpectArrayContaining,
    }) |Matcher| {
        if (Matcher.Binding.isInstance(rawValue(value))) return true;
    }
    return false;
}

pub fn run(global: *JSGlobalObject, context: anytype, expect: *Expect, args: anytype) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const expected = try expectedValue(global, context, args);
    if (expected) |value| value.ensureStillAlive();

    const scope = context;
    const received_result = try expect.getScopedValue(scope, "toThrow", "<green>expected<r>");
    switch (try ThrownValueEngine.invoke(scope, try received_result.view(scope), expect.flags.promise != .none)) {
        .thrown => |thrown| {
            const value = thrown.operand(scope);
            if (expect.flags.not) return runNegated(scope, expect, expected, value);
            return runPositive(scope, expect, expected, value);
        },
        .returned => |returned| {
            if (expect.flags.not) return;
            return failDidNotThrow(scope, expect, expected, returned.operand(scope));
        },
    }
}

fn expectedValue(global: *JSGlobalObject, context: anytype, args: anytype) bun.JSError!?JSValue {
    const value: ?JSValue = switch (args) {
        .empty => null,
        .expected => |values| switch (values.expected) {
            .undefined_value => null,
            .string_or_regexp => |view| view.operand(context).asEngine(),
            .object => |view| view.operand(context).asEngine(),
        },
    };
    const expected = value orelse return null;
    if (ExpectAny.Binding.isDirectInstance(rawValue(expected))) {
        var handle = (try ExpectAny.Binding.tryCast(rawValue(expected), global)) orelse
            @panic("ExpectAny lost its class identity");
        defer handle.deinit();
        return handle.get().constructor_value.operand(context).asEngine();
    }
    if (expected.isString()) {
        const engine_scope = expected;
        const length = engine_scope.engine(StringLengthSchema).call(.{ .value = expected });
        if (length == 0) return null;
    }
    return expected;
}

fn runNegated(scope: anytype, expect: *Expect, expected: ?JSValue, result: bindgen.EngineOperand) bun.JSError!void {
    const global = scope.viewToken().globalObject();
    const expectation = expected orelse return failUnexpectedThrow(scope, result);
    const message = try thrownMessage(scope, result);
    const match = try matchesExpected(scope, expectation, result, message);
    if (!match.matched) return;

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const signature = comptime Expect.getSignature("toThrow", "<green>expected<r>", true);
    if (expectation.isString()) {
        return expect.throw(global, signature, "\n\nExpected substring: not <green>{f}<r>\nReceived message: <red>{f}<r>\n", .{
            expectation.toFmt(&formatter),
            formatter.toScopedFmt(scope, (message orelse result).engineView()),
        });
    }
    if (expectation.isRegExp()) {
        return expect.throw(global, signature, "\n\nExpected pattern: not <green>{f}<r>\nReceived message: <red>{f}<r>\n", .{
            expectation.toFmt(&formatter),
            formatter.toScopedFmt(scope, (message orelse result).engineView()),
        });
    }
    if (isAsymmetricMatcher(expectation)) {
        return expect.throw(global, signature, "\n\nExpected value: not <green>{f}<r>\nReceived value: <red>{f}<r>\n", .{
            expectation.toFmt(&formatter),
            formatter.toScopedFmt(scope, result.engineView()),
        });
    }
    if (match.expected_message) |expected_message| {
        return expect.throw(global, signature, "\n\nExpected message: not <green>{f}<r>\n", .{formatter.toScopedFmt(scope, expected_message.engineView())});
    }

    const expected_class = try expectation.className();
    defer expected_class.deref();
    return expect.throw(global, signature, "\n\nExpected constructor: not <green>{f}<r>\n\nReceived message: <red>{f}<r>\n", .{
        expected_class,
        formatter.toScopedFmt(scope, (message orelse result).engineView()),
    });
}

fn runPositive(
    scope: anytype,
    expect: *Expect,
    expected: ?JSValue,
    thrown: bindgen.EngineOperand,
) bun.JSError!void {
    const expectation = expected orelse return;
    const message = try thrownMessage(scope, thrown);
    const match = try matchesExpected(scope, expectation, thrown, message);
    if (match.matched) return;
    return failMismatchedThrow(scope, expect, expectation, thrown, message, match.expected_message);
}

const ExpectedMatch = struct {
    matched: bool,
    expected_message: ?bindgen.EngineOperand = null,
};

fn matchesExpected(
    scope: anytype,
    expected: JSValue,
    thrown: bindgen.EngineOperand,
    message: ?bindgen.EngineOperand,
) bun.JSError!ExpectedMatch {
    if (expected.isString()) {
        const received_message = message orelse return .{ .matched = false };
        const expected_string = try expected.toSliceOrNull();
        defer expected_string.deinit();
        var text = try scope.engineIn("js_strings", "stringFromJS").call(.{ .value = received_message });
        defer text.deinit();
        const received_string = try text.toUTF8(bun.default_allocator);
        defer received_string.deinit();
        return .{ .matched = Core.stringMatches(.toInclude, received_string.slice(), expected_string.slice()) };
    }
    if (expected.isRegExp()) {
        const received_message = message orelse return .{ .matched = false };
        return .{ .matched = try scope.engineIn("regular_expressions", "jsValueToMatch").call(.{
            .regex = expected,
            .value = received_message,
        }) };
    }
    if (isAsymmetricMatcher(expected)) {
        return .{ .matched = try scope.engineIn("js_value_inspection", "jsValueJestStrictDeepEquals").call(.{ .input = .{
            .left = thrown,
            .right = expected,
        } }) };
    }
    if (try scope.engineIn("property_accessors", "jsValueFastGet").call(.{ .value = expected, .builtinId = .message })) |expected_message| {
        return .{
            .matched = if (message) |received_message| try scope.engineIn("js_value_inspection", "jsValueSameValue").call(.{ .operands = .{
                .left = received_message,
                .right = expected_message.operand(scope),
            } }) else false,
            .expected_message = expected_message.operand(scope),
        };
    }
    return .{ .matched = try scope.engineIn("js_value_inspection", "jsValueIsInstanceOf").call(.{ .input = .{
        .value = thrown,
        .constructor = expected,
    } }) };
}

fn failUnexpectedThrow(scope: anytype, thrown: bindgen.EngineOperand) bun.JSError {
    const global = scope.viewToken().globalObject();
    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const signature = comptime Expect.getSignature("toThrow", "", true);
    if (scope.engineIn("errors", "jsValueToError").call(.{ .value = thrown })) |err| {
        const name = try errorProperty(scope, err.operand(scope), .name);
        const message = try errorProperty(scope, err.operand(scope), .message);
        return global.throwPretty(signature ++ "\n\nError name: <red>{f}<r>\nError message: <red>{f}<r>\n", .{
            formatter.toScopedFmt(scope, name.engineView()),
            formatter.toScopedFmt(scope, message.engineView()),
        });
    }
    return global.throwPretty(signature ++ "\n\nThrown value: <red>{f}<r>\n", .{formatter.toScopedFmt(scope, thrown.engineView())});
}

fn errorProperty(scope: anytype, value: bindgen.EngineOperand, name: JSValue.BuiltinName) bun.JSError!bindgen.EngineOperand {
    const absent = bindgen.EngineValueResult.initUndefined(scope).operand(scope);
    const result = (try scope.engineIn("property_accessors", "jsValueFastGet").call(.{ .value = value, .builtinId = name })) orelse return absent;
    const is_null = scope.engineIn("js_value_inspection", "jsValueEqual").call(.{ .operands = .{
        .left = result.operand(scope),
        .right = bindgen.EngineValueResult.initNull(scope).operand(scope),
    } });
    return if (is_null) absent else result.operand(scope);
}

fn failMismatchedThrow(
    scope: anytype,
    expect: *Expect,
    expected: JSValue,
    thrown: bindgen.EngineOperand,
    message: ?bindgen.EngineOperand,
    expected_message_value: ?bindgen.EngineOperand,
) bun.JSError {
    const global = scope.viewToken().globalObject();
    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const signature = comptime Expect.getSignature("toThrow", "<green>expected<r>", false);
    if (expected.isString()) {
        if (message) |received_message| {
            return expect.throw(global, signature, "\n\nExpected substring: <green>{f}<r>\nReceived message: <red>{f}<r>\n", .{
                expected.toFmt(&formatter),
                formatter.toScopedFmt(scope, received_message.engineView()),
            });
        }
        return expect.throw(global, signature, "\n\nExpected substring: <green>{f}<r>\nReceived value: <red>{f}<r>", .{
            expected.toFmt(&formatter),
            formatter.toScopedFmt(scope, thrown.engineView()),
        });
    }
    if (expected.isRegExp()) {
        if (message) |received_message| {
            return expect.throw(global, signature, "\n\nExpected pattern: <green>{f}<r>\nReceived message: <red>{f}<r>\n", .{
                expected.toFmt(&formatter),
                formatter.toScopedFmt(scope, received_message.engineView()),
            });
        }
        return expect.throw(global, signature, "\n\nExpected pattern: <green>{f}<r>\nReceived value: <red>{f}<r>", .{
            expected.toFmt(&formatter),
            formatter.toScopedFmt(scope, thrown.engineView()),
        });
    }
    if (isAsymmetricMatcher(expected)) {
        return expect.throw(global, signature, "\n\nExpected value: <green>{f}<r>\nReceived value: <red>{f}<r>\n", .{
            expected.toFmt(&formatter),
            formatter.toScopedFmt(scope, thrown.engineView()),
        });
    }
    if (expected_message_value) |expected_message| {
        if (message) |received_message| {
            return expect.throw(global, signature, "\n\nExpected message: <green>{f}<r>\nReceived message: <red>{f}<r>\n", .{
                formatter.toScopedFmt(scope, expected_message.engineView()),
                formatter.toScopedFmt(scope, received_message.engineView()),
            });
        }
        return expect.throw(global, signature, "\n\nExpected message: <green>{f}<r>\nReceived value: <red>{f}<r>\n", .{
            formatter.toScopedFmt(scope, expected_message.engineView()),
            formatter.toScopedFmt(scope, thrown.engineView()),
        });
    }

    const expected_class = expected.className() catch |e| return e;
    defer expected_class.deref();
    var received_class = try scope.engineIn("js_value_inspection", "jsValueClassName").call(.{ .value = thrown });
    defer received_class.deinit();
    const prefix = signature ++ "\n\nExpected constructor: <green>{f}<r>\nReceived constructor: <red>{f}<r>\n\n";
    if (message) |received_message| {
        return global.throwPretty(prefix ++ "Received message: <red>{f}<r>\n", .{
            expected_class,
            received_class,
            formatter.toScopedFmt(scope, received_message.engineView()),
        });
    }
    return global.throwPretty(prefix ++ "Received value: <red>{f}<r>\n", .{
        expected_class,
        received_class,
        formatter.toScopedFmt(scope, thrown.engineView()),
    });
}

fn failDidNotThrow(scope: anytype, expect: *Expect, expected: ?JSValue, returned: bindgen.EngineOperand) bun.JSError {
    const global = scope.viewToken().globalObject();
    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const received_line = "Received function did not throw\nReceived value: <red>{f}<r>\n";
    const expectation = expected orelse {
        const signature = comptime Expect.getSignature("toThrow", "", false);
        return expect.throw(global, signature, "\n\n" ++ received_line, .{formatter.toScopedFmt(scope, returned.engineView())});
    };
    const signature = comptime Expect.getSignature("toThrow", "<green>expected<r>", false);
    if (expectation.isString()) {
        return expect.throw(global, signature, "\n\nExpected substring: <green>{f}<r>\n\n" ++ received_line, .{
            expectation.toFmt(&formatter),
            formatter.toScopedFmt(scope, returned.engineView()),
        });
    }
    if (expectation.isRegExp()) {
        return expect.throw(global, signature, "\n\nExpected pattern: <green>{f}<r>\n\n" ++ received_line, .{
            expectation.toFmt(&formatter),
            formatter.toScopedFmt(scope, returned.engineView()),
        });
    }
    if (isAsymmetricMatcher(expectation)) {
        return expect.throw(global, signature, "\n\nExpected value: <green>{f}<r>\n\n" ++ received_line, .{
            expectation.toFmt(&formatter),
            formatter.toScopedFmt(scope, returned.engineView()),
        });
    }
    if (try scope.engineIn("property_accessors", "jsValueFastGet").call(.{ .value = expectation, .builtinId = .message })) |expected_result| {
        const expected_message = expected_result.operand(scope);
        return expect.throw(global, signature, "\n\nExpected message: <green>{f}<r>\n\n" ++ received_line, .{
            formatter.toScopedFmt(scope, expected_message.engineView()),
            formatter.toScopedFmt(scope, returned.engineView()),
        });
    }
    const expected_class = expectation.className() catch |e| return e;
    defer expected_class.deref();
    return expect.throw(global, signature, "\n\nExpected constructor: <green>{f}<r>\n\n" ++ received_line, .{
        expected_class,
        formatter.toScopedFmt(scope, returned.engineView()),
    });
}

fn thrownMessage(scope: anytype, thrown: bindgen.EngineOperand) bun.JSError!?bindgen.EngineOperand {
    const kind: JSValue.JSType = @fromBackingInt(scope.engineIn("js_value_inspection", "jsValueType").call(.{ .value = thrown }));
    if (kind.isObject()) {
        const result = (try scope.engineIn("property_accessors", "jsValueFastGet").call(.{ .value = thrown, .builtinId = .message })) orelse return null;
        return result.operand(scope);
    }
    const result = try thrown.engine(ToStringSchema).call(.{ .value = thrown });
    return result.operand(scope).asEngine();
}

fn rawValue(value: JSValue) bun.jsc.JSValue {
    return BindingEscape.rawCallScopedValue(value, value.engineView());
}

const StringLengthSchema = bindgen.Module("js_strings").engineShim("jsStringLength");
const ToStringSchema = bindgen.Module("js_strings").engineShim("jsValueToString");
