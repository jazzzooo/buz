fn writeLatin1(input: []const u8, output: []u8, encoding: Encoding) usize {
    return switch (encoding) {
        inline else => |resolved| core.writeU8(input.ptr, input.len, output.ptr, output.len, resolved, false),
    };
}

fn writeUTF16(input: []const u16, output: []u8, encoding: Encoding) usize {
    return switch (encoding) {
        inline else => |resolved| core.writeU16(input.ptr, input.len, output.ptr, output.len, resolved, false),
    };
}

fn encodingFromBinding(value: @FieldType(bun.bindgen.Args(EncodingWriteLatin1Schema), "encoding")) Encoding {
    return switch (value) {
        inline else => |encoding| @field(Encoding, @tagName(encoding)),
    };
}

fn bindEncodingWriteLatin1(
    args: bun.bindgen.Args(EncodingWriteLatin1Schema),
) bun.bindgen.Return(EncodingWriteLatin1Schema) {
    const input = args.input.unsafePtr("the calling C++ frame retains the source string or Buffer until synchronous encoding returns");
    const output = args.output.unsafePtr("the C++ caller retains the destination String or Buffer, or borrows NAPI caller-owned output, until encoding returns");
    return writeLatin1(
        input,
        output,
        encodingFromBinding(args.encoding),
    );
}

fn bindEncodingWriteUTF16(
    args: bun.bindgen.Args(EncodingWriteUTF16Schema),
) bun.bindgen.Return(EncodingWriteUTF16Schema) {
    const input = args.input.unsafePtr("the calling C++ frame retains the UTF-16 string until synchronous encoding returns");
    const output = args.output.unsafePtr("the C++ caller retains the destination Buffer, or borrows NAPI caller-owned output, until encoding returns");
    return writeUTF16(
        input,
        output,
        encodingFromBinding(args.encoding),
    );
}

fn bindEncodingByteLengthLatin1AsUTF8(
    args: bun.bindgen.Args(EncodingByteLengthLatin1AsUTF8Schema),
) bun.bindgen.Return(EncodingByteLengthLatin1AsUTF8Schema) {
    const input = args.input.unsafePtr("the calling C++ frame retains the Latin-1 string until byte-length calculation returns");
    return core.byteLengthU8(input.ptr, input.len, .utf8);
}

fn bindEncodingByteLengthUTF16AsUTF8(
    args: bun.bindgen.Args(EncodingByteLengthUTF16AsUTF8Schema),
) bun.bindgen.Return(EncodingByteLengthUTF16AsUTF8Schema) {
    const input = args.input.unsafePtr("the calling C++ frame retains the UTF-16 string until byte-length calculation returns");
    return bun.strings.elementLengthUTF16IntoUTF8(input);
}

fn bindConstructFromLatin1(
    _: bun.bindgen.CallContext(ConstructFromLatin1Schema),
    args: bun.bindgen.Args(ConstructFromLatin1Schema),
) bun.JSError!bun.bindgen.Return(ConstructFromLatin1Schema) {
    const input = args.input.unsafePtr("the calling C++ frame retains the Latin-1 string until decoding into owned bytes returns");
    const slice = switch (encodingFromBinding(args.encoding)) {
        inline else => |encoding| try core.constructFromU8(input.ptr, input.len, bun.default_allocator, encoding),
    };
    return .fromDefaultAllocatedSlice(slice);
}

fn bindConstructFromUTF16(
    _: bun.bindgen.CallContext(ConstructFromUTF16Schema),
    args: bun.bindgen.Args(ConstructFromUTF16Schema),
) bun.JSError!bun.bindgen.Return(ConstructFromUTF16Schema) {
    const input = args.input.unsafePtr("the calling C++ frame retains the UTF-16 string until decoding into owned bytes returns");
    const slice = switch (encodingFromBinding(args.encoding)) {
        inline else => |encoding| try core.constructFromU16(input.ptr, input.len, bun.default_allocator, encoding),
    };
    return .fromDefaultAllocatedSlice(slice);
}

fn bindToString(
    _: bun.bindgen.CallContext(ToStringSchema),
    args: bun.bindgen.Args(ToStringSchema),
) bun.JSError!bun.bindgen.Return(ToStringSchema) {
    const input = args.input.unsafePtr("the C++ caller retains the source string, Buffer, or decoder storage until decoding into an owned string returns");
    return bun.bindgen.DOMString.fromBunString(core.toBunString(input, encodingFromBinding(args.encoding)));
}

const bun = @import("bun");
const core = @import("./encoding.zig");
const Encoding = @import("../node/types.zig").Encoding;
const TextCodecBindings = bun.bindgen.Module("text_codecs");
const EncodingWriteLatin1Schema = TextCodecBindings.nativeExport("encodingWriteLatin1");
const EncodingWriteUTF16Schema = TextCodecBindings.nativeExport("encodingWriteUTF16");
const EncodingByteLengthLatin1AsUTF8Schema = TextCodecBindings.nativeExport("encodingByteLengthLatin1AsUTF8");
const EncodingByteLengthUTF16AsUTF8Schema = TextCodecBindings.nativeExport("encodingByteLengthUTF16AsUTF8");
const ConstructFromLatin1Schema = TextCodecBindings.nativeExport("encodingConstructFromLatin1");
const ConstructFromUTF16Schema = TextCodecBindings.nativeExport("encodingConstructFromUTF16");
const ToStringSchema = TextCodecBindings.nativeExport("encodingToString");

comptime {
    _ = bun.bindgen.Fn(EncodingWriteLatin1Schema, bindEncodingWriteLatin1);
    _ = bun.bindgen.Fn(EncodingWriteUTF16Schema, bindEncodingWriteUTF16);
    _ = bun.bindgen.Fn(EncodingByteLengthLatin1AsUTF8Schema, bindEncodingByteLengthLatin1AsUTF8);
    _ = bun.bindgen.Fn(EncodingByteLengthUTF16AsUTF8Schema, bindEncodingByteLengthUTF16AsUTF8);
    _ = bun.bindgen.Fn(ConstructFromLatin1Schema, bindConstructFromLatin1);
    _ = bun.bindgen.Fn(ConstructFromUTF16Schema, bindConstructFromUTF16);
    _ = bun.bindgen.Fn(ToStringSchema, bindToString);
}
