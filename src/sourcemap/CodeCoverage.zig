const LinesHits = bun.collections.BabyList(u32);

pub const Report = struct {
    source_url: []const u8,
    executable_lines: Bitset,
    lines_which_have_executed: Bitset,
    line_hits: LinesHits = .{},
    functions: std.ArrayListUnmanaged(Block),
    functions_which_have_executed: Bitset,
    stmts_which_have_executed: Bitset,
    stmts: std.ArrayListUnmanaged(Block),
    total_lines: u32 = 0,

    pub fn linesCoverageFraction(this: *const Report) f64 {
        const total_count: f64 = @floatFromInt(this.executable_lines.count());
        if (total_count == 0) {
            return 1.0;
        }

        const intersected_count: f64 = @floatFromInt(this.coveredLineCount());

        return (intersected_count / total_count);
    }

    fn coveredLineCount(this: *const Report) usize {
        var count: usize = 0;
        var lines = this.executable_lines.iterator(.{});
        while (lines.next()) |line| {
            count += @intFromBool(this.lines_which_have_executed.isSet(line));
        }
        return count;
    }

    pub fn stmtsCoverageFraction(this: *const Report) f64 {
        const total_count: f64 = @floatFromInt(this.stmts.items.len);

        if (total_count == 0) {
            return 1.0;
        }

        return ((@as(f64, @floatFromInt(this.stmts_which_have_executed.count()))) / (total_count));
    }

    pub fn functionCoverageFraction(this: *const Report) f64 {
        const total_count: f64 = @floatFromInt(this.functions.items.len);
        if (total_count == 0) {
            return 1.0;
        }
        return (@as(f64, @floatFromInt(this.functions_which_have_executed.count())) / total_count);
    }

    pub const Text = struct {
        pub const writeFormatWithValues = CoverageReportText.writeFormatWithValues;

        pub fn writeFormat(
            report: *const Report,
            max_filename_length: usize,
            fraction: *Fraction,
            base_path: []const u8,
            allocator: std.mem.Allocator,
            writer: *std.Io.Writer,
            comptime enable_colors: bool,
        ) !void {
            const failing = fraction.*;
            const fns = report.functionCoverageFraction();
            const lines = report.linesCoverageFraction();
            const stmts = report.stmtsCoverageFraction();
            fraction.functions = fns;
            fraction.lines = lines;
            fraction.stmts = stmts;

            const failed = fns < failing.functions or lines < failing.lines; // or stmts < failing.stmts;
            fraction.failing = failed;

            var filename = report.source_url;
            var filename_owned: ?[]u8 = null;
            defer if (filename_owned) |path| allocator.free(path);
            if (base_path.len > 0) {
                filename_owned = try std.fs.path.relative(allocator, base_path, null, base_path, filename);
                bun.path.platformToPosixInPlace(u8, filename_owned.?);
                filename = filename_owned.?;
            }

            try writeFormatWithValues(
                filename,
                max_filename_length,
                fraction.*,
                failing,
                failed,
                writer,
                true,
                enable_colors,
            );

            try writer.writeAll(comptime prettyFmt("<r><d> | <r>", enable_colors));

            var iter = report.executable_lines.iterator(.{});
            var range: ?struct { start: usize, end: usize } = null;
            var is_first = true;
            while (iter.next()) |line| {
                if (report.lines_which_have_executed.isSet(line)) continue;
                if (range) |*pending| {
                    if (line == pending.end + 1) {
                        pending.end = line;
                        continue;
                    }
                    try writeUncoveredRange(writer, pending.start, pending.end, &is_first, enable_colors);
                }
                range = .{ .start = line, .end = line };
            }
            if (range) |pending| {
                try writeUncoveredRange(writer, pending.start, pending.end, &is_first, enable_colors);
            }
        }

        fn writeUncoveredRange(writer: *std.Io.Writer, start: usize, end: usize, is_first: *bool, comptime enable_colors: bool) !void {
            if (!is_first.*) {
                try writer.writeAll(comptime prettyFmt("<r><d>,<r>", enable_colors));
            }
            is_first.* = false;
            if (start == end) {
                try writer.print(comptime prettyFmt("<red>{d}", enable_colors), .{start + 1});
            } else {
                try writer.print(comptime prettyFmt("<red>{d}-{d}", enable_colors), .{ start + 1, end + 1 });
            }
        }
    };

    pub const Lcov = struct {
        pub fn writeFormat(
            report: *const Report,
            base_path: []const u8,
            allocator: std.mem.Allocator,
            writer: *std.Io.Writer,
        ) !void {
            var filename = report.source_url;
            var filename_owned: ?[]u8 = null;
            defer if (filename_owned) |path| allocator.free(path);
            if (base_path.len > 0) {
                filename_owned = try std.fs.path.relative(allocator, base_path, null, base_path, filename);
                bun.path.platformToPosixInPlace(u8, filename_owned.?);
                filename = filename_owned.?;
            }

            // TN: test name
            // Empty value appears fine. For example, `TN:`.
            try writer.writeAll("TN:\n");

            // SF: Source File path
            // For example, `SF:path/to/source.ts`
            try writer.print("SF:{s}\n", .{filename});

            // ** Per-function coverage not supported yet, since JSC does not support function names yet. **
            // FN: line number,function name

            // FNF: functions found
            try writer.print("FNF:{d}\n", .{report.functions.items.len});

            // FNH: functions hit
            try writer.print("FNH:{d}\n", .{report.functions_which_have_executed.count()});

            // ** Track all executable lines **
            // Executable lines that were not hit should be marked as 0
            var iter = report.executable_lines.iterator(.{});

            // ** Branch coverage not supported yet, since JSC does not support those yet. ** //
            // BRDA: line, block, (expressions,count)+
            // BRF: branches found
            // BRH: branches hit
            const line_hits = report.line_hits.slice();
            while (iter.next()) |line| {
                // DA: line number, hit count
                try writer.print("DA:{d},{d}\n", .{ line + 1, line_hits[line] });
            }

            // LF: lines found
            try writer.print("LF:{d}\n", .{report.executable_lines.count()});

            // LH: lines hit
            try writer.print("LH:{d}\n", .{report.coveredLineCount()});

            try writer.writeAll("end_of_record\n");
        }
    };

    pub fn deinit(this: *Report, allocator: std.mem.Allocator) void {
        allocator.free(this.source_url);
        this.executable_lines.deinit(allocator);
        this.lines_which_have_executed.deinit(allocator);
        this.line_hits.deinit(allocator);
        this.functions.deinit(allocator);
        this.stmts.deinit(allocator);
        this.functions_which_have_executed.deinit(allocator);
        this.stmts_which_have_executed.deinit(allocator);
    }

    pub const Generator = struct {
        allocator: std.mem.Allocator,
        byte_range_mapping: *ByteRangeMapping,
        result: *?Report,

        pub fn consume(
            this: *@This(),
            blocks: []const CoverageRange,
            function_blocks: []const CoverageRange,
            ignore_sourcemap: bool,
            parsed_mapping: ?*ParsedSourceMap,
        ) bun.OOM!void {
            if (blocks.len == 0 and function_blocks.len == 0) {
                return;
            }

            this.result.* = try this.byte_range_mapping.generateReportFromBlocks(
                this.allocator,
                this.byte_range_mapping.source_url,
                blocks,
                function_blocks,
                ignore_sourcemap,
                parsed_mapping,
            );
        }
    };
};

