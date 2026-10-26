const WebCryptoKey = @This();
const bun = @import("bun");
const bindgen = bun.bindgen;

pub const NativeKey = opaque {};

const Module = bindgen.Module("WebCryptoKey");
const Class = Module.class("CryptoKey");
const TypeGetter = Class.member("type");
const ExtractableGetter = Class.member("extractable");
const AlgorithmGetter = Class.member("algorithm");
const UsagesGetter = Class.member("usages");
const Adopt = Module.nativeExport("adopt");
const Native = Module.nativeExport("nativeKey");
const Key = @FieldType(bindgen.Args(Adopt), "key");

bindgen_state: bindgen.ClassState = .{},
key: Key,

pub const Binding = bindgen.Class(Class, WebCryptoKey);

pub fn destroy(this: *WebCryptoKey) void {
    this.key.deinit();
    bun.destroy(this);
}

pub fn getType(
    this: *WebCryptoKey,
    context: bindgen.CallContext(TypeGetter),
    _: bindgen.Args(TypeGetter),
) bun.JSError!bindgen.Return(TypeGetter) {
    return context.engineIn("WebCryptoKey", "type").call(.{ .key = &this.key });
}

pub fn getExtractable(
    this: *WebCryptoKey,
    context: bindgen.CallContext(ExtractableGetter),
    _: bindgen.Args(ExtractableGetter),
) bun.JSError!bool {
    return context.engineIn("WebCryptoKey", "extractable").call(.{ .key = &this.key });
}

pub fn getAlgorithm(
    this: *WebCryptoKey,
    context: bindgen.CallContext(AlgorithmGetter),
    _: bindgen.Args(AlgorithmGetter),
) bun.JSError!bindgen.Return(AlgorithmGetter) {
    return context.engineIn("WebCryptoKey", "algorithm").call(.{ .key = &this.key });
}

pub fn getUsages(
    this: *WebCryptoKey,
    context: bindgen.CallContext(UsagesGetter),
    _: bindgen.Args(UsagesGetter),
) bun.JSError!bindgen.Return(UsagesGetter) {
    return context.engineIn("WebCryptoKey", "usages").call(.{ .key = &this.key });
}

pub fn structuredCloneSerialize(
    this: *const WebCryptoKey,
    context: bindgen.StructuredCloneContext(Class),
    writer: bindgen.StructuredCloneWriter,
) bun.JSError!void {
    var bytes = try context.engineIn("WebCryptoKey", "serialize").call(.{ .key = &this.key });
    defer bytes.deinit();
    try writer.writeInt(u64, bytes.slice().len, .little);
    try writer.writeAll(bytes.slice());
}

pub fn structuredCloneDeserialize(
    context: bindgen.StructuredCloneContext(Class),
    reader: *bindgen.StructuredCloneReader,
) bindgen.StructuredCloneError!*WebCryptoKey {
    const length = reader.readInt(u64, .little) catch return error.InvalidData;
    if (length > reader.remaining()) return error.InvalidData;
    const size: usize = @intCast(length);
    var key = (try context.engineIn("WebCryptoKey", "deserialize").call(.{ .bytes = bun.bindgen.BytesOperand.fromSlice(reader.ptr[0..size]) })) orelse return error.InvalidData;
    errdefer key.deinit();
    const this = try bun.default_allocator.create(WebCryptoKey);
    this.* = .{ .key = key };
    reader.ptr += size;
    return this;
}

fn adopt(
    context: bindgen.CallContext(Adopt),
    args: *bindgen.Args(Adopt),
) bun.JSError!bindgen.Return(Adopt) {
    const this = try bun.default_allocator.create(WebCryptoKey);
    this.* = .{ .key = args.key.take() };
    return Binding.adoptResult(this, context);
}

fn nativeKey(args: bindgen.Args(Native)) *NativeKey {
    return args.owner.key.get();
}

comptime {
    _ = Binding;
    _ = bindgen.Fn(Adopt, adopt);
    _ = bindgen.Fn(Native, nativeKey);
}
