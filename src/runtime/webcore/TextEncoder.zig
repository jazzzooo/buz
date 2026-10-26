fn encodeLatin1(
    slice: []const u8,
) bun.OOM!bun.bindgen.OwnedBytes {
    if (slice.len == 0) return .empty();
    return .fromDefaultAllocatedSlice(try strings.allocateLatin1IntoUTF8(bun.default_allocator, slice));
}

fn encodeUTF16(
    slice: []const u16,
) bun.OOM!bun.bindgen.OwnedBytes {
    if (slice.len == 0) return .empty();
    return .fromDefaultAllocatedSlice(try strings.toUTF8Alloc(bun.default_allocator, slice));
}

fn encodeIntoUTF16(input: []const u16, output: []u8) u64 {
    var result: strings.EncodeIntoResult = strings.copyUTF16IntoUTF8(output, input);
    const first_is_unpaired_surrogate = if (input.len == 0)
        false
    else if (input[0] >= 0xdc00 and input[0] <= 0xdfff)
        true
    else
        input[0] >= 0xd800 and input[0] <= 0xdbff and
            (input.len == 1 or input[1] < 0xdc00 or input[1] > 0xdfff);
    if (output.len >= 3 and result.read == 0 and result.written == 0 and first_is_unpaired_surrogate) {
        const replacement_char = [_]u8{ 239, 191, 189 };
        @memcpy(output[0..replacement_char.len], &replacement_char);
        result.read = 1;
        result.written = 3;
    }
    const sized: [2]u32 = .{ result.read, result.written };
    return @bitCast(sized);
}

fn encodeIntoLatin1(input: []const u8, output: []u8) u64 {
    const result: strings.EncodeIntoResult =
        strings.copyLatin1IntoUTF8(output, input);
    const sized: [2]u32 = .{ result.read, result.written };
    return @bitCast(sized);
}

fn bindEncodeLatin1(
    _: bun.bindgen.CallContext(EncodeLatin1Schema),
    args: bun.bindgen.Args(EncodeLatin1Schema),
) bun.JSError!bun.bindgen.Return(EncodeLatin1Schema) {
    const input = args.input.unsafePtr("the C++ caller owns the Latin-1 string until this synchronous encoding returns");
    return try encodeLatin1(input);
}

fn bindEncodeUTF16(
    _: bun.bindgen.CallContext(EncodeUTF16Schema),
    args: bun.bindgen.Args(EncodeUTF16Schema),
) bun.JSError!bun.bindgen.Return(EncodeUTF16Schema) {
    const input = args.input.unsafePtr("the C++ caller owns the UTF-16 string until this synchronous encoding returns");
    return try encodeUTF16(input);
}

fn bindEncodeIntoLatin1(
    args: bun.bindgen.Args(EncodeIntoLatin1Schema),
) bun.bindgen.Return(EncodeIntoLatin1Schema) {
    const input = args.input.unsafePtr("the C++ caller owns the Latin-1 string until this synchronous encoding returns");
    const output = args.output.unsafePtr("the C++ caller holds the destination byte lease or V8 caller-owned buffer until this synchronous encoding returns");
    return encodeIntoLatin1(input, output);
}

fn bindEncodeIntoUTF16(
    args: bun.bindgen.Args(EncodeIntoUTF16Schema),
) bun.bindgen.Return(EncodeIntoUTF16Schema) {
    const input = args.input.unsafePtr("the C++ caller owns the UTF-16 string until this synchronous encoding returns");
    const output = args.output.unsafePtr("the C++ caller holds the destination byte lease or V8 caller-owned buffer until this synchronous encoding returns");
    return encodeIntoUTF16(input, output);
}

const TextCodecBindings = bun.bindgen.Module("text_codecs");
const EncodeLatin1Schema = TextCodecBindings.nativeExport("textEncoderEncodeLatin1");
const EncodeUTF16Schema = TextCodecBindings.nativeExport("textEncoderEncodeUTF16");
const EncodeIntoLatin1Schema = TextCodecBindings.nativeExport("textEncoderEncodeIntoLatin1");
const EncodeIntoUTF16Schema = TextCodecBindings.nativeExport("textEncoderEncodeIntoUTF16");
const EncodeLatin1Binding = bun.bindgen.Fn(EncodeLatin1Schema, bindEncodeLatin1);
const EncodeUTF16Binding = bun.bindgen.Fn(EncodeUTF16Schema, bindEncodeUTF16);
const EncodeIntoLatin1Binding = bun.bindgen.Fn(EncodeIntoLatin1Schema, bindEncodeIntoLatin1);
const EncodeIntoUTF16Binding = bun.bindgen.Fn(EncodeIntoUTF16Schema, bindEncodeIntoUTF16);

comptime {
    _ = EncodeLatin1Binding;
    _ = EncodeUTF16Binding;
    _ = EncodeIntoLatin1Binding;
    _ = EncodeIntoUTF16Binding;
}

const bun = @import("bun");
const strings = bun.strings;
