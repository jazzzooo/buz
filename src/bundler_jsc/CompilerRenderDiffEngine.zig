pub fn render(global: *bun.jsc.JSGlobalObject, args: bun.bindgen.Args(CompilerRenderDiffSchema)) bun.OOM!void {
    const expected = try args.expected.toUTF8(bun.default_allocator);
    defer expected.deinit();
    const received = try args.received.toUTF8(bun.default_allocator);
    defer received.deinit();
    const formatter = StringDiffFormatter{
        .received_string = received.slice(),
        .expected_string = expected.slice(),
        .io = global.bunVM().io,
    };
    bun.Output.errorWriter().print("DIFF:\n{any}\n", .{formatter}) catch {};
}

fn bindRenderDiff(
    context: bun.bindgen.CallContext(CompilerRenderDiffSchema),
    args: bun.bindgen.Args(CompilerRenderDiffSchema),
) bun.JSError!bun.bindgen.Return(CompilerRenderDiffSchema) {
    try render(context.viewToken().globalObject(), args);
}

const bun = @import("bun");
const StringDiffFormatter = @import("../test_runner/diff_format.zig").StringDiffFormatter;
const CompilerRenderDiffSchema = bun.bindgen.Module("compiler_module_records").nativeExport("compilerRenderDiff");
const CompilerRenderDiffBinding = bun.bindgen.Fn(CompilerRenderDiffSchema, bindRenderDiff);

comptime {
    _ = CompilerRenderDiffBinding;
}
