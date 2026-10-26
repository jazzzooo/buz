const BindingEscape = bun.bindgen.Escape(@This());
const bun = @import("bun");
const std = @import("std");
const Core = @import("./Matcher.zig");
pub const MockMatcherEngine = @import("./MockMatcherEngine.zig");
const SnapshotMatcherEngine = @import("./SnapshotMatcherEngine.zig");
pub const ThrowMatcherEngine = @import("./ThrowMatcherEngine.zig");

const bindgen = bun.bindgen;
const Expect = bun.jsc.Expect.Expect;
const JSGlobalObject = bun.jsc.JSGlobalObject;
const JSValue = bindgen.EngineOperand;
const DiffFormatter = @import("../DiffFormatEngine.zig").DiffFormatter;

pub fn capturedValue(expect: *Expect, context: anytype, matcher_name: []const u8, comptime matcher_params: []const u8) bun.JSError!bindgen.EngineOperand {
    const value = try expect.getScopedValue(context, matcher_name, matcher_params);
    return value.operand(context).asEngine();
}

pub fn run(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    args: anytype,
    comptime matcher: Core.Matcher,
) bindgen.CallError(@TypeOf(context))!void {
    defer expect.postMatch(global);

    return switch (matcher) {
        .fail, .pass => runAssertionControl(global, expect, args.message, matcher),
        .toBe => runToBe(global, context, expect, args.expected),
        .toBeArray,
        .toBeBoolean,
        .toBeDate,
        .toBeDefined,
        .toBeEven,
        .toBeFalse,
        .toBeFalsy,
        .toBeFinite,
        .toBeFunction,
        .toBeInteger,
        .toBeNaN,
        .toBeNegative,
        .toBeNil,
        .toBeNull,
        .toBeNumber,
        .toBeObject,
        .toBeOdd,
        .toBePositive,
        .toBeString,
        .toBeSymbol,
        .toBeTrue,
        .toBeTruthy,
        .toBeUndefined,
        .toBeValidDate,
        => runSimple(global, context, expect, matcher),
        .toBeArrayOfSize => runArrayOfSize(global, context, expect, args.size),
        .toBeCloseTo => runCloseTo(global, context, expect, args.expected, args.precision),
        .toBeGreaterThan,
        .toBeGreaterThanOrEqual,
        .toBeLessThan,
        .toBeLessThanOrEqual,
        => runComparison(global, context, expect, args.expected, matcher),
        .toBeWithin => runWithin(global, context, expect, args.start, args.end),
        .toContain => runContain(global, context, expect, args.expected, false),
        .toContainEqual => runContain(global, context, expect, args.expected, true),
        .toContainKey => runContainKey(global, context, expect, args.expected),
        .toContainAllKeys,
        .toContainAnyKeys,
        .toContainKeys,
        => runKeyCollection(context, expect, args.expected, matcher),
        .toContainValue => runContainValue(context, expect, args.expected),
        .toContainAllValues,
        .toContainAnyValues,
        .toContainValues,
        => runValueCollection(context, expect, args.expected, matcher),
        .toBeEmpty => runEmpty(global, context, expect),
        .toBeEmptyObject => runEmptyObject(global, context, expect),
        .toBeInstanceOf => runInstanceOf(global, context, expect, args.constructor),
        .toBeOneOf => runOneOf(global, context, expect, args.values),
        .toBeTypeOf => runTypeOf(global, context, expect, args.expected),
        .toEndWith,
        .toEqualIgnoringWhitespace,
        .toInclude,
        .toStartWith,
        => runString(global, context, expect, args.expected, matcher),
        .toIncludeRepeated => runIncludeRepeated(global, context, expect, args.substring, args.count),
        .toHaveLength => runHaveLength(global, context, expect, args.expected),
        .toHaveProperty => runHaveProperty(global, context, expect, args.path, args.expected),
        .toHaveBeenCalled,
        .toHaveBeenCalledOnce,
        .toHaveBeenCalledTimes,
        .toHaveBeenCalledWith,
        .toHaveBeenLastCalledWith,
        .toHaveBeenNthCalledWith,
        .toHaveLastReturnedWith,
        .toHaveNthReturnedWith,
        .toHaveReturned,
        .toHaveReturnedTimes,
        .toHaveReturnedWith,
        => MockMatcherEngine.run(global, context, expect, args, matcher),
        .toEqual,
        .toStrictEqual,
        => runDeepEquality(global, context, expect, args.expected, matcher),
        .toMatchObject => runMatchObject(global, context, expect, args.expected),
        .toMatch => runMatch(global, context, expect, args.expected),
        .toMatchInlineSnapshot,
        .toMatchSnapshot,
        .toThrowErrorMatchingInlineSnapshot,
        .toThrowErrorMatchingSnapshot,
        => SnapshotMatcherEngine.run(global, context, expect, args, matcher),
        .toSatisfy => runSatisfy(global, context, expect, args.predicate),
        .toThrow => ThrowMatcherEngine.run(global, context, expect, args),
    };
}

fn runAssertionControl(
    global: *JSGlobalObject,
    expect: *Expect,
    message: ?bindgen.DOMStringView,
    comptime matcher: Core.Matcher,
) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const fails = switch (matcher) {
        .fail => !expect.flags.not,
        .pass => expect.flags.not,
        else => @compileError("non-control matcher passed to assertion control"),
    };
    if (!fails) return;

    if (message) |view| {
        const text = try view.toUTF8(bun.default_allocator);
        defer text.deinit();
        const signature = comptime Expect.getSignature(matcher.name(), "", matcher == .pass);
        return expect.throw(global, signature, "\n\n{s}\n", .{text.slice()});
    }
    const default_message = switch (matcher) {
        .fail => "fails by .fail() assertion",
        .pass => "passes by .pass() assertion",
        else => unreachable,
    };
    const signature = comptime Expect.getSignature(matcher.name(), "", matcher == .pass);
    return expect.throw(global, signature, "\n\n{s}\n", .{default_message});
}

