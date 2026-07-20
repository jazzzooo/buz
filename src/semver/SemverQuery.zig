pub const Wildcard = enum {
    none,
    major,
    minor,
    patch,
};

const Operator = enum {
    version,
    gt,
    gte,
    lt,
    lte,
    tilde,
    caret,
};

pub const Group = struct {
    storage: Storage = .{ .single = .{} },
    allocator: Allocator,
    input: string = "",
    flags: Flags = .empty,

    const Storage = union(enum) {
        single: Range,
        compound: Compound,
    };

    const Compound = struct {
        ranges: []Range,
        alternative_starts: []usize,
    };

    pub const Flag = enum { build, pre };
    pub const Flags = std.enums.EnumSet(Flag);

    const Formatter = struct {
        group: *const Group,
        buf: string,

        pub fn format(formatter: @This(), writer: *std.Io.Writer) !void {
            const group = formatter.group;
            var alternative_iterator = group.alternatives();
            var alternative_index: usize = 0;
            while (alternative_iterator.next()) |alternative| : (alternative_index += 1) {
                if (alternative_index > 0) try writer.writeAll(" || ");

                for (alternative, 0..) |*range, range_index| {
                    if (range_index > 0) try writer.writeAll(" && ");
                    try writer.print("{f}", .{range.fmt(formatter.buf)});
                }
            }
        }
    };

    pub fn fmt(this: *const Group, buf: string) Formatter {
        return .{ .group = this, .buf = buf };
    }

    pub fn jsonStringify(this: *const Group, writer: anytype) !void {
        try std.json.encodeJsonString(this.input, .{}, writer);
    }

    pub fn deinit(this: *const Group) void {
        switch (this.storage) {
            .single => {},
            .compound => |compound| {
                this.allocator.free(compound.ranges);
                this.allocator.free(compound.alternative_starts);
            },
        }
    }

    pub fn ranges(this: *const Group) []const Range {
        return switch (this.storage) {
            .single => |*range| range[0..1],
            .compound => |compound| compound.ranges,
        };
    }

    fn alternativeStarts(this: *const Group) []const usize {
        return switch (this.storage) {
            .single => &.{},
            .compound => |compound| compound.alternative_starts,
        };
    }

    pub fn firstComparator(this: *const Group) Range.Comparator {
        return this.ranges()[0].left;
    }

    fn alternatives(this: *const Group) AlternativeIterator {
        return .{ .ranges = this.ranges(), .starts = this.alternativeStarts() };
    }

    pub fn getExactVersion(this: *const Group) ?Version {
        const range_items = this.ranges();
        if (range_items.len != 1) return null;

        const range = range_items[0];
        if (range.hasRight() or range.left.op != .eql) return null;
        return range.left.version;
    }

    pub fn from(version: Version) Group {
        return .{
            .allocator = bun.default_allocator,
            .storage = .{ .single = .{
                .left = .{
                    .op = .eql,
                    .version = version,
                },
            } },
        };
    }

    pub fn isExact(this: *const Group) bool {
        return this.getExactVersion() != null;
    }

    pub fn @"is *"(this: *const Group) bool {
        if (this.ranges().len != 1) return false;
        return this.ranges()[0].anyRangeSatisfies() and !this.flags.contains(.build);
    }

    pub fn eql(lhs: Group, rhs: Group) bool {
        const lhs_ranges = lhs.ranges();
        const rhs_ranges = rhs.ranges();
        if (lhs_ranges.len != rhs_ranges.len or !std.mem.eql(usize, lhs.alternativeStarts(), rhs.alternativeStarts())) return false;

        for (lhs_ranges, rhs_ranges) |lhs_range, rhs_range| {
            if (!lhs_range.eql(rhs_range)) return false;
        }

        return true;
    }

    pub fn toVersion(this: Group) Version {
        const range = this.ranges()[0];
        assert(this.isExact() or !range.hasLeft());
        return range.left.version;
    }

    pub fn satisfies(
        this: *const Group,
        version: Version,
        group_buf: string,
        version_buf: string,
    ) bool {
        var alternative_iterator = this.alternatives();
        while (alternative_iterator.next()) |alternative| {
            if (alternativeSatisfies(alternative, version, group_buf, version_buf)) return true;
        }

        return false;
    }

    fn alternativeSatisfies(alternative: []const Range, version: Version, group_buf: string, version_buf: string) bool {
        if (!version.tag.hasPre()) {
            for (alternative) |range| {
                if (!range.satisfies(version, group_buf, version_buf)) return false;
            }
            return true;
        }

        var pre_matched = false;
        for (alternative) |range| {
            if (!range.satisfiesPre(version, group_buf, version_buf, &pre_matched)) return false;
        }
        return pre_matched;
    }
};