pub const CoverageRange = struct {
    /// Half-open UTF-16 offsets in the generated source.
    start: u32,
    end: u32,
    execution_count: u64 = 0,
};

pub const ByteRangeMapping = struct {
    source_index: SourceIndex,
    source_id: u32,
    source_url: []const u8,

    pub fn isLessThan(_: void, a: ByteRangeMapping, b: ByteRangeMapping) bool {
        return bun.strings.order(a.source_url, b.source_url) == .lt;
    }

    pub const HashMap = bun.StringHashMap(ByteRangeMapping);

    pub fn deinit(this: *ByteRangeMapping, allocator: std.mem.Allocator) void {
        this.source_index.deinit(allocator);
        allocator.free(this.source_url);
    }

    pub threadlocal var map: ?*HashMap = null;
    /// Consumes `source_url` on both success and failure.
    pub fn generate(allocator: std.mem.Allocator, source_url: []const u8, source_contents: []const u8, source_id: u32) bun.OOM!void {
        var replacement = compute(allocator, source_contents, source_id, source_url) catch |err| {
            allocator.free(source_url);
            return err;
        };
        errdefer replacement.deinit(allocator);
        const path = source_url;
        const _map = map orelse {
            const new_map = try allocator.create(HashMap);
            errdefer allocator.destroy(new_map);
            new_map.* = HashMap.init(allocator);
            errdefer new_map.deinit();
            try new_map.put(path, replacement);
            map = new_map;
            return;
        };
        const entry = try _map.getOrPut(path);
        entry.key_ptr.* = path;
        if (entry.found_existing) {
            entry.value_ptr.deinit(allocator);
        }

        entry.value_ptr.* = replacement;
    }

    pub fn findSlice(path: []const u8) ?*ByteRangeMapping {
        var map_ = map orelse return null;
        return map_.getPtr(path);
    }

    const RangeRecorder = struct {
        executable_lines: *Bitset,
        executed_lines: *Bitset,
        line_hits: []u32,
        hit_count: u32 = 0,
        mark_executable: bool = true,

        fn record(this: *RangeRecorder, line: u32, range: *?Block) void {
            if (line >= this.line_hits.len) return;
            if (this.mark_executable) this.executable_lines.set(line);
            if (this.hit_count > 0) {
                this.executed_lines.set(line);
                // Overlapping blocks on a line contribute their maximum execution count.
                this.line_hits[line] = @max(this.line_hits[line], this.hit_count);
            }
            if (range.*) |*bounds| {
                bounds.start_line = @min(bounds.start_line, line);
                bounds.end_line = @max(bounds.end_line, line);
            } else {
                range.* = .{ .start_line = line, .end_line = line };
            }
        }
    };

    fn recordRange(this: *const ByteRangeMapping, block: CoverageRange, mapping: ?*ParsedSourceMap, recorder: *RangeRecorder) ?Block {
        var offset = block.start;
        const end = @min(block.end, this.source_index.length);
        if (offset >= end) return null;
        var line_index = this.source_index.lineAt(offset);
        var cursor = if (mapping) |source_map| source_map.internalCursor() else null;
        var range: ?Block = null;
        while (offset < end) {
            const source_line = this.source_index.lines[line_index];
            if (offset >= source_line.content_end) {
                line_index += 1;
                if (line_index == this.source_index.lines.len) break;
                offset = @max(offset, this.source_index.lines[line_index].start);
                continue;
            }
            const line_end = @min(end, source_line.content_end);
            if (mapping) |source_map| {
                while (offset < line_end) : (offset += 1) {
                    const line = bun.Ordinal.fromZeroBased(@intCast(line_index));
                    const column = bun.Ordinal.fromZeroBased(@intCast(offset - source_line.start));
                    const point = if (cursor) |*current|
                        current.moveTo(line, column)
                    else
                        source_map.findMapping(line, column);
                    if (point) |found| {
                        const original_line = found.original.lines.zeroBased();
                        if (original_line >= 0) recorder.record(@intCast(original_line), &range);
                    }
                }
            } else {
                recorder.record(@intCast(line_index), &range);
                offset = line_end;
            }
        }
        return range;
    }

    pub fn generateReportFromBlocks(
        this: *ByteRangeMapping,
        allocator: std.mem.Allocator,
        source_url: []const u8,
        blocks: []const CoverageRange,
        function_blocks: []const CoverageRange,
        ignore_sourcemap: bool,
        parsed_mapping: ?*ParsedSourceMap,
    ) !Report {
        const mapping = if (ignore_sourcemap) null else parsed_mapping;
        const line_count = if (mapping) |source_map|
            std.math.cast(u32, std.math.add(usize, source_map.input_line_count, 1) catch return error.OutOfMemory) orelse return error.OutOfMemory
        else
            std.math.cast(u32, this.source_index.lines.len) orelse return error.OutOfMemory;
        var executable_lines = try Bitset.initEmpty(allocator, line_count);
        errdefer executable_lines.deinit(allocator);
        var lines_which_have_executed = try Bitset.initEmpty(allocator, line_count);
        errdefer lines_which_have_executed.deinit(allocator);
        var line_hits = try LinesHits.initCapacity(allocator, line_count);
        errdefer line_hits.deinit(allocator);
        line_hits.len = line_count;
        @memset(line_hits.slice(), 0);
        var functions = std.ArrayListUnmanaged(Block).empty;
        try functions.ensureTotalCapacityPrecise(allocator, function_blocks.len);
        errdefer functions.deinit(allocator);
        var functions_which_have_executed: Bitset = try Bitset.initEmpty(allocator, function_blocks.len);
        errdefer functions_which_have_executed.deinit(allocator);
        var stmts_which_have_executed: Bitset = try Bitset.initEmpty(allocator, blocks.len);
        errdefer stmts_which_have_executed.deinit(allocator);

        var stmts = std.ArrayListUnmanaged(Block).empty;
        try stmts.ensureTotalCapacityPrecise(allocator, blocks.len);
        errdefer stmts.deinit(allocator);

        var recorder = RangeRecorder{
            .executable_lines = &executable_lines,
            .executed_lines = &lines_which_have_executed,
            .line_hits = line_hits.slice(),
        };
        for (blocks) |block| {
            const executed = block.execution_count > 0;
            recorder.hit_count = std.math.lossyCast(u32, block.execution_count);
            if (this.recordRange(block, mapping, &recorder)) |range| {
                if (executed) stmts_which_have_executed.set(stmts.items.len);
                stmts.appendAssumeCapacity(range);
            }
        }
        recorder.hit_count = 0;
        for (function_blocks) |function| {
            const executed = function.execution_count > 0;
            recorder.mark_executable = !executed;
            if (this.recordRange(function, mapping, &recorder)) |range| {
                if (executed) functions_which_have_executed.set(functions.items.len);
                functions.appendAssumeCapacity(range);
            }
        }

        return .{
            .source_url = try allocator.dupe(u8, source_url),
            .functions = functions,
            .executable_lines = executable_lines,
            .lines_which_have_executed = lines_which_have_executed,
            .line_hits = line_hits,
            .total_lines = line_count,
            .stmts = stmts,
            .functions_which_have_executed = functions_which_have_executed,
            .stmts_which_have_executed = stmts_which_have_executed,
        };
    }

    pub fn writeExecutedLines(
        allocator: std.mem.Allocator,
        source_url: []const u8,
        blocks: []const CoverageRange,
        function_blocks: []const CoverageRange,
        ignore_sourcemap: bool,
        parsed_mapping: ?*ParsedSourceMap,
        writer: *std.Io.Writer,
    ) bun.OOM!bool {
        var this = ByteRangeMapping.findSlice(source_url) orelse return false;
        var report = this.generateReportFromBlocks(
            allocator,
            source_url,
            blocks,
            function_blocks,
            ignore_sourcemap,
            parsed_mapping,
        ) catch return error.OutOfMemory;
        defer report.deinit(allocator);

        var coverage_fraction = Fraction{};

        Report.Text.writeFormat(&report, source_url.len, &coverage_fraction, "", allocator, writer, false) catch return error.OutOfMemory;
        return true;
    }

    pub fn compute(allocator: std.mem.Allocator, source_contents: []const u8, source_id: u32, source_url: []const u8) bun.OOM!ByteRangeMapping {
        return ByteRangeMapping{
            .source_index = try SourceIndex.init(allocator, std.unicode.Wtf8View.init(source_contents) catch unreachable),
            .source_id = source_id,
            .source_url = source_url,
        };
    }
};

