pub fn generate(
    global_this: *bun.jsc.JSGlobalObject,
    allocator: std.mem.Allocator,
    byte_range_mapping: *ByteRangeMapping,
    ignore_source_map: bool,
) bun.JSError!?Report {
    var result: ?Report = null;
    errdefer if (result) |*report| report.deinit(allocator);
    var generator: Report.Generator = .{
        .result = &result,
        .allocator = allocator,
        .byte_range_mapping = byte_range_mapping,
    };

    try bun.bindgen.Engine(CodeCoverageWithBlocksAndFunctionsSchema).call(global_this, .{
        .generator = @ptrCast(&generator),
        .sourceID = byte_range_mapping.source_id,
        .ignoreSourceMap = ignore_source_map,
    });

    return result;
}

fn copyRanges(allocator: std.mem.Allocator, blocks: anytype) bun.OOM![]CoverageRange {
    const result = try allocator.alloc(CoverageRange, blocks.len());
    errdefer allocator.free(result);
    for (result, 0..) |*block, index| {
        const input = blocks.at(index).?;
        block.* = .{
            .start = input.startUTF16,
            .end = input.endUTF16,
            .execution_count = input.executionCount,
        };
    }
    return result;
}

fn lookupSourceMap(source_url: []const u8, ignore_source_map: bool) bun.OOM!?ParsedSourceMapRef {
    if (ignore_source_map) return null;
    return bun.api.SourceMapEngine.lookup(source_url);
}

fn bindCodeCoverageConsumeBlocks(
    _: bun.bindgen.CallContext(CodeCoverageConsumeBlocksSchema),
    args: bun.bindgen.Args(CodeCoverageConsumeBlocksSchema),
) bun.JSError!bun.bindgen.Return(CodeCoverageConsumeBlocksSchema) {
    const blocks = try copyRanges(bun.default_allocator, args.blocks);
    defer bun.default_allocator.free(blocks);
    const functions = try copyRanges(bun.default_allocator, args.functions);
    defer bun.default_allocator.free(functions);

    var source_map = try lookupSourceMap(args.generator.byte_range_mapping.source_url, args.ignoreSourceMap);
    defer if (source_map) |*mapping| mapping.deinit();
    try args.generator.consume(
        blocks,
        functions,
        args.ignoreSourceMap,
        if (source_map) |mapping| mapping.get() else null,
    );
}

fn bindByteRangeMappingFindExecutedLines(
    _: bun.bindgen.CallContext(ByteRangeMappingFindExecutedLinesSchema),
    args: bun.bindgen.Args(ByteRangeMappingFindExecutedLinesSchema),
) bun.JSError!bun.bindgen.Return(ByteRangeMappingFindExecutedLinesSchema) {
    var source_url = try args.sourceURL.toUTF8(bun.default_allocator);
    defer source_url.deinit();
    const blocks = try copyRanges(bun.default_allocator, args.blocks);
    defer bun.default_allocator.free(blocks);
    const functions = try copyRanges(bun.default_allocator, args.functions);
    defer bun.default_allocator.free(functions);
    var source_map = try lookupSourceMap(source_url.slice(), args.ignoreSourceMap);
    defer if (source_map) |*mapping| mapping.deinit();

    var output = std.Io.Writer.Allocating.init(bun.default_allocator);
    defer output.deinit();
    if (!try ByteRangeMapping.writeExecutedLines(
        bun.default_allocator,
        source_url.slice(),
        blocks,
        functions,
        args.ignoreSourceMap,
        if (source_map) |mapping| mapping.get() else null,
        &output.writer,
    )) return null;
    output.writer.flush() catch return error.OutOfMemory;
    return try bun.bindgen.DOMString.fromUTF8(output.written());
}

fn bindByteRangeMappingGenerate(args: bun.bindgen.Args(ByteRangeMappingGenerateSchema)) bun.OOM!bun.bindgen.Return(ByteRangeMappingGenerateSchema) {
    var source_url = try args.sourceURL.toUTF8(bun.default_allocator);
    defer source_url.deinit();
    var source = try args.source.toUTF8(bun.default_allocator);
    defer source.deinit();
    const owned_source_url = try source_url.intoOwnedSlice(bun.default_allocator);
    try ByteRangeMapping.generate(
        bun.default_allocator,
        owned_source_url,
        source.slice(),
        args.sourceID,
    );
}

fn bindByteRangeMappingSourceID(args: bun.bindgen.Args(ByteRangeMappingSourceIDSchema)) bun.bindgen.Return(ByteRangeMappingSourceIDSchema) {
    const mappings = ByteRangeMapping.map orelse return null;
    const Lookup = struct {
        pub fn hash(_: @This(), path: bun.bindgen.DOMStringView) u64 {
            return path.hashUTF8();
        }

        pub fn eql(_: @This(), path: bun.bindgen.DOMStringView, key: []const u8) bool {
            return path.eqlUTF8(key);
        }
    };
    const mapping = mappings.getAdapted(args.sourceURL, Lookup{}) orelse return null;
    return mapping.source_id;
}

comptime {
    if (bun.Environment.isNative) {
        _ = CodeCoverageConsumeBlocksBinding;
        _ = ByteRangeMappingFindExecutedLinesBinding;
        _ = ByteRangeMappingGenerateBinding;
        _ = ByteRangeMappingSourceIDBinding;
    }
}

const std = @import("std");
const bun = @import("bun");
const coverage = @import("../sourcemap/CodeCoverage.zig");

const CoverageRange = coverage.CoverageRange;
const ByteRangeMapping = coverage.ByteRangeMapping;
const Report = coverage.Report;
const ParsedSourceMapRef = bun.bindgen.RefNative(bun.SourceMap.ParsedSourceMap, .any);

const CodeCoverageBindings = bun.bindgen.Module("code_coverage");
const CodeCoverageWithBlocksAndFunctionsSchema = CodeCoverageBindings.engineShim("codeCoverageWithBlocksAndFunctions");
const CodeCoverageConsumeBlocksSchema = CodeCoverageBindings.nativeExport("codeCoverageConsumeBlocks");
const ByteRangeMappingFindExecutedLinesSchema = CodeCoverageBindings.nativeExport("byteRangeMappingFindExecutedLines");
const ByteRangeMappingGenerateSchema = CodeCoverageBindings.nativeExport("byteRangeMappingGenerate");
const ByteRangeMappingSourceIDSchema = CodeCoverageBindings.nativeExport("byteRangeMappingSourceID");
const CodeCoverageConsumeBlocksBinding = bun.bindgen.Fn(CodeCoverageConsumeBlocksSchema, bindCodeCoverageConsumeBlocks);
const ByteRangeMappingFindExecutedLinesBinding = bun.bindgen.Fn(ByteRangeMappingFindExecutedLinesSchema, bindByteRangeMappingFindExecutedLines);
const ByteRangeMappingGenerateBinding = bun.bindgen.Fn(ByteRangeMappingGenerateSchema, bindByteRangeMappingGenerate);
const ByteRangeMappingSourceIDBinding = bun.bindgen.Fn(ByteRangeMappingSourceIDSchema, bindByteRangeMappingSourceID);
