const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const text_codec = b.nominalHandle("TextCodecOwner", .{
    .cpp_type = .{ .pointer = &.{ .named = "PAL::TextCodec" } },
    .cpp_declarations = &.{.{ .class = "PAL::TextCodec" }},
    .ownership = .owned,
    .cpp_release = "releaseTextCodec",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const text_codec_encoding = b.enumeration("TextCodecEncoding", .{
    b.enumerationValue("ibm866", "ibm866"),
    b.enumerationValue("iso_8859_3", "iso-8859-3"),
    b.enumerationValue("iso_8859_6", "iso-8859-6"),
    b.enumerationValue("iso_8859_7", "iso-8859-7"),
    b.enumerationValue("iso_8859_8", "iso-8859-8"),
    b.enumerationValue("koi8_u", "koi8-u"),
    b.enumerationValue("windows_874", "windows-874"),
    b.enumerationValue("windows_1253", "windows-1253"),
    b.enumerationValue("windows_1255", "windows-1255"),
    b.enumerationValue("windows_1257", "windows-1257"),
    b.enumerationValue("big5", "big5"),
    b.enumerationValue("euc_jp", "euc-jp"),
    b.enumerationValue("iso_2022_jp", "iso-2022-jp"),
    b.enumerationValue("shift_jis", "shift_jis"),
    b.enumerationValue("euc_kr", "euc-kr"),
    b.enumerationValue("user_defined", "x-user-defined"),
    b.enumerationValue("gbk", "gbk"),
    b.enumerationValue("gb18030", "gb18030"),
});

const decode_result = b.dictionary("TextCodecDecodeResult", .{
    b.dictionaryField("result", b.dom_string, .{ .required = true }),
    b.dictionaryField("sawError", b.boolean, .{ .required = true }),
});

const engine_shims = .{
    b.engineShim(
        "textCodecCreate",
        .{b.argument("encoding", text_codec_encoding, .{})},
        text_codec,
        .vm_thread_allocating,
    ),
    b.engineShim(
        "textCodecReset",
        .{b.argument("codec", text_codec, .{})},
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "textCodecDecode",
        .{
            b.argument("codec", text_codec, .{}),
            b.argument("data", b.buffer(.copy), .{}),
            b.argument("flush", b.boolean, .{}),
            b.argument("stopOnError", b.boolean, .{}),
        },
        decode_result,
        .vm_thread_allocating,
    ),
};

const native_exports = .{
    b.nativeExportWithOptions("textEncoderEncodeLatin1", .{b.argument("input", b.buffer(.copy), .{})}, b.uint8_array_result, .current_realm_throwing),
    b.nativeExportWithOptions("textEncoderEncodeUTF16", .{b.argument("input", b.nativeSlice(.uint16, .read_only), .{})}, b.uint8_array_result, .current_realm_throwing),
    b.nativeExport("textEncoderEncodeIntoLatin1", .{
        b.argument("input", b.buffer(.copy), .{}),
        b.argument("output", b.nativeSlice(.uint8, .read_write), .{}),
    }, b.uint64),
    b.nativeExport("textEncoderEncodeIntoUTF16", .{
        b.argument("input", b.nativeSlice(.uint16, .read_only), .{}),
        b.argument("output", b.nativeSlice(.uint8, .read_write), .{}),
    }, b.uint64),
    b.nativeExport("encodingWriteLatin1", .{
        b.argument("input", b.buffer(.copy), .{}),
        b.argument("output", b.nativeSlice(.uint8, .read_write), .{}),
        b.argument("encoding", archetypes.buffer_encoding, .{}),
    }, b.size),
    b.nativeExport("encodingWriteUTF16", .{
        b.argument("input", b.nativeSlice(.uint16, .read_only), .{}),
        b.argument("output", b.nativeSlice(.uint8, .read_write), .{}),
        b.argument("encoding", archetypes.buffer_encoding, .{}),
    }, b.size),
    b.nativeExport("encodingByteLengthLatin1AsUTF8", .{b.argument("input", b.buffer(.copy), .{})}, b.size),
    b.nativeExport("encodingByteLengthUTF16AsUTF8", .{b.argument("input", b.nativeSlice(.uint16, .read_only), .{})}, b.size),
    b.nativeExportWithOptions("encodingConstructFromLatin1", .{
        b.argument("input", b.buffer(.copy), .{}),
        b.argument("encoding", archetypes.buffer_encoding, .{}),
    }, b.node_buffer, .current_realm_throwing),
    b.nativeExportWithOptions("encodingConstructFromUTF16", .{
        b.argument("input", b.nativeSlice(.uint16, .read_only), .{}),
        b.argument("encoding", archetypes.buffer_encoding, .{}),
    }, b.node_buffer, .current_realm_throwing),
    b.nativeExportWithOptions("encodingToString", .{
        b.argument("input", b.buffer(.copy), .{}),
        b.argument("encoding", archetypes.buffer_encoding, .{}),
    }, b.dom_string, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("text_codecs", .{}, .{}, engine_shims, native_exports);
