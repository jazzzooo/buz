const SourceProperties = struct {
    grapheme_break: types.GraphemeBreak = .other,
    indic_conjunct_break: types.IndicConjunctBreak = .none,
    east_asian_width: EastAsianWidth = .neutral,
    general_category: GeneralCategory = .other,
    default_ignorable: bool = false,
    emoji: bool = false,
    extended_pictographic: bool = false,
    emoji_modifier: bool = false,

    fn toProperties(self: SourceProperties) types.Properties {
        return .{
            .grapheme_break = self.grapheme_break,
            .indic_conjunct_break = self.indic_conjunct_break,
            .width = width(self),
            .emoji = self.emoji,
            .extended_pictographic = self.extended_pictographic,
            .emoji_modifier = self.emoji_modifier,
        };
    }
};

const EastAsianWidth = enum {
    neutral,
    ambiguous,
    fullwidth,
    halfwidth,
    narrow,
    wide,
};

const GeneralCategory = enum {
    other,
    unassigned,
    control,
    format,
    surrogate,
    nonspacing_mark,
    spacing_mark,
    enclosing_mark,
};

const Range = struct {
    first: u32,
    last: u32,

    fn contains(self: Range, other: Range) bool {
        return self.first <= other.first and other.last <= self.last;
    }
};

const Block = struct {
    range: Range,
    properties: SourceProperties,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidArguments;

    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(8 << 20));
    const properties = try allocator.alloc(types.Properties, types.max_code_point + 1);
    try parse(input, properties);
    try validate(properties);

    const indexes = try allocator.alloc(u8, properties.len);
    var values: std.array_hash_map.Auto(u16, void) = .empty;
    for (properties, indexes) |value, *index| {
        const raw: u16 = @bitCast(value);
        const result = try values.getOrPut(allocator, raw);
        if (result.index > std.math.maxInt(u8)) return error.TooManyPropertyValues;
        index.* = @intCast(result.index);
    }

    const page_count = (types.max_code_point + 1) / 256;
    var stage1: [page_count]u16 = undefined;
    var pages: std.array_hash_map.Auto([256]u8, void) = .empty;
    for (&stage1, 0..) |*offset, page_index| {
        const start = page_index * 256;
        const page = indexes[start..][0..256].*;
        const result = try pages.getOrPut(allocator, page);
        const page_offset = result.index * 256;
        if (page_offset > std.math.maxInt(u16) - 255) return error.TooManyPages;
        offset.* = @intCast(page_offset);
    }

    const output_file = try std.Io.Dir.cwd().createFile(init.io, args[2], .{});
    defer output_file.close(init.io);
    var buffer: [4096]u8 = undefined;
    var output_writer = output_file.writerStreaming(init.io, &buffer);
    const output = &output_writer.interface;
    try output.print(
        \\pub const unicode_version = "{s}";
        \\
        \\
    , .{types.version});
    try writeArray(output, u16, "stage1", &stage1, 24);
    try writeArray(output, u8, "stage2", std.mem.sliceAsBytes(pages.keys()), 32);
    try writeArray(output, u16, "stage3", values.keys(), 24);
    try output.flush();
}

fn parse(input: []const u8, output: []types.Properties) !void {
    var defaults: SourceProperties = .{};
    var block: ?Block = null;
    var saw_version = false;
    var saw_defaults = false;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |untrimmed_line| {
        const line = std.mem.trim(u8, untrimmed_line, " \r");
        if (line.len == 0 or line[0] == '#') continue;

        var fields = std.mem.splitScalar(u8, line, ';');
        const kind_text = fields.next().?;
        if (std.mem.eql(u8, kind_text, "ucd")) {
            const version = fields.next() orelse return error.InvalidUnicodeData;
            if (!std.mem.eql(u8, version, types.version)) return error.UnexpectedUnicodeVersion;
            saw_version = true;
            continue;
        }
        const kind = std.meta.stringToEnum(RecordKind, kind_text) orelse continue;

        const range = try parseRange(fields.next() orelse return error.InvalidUnicodeData);
        if (range.last > types.max_code_point) return error.InvalidUnicodeData;

        var properties: SourceProperties = switch (kind) {
            .defaults => .{},
            .block => defaults,
            .cp => if (block) |current|
                if (current.range.contains(range)) current.properties else defaults
            else
                defaults,
            .unassigned => defaults,
        };

        while (fields.next()) |field| try applyField(&properties, field);

        switch (kind) {
            .defaults => {
                if (range.first != 0 or range.last != types.max_code_point or saw_defaults)
                    return error.InvalidUnicodeData;
                defaults = properties;
                @memset(output, defaults.toProperties());
                saw_defaults = true;
            },
            .block, .cp, .unassigned => {
                if (!saw_defaults) return error.InvalidUnicodeData;
                @memset(output[range.first .. range.last + 1], properties.toProperties());
                if (kind == .block) block = .{ .range = range, .properties = properties };
            },
        }
    }
    if (!saw_version or !saw_defaults) return error.InvalidUnicodeData;
}

fn parseRange(text: []const u8) !Range {
    if (std.mem.indexOf(u8, text, "..")) |separator| {
        const first = try std.fmt.parseInt(u32, text[0..separator], 16);
        const last = try std.fmt.parseInt(u32, text[separator + 2 ..], 16);
        if (first > last) return error.InvalidUnicodeData;
        return .{ .first = first, .last = last };
    }
    const cp = try std.fmt.parseInt(u32, text, 16);
    return .{ .first = cp, .last = cp };
}

