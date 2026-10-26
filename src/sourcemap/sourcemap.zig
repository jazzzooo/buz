pub const SourceMap = @This();
const debug = bun.Output.scoped(.SourceMap, .visible);

/// Coordinates in source maps are stored using relative offsets for size
/// reasons. When joining together chunks of a source map that were emitted
/// in parallel for different parts of a file, we need to fix up the first
/// segment of each chunk to be relative to the end of the previous chunk.
pub const SourceMapState = struct {
    /// This isn't stored in the source map. It's only used by the bundler to join
    /// source map chunks together correctly.
    generated_line: i32 = 0,

    /// These are stored in the source map in VLQ format.
    generated_column: i32 = 0,
    source_index: i32 = 0,
    original_line: i32 = 0,
    original_column: i32 = 0,
};

sources: [][]const u8 = &[_][]u8{},
sources_content: []string,
mapping: Mapping.List = .{},
allocator: std.mem.Allocator,

/// Dictates what parseUrl/parseJSON return.
pub const ParseUrlResultHint = union(enum) {
    mappings_only,
    /// Source Index to fetch
    source_only: u32,
    /// In order to fetch source contents, you need to know the
    /// index, but you cant know the index until the mappings
    /// are loaded. So pass in line+col.
    all: struct {
        line: i32,
        column: i32,
    },
};

pub const ParseUrl = struct {
    /// Populated when `mappings_only` or `all`.
    map: ?*ParsedSourceMap = null,
    /// Populated when `all`
    /// May be `null` even when requested.
    mapping: ?Mapping = null,
    /// Populated when `source_only` or `all`
    /// May be `null` even when requested, if did not exist in map.
    source_contents: ?[]const u8 = null,
};

/// Parses an inline source map url like `data:application/json,....`
/// Currently does not handle non-inline source maps.
///
/// `source` must be in UTF-8 and can be freed after this call.
/// The mappings are owned by the `alloc` allocator.
/// Temporary allocations are made to the `arena` allocator, which
/// should be an arena allocator (caller is assumed to call `deinit`).
pub fn parseUrl(
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
    hint: ParseUrlResultHint,
) !ParseUrl {
    const json_bytes = json_bytes: {
        const data_prefix = "data:application/json";

        if (bun.strings.hasPrefixComptime(source, data_prefix) and source.len > (data_prefix.len + 1)) try_data_url: {
            debug("parse (data url, {d} bytes)", .{source.len});
            switch (source[data_prefix.len]) {
                ';' => {
                    const encoded = source[data_prefix.len + 1 ..];
                    const comma = std.mem.indexOfScalar(u8, encoded, ',') orelse return error.UnsupportedFormat;
                    const encoding = encoded[0..comma];
                    if (!bun.strings.eqlComptime(encoding, "base64")) break :try_data_url;
                    const base64_data = encoded[comma + 1 ..];

                    const len = bun.base64.decodeLen(base64_data);
                    const bytes = try arena.alloc(u8, len);
                    const decoded = bun.base64.decodeForgiving(bytes, base64_data);
                    if (!decoded.isSuccessful()) {
                        return error.InvalidBase64;
                    }
                    break :json_bytes bytes[0..decoded.count];
                },
                ',' => break :json_bytes source[data_prefix.len + 1 ..],
                else => break :try_data_url,
            }
        }

        return error.UnsupportedFormat;
    };

    return parseJSON(alloc, arena, json_bytes, hint);
}

