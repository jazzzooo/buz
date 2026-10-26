const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const engine_types = @import("binding_schema_engine_types");

const unsafe_external_memory_pointer_handle = b.nominalHandle("UnsafeExternalMemoryPointer", .{
    .cpp_type = .{ .pointer = &.{ .named = "uint8_t" } },
    .cpp_declarations = &.{},
    .raw_pointer_escape = "the caller guarantees external memory remains alive for the created JavaScript buffer",
    .zig_type = "u8",
    .access_thread = .any,
});

const engine_shims = .{
    b.engineShim(
        "jsValueIsBuffer",
        .{b.argument("value", b.engine_value, .{})},
        b.boolean,
        .current_realm_nonthrowing,
    ),
    b.engineShim(
        "createBufferFromLength",
        .{b.argument("length", b.int64, .{})},
        b.js_uint8_array,
        .current_realm_throwing,
    ),
    b.engineShim(
        "createUint8ArrayFromBytes",
        .{
            b.argument("bytes", b.buffer(.copy), .{}),
            b.argument("buffer", b.boolean, .{}),
        },
        b.js_uint8_array,
        .current_realm_throwing,
    ),
    b.engineShim(
        "createArrayBufferFromBytes",
        .{b.argument("bytes", b.buffer(.copy), .{})},
        b.js_array_buffer_object,
        .current_realm_throwing,
    ),
    b.engineShim(
        "createUninitializedUint8Array",
        .{b.argument("length", b.size, .{})},
        b.js_uint8_array,
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsValueCopyArrayBufferView",
        .{b.argument("value", b.engine_value, .{})},
        b.optional(b.buffer(.copy)),
        .current_realm_throwing,
    ),
    b.engineShim(
        "jsValueArrayBufferIsShared",
        .{b.argument("value", b.engine_value, .{})},
        b.boolean,
        .current_realm_unchecked,
    ),
    b.engineShim(
        "jsArrayBufferViewBuffer",
        .{b.argument("value", b.brandCast(b.js_array_buffer_view, .{ .failure = .assert, .input = .engine_value }), .{})},
        archetypes.array_buffer_object,
        .current_realm_throwing,
    ),
    b.engineShim(
        "bufferAdoptOwnedBytes",
        .{b.argument("owner", engine_types.external_bytes_owner, .{ .ownership = .transfer })},
        b.js_uint8_array,
        .current_realm_throwing,
    ),
    b.engineShim(
        "arrayBufferAdoptOwnedBytes",
        .{b.argument("owner", engine_types.external_bytes_owner, .{ .ownership = .transfer })},
        b.js_array_buffer_object,
        .current_realm_throwing,
    ),
    b.engineShim(
        "uint8ArrayAdoptOwnedBytes",
        .{b.argument("owner", engine_types.external_bytes_owner, .{ .ownership = .transfer })},
        b.js_uint8_array,
        .current_realm_throwing,
    ),
    b.engineShim(
        "bufferBorrowExternalMemoryUnsafe",
        .{
            b.argument("data", unsafe_external_memory_pointer_handle, .{}),
            b.argument("length", b.size, .{}),
        },
        b.js_uint8_array,
        .current_realm_throwing,
    ),
    b.engineShim(
        "arrayBufferBorrowExternalMemoryUnsafe",
        .{
            b.argument("data", unsafe_external_memory_pointer_handle, .{}),
            b.argument("length", b.size, .{}),
        },
        b.js_array_buffer_object,
        .current_realm_throwing,
    ),
};

const native_exports = .{
    b.nativeExport("bufferFill", .{
        b.argument("input", b.dom_string, .{}),
        b.argument("output", b.nativeSlice(.uint8, .read_write), .{}),
        b.argument("encoding", archetypes.buffer_encoding, .{}),
    }, b.boolean),
};

pub const schema = b.moduleWithDeclarations("array_buffers", .{}, .{}, engine_shims, native_exports);