const AlternativeIterator = struct {
    ranges: []const Range,
    starts: []const usize,
    index: usize = 0,

    fn next(this: *AlternativeIterator) ?[]const Range {
        if (this.index > this.starts.len) return null;

        const start = if (this.index == 0) 0 else this.starts[this.index - 1];
        const end = if (this.index == this.starts.len) this.ranges.len else this.starts[this.index];
        this.index += 1;
        return this.ranges[start..end];
    }
};

const Builder = struct {
    allocator: Allocator,
    ranges: std.ArrayList(Range) = .empty,
    alternative_starts: std.ArrayList(usize) = .empty,

    fn deinit(this: *Builder) void {
        this.ranges.deinit(this.allocator);
        this.alternative_starts.deinit(this.allocator);
    }

    fn append(this: *Builder, range: Range, starts_alternative: bool) bun.OOM!void {
        if (starts_alternative and this.ranges.items.len > 0) {
            try this.alternative_starts.append(this.allocator, this.ranges.items.len);
        }
        try this.ranges.append(this.allocator, range);
    }

    fn finish(this: *Builder, input: string, flags: Group.Flags) bun.OOM!Group {
        if (this.ranges.items.len == 0) {
            this.deinit();
            return .{ .allocator = this.allocator, .input = input, .flags = flags };
        }

        if (this.ranges.items.len == 1) {
            const range = this.ranges.items[0];
            this.deinit();
            return .{
                .allocator = this.allocator,
                .input = input,
                .flags = flags,
                .storage = .{ .single = range },
            };
        }

        const ranges = try this.ranges.toOwnedSlice(this.allocator);
        errdefer this.allocator.free(ranges);
        const alternative_starts = try this.alternative_starts.toOwnedSlice(this.allocator);

        return .{
            .allocator = this.allocator,
            .input = input,
            .flags = flags,
            .storage = .{ .compound = .{
                .ranges = ranges,
                .alternative_starts = alternative_starts,
            } },
        };
    }
};