pub const Fraction = @import("./CoverageFraction.zig").Fraction;

pub const Block = struct {
    start_line: u32 = 0,
    end_line: u32 = 0,
};

const SourceIndex = struct {
    const Line = struct { start: u32, content_end: u32 };
    lines: []const Line,
    length: u32,

    fn init(allocator: std.mem.Allocator, source: std.unicode.Wtf8View) bun.OOM!SourceIndex {
        var lines: std.ArrayList(Line) = .empty;
        defer lines.deinit(allocator);
        var offset: u32 = 0;
        var line_start: u32 = 0;
        var previous_cr = false;
        var chars = source.iterator();
        while (chars.nextCodepoint()) |char| {
            const start = offset;
            offset = std.math.add(u32, offset, if (char > 0xffff) 2 else 1) catch return error.OutOfMemory;
            if (offset > std.math.maxInt(i32)) return error.OutOfMemory;
            if (char == '\n' and previous_cr) {
                line_start = offset;
                previous_cr = false;
                continue;
            }
            previous_cr = char == '\r';
            switch (char) {
                '\r', '\n', 0x2028, 0x2029 => {
                    try lines.append(allocator, .{ .start = line_start, .content_end = start });
                    line_start = offset;
                },
                else => {},
            }
        }
        try lines.append(allocator, .{ .start = line_start, .content_end = offset });
        return .{ .lines = try lines.toOwnedSlice(allocator), .length = offset };
    }

    fn deinit(this: *SourceIndex, allocator: std.mem.Allocator) void {
        allocator.free(this.lines);
    }

    fn lineAt(this: SourceIndex, offset: u32) usize {
        var start: usize = 0;
        var end = this.lines.len;
        while (start < end) {
            const middle = start + (end - start) / 2;
            if (this.lines[middle].start <= offset) {
                start = middle + 1;
            } else {
                end = middle;
            }
        }
        return start - 1;
    }
};