/// Parses a JSON source-map
///
/// `source` must be in UTF-8 and can be freed after this call.
/// The mappings are owned by the `alloc` allocator.
/// Temporary allocations are made to the `arena` allocator, which
/// should be an arena allocator (caller is assumed to call `deinit`).
pub fn parseJSON(
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
    hint: ParseUrlResultHint,
) !ParseUrl {
    const json_src = bun.logger.Source.initPathString("sourcemap.json", source);
    var log = bun.logger.Log.init(arena);
    defer log.deinit();

    // the allocator given to the JS parser is not respected for all parts
    // of the parse, so we need to remember to reset the ast store
    bun.ast.Expr.Data.Store.reset();
    bun.ast.Stmt.Data.Store.reset();
    defer {
        // the allocator given to the JS parser is not respected for all parts
        // of the parse, so we need to remember to reset the ast store
        bun.ast.Expr.Data.Store.reset();
        bun.ast.Stmt.Data.Store.reset();
    }
    debug("parse (JSON, {d} bytes)", .{source.len});
    var json = bun.json.parse(&json_src, &log, arena, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJSON,
    };

    if (json.get("version")) |version| {
        if (version.data != .e_number or version.data.e_number.value != 3.0) {
            return error.UnsupportedVersion;
        }
    }

    const mappings_str = json.get("mappings") orelse {
        return error.UnsupportedVersion;
    };

    if (mappings_str.data != .e_string) {
        return error.InvalidSourceMap;
    }

    const sources_content = switch ((json.get("sourcesContent") orelse return error.InvalidSourceMap).data) {
        .e_array => |arr| arr,
        else => return error.InvalidSourceMap,
    };

    const sources_paths = switch ((json.get("sources") orelse return error.InvalidSourceMap).data) {
        .e_array => |arr| arr,
        else => return error.InvalidSourceMap,
    };

    if (sources_content.items.len != sources_paths.items.len) {
        return error.InvalidSourceMap;
    }

    const map = if (hint != .source_only) map: {
        var map_data = switch (Mapping.parse(
            alloc,
            try mappings_str.data.e_string.string(arena),
            null,
            std.math.cast(i32, sources_paths.items.len) orelse return error.OutOfMemory,
            null,
            .{ .allow_names = false, .sort = true },
        )) {
            .success => |x| x,
            .fail => |fail| return fail.err,
        };
        errdefer map_data.mappings.deinit(alloc);

        const source_paths = try alloc.alloc([]const u8, sources_paths.items.len);
        var initialized: usize = 0;
        errdefer {
            for (source_paths[0..initialized]) |path| alloc.free(path);
            alloc.free(source_paths);
        }
        for (sources_paths.items.slice(), source_paths) |item, *path| {
            if (item.data != .e_string) return error.InvalidSourceMap;
            path.* = try item.data.e_string.stringCloned(alloc);
            initialized += 1;
        }

        const ptr = try alloc.create(ParsedSourceMap);
        ptr.* = map_data;
        ptr.external_source_names = source_paths;

        break :map ptr;
    } else null;
    errdefer if (map) |m| m.deref();

    const mapping, const source_index = switch (hint) {
        .source_only => |index| .{ null, index },
        .all => |loc| brk: {
            const mapping = map.?.findMapping(.fromZeroBased(loc.line), .fromZeroBased(loc.column)) orelse
                break :brk .{ null, null };
            break :brk .{ mapping, std.math.cast(u32, mapping.source_index) };
        },
        .mappings_only => .{ null, null },
    };

    const content_slice: ?[]const u8 = if (hint != .mappings_only and
        source_index != null and
        source_index.? < sources_content.items.len)
    content: {
        const item = sources_content.items.slice()[source_index.?];
        if (item.data != .e_string) {
            break :content null;
        }

        const str = try item.data.e_string.string(arena);
        if (str.len == 0) {
            break :content null;
        }

        break :content try alloc.dupe(u8, str);
    } else null;

    return .{
        .map = map,
        .mapping = mapping,
        .source_contents = content_slice,
    };
}

/// Corresponds to a segment in the "mappings" field of a sourcemap
pub const Mapping = @import("./Mapping.zig");

pub const ParseResult = union(enum) {
    fail: struct {
        loc: Logger.Loc,
        err: anyerror,
        value: i32 = 0,
        msg: []const u8 = "",

        pub fn toData(this: @This(), path: []const u8) Logger.Data {
            return Logger.Data{
                .location = Logger.Location{
                    .file = path,
                    .offset = this.loc.toUsize(),
                    // TODO: populate correct line and column information
                    .line = -1,
                    .column = -1,
                },
                .text = this.msg,
            };
        }
    },
    success: ParsedSourceMap,
};

pub const ParsedSourceMap = @import("./ParsedSourceMap.zig");

/// For some sourcemap loading code, this enum is used as a hint if it should
/// bother loading source code into memory. Most uses of source maps only care
/// about filenames and source mappings, and we should avoid loading contents
/// whenever possible.
pub const SourceContentHandling = enum(u1) {
    no_source_contents,
    source_contents,
};

/// For some sourcemap loading code, this enum is used as a hint if we already
/// know if the sourcemap is located on disk or inline in the source code.
pub const SourceMapLoadHint = enum(u2) {
    none,
    is_inline_map,
    is_external_map,
};