const Parser = struct {
    input: string,
    sliced: SlicedString,
    index: usize = 0,
    pending_or: bool = false,
    flags: Group.Flags = .empty,
    builder: Builder,

    fn init(allocator: Allocator, input: string, sliced: SlicedString) Parser {
        return .{
            .input = input,
            .sliced = sliced,
            .builder = .{ .allocator = allocator },
        };
    }

    fn parse(this: *Parser) bun.OOM!Group {
        errdefer this.builder.deinit();

        while (this.index < this.input.len) {
            this.skipWhitespace();
            if (this.index == this.input.len) break;

            if (this.input[this.index] == '|') {
                while (this.index < this.input.len and this.input[this.index] == '|') this.index += 1;
                this.pending_or = true;
                continue;
            }

            const iteration_start = this.index;
            if (this.parseRange()) |parsed| {
                const starts_alternative = this.pending_or or (parsed.implicit_or and this.builder.ranges.items.len > 0);
                try this.builder.append(parsed.range, starts_alternative);
                this.pending_or = false;
            } else if (this.index == iteration_start) {
                this.skipInvalidChunk();
            }
        }

        return this.builder.finish(this.input, this.flags);
    }

    const ParsedRange = struct {
        range: Range,
        implicit_or: bool,
    };

    fn parseRange(this: *Parser) ?ParsedRange {
        const operator: Operator = switch (this.input[this.index]) {
            '>' => operator: {
                this.index += 1;
                if (this.index < this.input.len and this.input[this.index] == '=') {
                    this.index += 1;
                    break :operator .gte;
                }
                break :operator .gt;
            },
            '<' => operator: {
                this.index += 1;
                if (this.index < this.input.len and this.input[this.index] == '=') {
                    this.index += 1;
                    break :operator .lte;
                }
                break :operator .lt;
            },
            '=' => operator: {
                this.index += 1;
                break :operator .version;
            },
            'v' => operator: {
                this.index += 1;
                break :operator .version;
            },
            '~' => operator: {
                this.index += 1;
                if (this.index < this.input.len and this.input[this.index] == '>') this.index += 1;
                break :operator .tilde;
            },
            '^' => operator: {
                this.index += 1;
                break :operator .caret;
            },
            '0'...'9', 'X', 'x', '*' => .version,
            else => return null,
        };

        this.skipVersionPrefixes();
        if (this.index == this.input.len or !isVersionStart(this.input[this.index])) return null;

        const version_start = this.index;
        const version_end = this.versionTokenEnd(version_start);
        const parsed = Version.parse(this.sliced.sub(this.input[version_start..version_end]));
        this.index = version_end;
        if (!parsed.valid or parsed.len == 0) return null;

        this.recordFlags(parsed.version.tag);

        if (this.parseHyphenRange(parsed.version)) |range| {
            return .{ .range = range, .implicit_or = operator == .version };
        }

        return .{
            .range = toRange(operator, parsed.version, parsed.wildcard),
            .implicit_or = operator == .version,
        };
    }

    fn parseHyphenRange(this: *Parser, first: Version.Partial) ?Range {
        const first_end = this.index;
        if (first_end == this.input.len or !std.ascii.isWhitespace(this.input[first_end])) return null;

        var cursor = first_end;
        while (cursor < this.input.len and std.ascii.isWhitespace(this.input[cursor])) cursor += 1;
        if (cursor == this.input.len or this.input[cursor] != '-') return null;

        cursor += 1;
        while (cursor < this.input.len and std.ascii.isWhitespace(this.input[cursor])) cursor += 1;
        while (cursor < this.input.len and (this.input[cursor] == 'v' or this.input[cursor] == '=')) {
            cursor += 1;
            while (cursor < this.input.len and std.ascii.isWhitespace(this.input[cursor])) cursor += 1;
        }
        if (cursor == this.input.len or !isVersionStart(this.input[cursor])) return null;

        const second_end = this.versionTokenEnd(cursor);
        const second = Version.parse(this.sliced.sub(this.input[cursor..second_end]));
        if (!second.valid or second.len == 0) return null;

        const first_version = first.min();
        var second_version = second.version.min();
        this.recordFlags(second.version.tag);
        this.index = second_end;

        return switch (second.wildcard) {
            .major => .{
                .left = .{ .op = .gte, .version = first_version },
            },
            .minor => range: {
                second_version.major +|= 1;
                second_version.minor = 0;
                second_version.patch = 0;
                break :range .{
                    .left = .{ .op = .gte, .version = first_version },
                    .right = .{ .op = .lt, .version = second_version },
                };
            },
            .patch => range: {
                second_version.minor +|= 1;
                second_version.patch = 0;
                break :range .{
                    .left = .{ .op = .gte, .version = first_version },
                    .right = .{ .op = .lt, .version = second_version },
                };
            },
            .none => .{
                .left = .{ .op = .gte, .version = first_version },
                .right = .{ .op = .lte, .version = second_version },
            },
        };
    }

    fn skipWhitespace(this: *Parser) void {
        while (this.index < this.input.len and std.ascii.isWhitespace(this.input[this.index])) this.index += 1;
    }

    fn skipVersionPrefixes(this: *Parser) void {
        while (true) {
            this.skipWhitespace();
            if (this.index == this.input.len or (this.input[this.index] != 'v' and this.input[this.index] != '=')) return;
            this.index += 1;
        }
    }

    fn skipInvalidChunk(this: *Parser) void {
        this.index += 1;
        while (this.index < this.input.len and !std.ascii.isWhitespace(this.input[this.index]) and this.input[this.index] != '|') {
            this.index += 1;
        }
    }

    fn versionTokenEnd(this: *const Parser, start: usize) usize {
        var end = start;
        while (end < this.input.len and !std.ascii.isWhitespace(this.input[end]) and this.input[end] != '|') end += 1;
        return end;
    }

    fn recordFlags(this: *Parser, tag: Version.Tag) void {
        if (tag.hasBuild()) this.flags.insert(.build);
        if (tag.hasPre()) this.flags.insert(.pre);
    }
};