test "coverage URL replacement and reports clean up on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const previous_map = ByteRangeMapping.map;
            ByteRangeMapping.map = null;
            defer ByteRangeMapping.map = previous_map;
            defer if (ByteRangeMapping.map) |map| {
                var entries = map.valueIterator();
                while (entries.next()) |entry| entry.deinit(allocator);
                map.deinit();
                allocator.destroy(map);
            };

            try ByteRangeMapping.generate(allocator, try allocator.dupe(u8, "first.js"), "a\n", 1);
            try ByteRangeMapping.generate(allocator, try allocator.dupe(u8, "café.js"), "é\n", 0x80000000);
            const replacement_url = try allocator.dupe(u8, "first.js");
            ByteRangeMapping.generate(allocator, replacement_url, "é\n", 3) catch |err| {
                try std.testing.expectEqual(@as(u32, 1), ByteRangeMapping.findSlice("first.js").?.source_id);
                try std.testing.expectEqual(@as(u32, 0x80000000), ByteRangeMapping.findSlice("café.js").?.source_id);
                try std.testing.expectEqual(@as(u32, 2), ByteRangeMapping.map.?.count());
                return err;
            };
            try std.testing.expectEqual(@as(u32, 2), ByteRangeMapping.map.?.count());
            try std.testing.expect(ByteRangeMapping.findSlice("missing.js") == null);
            try std.testing.expectEqual(@as(u32, 0x80000000), ByteRangeMapping.findSlice("café.js").?.source_id);
            const mapping = ByteRangeMapping.findSlice("first.js").?;
            try std.testing.expectEqual(@as(u32, 3), mapping.source_id);

            var report = try mapping.generateReportFromBlocks(allocator, mapping.source_url, &.{.{
                .start = 0,
                .end = 2,
                .execution_count = 1,
            }}, &.{}, true, null);
            defer report.deinit(allocator);
            try std.testing.expectEqualStrings("first.js", report.source_url);
        }
    }.run, .{});
}