fn applyField(properties: *SourceProperties, field: []const u8) !void {
    if (std.mem.startsWith(u8, field, "GCB=")) {
        properties.grapheme_break = grapheme_break_values.get(field[4..]) orelse return error.InvalidUnicodeData;
    } else if (std.mem.startsWith(u8, field, "InCB=")) {
        properties.indic_conjunct_break = indic_conjunct_break_values.get(field[5..]) orelse return error.InvalidUnicodeData;
    } else if (std.mem.startsWith(u8, field, "ea=")) {
        properties.east_asian_width = east_asian_width_values.get(field[3..]) orelse return error.InvalidUnicodeData;
    } else if (std.mem.startsWith(u8, field, "gc=")) {
        properties.general_category = general_category_values.get(field[3..]) orelse return error.InvalidUnicodeData;
    } else if (std.mem.eql(u8, field, "DI")) {
        properties.default_ignorable = true;
    } else if (std.mem.eql(u8, field, "-DI")) {
        properties.default_ignorable = false;
    } else if (std.mem.eql(u8, field, "Emoji")) {
        properties.emoji = true;
    } else if (std.mem.eql(u8, field, "-Emoji")) {
        properties.emoji = false;
    } else if (std.mem.eql(u8, field, "ExtPict")) {
        properties.extended_pictographic = true;
    } else if (std.mem.eql(u8, field, "-ExtPict")) {
        properties.extended_pictographic = false;
    } else if (std.mem.eql(u8, field, "EMod")) {
        properties.emoji_modifier = true;
    } else if (std.mem.eql(u8, field, "-EMod")) {
        properties.emoji_modifier = false;
    }
}

fn width(properties: SourceProperties) types.Width {
    if (properties.grapheme_break == .v or
        properties.grapheme_break == .t or
        switch (properties.general_category) {
            .control, .format, .surrogate, .nonspacing_mark, .spacing_mark, .enclosing_mark => true,
            .unassigned => properties.default_ignorable,
            else => false,
        })
    {
        return .zero;
    }
    return switch (properties.east_asian_width) {
        .wide, .fullwidth => .wide,
        .ambiguous => .ambiguous,
        else => .narrow,
    };
}

fn validate(source: []const types.Properties) !void {
    if (source.len != types.max_code_point + 1 or
        source[0x0300].grapheme_break != .extend or
        source[0x094d].indic_conjunct_break != .linker or
        source[0x1f1e6].grapheme_break != .regional_indicator or
        !source[0x1f600].emoji or
        !source[0x1f600].extended_pictographic or
        source[0x4e00].width != .wide or
        source[0x2065].width != .zero or
        source[0x115f].width != .wide or
        source[0x3164].width != .wide or
        source[0xffa0].width != .narrow)
    {
        return error.InvalidUnicodeData;
    }
}

fn writeArray(
    output: *std.Io.Writer,
    comptime T: type,
    name: []const u8,
    values: []const T,
    per_line: usize,
) !void {
    try output.print("pub const {s} = [_]{s}{{\n", .{ name, @typeName(T) });
    for (values, 0..) |value, index| {
        if (index % per_line == 0) try output.writeAll("    ");
        try output.print("{d},", .{value});
        if (index % per_line == per_line - 1 or index + 1 == values.len)
            try output.writeByte('\n')
        else
            try output.writeByte(' ');
    }
    try output.writeAll("};\n\n");
}

const RecordKind = enum {
    defaults,
    block,
    cp,
    unassigned,
};

const grapheme_break_values = std.StaticStringMap(types.GraphemeBreak).initComptime(.{
    .{ "XX", .other },
    .{ "CN", .control },
    .{ "CR", .cr },
    .{ "LF", .lf },
    .{ "EX", .extend },
    .{ "RI", .regional_indicator },
    .{ "PP", .prepend },
    .{ "SM", .spacing_mark },
    .{ "L", .l },
    .{ "V", .v },
    .{ "T", .t },
    .{ "LV", .lv },
    .{ "LVT", .lvt },
    .{ "ZWJ", .zwj },
});

const indic_conjunct_break_values = std.StaticStringMap(types.IndicConjunctBreak).initComptime(.{
    .{ "None", .none },
    .{ "Consonant", .consonant },
    .{ "Extend", .extend },
    .{ "Linker", .linker },
});

const east_asian_width_values = std.StaticStringMap(EastAsianWidth).initComptime(.{
    .{ "N", .neutral },
    .{ "A", .ambiguous },
    .{ "F", .fullwidth },
    .{ "H", .halfwidth },
    .{ "Na", .narrow },
    .{ "W", .wide },
});

const general_category_values = std.StaticStringMap(GeneralCategory).initComptime(.{
    .{ "Cc", .control },
    .{ "Cf", .format },
    .{ "Cn", .unassigned },
    .{ "Co", .other },
    .{ "Cs", .surrogate },
    .{ "Ll", .other },
    .{ "Lm", .other },
    .{ "Lo", .other },
    .{ "Lt", .other },
    .{ "Lu", .other },
    .{ "Mc", .spacing_mark },
    .{ "Me", .enclosing_mark },
    .{ "Mn", .nonspacing_mark },
    .{ "Nd", .other },
    .{ "Nl", .other },
    .{ "No", .other },
    .{ "Pc", .other },
    .{ "Pd", .other },
    .{ "Pe", .other },
    .{ "Pf", .other },
    .{ "Pi", .other },
    .{ "Po", .other },
    .{ "Ps", .other },
    .{ "Sc", .other },
    .{ "Sk", .other },
    .{ "Sm", .other },
    .{ "So", .other },
    .{ "Zl", .other },
    .{ "Zp", .other },
    .{ "Zs", .other },
});

const types = @import("types.zig");
const std = @import("std");
