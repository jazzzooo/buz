/// https://github.com/pnpm/pnpm/blob/3abd3946237aa6ba7831552310ec371ddd3616c2/config/matcher/src/index.ts
const PnpmMatcher = @This();

matchers: []const Matcher,
behavior: Behavior,

const Matcher = struct {
    pattern: []const u8,
    is_exclude: bool,
};

const Behavior = enum {
    all_matchers_include,
    all_matchers_exclude,
    has_exclude_and_include_matchers,
};

const FromExprError = OOM || error{UnexpectedExpr};

pub fn fromExpr(allocator: std.mem.Allocator, expr: ast.Expr, log: *logger.Log, source: *const logger.Source) FromExprError!PnpmMatcher {
    var matchers: collections.ArrayListDefault(Matcher) = .init();

    var has_include = false;
    var has_exclude = false;

    switch (expr.data) {
        .e_string => {
            const pattern = (try expr.asStringCloned(allocator)).?;
            const matcher = createMatcher(pattern);
            has_include = has_include or !matcher.is_exclude;
            has_exclude = has_exclude or matcher.is_exclude;
            try matchers.append(matcher);
        },
        .e_array => |patterns| {
            for (patterns.slice()) |pattern_expr| {
                if (try pattern_expr.asStringCloned(allocator)) |pattern| {
                    const matcher = createMatcher(pattern);
                    has_include = has_include or !matcher.is_exclude;
                    has_exclude = has_exclude or matcher.is_exclude;
                    try matchers.append(matcher);
                } else {
                    try log.addErrorOpts("Expected a string", .{
                        .loc = pattern_expr.loc,
                        .redact_sensitive_information = true,
                        .source = source,
                    });
                    return error.UnexpectedExpr;
                }
            }
        },
        else => {
            try log.addErrorOpts("Expected a string or an array of strings", .{
                .loc = expr.loc,
                .redact_sensitive_information = true,
                .source = source,
            });
            return error.UnexpectedExpr;
        },
    }

    const behavior: Behavior = if (!has_include)
        .all_matchers_exclude
    else if (!has_exclude)
        .all_matchers_include
    else
        .has_exclude_and_include_matchers;

    return .{
        .matchers = try matchers.toOwnedSlice(),
        .behavior = behavior,
    };
}

fn createMatcher(raw: []const u8) Matcher {
    var trimmed = strings.trim(raw, &strings.whitespace_chars);

    var is_exclude = false;
    if (strings.startsWithChar(trimmed, '!')) {
        is_exclude = true;
        trimmed = trimmed[1..];
    }

    return .{ .pattern = trimmed, .is_exclude = is_exclude };
}

fn matchesPattern(pattern: []const u8, name: []const u8) bool {
    var pattern_index: usize = 0;
    var name_index: usize = 0;
    var last_star: ?usize = null;
    var retry_name_index: usize = 0;

    while (name_index < name.len) {
        if (pattern_index < pattern.len and pattern[pattern_index] != '*' and pattern[pattern_index] == name[name_index]) {
            pattern_index += 1;
            name_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            last_star = pattern_index;
            pattern_index += 1;
            retry_name_index = name_index;
        } else if (last_star) |star_index| {
            retry_name_index += 1;
            name_index = retry_name_index;
            pattern_index = star_index + 1;
        } else {
            return false;
        }
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
        pattern_index += 1;
    }

    return pattern_index == pattern.len;
}

pub fn isMatch(this: *const PnpmMatcher, name: []const u8) bool {
    if (this.matchers.len == 0) {
        return false;
    }

    switch (this.behavior) {
        .all_matchers_include => {
            for (this.matchers) |matcher| {
                if (matchesPattern(matcher.pattern, name)) {
                    return true;
                }
            }
            return false;
        },
        .all_matchers_exclude => {
            for (this.matchers) |matcher| {
                if (matchesPattern(matcher.pattern, name)) {
                    return false;
                }
            }
            return true;
        },
        .has_exclude_and_include_matchers => {
            var matches = false;
            for (this.matchers) |matcher| {
                if (matchesPattern(matcher.pattern, name)) {
                    matches = !matcher.is_exclude;
                }
            }
            return matches;
        },
    }
}

const std = @import("std");

const bun = @import("bun");
const OOM = bun.OOM;
const ast = bun.ast;
const collections = bun.collections;
const logger = bun.logger;
const strings = bun.strings;
