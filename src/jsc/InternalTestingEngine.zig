const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const ReadTarballSchema = InternalTestingBindings.function("readTarball");
const OpenTempDirWithoutSharingDeleteSchema = InternalTestingBindings.function("openTempDirWithoutSharingDelete");
const CloseTempDirHandleSchema = InternalTestingBindings.function("closeTempDirHandle");
const CodeCoverageBindings = bun.bindgen.Module("code_coverage");
const ShouldGenerateCodeCoverageSchema = CodeCoverageBindings.nativeExport("codeCoverageShouldGenerate");

fn bindShouldGenerateCodeCoverage(
    args: bun.bindgen.Args(ShouldGenerateCodeCoverageSchema),
) bun.OOM!bun.bindgen.Return(ShouldGenerateCodeCoverageSchema) {
    var source_url = try args.sourceURL.toUTF8(bun.default_allocator);
    defer source_url.deinit();
    return TestCommand.shouldGenerateCodeCoverage(source_url.slice());
}

const ReadTarballBinding = bun.bindgen.Fn(ReadTarballSchema, PackCommandEngine.jsReadTarball);
const OpenTempDirWithoutSharingDeleteBinding = bun.bindgen.Fn(
    OpenTempDirWithoutSharingDeleteSchema,
    UpgradeCommandEngine.openTempDirWithoutSharingDelete,
);
const CloseTempDirHandleBinding = bun.bindgen.Fn(
    CloseTempDirHandleSchema,
    UpgradeCommandEngine.closeTempDirHandle,
);
const ShouldGenerateCodeCoverageBinding = bun.bindgen.Fn(
    ShouldGenerateCodeCoverageSchema,
    bindShouldGenerateCodeCoverage,
);

comptime {
    _ = ReadTarballBinding;
    _ = OpenTempDirWithoutSharingDeleteBinding;
    _ = CloseTempDirHandleBinding;
    _ = ShouldGenerateCodeCoverageBinding;
}

const bun = @import("bun");
const PackCommandEngine = @import("../cli/PackCommandEngine.zig");
const UpgradeCommandEngine = @import("../cli/UpgradeCommandEngine.zig");
const TestCommand = @import("../cli/test_command.zig");
