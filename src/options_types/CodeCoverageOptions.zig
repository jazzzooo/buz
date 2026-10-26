//! Coverage configuration shared by CLI parsing and reporting.

pub const CodeCoverageOptions = struct {
    skip_test_files: bool = !bun.Environment.allow_assert,
    reporters: Reporters = .{ .text = true, .lcov = false },
    reports_directory: []const u8 = "coverage",
    fractions: CoverageFraction = .{},
    ignore_sourcemap: bool = false,
    enabled: bool = false,
    fail_on_low_coverage: bool = false,
    ignore_patterns: []const []const u8 = &.{},
};

pub const Reporter = enum {
    text,
    lcov,
};

pub const Reporters = struct {
    text: bool,
    lcov: bool,
};

const bun = @import("bun");
const CoverageFraction = @import("../sourcemap/CoverageFraction.zig").Fraction;