/// Returns an owned UTF-8 copy of the source-map URL.
pub fn findSourceMappingURL(source: bun.TextView, alloc: std.mem.Allocator) bun.OOM!?[]u8 {
    const url: bun.TextView = switch (source) {
        inline else => |units, encoding| url: {
            const T = std.meta.Elem(@TypeOf(units));
            const needle = comptime bun.strings.literal(T, "\n//# sourceMappingURL=");
            const found = std.mem.lastIndexOf(T, units, needle) orelse return null;
            const end = std.mem.indexOfScalarPos(T, units, found + needle.len, '\n') orelse units.len;
            const value = std.mem.trimEnd(T, units[found + needle.len .. end], &.{ ' ', '\r' });
            break :url @unionInit(bun.TextView, @tagName(encoding), value);
        },
    };
    return try url.toOwnedSlice(alloc);
}

test "source-map URL extraction preserves text encoding and owns its result" {
    const allocator = std.testing.allocator;
    var latin1 = "\n//# sourceMappingURL=caf\xe9.map \r\n".*;
    const copied = (try findSourceMappingURL(.{ .latin1 = &latin1 }, allocator)).?;
    defer allocator.free(copied);
    @memset(&latin1, 0);
    try std.testing.expectEqualStrings("café.map", copied);

    const source = "\n//# sourceMappingURL=old.map\n//# sourceMappingURL=😀.map\n";
    for ([_]bun.TextView{
        .{ .utf8 = source },
        .{ .utf16 = std.unicode.utf8ToUtf16LeStringLiteral(source) },
    }) |text| {
        const url = (try findSourceMappingURL(text, allocator)).?;
        defer allocator.free(url);
        try std.testing.expectEqualStrings("😀.map", url);
    }
}

pub const SourceMapInput = @import("./SourceMapInput.zig");

pub const LoadResult = union(enum) {
    parsed: ParseUrl,
    missing,
    invalid,
};

pub fn loadSourceMap(
    io: std.Io,
    input: *SourceMapInput,
    source_filename: []const u8,
    load_hint: SourceMapLoadHint,
    result: ParseUrlResultHint,
) bun.OOM!LoadResult {
    const STACK_SPACE_TO_USE = 1024;
    var sfb_buffer: [STACK_SPACE_TO_USE]u8 = undefined;
    var sfb: std.heap.BufferFirstAllocator = .init(&sfb_buffer, bun.default_allocator);
    var arena = bun.ArenaAllocator.init(sfb.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const new_load_hint: SourceMapLoadHint, const parsed = parsed: {
        var inline_err: ?anyerror = null;

        // try to get an inline source map
        if (load_hint != .is_external_map) try_inline: {
            const found_url = input.inline_url orelse break :try_inline;

            const parsed = parseUrl(
                bun.default_allocator,
                allocator,
                found_url,
                result,
            ) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                inline_err = err;
                break :try_inline;
            };

            break :parsed .{
                .is_inline_map,
                parsed,
            };
        }

        // try to load a .map file
        if (load_hint != .is_inline_map) try_external: {
            const data = input.external_json orelse file: {
                if (!input.allow_external_file) break :try_external;
                const load_path = try std.mem.concat(allocator, u8, &.{ source_filename, ".map" });
                break :file std.Io.Dir.cwd().readFileAlloc(io, load_path, allocator, .unlimited) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => break :try_external,
                };
            };
            if (data.len == 0) break :try_external;

            break :parsed .{
                .is_external_map,
                parseJSON(
                    bun.default_allocator,
                    allocator,
                    data,
                    result,
                ) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    // Print warning even if this came from non-visible code like
                    // calling `error.stack`. This message is only printed if
                    // the sourcemap has been found but is invalid, such as being
                    // invalid JSON text or corrupt mappings.
                    bun.Output.warn("Could not decode sourcemap in '{s}': {s}", .{
                        source_filename,
                        @errorName(err),
                    });
                    return .invalid;
                },
            };
        }

        if (inline_err) |err| {
            bun.Output.warn("Could not decode sourcemap in '{s}': {s}", .{
                source_filename,
                @errorName(err),
            });
            return .invalid;
        }

        return .missing;
    };
    if (parsed.map) |ptr| {
        input.ref();
        ptr.source_content = .{ .input = .{
            .data = input,
            .load_hint = new_load_hint,
        } };
    }
    return .{ .parsed = parsed };
}