fn runSimple(global: *JSGlobalObject, context: anytype, expect: *Expect, comptime matcher: Core.Matcher) bun.JSError!void {
    const value = try capturedValue(expect, context, matcher.name(), "");
    expect.incrementExpectCallCounter();

    if (Core.simplePasses(matcher, inspectSimple(matcher, value), expect.flags.not)) return;

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const received = value.toFmt(&formatter);

    switch (matcher.failureStyle()) {
        .received => if (expect.flags.not) {
            const signature = comptime Expect.getSignature(matcher.name(), "", true);
            return expect.throw(global, signature, "\n\nReceived: <red>{f}<r>\n", .{received});
        } else {
            const signature = comptime Expect.getSignature(matcher.name(), "", false);
            return expect.throw(global, signature, "\n\nReceived: <red>{f}<r>\n", .{received});
        },
        .object => if (expect.flags.not) {
            const signature = comptime Expect.getSignature(matcher.name(), "", true);
            return expect.throw(global, signature, "\n\nExpected value <b>not<r> to be an object\n\nReceived: <red>{f}<r>\n", .{received});
        } else {
            const signature = comptime Expect.getSignature(matcher.name(), "", false);
            return expect.throw(global, signature, "\n\nExpected value to be an object\n\nReceived: <red>{f}<r>\n", .{received});
        },
    }
}

fn runArrayOfSize(global: *JSGlobalObject, context: anytype, expect: *Expect, size: i64) bun.JSError!void {
    const value = try capturedValue(expect, context, "toBeArrayOfSize", "");
    expect.incrementExpectCallCounter();

    const actual_length: ?u64 = if (value.jsType().isArray())
        @intCast(try value.getLength())
    else
        null;
    if (Core.arrayHasSize(actual_length, size) != expect.flags.not) return;

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const received = value.toFmt(&formatter);
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature("toBeArrayOfSize", "", true);
        return expect.throw(global, signature, "\n\nReceived: <red>{f}<r>\n", .{received});
    }
    const signature = comptime Expect.getSignature("toBeArrayOfSize", "", false);
    return expect.throw(global, signature, "\n\nReceived: <red>{f}<r>\n", .{received});
}

fn runCloseTo(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    expected_number: f64,
    precision: ?f64,
) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const received_value = try capturedValue(expect, context, "toBeCloseTo", "<green>expected<r>, precision");
    if (!received_value.isNumber()) {
        return global.throwInvalidArgumentType("expect", "received", "number");
    }

    const precision_value = precision orelse 2.0;
    const result = Core.closeTo(received_value.asNumber(), expected_number, precision_value);
    if (result.matched != expect.flags.not) return;

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const expected = BindingEscape.borrowEngineValue(context, bun.jsc.JSValue.jsNumber(expected_number)).toFmt(&formatter);
    const received = received_value.toFmt(&formatter);
    const suffix = "\n\nExpected: <green>{f}<r>\n" ++
        "Received: <red>{f}<r>\n\n" ++
        "Expected precision: {d}\n" ++
        "Expected difference: \\< <green>{d}<r>\n" ++
        "Received difference: <red>{d}<r>\n";
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature("toBeCloseTo", "<green>expected<r>, precision", true);
        return expect.throw(global, signature, suffix, .{ expected, received, precision_value, result.expected_difference, result.actual_difference });
    }
    const signature = comptime Expect.getSignature("toBeCloseTo", "<green>expected<r>, precision", false);
    return expect.throw(global, signature, suffix, .{ expected, received, precision_value, result.expected_difference, result.actual_difference });
}

fn runComparison(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    expected_view: anytype,
    comptime matcher: Core.Matcher,
) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const received = try capturedValue(expect, context, matcher.name(), "<green>expected<r>");
    if (!received.isNumber() and !received.isBigInt()) {
        return global.throw("Expected and actual values must be numbers or bigints", .{});
    }

    const expected = switch (expected_view) {
        .number => |value| BindingEscape.borrowEngineValue(context, bun.jsc.JSValue.jsNumber(value)),
        .bigint => |view| view.operand(context).asEngine(),
    };
    const matched = Core.comparisonMatches(matcher, compare(received, expected));
    if (matched != expect.flags.not) return;

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const expected_fmt = expected.toFmt(&formatter);
    const received_fmt = received.toFmt(&formatter);
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature(matcher.name(), "<green>expected<r>", true);
        return expect.throw(global, signature, comparisonFailureFormat(matcher, true), .{ expected_fmt, received_fmt });
    }
    const signature = comptime Expect.getSignature(matcher.name(), "<green>expected<r>", false);
    return expect.throw(global, signature, comparisonFailureFormat(matcher, false), .{ expected_fmt, received_fmt });
}

fn runWithin(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    start: f64,
    end: f64,
) bun.JSError!void {
    const received = try capturedValue(expect, context, "toBeWithin", "<green>start<r><d>, <r><green>end<r>");
    expect.incrementExpectCallCounter();

    const matched = Core.within(if (received.isNumber()) received.asNumber() else null, start, end);
    if (matched != expect.flags.not) return;

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const start_fmt = BindingEscape.borrowEngineValue(context, bun.jsc.JSValue.jsNumber(start)).toFmt(&formatter);
    const end_fmt = BindingEscape.borrowEngineValue(context, bun.jsc.JSValue.jsNumber(end)).toFmt(&formatter);
    const received_fmt = received.toFmt(&formatter);
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature("toBeWithin", "<green>start<r><d>, <r><green>end<r>", true);
        return expect.throw(global, signature, "\n\nExpected: not between <green>{f}<r> <d>(inclusive)<r> and <green>{f}<r> <d>(exclusive)<r>\nReceived: <red>{f}<r>\n", .{ start_fmt, end_fmt, received_fmt });
    }
    const signature = comptime Expect.getSignature("toBeWithin", "<green>start<r><d>, <r><green>end<r>", false);
    return expect.throw(global, signature, "\n\nExpected: between <green>{f}<r> <d>(inclusive)<r> and <green>{f}<r> <d>(exclusive)<r>\nReceived: <red>{f}<r>\n", .{ start_fmt, end_fmt, received_fmt });
}

fn runString(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    expected_view: anytype,
    comptime matcher: Core.Matcher,
) bun.JSError!void {
    const received = try capturedValue(expect, context, matcher.name(), stringSignatureArguments(matcher));
    expect.incrementExpectCallCounter();

    const expected = expected_view.operand(context).asEngine();
    var matched = false;
    if (received.isString()) {
        const received_string = try received.toSliceOrNull();
        defer received_string.deinit();
        const expected_string = try expected.toSliceOrNull();
        defer expected_string.deinit();
        matched = Core.stringMatches(matcher, received_string.slice(), expected_string.slice());
    }
    if (matched != expect.flags.not) return;

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const expected_fmt = expected.toFmt(&formatter);
    const received_fmt = received.toFmt(&formatter);
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature(matcher.name(), stringSignatureArguments(matcher), true);
        return expect.throw(global, signature, stringFailureFormat(matcher, true), .{ expected_fmt, received_fmt });
    }
    const signature = comptime Expect.getSignature(matcher.name(), stringSignatureArguments(matcher), false);
    return expect.throw(global, signature, stringFailureFormat(matcher, false), .{ expected_fmt, received_fmt });
}

