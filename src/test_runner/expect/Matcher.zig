const std = @import("std");
const math = std.math;

pub const Matcher = enum {
    fail,
    pass,
    toBe,
    toBeArray,
    toBeArrayOfSize,
    toBeBoolean,
    toBeCloseTo,
    toBeDate,
    toBeDefined,
    toBeEmpty,
    toBeEmptyObject,
    toBeEven,
    toBeFalse,
    toBeFalsy,
    toBeFinite,
    toBeFunction,
    toBeGreaterThan,
    toBeGreaterThanOrEqual,
    toBeInstanceOf,
    toBeInteger,
    toBeLessThan,
    toBeLessThanOrEqual,
    toBeNaN,
    toBeNegative,
    toBeNil,
    toBeNull,
    toBeNumber,
    toBeObject,
    toBeOdd,
    toBeOneOf,
    toBePositive,
    toBeString,
    toBeSymbol,
    toBeTrue,
    toBeTruthy,
    toBeTypeOf,
    toBeUndefined,
    toBeValidDate,
    toBeWithin,
    toContain,
    toContainAllKeys,
    toContainAllValues,
    toContainAnyKeys,
    toContainAnyValues,
    toContainEqual,
    toContainKey,
    toContainKeys,
    toContainValue,
    toContainValues,
    toEndWith,
    toEqual,
    toEqualIgnoringWhitespace,
    toHaveLength,
    toHaveBeenCalled,
    toHaveBeenCalledOnce,
    toHaveBeenCalledTimes,
    toHaveBeenCalledWith,
    toHaveBeenLastCalledWith,
    toHaveBeenNthCalledWith,
    toHaveLastReturnedWith,
    toHaveNthReturnedWith,
    toHaveProperty,
    toHaveReturned,
    toHaveReturnedTimes,
    toHaveReturnedWith,
    toInclude,
    toIncludeRepeated,
    toMatchObject,
    toMatch,
    toMatchInlineSnapshot,
    toMatchSnapshot,
    toSatisfy,
    toStartWith,
    toStrictEqual,
    toThrow,
    toThrowErrorMatchingInlineSnapshot,
    toThrowErrorMatchingSnapshot,

    pub fn fromBindingImplementation(comptime implementation: []const u8) Matcher {
        const prefix = "bind_instance_";
        if (comptime !std.mem.startsWith(u8, implementation, prefix)) {
            @compileError("simple matcher capability used by an unrelated binding member");
        }
        const member_name = implementation[prefix.len..];
        const matcher_name = comptime canonicalBindingName(member_name);
        const info = @typeInfo(Matcher).@"enum";
        inline for (info.field_names, info.field_values) |field_name, field_value| {
            if (comptime std.mem.eql(u8, matcher_name, field_name)) return @fromBackingInt(@intCast(field_value));
        }
        @compileError("simple matcher capability used by unsupported binding member '" ++ matcher_name ++ "'");
    }

    fn canonicalBindingName(comptime name_: []const u8) []const u8 {
        if (comptime std.mem.eql(u8, name_, "lastCalledWith")) return "toHaveBeenLastCalledWith";
        if (comptime std.mem.eql(u8, name_, "lastReturnedWith")) return "toHaveLastReturnedWith";
        if (comptime std.mem.eql(u8, name_, "nthCalledWith")) return "toHaveBeenNthCalledWith";
        if (comptime std.mem.eql(u8, name_, "nthReturnedWith")) return "toHaveNthReturnedWith";
        if (comptime std.mem.eql(u8, name_, "toBeCalled")) return "toHaveBeenCalled";
        if (comptime std.mem.eql(u8, name_, "toBeCalledTimes")) return "toHaveBeenCalledTimes";
        if (comptime std.mem.eql(u8, name_, "toBeCalledWith")) return "toHaveBeenCalledWith";
        if (comptime std.mem.eql(u8, name_, "toReturn")) return "toHaveReturned";
        if (comptime std.mem.eql(u8, name_, "toThrowError")) return "toThrow";
        return name_;
    }

    pub fn name(comptime matcher: Matcher) []const u8 {
        return @tagName(matcher);
    }

    pub fn failureStyle(comptime matcher: Matcher) FailureStyle {
        return switch (matcher) {
            .toBeObject => .object,
            else => .received,
        };
    }
};

pub const FailureStyle = enum {
    received,
    object,
};

pub const Numeric = union(enum) {
    integer: i64,
    big_integer: i64,
    number: f64,
    other,
};

pub const Evidence = union(enum) {
    predicate: bool,
    numeric: Numeric,
    number: ?f64,
    date_timestamp: ?f64,
};

