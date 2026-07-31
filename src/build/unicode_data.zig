const std = @import("std");

const Build = std.Build;
const Module = Build.Module;

pub fn addModule(b: *Build, icu: *Build.Dependency) *Module {
    const generator = b.addExecutable(.{
        .name = "generate-unicode-tables",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode/generate_tables.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    generator.incremental = false;
    const run = b.addRunArtifact(generator);
    run.addFileArg2(icu.path("icu/source/data/unidata/ppucd.txt"), .{});
    const generated = run.addOutputFileArg2("unicode_tables.zig", .{});

    const tables = b.createModule(.{ .root_source_file = generated });
    const data = b.createModule(.{
        .root_source_file = b.path("src/unicode/data.zig"),
    });
    data.addImport("unicode_tables", tables);

    const grapheme = b.createModule(.{
        .root_source_file = b.path("src/string/immutable/grapheme.zig"),
        .imports = &.{
            .{ .name = "unicode_data", .module = data },
        },
    });
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/unicode/grapheme_test.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "grapheme", .module = grapheme },
        },
    });
    test_module.addAnonymousImport("grapheme_break_test", .{
        .root_source_file = icu.path("icu/source/test/testdata/GraphemeBreakTest.txt"),
    });
    const tests = b.addTest(.{ .root_module = test_module });
    tests.incremental = false;
    const test_step = b.step("test-unicode", "Run Unicode conformance tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    return data;
}