fn runIncludeRepeated(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    substring_view: anytype,
    count_view: anytype,
) bun.JSError!void {
    const received = try capturedValue(expect, context, "toIncludeRepeated", "<green>expected<r>");
    expect.incrementExpectCallCounter();
    if (!received.isString()) {
        return global.throw("toIncludeRepeated() requires the expect(value) to be a string", .{});
    }

    const substring = substring_view.operand(context).asEngine();
    const count = count_view.operand(context).asEngine();
    const received_string = try received.toSliceOrNull();
    defer received_string.deinit();
    const substring_string = try substring.toSliceOrNull();
    defer substring_string.deinit();
    if (substring_string.length() == 0) {
        return global.throw("toIncludeRepeated() requires the first argument to be a non-empty string", .{});
    }

    const expected_count = count.toU32();
    const matched = Core.includeRepeated(received_string.slice(), substring_string.slice(), expected_count);
    if (matched != expect.flags.not) return;

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const substring_fmt = substring.toFmt(&formatter);
    const count_fmt = count.toFmt(&formatter);
    const received_fmt = received.toFmt(&formatter);
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature("toIncludeRepeated", "<green>expected<r>", true);
        return switch (expected_count) {
            0 => expect.throw(global, signature, "\n\nExpected to include: <green>{f}<r> \nReceived: <red>{f}<r>\n", .{ substring_fmt, received_fmt }),
            1 => expect.throw(global, signature, "\n\nExpected not to include: <green>{f}<r> \nReceived: <red>{f}<r>\n", .{ substring_fmt, received_fmt }),
            else => expect.throw(global, signature, "\n\nExpected not to include: <green>{f}<r> <green>{f}<r> times \nReceived: <red>{f}<r>\n", .{ substring_fmt, count_fmt, received_fmt }),
        };
    }
    const signature = comptime Expect.getSignature("toIncludeRepeated", "<green>expected<r>", false);
    return switch (expected_count) {
        0 => expect.throw(global, signature, "\n\nExpected to not include: <green>{f}<r>\nReceived: <red>{f}<r>\n", .{ substring_fmt, received_fmt }),
        1 => expect.throw(global, signature, "\n\nExpected to include: <green>{f}<r>\nReceived: <red>{f}<r>\n", .{ substring_fmt, received_fmt }),
        else => expect.throw(global, signature, "\n\nExpected to include: <green>{f}<r> <green>{f}<r> times \nReceived: <red>{f}<r>\n", .{ substring_fmt, count_fmt, received_fmt }),
    };
}

fn runEmpty(global: *JSGlobalObject, context: anytype, expect: *Expect) bun.JSError!void {
    const value = try capturedValue(expect, context, "toBeEmpty", "");
    expect.incrementExpectCallCounter();

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();

    const actual_length = try value.getLengthIfPropertyExists();
    var evidence: Core.EmptyEvidence = undefined;
    if (actual_length == null) {
        if (!value.jsTypeLoose().isObject()) {
            const signature = comptime Expect.getSignature("toBeEmpty", "", false);
            return global.throwPretty(signature ++
                "\n\nExpected value to be a string, object, or iterable" ++
                "\n\nReceived: <red>{f}<r>\n", .{value.toFmt(&formatter)});
        }
        if (try value.isIterable()) {
            var has_items = false;
            try value.forEach(&has_items, markCollectionItem);
            evidence = .{ .collection_has_items = has_items };
        } else {
            if (!value.isCell()) {
                return global.throwTypeError("Expected value to be a string, object, or iterable", .{});
            }
            const object = try context.engineIn("js_value_conversions", "jsValueToObject").call(.{
                .value = value,
            });
            var object_root = try object.eraseBrandToEngineRoot();
            defer object_root.deinit();
            var properties = try bun.jsc.JSPropertyIterator(.{
                .skip_empty_name = false,
                .own_properties_only = false,
            }).init(context, &object_root);
            defer properties.deinit();
            evidence = .{ .collection_has_items = properties.len != 0 };
        }
    } else if (std.math.isNan(actual_length.?)) {
        return global.throw("Received value has non-number length property: {}", .{actual_length.?});
    } else {
        evidence = .{ .length = actual_length.? };
    }

    if (Core.passes(Core.emptyMatches(evidence), expect.flags.not)) return;
    const received = value.toFmt(&formatter);
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature("toBeEmpty", "", true);
        return expect.throw(global, signature, "\n\nExpected value <b>not<r> to be empty\n\nReceived: <red>{f}<r>\n", .{received});
    }
    const signature = comptime Expect.getSignature("toBeEmpty", "", false);
    return expect.throw(global, signature, "\n\nExpected value to be empty\n\nReceived: <red>{f}<r>\n", .{received});
}

fn runEmptyObject(global: *JSGlobalObject, context: anytype, expect: *Expect) bun.JSError!void {
    const value = try capturedValue(expect, context, "toBeEmptyObject", "");
    expect.incrementExpectCallCounter();
    if (Core.passes(try value.isObjectEmpty(), expect.flags.not)) return;

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const received = value.toFmt(&formatter);
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature("toBeEmptyObject", "", true);
        return expect.throw(global, signature, "\n\nReceived: <red>{f}<r>\n", .{received});
    }
    const signature = comptime Expect.getSignature("toBeEmptyObject", "", false);
    return expect.throw(global, signature, "\n\nReceived: <red>{f}<r>\n", .{received});
}

