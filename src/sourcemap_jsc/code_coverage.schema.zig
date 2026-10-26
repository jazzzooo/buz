const b = @import("bindgen_schema");

const code_coverage_generator = b.nominalHandle("CodeCoverageGenerator", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::CodeCoverageGeneratorNative" } },
    .cpp_declarations = &.{.{ .structure = "Bun::CodeCoverageGeneratorNative" }},
    .zig_type = "api.SourceMapCoverage.Report.Generator",
    .access_thread = .vm,
});

/// Includes startUTF16 and excludes endUTF16.
const code_coverage_range = b.dictionary("CodeCoverageRange", .{
    b.dictionaryField("startUTF16", b.uint32, .{ .required = true }),
    b.dictionaryField("endUTF16", b.uint32, .{ .required = true }),
    b.dictionaryField("executionCount", b.uint64, .{ .required = true }),
});

const engine_shims = .{b.engineShim(
    "codeCoverageWithBlocksAndFunctions",
    .{
        b.argument("generator", code_coverage_generator, .{}),
        b.argument("sourceID", b.uint32, .{}),
        b.argument("ignoreSourceMap", b.boolean, .{}),
    },
    b.none,
    .current_realm_throwing,
)};

const native_exports = .{
    b.nativeExportWithOptions("codeCoverageShouldGenerate", .{b.argument("sourceURL", b.dom_string, .{})}, b.boolean, .allocating),
    b.nativeExportWithOptions("byteRangeMappingGenerate", .{
        b.argument("sourceURL", b.dom_string, .{}),
        b.argument("source", b.dom_string, .{}),
        b.argument("sourceID", b.uint32, .{}),
    }, b.none, .allocating),
    b.nativeExport(
        "byteRangeMappingSourceID",
        .{b.argument("sourceURL", b.dom_string, .{})},
        b.optional(b.uint32),
    ),
    b.nativeExportWithOptions("codeCoverageConsumeBlocks", .{
        b.argument("generator", code_coverage_generator, .{}),
        b.argument("blocks", b.sequence(code_coverage_range), .{}),
        b.argument("functions", b.sequence(code_coverage_range), .{}),
        b.argument("ignoreSourceMap", b.boolean, .{}),
    }, b.none, .current_realm_throwing),
    b.nativeExportWithOptions("byteRangeMappingFindExecutedLines", .{
        b.argument("sourceURL", b.dom_string, .{}),
        b.argument("blocks", b.sequence(code_coverage_range), .{}),
        b.argument("functions", b.sequence(code_coverage_range), .{}),
        b.argument("ignoreSourceMap", b.boolean, .{}),
    }, b.optional(b.dom_string), .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("code_coverage", .{}, .{}, engine_shims, native_exports);
