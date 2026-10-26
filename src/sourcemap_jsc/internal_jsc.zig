//! JS testing bindings for `InternalSourceMap`. Keeps `src/sourcemap/` free of JSC types.

pub const TestingAPIs = struct {
    pub fn fromVLQ(
        context: bun.bindgen.CallContext(SourceMapFromVLQSchema),
        args: bun.bindgen.Args(SourceMapFromVLQSchema),
    ) bun.bindgen.CallError(SourceMapFromVLQSchema)!bun.bindgen.OwnedBytes {
        const vlq = try args.vlq.toUTF8(bun.default_allocator);
        defer vlq.deinit();

        const blob = InternalSourceMap.fromVLQ(bun.default_allocator, vlq.slice(), 0) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSourceMap => return context.fail(.invalid_input, {}),
        };
        defer bun.default_allocator.free(blob);
        return bun.bindgen.OwnedBytes.fromSlice(blob);
    }

    pub fn toVLQ(
        context: bun.bindgen.CallContext(SourceMapToVLQSchema),
        args: bun.bindgen.Args(SourceMapToVLQSchema),
    ) bun.bindgen.CallError(SourceMapToVLQSchema)!bun.bindgen.DOMString {
        const bytes = args.blob.unsafePtr("The generated call frame holds the blob lease through source-map encoding's last byte read");
        if (!InternalSourceMap.isValidBlob(bytes)) {
            return context.fail(.invalid_blob, {});
        }
        const ism = InternalSourceMap{ .data = bytes.ptr };
        var out = MutableString.initEmpty(bun.default_allocator);
        defer out.deinit();
        try ism.appendVLQTo(&out);
        return bun.bindgen.DOMString.fromUTF8(out.list.items);
    }

    pub fn find(
        context: bun.bindgen.CallContext(SourceMapFindSchema),
        args: bun.bindgen.Args(SourceMapFindSchema),
    ) bun.bindgen.CallError(SourceMapFindSchema)!bun.bindgen.Return(SourceMapFindSchema) {
        const bytes = args.blob.unsafePtr("The generated call frame owns the copied blob until source-map lookup returns");
        if (!InternalSourceMap.isValidBlob(bytes)) {
            return context.fail(.invalid_blob, {});
        }
        const line = if (args.line) |input| line: {
            const converted = try input.convert(context);
            break :line converted.value;
        } else 0;
        const column = if (args.column) |input| column: {
            const converted = try input.convert(context);
            break :column converted.value;
        } else 0;
        if (line < 0 or column < 0) return null;
        const ism = InternalSourceMap{ .data = bytes.ptr };
        const mapping = ism.find(.fromZeroBased(line), .fromZeroBased(column)) orelse return null;

        return .{
            .generated_line = mapping.generated.lines.zeroBased(),
            .generated_column = mapping.generated.columns.zeroBased(),
            .original_line = mapping.original.lines.zeroBased(),
            .original_column = mapping.original.columns.zeroBased(),
            .source_index = mapping.source_index,
        };
    }
};

const bun = @import("bun");
const MutableString = bun.MutableString;
const InternalSourceMap = bun.SourceMap.InternalSourceMap;

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const SourceMapFromVLQSchema = InternalTestingBindings.function("sourceMapFromVLQ");
const SourceMapToVLQSchema = InternalTestingBindings.function("sourceMapToVLQ");
const SourceMapFindSchema = InternalTestingBindings.function("sourceMapFind");
const SourceMapFromVLQBinding = bun.bindgen.Fn(SourceMapFromVLQSchema, TestingAPIs.fromVLQ);
const SourceMapToVLQBinding = bun.bindgen.Fn(SourceMapToVLQSchema, TestingAPIs.toVLQ);
const SourceMapFindBinding = bun.bindgen.Fn(SourceMapFindSchema, TestingAPIs.find);

comptime {
    _ = SourceMapFromVLQBinding;
    _ = SourceMapToVLQBinding;
    _ = SourceMapFindBinding;
}