fn runInstanceOf(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    constructor_view: anytype,
) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const constructor = constructor_view.operand(context).asEngine();
    const value = try capturedValue(expect, context, "toBeInstanceOf", "<green>expected<r>");
    if (Core.passes(try value.isInstanceOf(constructor), expect.flags.not)) return;

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const expected_fmt = constructor.toFmt(&formatter);
    const value_fmt = value.toFmt(&formatter);
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature("toBeInstanceOf", "<green>expected<r>", true);
        return expect.throw(global, signature, "\n\nExpected constructor: not <green>{f}<r>\nReceived value: <red>{f}<r>\n", .{ expected_fmt, value_fmt });
    }
    const signature = comptime Expect.getSignature("toBeInstanceOf", "<green>expected<r>", false);
    return expect.throw(global, signature, "\n\nExpected constructor: <green>{f}<r>\nReceived value: <red>{f}<r>\n", .{ expected_fmt, value_fmt });
}

fn runOneOf(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    values_view: anytype,
) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const received = try capturedValue(expect, context, "toBeOneOf", "<green>expected<r>");
    const values = values_view.operand(context).asEngine();
    var matched = false;

    if (values.jsTypeLoose().isArrayLike()) {
        var iterator = try values.arrayIterator();
        defer iterator.deinit();
        while (try iterator.next(context)) |item_result| {
            if (try context.engineIn("js_value_inspection", "jsValueJestDeepEquals").call(.{ .input = .{
                .left = item_result.operand(context),
                .right = received,
            } })) {
                matched = true;
                break;
            }
        }
    } else if (try values.isIterable()) {
        var state = OneOfState{ .received = received, .matched = &matched };
        try values.forEach(&state, matchCollectionItem);
    } else {
        return global.throw("Received value must be an array type, or both received and expected values must be strings.", .{});
    }

    if (Core.passes(matched, expect.flags.not)) return;
    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const values_fmt = values.toFmt(&formatter);
    const received_fmt = received.toFmt(&formatter);
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature("toBeOneOf", "<green>expected<r>", true);
        return expect.throw(global, signature, "\n\nExpected to not be one of: <green>{f}<r>\nReceived: <red>{f}<r>\n", .{ values_fmt, received_fmt });
    }
    const signature = comptime Expect.getSignature("toBeOneOf", "<green>expected<r>", false);
    return expect.throw(global, signature, "\n\nExpected to be one of: <green>{f}<r>\nReceived: <red>{f}<r>\n", .{ values_fmt, received_fmt });
}

fn runTypeOf(global: *JSGlobalObject, context: anytype, expect: *Expect, expected_tag: anytype) bun.JSError!void {
    const value = try capturedValue(expect, context, "toBeTypeOf", "");
    expect.incrementExpectCallCounter();
    const expected = expectedJavaScriptType(expected_tag);
    const actual = try actualJavaScriptType(global, value);
    if (Core.passes(Core.typeMatches(actual, expected), expect.flags.not)) return;

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const received = value.toFmt(&formatter);
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature("toBeTypeOf", "", true);
        return expect.throw(global, signature, "\n\nExpected type: not <green>\"{s}\"<r>\nReceived type: <red>\"{s}\"<r>\nReceived value: <red>{f}<r>\n", .{ expected.name(), actual.name(), received });
    }
    const signature = comptime Expect.getSignature("toBeTypeOf", "", false);
    return expect.throw(global, signature, "\n\nExpected type: <green>\"{s}\"<r>\nReceived type: <red>\"{s}\"<r>\nReceived value: <red>{f}<r>\n", .{ expected.name(), actual.name(), received });
}

fn runHaveLength(global: *JSGlobalObject, context: anytype, expect: *Expect, expected: u64) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const value = try capturedValue(expect, context, "toHaveLength", "<green>expected<r>");
    if (!value.isObject() and !value.isString()) {
        var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
        defer formatter.deinit();
        return global.throw("Received value does not have a length property: {f}", .{value.toFmt(&formatter)});
    }

    const actual = (try value.getLengthIfPropertyExists()) orelse {
        var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
        defer formatter.deinit();
        return global.throw("Received value does not have a length property: {f}", .{value.toFmt(&formatter)});
    };
    if (std.math.isNan(actual)) {
        return global.throw("Received value has non-number length property: {}", .{actual});
    }
    if (Core.passes(Core.lengthMatches(actual, expected), expect.flags.not)) return;

    if (expect.flags.not) {
        const signature = comptime Expect.getSignature("toHaveLength", "<green>expected<r>", true);
        return expect.throw(global, signature, "\n\nExpected length: not <green>{d}<r>\n", .{expected});
    }
    const signature = comptime Expect.getSignature("toHaveLength", "<green>expected<r>", false);
    return expect.throw(global, signature, "\n\nExpected length: <green>{d}<r>\nReceived length: <red>{d}<r>\n", .{ expected, actual });
}

fn runToBe(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    expected_view: anytype,
) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const expected = expected_view.operand(context).asEngine();
    const received = try capturedValue(expect, context, "toBe", "<green>expected<r>");
    if (Core.passes(try expected.isSameValue(received), expect.flags.not)) return;

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature("toBe", "<green>expected<r>", true);
        return expect.throw(global, signature, "\n\nExpected: not <green>{f}<r>\n", .{expected.toFmt(&formatter)});
    }

    const signature = comptime Expect.getSignature("toBe", "<green>expected<r>", false);
    if (try received.deepEquals(expected) or try received.strictDeepEquals(expected)) {
        if (expect.custom_label.isEmpty()) {
            return expect.throw(global, signature, "\n\n<d>If this test should pass, replace \"toBe\" with \"toEqual\" or \"toStrictEqual\"<r>\n\nExpected: <green>{f}<r>\nReceived: serializes to the same string\n", .{expected.toFmt(&formatter)});
        }
        return expect.throw(global, signature, "\n\nExpected: <green>{f}<r>\nReceived: serializes to the same string\n", .{expected.toFmt(&formatter)});
    }
    if (expected.isString() and received.isString()) {
        const diff = DiffFormatter{ .expected = expected, .received = received, .globalThis = global, .not = false };
        return expect.throw(global, signature, "\n\n{f}\n", .{diff});
    }
    return expect.throw(global, signature, "\n\nExpected: <green>{f}<r>\nReceived: <red>{f}<r>\n", .{
        expected.toFmt(&formatter),
        received.toFmt(&formatter),
    });
}