/// The sourcemap spec says line and column offsets are zero-based
pub const LineColumnOffset = struct {
    /// The zero-based line offset
    lines: bun.Ordinal = bun.Ordinal.start,
    /// The zero-based column offset
    columns: bun.Ordinal = bun.Ordinal.start,

    pub fn fromOptional(line: ?u32, column: ?u32) ?LineColumnOffset {
        return .{
            .lines = if (line) |n| .fromZeroBased(std.math.cast(i32, n) orelse return null) else .invalid,
            .columns = if (column) |n| .fromZeroBased(std.math.cast(i32, n) orelse return null) else .invalid,
        };
    }

    pub const Optional = union(enum) {
        null: void,
        value: LineColumnOffset,

        pub fn advance(this: *Optional, input: []const u8) void {
            switch (this.*) {
                .null => {},
                .value => |*v| v.advance(input),
            }
        }

        pub fn reset(this: *Optional) void {
            switch (this.*) {
                .null => {},
                .value => this.* = .{ .value = .{} },
            }
        }
    };

    pub fn add(this: *LineColumnOffset, b: LineColumnOffset) void {
        if (b.lines.zeroBased() == 0) {
            this.columns = this.columns.add(b.columns);
        } else {
            this.lines = this.lines.add(b.lines);
            this.columns = b.columns;
        }
    }

    pub fn advance(this_ptr: *LineColumnOffset, input: []const u8) void {
        // Instead of mutating `this_ptr` directly, copy the state to the stack and do
        // all the work here, then move it back to the input pointer. When sourcemaps
        // are enabled, this function is extremely hot.
        var this = this_ptr.*;
        defer this_ptr.* = this;

        bun.debugAssert(std.unicode.wtf8ValidateSlice(input));
        var offset: u32 = 0;
        while (strings.indexOfNewlineOrNonASCII(input, offset)) |i| {
            assert(i >= offset);
            assert(i < input.len);

            var iterator = std.unicode.Wtf8Iterator{
                .bytes = input,
                .i = i,
            };
            const codepoint = iterator.nextCodepoint().?;
            offset = @intCast(iterator.i);

            switch (codepoint) {
                '\r', '\n', 0x2028, 0x2029 => {
                    // Handle Windows-specific "\r\n" newlines
                    if (codepoint == '\r' and input.len > i + 1 and input[i + 1] == '\n') {
                        this.columns = this.columns.addScalar(1);
                        continue;
                    }

                    this.lines = this.lines.addScalar(1);
                    this.columns = bun.Ordinal.start;
                },
                else => |c| {
                    // Mozilla's "source-map" library counts columns using UTF-16 code units
                    this.columns = this.columns.addScalar(switch (c) {
                        0...0xFFFF => 1,
                        else => 2,
                    });
                },
            }
        }

        const remain = input[offset..];

        if (bun.Environment.allow_assert) {
            assert(bun.strings.isAllASCII(remain));
            assert(!bun.strings.containsChar(remain, '\n'));
            assert(!bun.strings.containsChar(remain, '\r'));
        }

        this.columns = this.columns.addScalar(@intCast(remain.len));
    }

    pub fn comesBefore(a: LineColumnOffset, b: LineColumnOffset) bool {
        return a.lines.zeroBased() < b.lines.zeroBased() or (a.lines.zeroBased() == b.lines.zeroBased() and a.columns.zeroBased() < b.columns.zeroBased());
    }

    pub fn cmp(_: void, a: LineColumnOffset, b: LineColumnOffset) std.math.Order {
        if (a.lines.zeroBased() != b.lines.zeroBased()) {
            return std.math.order(a.lines.zeroBased(), b.lines.zeroBased());
        }

        return std.math.order(a.columns.zeroBased(), b.columns.zeroBased());
    }
};

pub fn find(
    this: *const SourceMap,
    line: bun.Ordinal,
    column: bun.Ordinal,
) ?Mapping {
    return this.mapping.find(line, column);
}

pub const SourceMapShifts = struct {
    before: LineColumnOffset,
    after: LineColumnOffset,
};