test "coverage formatting retains uncovered single lines without allocating bitsets" {
    const allocator = std.testing.allocator;
    const source_url = try allocator.dupe(u8, "file.js");
    const source: [8][2]u8 = @splat("x\n".*);
    var mapping = ByteRangeMapping.compute(allocator, std.mem.asBytes(&source), 1, source_url) catch |err| {
        allocator.free(source_url);
        return err;
    };
    defer mapping.deinit(allocator);
    var report = try mapping.generateReportFromBlocks(allocator, mapping.source_url, &.{}, &.{}, true, null);
    defer report.deinit(allocator);
    for ([_]usize{ 0, 1, 2, 3, 4, 7 }) |line| report.executable_lines.set(line);
    for ([_]usize{ 0, 2, 6 }) |line| report.lines_which_have_executed.set(line);
    try std.testing.expectEqual(@as(f64, 1.0 / 3.0), report.linesCoverageFraction());

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var text_buffer: [1024]u8 = undefined;
    var text = std.Io.Writer.fixed(&text_buffer);
    var fraction = Fraction{};
    try Report.Text.writeFormat(&report, 7, &fraction, "", failing.allocator(), &text, false);
    try std.testing.expect(std.mem.endsWith(u8, text.buffered(), "2,4-5,8"));

    var lcov_buffer: [1024]u8 = undefined;
    var lcov = std.Io.Writer.fixed(&lcov_buffer);
    try Report.Lcov.writeFormat(&report, "", failing.allocator(), &lcov);
    try std.testing.expect(std.mem.indexOf(u8, lcov.buffered(), "LF:6\nLH:2\n") != null);
}