fn runDeepEquality(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    expected_view: anytype,
    comptime matcher: Core.Matcher,
) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const expected = expected_view.operand(context).asEngine();
    const received = try capturedValue(expect, context, matcher.name(), "<green>expected<r>");
    const matched = switch (matcher) {
        .toEqual => try received.jestDeepEquals(expected),
        .toStrictEqual => try received.jestStrictDeepEquals(expected),
        else => @compileError("non-equality matcher passed to deep equality evaluator"),
    };
    if (Core.passes(matched, expect.flags.not)) return;

    const diff = DiffFormatter{
        .received = received,
        .expected = expected,
        .globalThis = global,
        .not = expect.flags.not,
    };
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature(matcher.name(), "<green>expected<r>", true);
        return expect.throw(global, signature, "\n\n{f}\n", .{diff});
    }
    const signature = comptime Expect.getSignature(matcher.name(), "<green>expected<r>", false);
    return expect.throw(global, signature, "\n\n{f}\n", .{diff});
}

fn runMatchObject(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    expected_view: anytype,
) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const expected = expected_view.operand(context).asEngine();
    const received = try capturedValue(expect, context, "toMatchObject", "<green>expected<r>");
    if (!received.isObject()) {
        const matcher_error = "\n\n<b>Matcher error<r>: <red>received<r> value must be a non-null object\n";
        if (expect.flags.not) {
            const signature = comptime Expect.getSignature("toMatchObject", "<green>expected<r>", true);
            return expect.throw(global, signature, matcher_error, .{});
        }
        const signature = comptime Expect.getSignature("toMatchObject", "<green>expected<r>", false);
        return expect.throw(global, signature, matcher_error, .{});
    }

    if (Core.passes(try received.jestDeepMatch(expected, true), expect.flags.not)) return;
    const diff = DiffFormatter{
        .received = received,
        .expected = expected,
        .globalThis = global,
        .not = expect.flags.not,
    };
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature("toMatchObject", "<green>expected<r>", true);
        return expect.throw(global, signature, "\n\n{f}\n", .{diff});
    }
    const signature = comptime Expect.getSignature("toMatchObject", "<green>expected<r>", false);
    return expect.throw(global, signature, "\n\n{f}\n", .{diff});
}

fn runMatch(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    expected_view: anytype,
) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const expected = expected_view.operand(context).asEngine();
    const received = try capturedValue(expect, context, "toMatch", "<green>expected<r>");
    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    if (!received.isString()) {
        return global.throw("Received value must be a string: {f}", .{received.toFmt(&formatter)});
    }

    const matched = if (expected.isString())
        try received.stringIncludes(expected)
    else
        try expected.toMatch(received);
    if (Core.passes(matched, expect.flags.not)) return;

    const expected_fmt = expected.toFmt(&formatter);
    const received_fmt = received.toFmt(&formatter);
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature("toMatch", "<green>expected<r>", true);
        return expect.throw(global, signature, "\n\nExpected substring or pattern: not <green>{f}<r>\nReceived: <red>{f}<r>\n", .{ expected_fmt, received_fmt });
    }
    const signature = comptime Expect.getSignature("toMatch", "<green>expected<r>", false);
    return expect.throw(global, signature, "\n\nExpected substring or pattern: <green>{f}<r>\nReceived: <red>{f}<r>\n", .{ expected_fmt, received_fmt });
}

fn runSatisfy(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    predicate_view: anytype,
) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const predicate = predicate_view.operand(context).asEngine();
    const received = try capturedValue(expect, context, "toSatisfy", "<green>expected<r>");
    const result = predicate.call(BindingEscape.borrowEngineValue(context, .js_undefined).asAny(), &.{received.asAny()}) catch |err| {
        const exception = try context.takeThrownException(err);
        var exception_root = try exception.toRoot();
        defer exception_root.deinit();
        var message = try bindgen.DOMString.fromUTF8("toSatisfy() predicate threw an exception");
        defer message.deinit();
        const aggregate = try context.engineIn("errors", "createAggregateError").call(.{
            .errors = &.{exception_root.operand(context)},
            .message = message.operand(),
        });
        return aggregate.throwException(context);
    };
    const matched = result.isBoolean() and result.toBoolean();
    if (Core.passes(matched, expect.flags.not)) return;

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature("toSatisfy", "<green>expected<r>", true);
        return expect.throw(global, signature, "\n\nExpected: not <green>{f}<r>\n", .{predicate.toFmt(&formatter)});
    }
    const signature = comptime Expect.getSignature("toSatisfy", "<green>expected<r>", false);
    return expect.throw(global, signature, "\n\nExpected: <green>{f}<r>\nReceived: <red>{f}<r>\n", .{
        predicate.toFmt(&formatter),
        received.toFmt(&formatter),
    });
}

fn runHaveProperty(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    path_view: anytype,
    expected_view: anytype,
) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const path = switch (path_view) {
        inline else => |view| view.operand(context).asEngine(),
    };
    const expected: ?JSValue = if (expected_view) |view|
        view.operand(context).asEngine()
    else
        null;
    const received = try capturedValue(expect, context, "toHaveProperty", "<green>path<r><d>, <r><green>value<r>");

    var property: ?bindgen.EngineValueResult = null;
    if (!received.isUndefinedOrNull()) {
        property = try context.engineIn("property_accessors", "jsValueGetIfPropertyExistsFromPath").call(.{
            .value = received,
            .path = switch (path_view) {
                .string => .{ .string = path },
                .array => .{ .array = path },
            },
        });
    }
    const matched = if (property) |actual|
        if (expected) |wanted| try context.engineIn("js_value_inspection", "jsValueJestDeepEquals").call(.{ .input = .{
            .left = actual.operand(context),
            .right = wanted,
        } }) else true
    else
        false;
    if (Core.passes(matched, expect.flags.not)) return;

    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    if (expect.flags.not) {
        if (expected) |wanted| {
            if (property != null) {
                const signature = comptime Expect.getSignature("toHaveProperty", "<green>path<r><d>, <r><green>value<r>", true);
                return expect.throw(global, signature, "\n\nExpected path: <green>{f}<r>\n\nExpected value: not <green>{f}<r>\n", .{
                    path.toFmt(&formatter),
                    wanted.toFmt(&formatter),
                });
            }
        }
        const signature = comptime Expect.getSignature("toHaveProperty", "<green>path<r>", true);
        return expect.throw(global, signature, "\n\nExpected path: not <green>{f}<r>\n\nReceived value: <red>{f}<r>\n", .{
            path.toFmt(&formatter),
            formatter.toScopedFmt(context, property.?.operand(context).engineView()),
        });
    }

    if (expected) |wanted| {
        const signature = comptime Expect.getSignature("toHaveProperty", "<green>path<r><d>, <r><green>value<r>", false);
        if (property) |actual| {
            const diff = DiffFormatter{ .received = actual.operand(context).asEngine(), .expected = wanted, .globalThis = global };
            return expect.throw(global, signature, "\n\n{f}\n", .{diff});
        }
        return expect.throw(global, signature, "\n\nExpected path: <green>{f}<r>\n\nExpected value: <green>{f}<r>\n\nUnable to find property\n", .{
            path.toFmt(&formatter),
            wanted.toFmt(&formatter),
        });
    }

    const signature = comptime Expect.getSignature("toHaveProperty", "<green>path<r>", false);
    return expect.throw(global, signature, "\n\nExpected path: <green>{f}<r>\n\nUnable to find property\n", .{path.toFmt(&formatter)});
}