pub fn simpleMatches(comptime matcher: Matcher, evidence: Evidence) bool {
    return switch (matcher) {
        .toBeEven => even(evidence.numeric),
        .toBeOdd => odd(evidence.numeric),
        .toBeFinite => if (evidence.number) |number| math.isFinite(number) else false,
        .toBeNaN => if (evidence.number) |number| math.isNan(number) else false,
        .toBePositive => if (evidence.number) |number|
            math.isFinite(number) and @round(number) > 0
        else
            false,
        .toBeNegative => if (evidence.number) |number|
            math.isFinite(number) and @round(number) < 0
        else
            false,
        .toBeValidDate => if (evidence.date_timestamp) |timestamp| !math.isNan(timestamp) else false,
        .toBeArray,
        .toBeBoolean,
        .toBeDate,
        .toBeDefined,
        .toBeFalse,
        .toBeFalsy,
        .toBeFunction,
        .toBeInteger,
        .toBeNil,
        .toBeNull,
        .toBeNumber,
        .toBeObject,
        .toBeString,
        .toBeSymbol,
        .toBeTrue,
        .toBeTruthy,
        .toBeUndefined,
        => evidence.predicate,
        else => @compileError("argument matcher passed to simple matcher evaluator"),
    };
}

pub fn simplePasses(comptime matcher: Matcher, evidence: Evidence, negated: bool) bool {
    return passes(simpleMatches(matcher, evidence), negated);
}

pub fn passes(matched: bool, negated: bool) bool {
    return matched != negated;
}

pub fn arrayHasSize(actual: ?u64, expected: i64) bool {
    const length = actual orelse return false;
    return expected >= 0 and length == @as(u64, @intCast(expected));
}

pub const CloseResult = struct {
    matched: bool,
    expected_difference: f64,
    actual_difference: f64,
};

pub fn closeTo(received_value: f64, expected_value: f64, precision: f64) CloseResult {
    const expected_difference = math.pow(f64, 10, -precision) / 2;
    const actual_difference = @abs(received_value - expected_value);
    return .{
        .matched = (math.isInf(received_value) and received_value == expected_value) or
            actual_difference < expected_difference,
        .expected_difference = expected_difference,
        .actual_difference = actual_difference,
    };
}

pub const Ordering = enum {
    less,
    equal,
    greater,
    undefined_result,
};

pub fn comparisonMatches(comptime matcher: Matcher, ordering: Ordering) bool {
    return switch (matcher) {
        .toBeGreaterThan => ordering == .greater,
        .toBeGreaterThanOrEqual => ordering == .greater or ordering == .equal,
        .toBeLessThan => ordering == .less,
        .toBeLessThanOrEqual => ordering == .less or ordering == .equal,
        else => @compileError("non-comparison matcher passed to comparison evaluator"),
    };
}

pub fn comparisonOperator(comptime matcher: Matcher) []const u8 {
    return switch (matcher) {
        .toBeGreaterThan => ">",
        .toBeGreaterThanOrEqual => ">=",
        .toBeLessThan => "<",
        .toBeLessThanOrEqual => "<=",
        else => @compileError("non-comparison matcher has no comparison operator"),
    };
}

pub fn within(received: ?f64, start: f64, end: f64) bool {
    const value = received orelse return false;
    return value >= start and value < end;
}

pub fn stringMatches(comptime matcher: Matcher, received: []const u8, expected: []const u8) bool {
    return switch (matcher) {
        .toStartWith => std.mem.startsWith(u8, received, expected),
        .toEndWith => std.mem.endsWith(u8, received, expected),
        .toInclude => std.mem.indexOf(u8, received, expected) != null,
        .toEqualIgnoringWhitespace => equalIgnoringWhitespace(received, expected),
        else => @compileError("non-string matcher passed to string evaluator"),
    };
}

pub fn includeRepeated(received: []const u8, substring: []const u8, expected_count: u32) bool {
    return std.mem.count(u8, received, substring) == expected_count;
}

pub const JavaScriptType = enum {
    callable,
    object,
    bigint,
    boolean,
    number,
    string,
    symbol,
    undefined_value,

    pub fn name(value: JavaScriptType) []const u8 {
        return switch (value) {
            .callable => "function",
            .object => "object",
            .bigint => "bigint",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .symbol => "symbol",
            .undefined_value => "undefined",
        };
    }
};

pub fn typeMatches(actual: JavaScriptType, expected: JavaScriptType) bool {
    return actual == expected;
}

pub const EmptyEvidence = union(enum) {
    length: f64,
    collection_has_items: bool,
};

pub fn emptyMatches(evidence: EmptyEvidence) bool {
    return switch (evidence) {
        .length => |length| length == 0,
        .collection_has_items => |has_items| !has_items,
    };
}

pub fn lengthMatches(actual: f64, expected: u64) bool {
    return actual == @as(f64, @floatFromInt(expected));
}

pub const CollectionRequirement = enum {
    any,
    all,
    exact,
};

pub fn collectionMatches(
    requirement: CollectionRequirement,
    actual_count: u32,
    expected_count: u32,
    matched_count: u32,
) bool {
    return switch (requirement) {
        .any => matched_count != 0,
        .all => matched_count == expected_count,
        .exact => actual_count == expected_count and matched_count == expected_count,
    };
}