test "coverage ranges use UTF-16 offsets and profiler hit counts" {
    const allocator = std.testing.allocator;
    const source_url = try allocator.dupe(u8, "unicode.js");
    var mapping = ByteRangeMapping.compute(allocator, "é😀\r\nx\u{2028}y", 1, source_url) catch |err| {
        allocator.free(source_url);
        return err;
    };
    defer mapping.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 8), mapping.source_index.length);
    var report = try mapping.generateReportFromBlocks(allocator, source_url, &.{
        .{ .start = 0, .end = 1, .execution_count = 3 },
        .{ .start = 2, .end = 6, .execution_count = 7 },
        .{ .start = 7, .end = 8, .execution_count = 2 },
        .{ .start = 7, .end = 7, .execution_count = 100 },
        .{ .start = 8, .end = 11, .execution_count = 100 },
        .{ .start = 3, .end = 5, .execution_count = 100 },
    }, &.{
        .{ .start = 99, .end = 101 },
        .{ .start = 5, .end = 6 },
        .{ .start = 7, .end = 8, .execution_count = 1 },
    }, true, null);
    defer report.deinit(allocator);
    try std.testing.expectEqualSlices(u32, &.{ 7, 7, 2 }, report.line_hits.slice());
    try std.testing.expectEqual(@as(usize, 3), report.stmts.items.len);
    try std.testing.expectEqual(@as(usize, 2), report.functions.items.len);
    try std.testing.expectEqual(@as(f64, 1), report.linesCoverageFraction());
    try std.testing.expectEqual(@as(f64, 1), report.stmtsCoverageFraction());
    try std.testing.expectEqual(@as(f64, 0.5), report.functionCoverageFraction());

    const blob = try bun.SourceMap.InternalSourceMap.fromVLQ(allocator, "AAEA,CAEA;AAHA;AACA", 0);
    defer allocator.free(blob);
    var parsed: ParsedSourceMap = .{
        .ref_count = .init(),
        .input_line_count = 2,
        .internal = .{ .data = blob.ptr },
    };
    var remapped = try mapping.generateReportFromBlocks(allocator, source_url, &.{
        .{ .start = 0, .end = 6, .execution_count = 9 },
    }, &.{}, false, &parsed);
    defer remapped.deinit(allocator);
    try std.testing.expectEqualSlices(u32, &.{ 0, 9, 9 }, remapped.line_hits.slice());
}

const std = @import("std");

const bun = @import("bun");
const Bitset = std.bit_set.Dynamic;
const ParsedSourceMap = bun.SourceMap.ParsedSourceMap;

const Output = bun.Output;
const prettyFmt = Output.prettyFmt;
const CoverageReportText = @import("./CoverageReportText.zig");