fn runContain(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    expected_view: anytype,
    comptime deep: bool,
) bun.JSError!void {
    const matcher: Core.Matcher = if (deep) .toContainEqual else .toContain;
    expect.incrementExpectCallCounter();
    const expected = expected_view.operand(context).asEngine();
    const received = try capturedValue(expect, context, matcher.name(), "<green>expected<r>");
    var matched = false;

    if (received.jsTypeLoose().isArrayLike()) {
        var iterator = try received.arrayIterator();
        defer iterator.deinit();
        while (try iterator.next(context)) |item_result| {
            const equal = if (deep)
                try context.engineIn("js_value_inspection", "jsValueJestDeepEquals").call(.{ .input = .{
                    .left = item_result.operand(context),
                    .right = expected,
                } })
            else
                try context.engineIn("js_value_inspection", "jsValueSameValue").call(.{ .operands = .{
                    .left = item_result.operand(context),
                    .right = expected,
                } });
            if (equal) {
                matched = true;
                break;
            }
        }
    } else if (deep and received.jsType().isStringLike() and expected.jsType().isStringLike()) {
        if (!expected.jsType().isStringObjectLike() or !received.jsType().isString()) {
            const received_string = try received.toSliceOrNull();
            defer received_string.deinit();
            const expected_string = try expected.toSliceOrNull();
            defer expected_string.deinit();
            matched = Core.containsEqualString(received_string.slice(), expected_string.slice());
        }
    } else if (!deep and received.isStringLiteral() and expected.isStringLiteral()) {
        const received_string = try received.toSliceOrNull();
        defer received_string.deinit();
        const expected_string = try expected.toSliceOrNull();
        defer expected_string.deinit();
        matched = Core.stringMatches(.toInclude, received_string.slice(), expected_string.slice());
    } else if (try received.isIterable()) {
        var state = CollectionSearchState{
            .expected = expected,
            .matched = &matched,
            .comparison = if (deep) .deep else .same_value,
        };
        try received.forEach(&state, matchCollectionValue);
    } else {
        return global.throw("Received value must be an array type, or both received and expected values must be strings.", .{});
    }

    if (Core.passes(matched, expect.flags.not)) return;
    return throwCollectionFailure(context, expect, matcher, expected, received);
}

fn runContainKey(
    global: *JSGlobalObject,
    context: anytype,
    expect: *Expect,
    expected_view: anytype,
) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const expected = expected_view.operand(context).asEngine();
    const received = try capturedValue(expect, context, "toContainKey", "<green>expected<r>");
    if (!received.isObject()) {
        var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
        defer formatter.deinit();
        return global.throwInvalidArguments("Expected value must be an object\nReceived: {f}", .{received.toFmt(&formatter)});
    }

    if (Core.passes(try received.hasOwnPropertyValue(expected), expect.flags.not)) return;
    return throwCollectionFailure(context, expect, .toContainKey, expected, received);
}

fn runKeyCollection(
    context: anytype,
    expect: *Expect,
    expected_view: anytype,
    comptime matcher: Core.Matcher,
) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const expected = expected_view.operand(context).asEngine();
    const received = try capturedValue(expect, context, matcher.name(), "<green>expected<r>");
    const expected_count: u32 = @intCast(try expected.getLength());
    var display_received = received;
    const matched = switch (matcher) {
        .toContainKeys, .toContainAnyKeys => blk: {
            var matched_count: u32 = 0;
            if (received.isObject()) {
                var index: u32 = 0;
                while (index < expected_count) : (index += 1) {
                    if (try received.hasOwnPropertyValue(try expected.getIndex(index))) {
                        matched_count += 1;
                    }
                }
            }
            const requirement: Core.CollectionRequirement = if (matcher == .toContainAnyKeys) .any else .all;
            break :blk Core.collectionMatches(requirement, 0, expected_count, matched_count);
        },
        .toContainAllKeys => blk: {
            const actual_keys = try context.engineIn("property_accessors", "jsValueKeys").call(.{ .value = received });
            display_received = actual_keys.operand(context).asEngine();
            const actual_count: u32 = @intCast(try context.engineIn("property_accessors", "jsValueGetIndexedLength").call(.{ .value = actual_keys.operand(context).asEngine() }));
            var matched_count: u32 = 0;
            var actual_index: u32 = 0;
            while (actual_index < actual_count) : (actual_index += 1) {
                const actual_key = try context.engineIn("property_accessors", "jsValueGetIndex").call(.{ .value = actual_keys.operand(context).asEngine(), .index = actual_index });
                var expected_index: u32 = 0;
                while (expected_index < expected_count) : (expected_index += 1) {
                    const expected_key = try context.engineIn("property_accessors", "jsValueGetIndex").call(.{ .value = expected, .index = expected_index });
                    if (try context.engineIn("js_value_inspection", "jsValueJestDeepEquals").call(.{ .input = .{ .left = actual_key.operand(context), .right = expected_key.operand(context) } })) {
                        matched_count += 1;
                        break;
                    }
                }
            }
            break :blk Core.collectionMatches(.exact, actual_count, expected_count, matched_count);
        },
        else => @compileError("non-key matcher passed to key collection evaluator"),
    };

    if (Core.passes(matched, expect.flags.not)) return;
    return throwCollectionFailure(context, expect, matcher, expected, display_received);
}