pub const CountExpectation = union(enum) {
    at_least: u32,
    exactly: u32,
};

pub fn countMatches(actual: u32, expected: CountExpectation) bool {
    return switch (expected) {
        .at_least => |minimum| actual >= minimum,
        .exactly => |count| actual == count,
    };
}

pub fn containsEqualString(received: []const u8, expected: []const u8) bool {
    if (!isSingleUtf8Sequence(expected)) return false;
    return std.mem.indexOf(u8, received, expected) != null;
}

fn isSingleUtf8Sequence(value: []const u8) bool {
    if (value.len == 0) return false;
    const sequence_length = std.unicode.utf8ByteSequenceLength(value[0]) catch return false;
    return sequence_length == value.len;
}

fn equalIgnoringWhitespace(received: []const u8, expected: []const u8) bool {
    var received_index: usize = 0;
    var expected_index: usize = 0;

    while (received_index < received.len and std.ascii.isWhitespace(received[received_index])) received_index += 1;
    while (expected_index < expected.len and std.ascii.isWhitespace(expected[expected_index])) expected_index += 1;

    while (received_index < received.len and expected_index < expected.len) {
        if (received[received_index] != expected[expected_index]) return false;
        received_index += 1;
        expected_index += 1;
        while (received_index < received.len and std.ascii.isWhitespace(received[received_index])) received_index += 1;
        while (expected_index < expected.len and std.ascii.isWhitespace(expected[expected_index])) expected_index += 1;
    }

    return received_index == received.len and expected_index == expected.len;
}

fn even(numeric: Numeric) bool {
    return switch (numeric) {
        .integer => |value| @mod(value, 2) == 0,
        .big_integer => |value| value & 1 == 0,
        .number => |value| math.isFinite(value) and @mod(value, 1) == 0 and @mod(value, 2) == 0,
        .other => false,
    };
}

fn odd(numeric: Numeric) bool {
    return switch (numeric) {
        .integer => |value| @mod(value, 2) == 1,
        .big_integer => |value| value & 1 == 1,
        .number => |value| math.isFinite(value) and @mod(value, 1) == 0 and @mod(value, 2) == 1,
        .other => false,
    };
}

test "binding implementation names select exact matchers" {
    try std.testing.expectEqual(
        Matcher.toBeGreaterThanOrEqual,
        Matcher.fromBindingImplementation("bind_instance_toBeGreaterThanOrEqual"),
    );
}

test "matcher decisions are VM independent" {
    try std.testing.expect(simpleMatches(.toBeEven, .{ .numeric = .{ .integer = -4 } }));
    try std.testing.expect(simpleMatches(.toBeOdd, .{ .numeric = .{ .big_integer = -3 } }));
    try std.testing.expect(comparisonMatches(.toBeLessThanOrEqual, .equal));
    try std.testing.expect(within(3, 2, 4));
    try std.testing.expect(!within(4, 2, 4));
    try std.testing.expect(closeTo(math.inf(f64), math.inf(f64), 2).matched);
    try std.testing.expect(closeTo(-math.inf(f64), -math.inf(f64), 2).matched);
    try std.testing.expect(!closeTo(math.inf(f64), -math.inf(f64), 2).matched);
    try std.testing.expect(!closeTo(-math.inf(f64), math.inf(f64), 2).matched);
    try std.testing.expect(!closeTo(math.nan(f64), math.nan(f64), 2).matched);
    try std.testing.expect(!closeTo(1.3, 1, 0.5).matched);
    try std.testing.expect(stringMatches(.toStartWith, "prefix-value", "prefix"));
    try std.testing.expect(stringMatches(.toEndWith, "value-suffix", "suffix"));
    try std.testing.expect(stringMatches(.toInclude, "contains a value", "a value"));
    try std.testing.expect(stringMatches(.toEqualIgnoringWhitespace, " a\tb\n c ", "abc"));
    try std.testing.expect(includeRepeated("one one", "one", 2));
    try std.testing.expect(typeMatches(.callable, .callable));
    try std.testing.expect(emptyMatches(.{ .length = 0 }));
    try std.testing.expect(!emptyMatches(.{ .collection_has_items = true }));
    try std.testing.expect(lengthMatches(3, 3));
    try std.testing.expect(collectionMatches(.any, 3, 2, 1));
    try std.testing.expect(collectionMatches(.all, 3, 2, 2));
    try std.testing.expect(!collectionMatches(.exact, 3, 2, 2));
    try std.testing.expect(containsEqualString("abc", "b"));
    try std.testing.expect(containsEqualString("a😀c", "😀"));
    try std.testing.expect(!containsEqualString("abc", "bc"));
    try std.testing.expect(countMatches(2, .{ .at_least = 1 }));
    try std.testing.expect(countMatches(2, .{ .exactly = 2 }));
}