fn isVersionStart(byte: u8) bool {
    return switch (byte) {
        '0'...'9', 'X', 'x', '*' => true,
        else => false,
    };
}

fn toRange(operator: Operator, version: Version.Partial, wildcard: Wildcard) Range {
    switch (operator) {
        .caret => {
            var range = Range{};
            if (version.major) |major| done: {
                range.left = .{
                    .op = .gte,
                    .version = .{ .major = major },
                };
                range.right = .{ .op = .lt };
                if (version.minor) |minor| {
                    range.left.version.minor = minor;
                    if (version.patch) |patch| {
                        range.left.version.patch = patch;
                        range.left.version.tag = version.tag;
                        if (major == 0) {
                            if (minor == 0) {
                                range.right.version.patch = patch +| 1;
                            } else {
                                range.right.version.minor = minor +| 1;
                            }
                            break :done;
                        }
                    } else if (major == 0) {
                        range.right.version.minor = minor +| 1;
                        break :done;
                    }
                }
                range.right.version.major = major +| 1;
            }
            return range;
        },
        .tilde => {
            var range = Range{};
            if (version.major) |major| done: {
                range.left = .{
                    .op = .gte,
                    .version = .{ .major = major },
                };
                range.right = .{ .op = .lt };
                if (version.minor) |minor| {
                    range.left.version.minor = minor;
                    if (version.patch) |patch| {
                        range.left.version.patch = patch;
                        range.left.version.tag = version.tag;
                    }
                    range.right.version.major = major;
                    range.right.version.minor = minor +| 1;
                    break :done;
                }
                range.right.version.major = major +| 1;
            }
            return range;
        },
        .version => {
            if (wildcard != .none) return Range.initWildcard(version.min(), wildcard);
            return .{ .left = .{ .op = .eql, .version = version.min() } };
        },
        else => {},
    }

    return switch (wildcard) {
        .major => .{
            .left = .{ .op = .gte, .version = version.min() },
            .right = .{
                .op = .lte,
                .version = .{
                    .major = std.math.maxInt(u64),
                    .minor = std.math.maxInt(u64),
                    .patch = std.math.maxInt(u64),
                },
            },
        },
        .minor => switch (operator) {
            .lte => .{ .left = .{ .op = .lte, .version = .{
                .major = version.major orelse 0,
                .minor = std.math.maxInt(u64),
                .patch = std.math.maxInt(u64),
            } } },
            .lt => .{ .left = .{ .op = .lt, .version = .{
                .major = version.major orelse 0,
            } } },
            .gt => .{ .left = .{ .op = .gt, .version = .{
                .major = version.major orelse 0,
                .minor = std.math.maxInt(u64),
                .patch = std.math.maxInt(u64),
            } } },
            .gte => .{ .left = .{ .op = .gte, .version = .{
                .major = version.major orelse 0,
            } } },
            else => unreachable,
        },
        .patch => switch (operator) {
            .lte => .{ .left = .{ .op = .lte, .version = .{
                .major = version.major orelse 0,
                .minor = version.minor orelse 0,
                .patch = std.math.maxInt(u64),
            } } },
            .lt => .{ .left = .{ .op = .lt, .version = .{
                .major = version.major orelse 0,
                .minor = version.minor orelse 0,
            } } },
            .gt => .{ .left = .{ .op = .gt, .version = .{
                .major = version.major orelse 0,
                .minor = version.minor orelse 0,
                .patch = std.math.maxInt(u64),
            } } },
            .gte => .{ .left = .{ .op = .gte, .version = .{
                .major = version.major orelse 0,
                .minor = version.minor orelse 0,
            } } },
            else => unreachable,
        },
        .none => .{
            .left = .{
                .op = switch (operator) {
                    .gt => .gt,
                    .gte => .gte,
                    .lt => .lt,
                    .lte => .lte,
                    else => unreachable,
                },
                .version = version.min(),
            },
        },
    };
}

pub fn parse(allocator: Allocator, input: string, sliced: SlicedString) bun.OOM!Group {
    var parser = Parser.init(allocator, input, sliced);
    return parser.parse();
}

const string = []const u8;

const std = @import("std");
const Allocator = std.mem.Allocator;

const bun = @import("bun");
const assert = bun.assert;

const Range = bun.Semver.Range;
const SlicedString = bun.Semver.SlicedString;
const Version = bun.Semver.Version;