fn runContainValue(
    context: anytype,
    expect: *Expect,
    expected_view: anytype,
) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const expected = expected_view.operand(context).asEngine();
    const received = try capturedValue(expect, context, "toContainValue", "<green>expected<r>");
    var matched = false;
    if (!received.isUndefinedOrNull()) {
        const values = try context.engineIn("property_accessors", "jsValueValues").call(.{ .value = received });
        const count: u32 = @intCast(try context.engineIn("property_accessors", "jsValueGetIndexedLength").call(.{ .value = values.operand(context).asEngine() }));
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            const item = try context.engineIn("property_accessors", "jsValueGetIndex").call(.{ .value = values.operand(context).asEngine(), .index = index });
            if (try context.engineIn("js_value_inspection", "jsValueJestDeepEquals").call(.{ .input = .{ .left = item.operand(context), .right = expected } })) {
                matched = true;
                break;
            }
        }
    }
    if (Core.passes(matched, expect.flags.not)) return;
    return throwCollectionFailure(context, expect, .toContainValue, expected, received);
}

fn runValueCollection(
    context: anytype,
    expect: *Expect,
    expected_view: anytype,
    comptime matcher: Core.Matcher,
) bun.JSError!void {
    expect.incrementExpectCallCounter();
    const expected = expected_view.operand(context).asEngine();
    const received = try capturedValue(expect, context, matcher.name(), "<green>expected<r>");
    const expected_count: u32 = @intCast(try expected.getLength());
    var actual_count: u32 = 0;
    var matched_count: u32 = 0;
    if (!received.isUndefinedOrNull()) {
        const values = try context.engineIn("property_accessors", "jsValueValues").call(.{ .value = received });
        actual_count = @intCast(try context.engineIn("property_accessors", "jsValueGetIndexedLength").call(.{ .value = values.operand(context).asEngine() }));
        var expected_index: u32 = 0;
        while (expected_index < expected_count) : (expected_index += 1) {
            const expected_value = try context.engineIn("property_accessors", "jsValueGetIndex").call(.{ .value = expected, .index = expected_index });
            var actual_index: u32 = 0;
            while (actual_index < actual_count) : (actual_index += 1) {
                const item = try context.engineIn("property_accessors", "jsValueGetIndex").call(.{ .value = values.operand(context).asEngine(), .index = actual_index });
                if (try context.engineIn("js_value_inspection", "jsValueJestDeepEquals").call(.{ .input = .{ .left = item.operand(context), .right = expected_value.operand(context) } })) {
                    matched_count += 1;
                    break;
                }
            }
        }
    }

    const requirement: Core.CollectionRequirement = switch (matcher) {
        .toContainAnyValues => .any,
        .toContainValues => .all,
        .toContainAllValues => .exact,
        else => @compileError("non-value matcher passed to value collection evaluator"),
    };
    if (Core.passes(Core.collectionMatches(requirement, actual_count, expected_count, matched_count), expect.flags.not)) return;
    return throwCollectionFailure(context, expect, matcher, expected, received);
}

fn throwCollectionFailure(
    scope: anytype,
    expect: *Expect,
    comptime matcher: Core.Matcher,
    expected: bindgen.EngineOperand,
    received: bindgen.EngineOperand,
) bun.JSError {
    const global = scope.viewToken().globalObject();
    var formatter = bun.jsc.ConsoleObject.Formatter{ .globalThis = global, .quote_strings = true };
    defer formatter.deinit();
    const expected_fmt = formatter.toScopedFmt(scope, expected.engineView());
    const received_fmt = formatter.toScopedFmt(scope, received.engineView());
    if (expect.flags.not) {
        const signature = comptime Expect.getSignature(matcher.name(), "<green>expected<r>", true);
        return expect.throw(global, signature, "\n\nExpected to not {s}: <green>{f}<r>\nReceived: <red>{f}<r>\n", .{ collectionPhrase(matcher), expected_fmt, received_fmt });
    }
    const signature = comptime Expect.getSignature(matcher.name(), "<green>expected<r>", false);
    return expect.throw(global, signature, "\n\nExpected to {s}: <green>{f}<r>\nReceived: <red>{f}<r>\n", .{ collectionPhrase(matcher), expected_fmt, received_fmt });
}

fn collectionPhrase(comptime matcher: Core.Matcher) []const u8 {
    return switch (matcher) {
        .toContain, .toContainEqual, .toContainKey, .toContainKeys, .toContainValue, .toContainValues => "contain",
        .toContainAllKeys => "contain all keys",
        .toContainAnyKeys => "contain any key",
        .toContainAllValues => "contain all values",
        .toContainAnyValues => "contain any of the following values",
        else => @compileError("non-collection matcher has no collection phrase"),
    };
}

fn expectedJavaScriptType(expected: anytype) Core.JavaScriptType {
    return switch (expected) {
        .function => .callable,
        .object => .object,
        .bigint => .bigint,
        .boolean => .boolean,
        .number => .number,
        .string => .string,
        .symbol => .symbol,
        .undefined => .undefined_value,
    };
}

fn actualJavaScriptType(global: *JSGlobalObject, value: JSValue) bun.JSError!Core.JavaScriptType {
    if (value.isCallable()) return .callable;
    if (value.isObject() or value.jsType().isArray() or value.isNull()) return .object;
    if (value.isBigInt()) return .bigint;
    if (value.isBoolean()) return .boolean;
    if (value.isNumber()) return .number;
    if (value.jsType().isString()) return .string;
    if (value.isSymbol()) return .symbol;
    if (value.isUndefined()) return .undefined_value;
    return global.throw("Internal consistency error: unknown JSValue type", .{});
}

fn markCollectionItem(_: *bun.jsc.VM, _: *JSGlobalObject, has_items: *bool, _: JSValue) void {
    has_items.* = true;
}

const OneOfState = struct {
    received: JSValue,
    matched: *bool,
};

fn matchCollectionItem(_: *bun.jsc.VM, _: *JSGlobalObject, state: *OneOfState, item: JSValue) void {
    if (item.jestDeepEquals(state.received) catch return) state.matched.* = true;
}

const CollectionComparison = enum { same_value, deep };

const CollectionSearchState = struct {
    expected: JSValue,
    matched: *bool,
    comparison: CollectionComparison,
};

fn matchCollectionValue(_: *bun.jsc.VM, _: *JSGlobalObject, state: *CollectionSearchState, item: JSValue) void {
    const equal = switch (state.comparison) {
        .same_value => item.isSameValue(state.expected),
        .deep => item.jestDeepEquals(state.expected),
    } catch return;
    if (equal) state.matched.* = true;
}