pub const SourceMapPieces = struct {
    prefix: std.array_list.Managed(u8),
    mappings: std.array_list.Managed(u8),
    suffix: std.array_list.Managed(u8),

    pub fn init(allocator: std.mem.Allocator) SourceMapPieces {
        return .{
            .prefix = std.array_list.Managed(u8).init(allocator),
            .mappings = std.array_list.Managed(u8).init(allocator),
            .suffix = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(this: *SourceMapPieces) void {
        const allocator = this.prefix.allocator;
        this.prefix.deinit();
        this.mappings.deinit();
        this.suffix.deinit();
        this.* = init(allocator);
    }

    pub fn finalize(this: *SourceMapPieces, allocator: std.mem.Allocator, _shifts: []SourceMapShifts) ![]const u8 {
        var shifts = _shifts;
        var start_of_run: usize = 0;
        var current: usize = 0;
        var generated = LineColumnOffset{};
        var prev_shift_column_delta: i32 = 0;

        // the joiner's node allocator contains string join nodes as well as some vlq encodings
        // it doesnt contain json payloads or source code, so 16kb is probably going to cover
        // most applications.
        var sfb_buffer: [16384]u8 = undefined;
        var sfb: std.heap.BufferFirstAllocator = .init(&sfb_buffer, bun.default_allocator);
        var j = StringJoiner{ .allocator = sfb.allocator() };
        defer j.deinit();

        try j.pushStatic(this.prefix.items);
        const mappings = this.mappings.items;

        while (current < mappings.len) {
            if (mappings[current] == ';') {
                generated.lines = generated.lines.addScalar(1);
                generated.columns = bun.Ordinal.start;
                prev_shift_column_delta = 0;
                current += 1;
                continue;
            }

            const potential_end_of_run = current;

            const decode_result = decodeVLQ(mappings, current);
            generated.columns = generated.columns.addScalar(decode_result.value);
            current = decode_result.start;

            const potential_start_of_run = current;

            current = decodeVLQAssumeValid(mappings, current).start;
            current = decodeVLQAssumeValid(mappings, current).start;
            current = decodeVLQAssumeValid(mappings, current).start;

            if (current < mappings.len) {
                const c = mappings[current];
                if (c != ',' and c != ';') {
                    current = decodeVLQAssumeValid(mappings, current).start;
                }
            }

            if (current < mappings.len and mappings[current] == ',') {
                current += 1;
            }

            var did_cross_boundary = false;
            if (shifts.len > 1 and shifts[1].before.comesBefore(generated)) {
                shifts = shifts[1..];
                did_cross_boundary = true;
            }

            if (!did_cross_boundary) {
                continue;
            }

            const shift = shifts[0];
            if (shift.after.lines.zeroBased() != generated.lines.zeroBased()) {
                continue;
            }

            try j.pushStatic(mappings[start_of_run..potential_end_of_run]);

            assert(shift.before.lines.zeroBased() == shift.after.lines.zeroBased());

            const shift_column_delta = shift.after.columns.zeroBased() - shift.before.columns.zeroBased();
            const vlq_value = decode_result.value + shift_column_delta - prev_shift_column_delta;
            const encode = VLQ.encode(vlq_value);
            try j.pushCloned(encode.slice());
            prev_shift_column_delta = shift_column_delta;

            start_of_run = potential_start_of_run;
        }

        try j.pushStatic(mappings[start_of_run..]);

        const str = try j.doneWithEnd(allocator, this.suffix.items);
        bun.assert(str[0] == '{'); // invalid json
        return str;
    }
};

// -- comment from esbuild --
// Source map chunks are computed in parallel for speed. Each chunk is relative
// to the zero state instead of being relative to the end state of the previous
// chunk, since it's impossible to know the end state of the previous chunk in
// a parallel computation.
//
// After all chunks are computed, they are joined together in a second pass.
// This rewrites the first mapping in each chunk to be relative to the end
// state of the previous chunk.
pub fn appendSourceMapChunk(
    j: *StringJoiner,
    allocator: std.mem.Allocator,
    prev_end_state_: SourceMapState,
    start_state_: SourceMapState,
    source_map_: []const u8,
) !void {
    var prev_end_state = prev_end_state_;
    var start_state = start_state_;
    // Handle line breaks in between this mapping and the previous one
    if (start_state.generated_line != 0) {
        try j.push(try strings.repeatingAlloc(allocator, @intCast(start_state.generated_line), ';'), allocator);
        prev_end_state.generated_column = 0;
    }

    // Skip past any leading semicolons, which indicate line breaks
    var source_map = source_map_;
    if (strings.indexOfNotChar(source_map, ';')) |semicolons| {
        if (semicolons > 0) {
            try j.pushStatic(source_map[0..semicolons]);
            source_map = source_map[semicolons..];
            prev_end_state.generated_column = 0;
            start_state.generated_column = 0;
        }
    }

    // Strip off the first mapping from the buffer. The first mapping should be
    // for the start of the original file (the printer always generates one for
    // the start of the file).
    var i: usize = 0;
    const generated_column = decodeVLQAssumeValid(source_map, i);
    i = generated_column.start;
    const source_index = decodeVLQAssumeValid(source_map, i);
    i = source_index.start;
    const original_line = decodeVLQAssumeValid(source_map, i);
    i = original_line.start;
    const original_column = decodeVLQAssumeValid(source_map, i);
    i = original_column.start;

    source_map = source_map[i..];

    // Rewrite the first mapping to be relative to the end state of the previous
    // chunk. We now know what the end state is because we're in the second pass
    // where all chunks have already been generated.
    start_state.source_index += source_index.value;
    start_state.generated_column += generated_column.value;
    start_state.original_line += original_line.value;
    start_state.original_column += original_column.value;

    var str = MutableString.initEmpty(allocator);
    defer str.deinit();
    try appendMappingToBuffer(&str, j.lastByte(), prev_end_state, start_state);
    try j.push(try str.list.toOwnedSlice(allocator), allocator);

    // Then append everything after that without modification.
    try j.pushStatic(source_map);
}

/// This function is extremely hot.
pub fn appendMappingToBuffer(buffer: *MutableString, last_byte: u8, prev_state: SourceMapState, current_state: SourceMapState) bun.OOM!void {
    const needs_comma = last_byte != 0 and last_byte != ';' and last_byte != '"';

    const vlqs = [_]VLQ{
        // Record the generated column (the line is recorded using ';' elsewhere)
        .encode(current_state.generated_column -| prev_state.generated_column),
        // Record the generated source
        .encode(current_state.source_index -| prev_state.source_index),
        // Record the original line
        .encode(current_state.original_line -| prev_state.original_line),
        // Record the original column
        .encode(current_state.original_column -| prev_state.original_column),
    };

    // Count exactly how many bytes we need to write
    const total_len = @as(usize, vlqs[0].len) +
        @as(usize, vlqs[1].len) +
        @as(usize, vlqs[2].len) +
        @as(usize, vlqs[3].len);

    // Instead of updating .len 5 times, we only need to update it once.
    var writable = try buffer.writableNBytes(total_len + @as(usize, @intFromBool(needs_comma)));

    // Put commas in between mappings
    if (needs_comma) {
        writable[0] = ',';
        writable = writable[1..];
    }

    inline for (&vlqs) |item| {
        @memcpy(writable[0..item.len], item.slice());
        writable = writable[item.len..];
    }
}

pub const Chunk = @import("./Chunk.zig");

/// https://sentry.engineering/blog/the-case-for-debug-ids
/// https://github.com/mitsuhiko/source-map-rfc/blob/proposals/debug-id/proposals/debug-id.md
/// https://github.com/source-map/source-map-rfc/pull/20
/// https://github.com/getsentry/rfcs/blob/main/text/0081-sourcemap-debugid.md#the-debugid-format
pub const DebugIDFormatter = struct {
    id: u64 = 0,

    pub fn format(self: DebugIDFormatter, writer: *std.Io.Writer) !void {
        // The RFC asks for a UUID, which is 128 bits (32 hex chars). Our hashes are only 64 bits.
        // We fill the end of the id with "bun!bun!" hex encoded
        var buf: [32]u8 = undefined;
        const formatter = bun.fmt.hexIntUpper(self.id);
        _ = std.fmt.bufPrint(&buf, "{f}64756E2164756E21", .{formatter}) catch unreachable;
        try writer.writeAll(&buf);
    }
};

pub const VLQ = @import("./VLQ.zig");
pub const LineOffsetTable = @import("./LineOffsetTable.zig");
pub const InternalSourceMap = @import("./InternalSourceMap.zig");

const decodeVLQAssumeValid = VLQ.decodeAssumeValid;
const decodeVLQ = VLQ.decode;

const string = []const u8;

const std = @import("std");

const bun = @import("bun");
const Logger = bun.logger;
const MutableString = bun.MutableString;
const StringJoiner = bun.StringJoiner;
const assert = bun.assert;
const strings = bun.strings;