fn stringSignatureArguments(comptime matcher: Core.Matcher) []const u8 {
    return switch (matcher) {
        .toInclude => "",
        .toStartWith, .toEndWith, .toEqualIgnoringWhitespace => "<green>expected<r>",
        else => @compileError("non-string matcher has no string signature"),
    };
}

fn stringFailureFormat(comptime matcher: Core.Matcher, comptime negated: bool) [:0]const u8 {
    return switch (matcher) {
        .toStartWith => if (negated)
            "\n\nExpected to not start with: <green>{f}<r>\nReceived: <red>{f}<r>\n"
        else
            "\n\nExpected to start with: <green>{f}<r>\nReceived: <red>{f}<r>\n",
        .toEndWith => if (negated)
            "\n\nExpected to not end with: <green>{f}<r>\nReceived: <red>{f}<r>\n"
        else
            "\n\nExpected to end with: <green>{f}<r>\nReceived: <red>{f}<r>\n",
        .toInclude => if (negated)
            "\n\nExpected to not include: <green>{f}<r>\nReceived: <red>{f}<r>\n"
        else
            "\n\nExpected to include: <green>{f}<r>\nReceived: <red>{f}<r>\n",
        .toEqualIgnoringWhitespace => if (negated)
            "\n\nExpected: not <green>{f}<r>\nReceived: <red>{f}<r>\n"
        else
            "\n\nExpected: <green>{f}<r>\nReceived: <red>{f}<r>\n",
        else => @compileError("non-string matcher has no string failure format"),
    };
}

fn inspectSimple(comptime matcher: Core.Matcher, value: JSValue) Core.Evidence {
    return switch (matcher) {
        .toBeArray => .{ .predicate = value.jsType().isArray() },
        .toBeBoolean => .{ .predicate = value.isBoolean() },
        .toBeDate => .{ .predicate = value.isDate() },
        .toBeDefined => .{ .predicate = !value.isUndefined() },
        .toBeEven => .{ .numeric = numericForEven(value) },
        .toBeFalse => .{ .predicate = value.isBoolean() and !value.toBoolean() },
        .toBeFalsy => .{ .predicate = !value.toBoolean() },
        .toBeFinite, .toBeNaN, .toBeNegative, .toBePositive => .{
            .number = if (value.isNumber()) value.asNumber() else null,
        },
        .toBeFunction => .{ .predicate = value.isCallable() },
        .toBeInteger => .{ .predicate = value.isAnyInt() },
        .toBeNil => .{ .predicate = value.isUndefinedOrNull() },
        .toBeNull => .{ .predicate = value.isNull() },
        .toBeNumber => .{ .predicate = value.isNumber() },
        .toBeObject => .{ .predicate = value.isObject() },
        .toBeOdd => .{ .numeric = numericForOdd(value) },
        .toBeString => .{ .predicate = value.isString() },
        .toBeSymbol => .{ .predicate = value.isSymbol() },
        .toBeTrue => .{ .predicate = value.isBoolean() and value.toBoolean() },
        .toBeTruthy => .{ .predicate = value.toBoolean() },
        .toBeUndefined => .{ .predicate = value.isUndefined() },
        .toBeValidDate => .{
            .date_timestamp = if (value.isDate()) value.getUnixTimestamp() else null,
        },
        else => @compileError("argument matcher passed to simple matcher inspection"),
    };
}

fn compare(received: JSValue, expected: JSValue) Core.Ordering {
    if (!received.isBigInt() and !expected.isBigInt()) {
        const left = received.asNumber();
        const right = expected.asNumber();
        if (left < right) return .less;
        if (left > right) return .greater;
        if (left == right) return .equal;
        return .undefined_result;
    }
    if (received.isBigInt()) return comparisonOrdering(received.asBigIntCompare(expected));
    return reverseOrdering(comparisonOrdering(expected.asBigIntCompare(received)));
}

fn comparisonOrdering(ordering: JSValue.ComparisonResult) Core.Ordering {
    return switch (ordering) {
        .less_than => .less,
        .equal => .equal,
        .greater_than => .greater,
        .undefined_result, .invalid_comparison => .undefined_result,
    };
}

fn reverseOrdering(ordering: Core.Ordering) Core.Ordering {
    return switch (ordering) {
        .less => .greater,
        .equal => .equal,
        .greater => .less,
        .undefined_result => .undefined_result,
    };
}

fn comparisonFailureFormat(comptime matcher: Core.Matcher, comptime negated: bool) [:0]const u8 {
    return switch (matcher) {
        .toBeGreaterThan => if (negated)
            "\n\nExpected: not \\> <green>{f}<r>\nReceived: <red>{f}<r>\n"
        else
            "\n\nExpected: \\> <green>{f}<r>\nReceived: <red>{f}<r>\n",
        .toBeGreaterThanOrEqual => if (negated)
            "\n\nExpected: not \\>= <green>{f}<r>\nReceived: <red>{f}<r>\n"
        else
            "\n\nExpected: \\>= <green>{f}<r>\nReceived: <red>{f}<r>\n",
        .toBeLessThan => if (negated)
            "\n\nExpected: not \\< <green>{f}<r>\nReceived: <red>{f}<r>\n"
        else
            "\n\nExpected: \\< <green>{f}<r>\nReceived: <red>{f}<r>\n",
        .toBeLessThanOrEqual => if (negated)
            "\n\nExpected: not \\<= <green>{f}<r>\nReceived: <red>{f}<r>\n"
        else
            "\n\nExpected: \\<= <green>{f}<r>\nReceived: <red>{f}<r>\n",
        else => @compileError("non-comparison matcher has no failure format"),
    };
}

fn numericForEven(value: JSValue) Core.Numeric {
    if (value.isAnyInt()) return .{ .integer = value.toInt64() };
    if (value.isBigInt() or value.isBigInt32()) return .{ .big_integer = value.toInt64() };
    if (value.isNumber()) return .{ .number = value.asNumber() };
    return .other;
}

fn numericForOdd(value: JSValue) Core.Numeric {
    if (value.isBigInt32() or value.isBigInt()) return .{ .big_integer = value.toInt64() };
    if (value.isInt32() or value.isAnyInt()) return .{ .integer = value.toInt64() };
    if (value.isNumber()) return .{ .number = value.asNumber() };
    return .other;
}
