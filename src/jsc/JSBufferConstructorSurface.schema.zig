const b = @import("bindgen_schema");
const buffer = @import("binding_schema_BufferHost");

const configurable = b.SurfaceMemberOptions{ .attributes = .{} };
const readonly_non_enumerable = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .enumerable = false },
};
const constructable = b.SurfaceMemberOptions{
    .attributes = .{},
    .constructable = true,
};

fn function(comptime property_name: []const u8, comptime declaration_name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(property_name, buffer.schema.function(declaration_name), configurable);
}

fn constructableFunction(comptime property_name: []const u8, comptime declaration_name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(property_name, buffer.schema.function(declaration_name), constructable);
}

fn prototypeFunction(comptime property_name: []const u8, comptime declaration_name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(property_name, buffer.schema.function(declaration_name), configurable);
}

fn prototypeFunctionWithAliases(
    comptime property_name: []const u8,
    comptime declaration_name: []const u8,
    comptime aliases: []const b.SurfaceMemberAlias,
) b.SurfaceMember {
    return b.surfaceFunction(property_name, buffer.schema.function(declaration_name), .{
        .attributes = .{},
        .aliases = aliases,
    });
}

const constructor = b.objectSurface("JSBufferConstructor", .{
    constructableFunction("alloc", "jsBufferConstructorFunction_alloc"),
    constructableFunction("allocUnsafe", "jsBufferConstructorFunction_allocUnsafe"),
    constructableFunction("allocUnsafeSlow", "jsBufferConstructorFunction_allocUnsafeSlow"),
    function("byteLength", "jsBufferConstructorFunction_byteLength"),
    function("compare", "jsBufferConstructorFunction_compare"),
    function("concat", "jsBufferConstructorFunction_concat"),
    function("copyBytesFrom", "jsBufferConstructorFunction_copyBytesFrom"),
    function("from", "from"),
    function("isBuffer", "isBuffer"),
    function("isEncoding", "jsBufferConstructorFunction_isEncoding"),
    b.surfaceLazyProperty("prototype", buffer.schema.function("getJSBufferPrototype"), .{
        .attributes = .{ .writable = false, .enumerable = false, .configurable = false },
    }),
    b.surfaceInteger("poolSize", 8192, configurable),
}, .{});

const prototype = b.objectSurface("JSBufferPrototype", .{
    prototypeFunction("asciiSlice", "jsBufferPrototypeFunction_asciiSlice"),
    prototypeFunction("asciiWrite", "jsBufferPrototypeFunction_asciiWrite"),
    prototypeFunction("base64Slice", "jsBufferPrototypeFunction_base64Slice"),
    prototypeFunction("base64Write", "jsBufferPrototypeFunction_base64Write"),
    prototypeFunction("base64urlSlice", "jsBufferPrototypeFunction_base64urlSlice"),
    prototypeFunction("base64urlWrite", "jsBufferPrototypeFunction_base64urlWrite"),
    prototypeFunction("compare", "jsBufferPrototypeFunction_compare"),
    prototypeFunction("copy", "jsBufferPrototypeFunction_copy"),
    prototypeFunction("equals", "jsBufferPrototypeFunction_equals"),
    prototypeFunction("fill", "jsBufferPrototypeFunction_fill"),
    prototypeFunction("hexSlice", "jsBufferPrototypeFunction_hexSlice"),
    prototypeFunction("hexWrite", "jsBufferPrototypeFunction_hexWrite"),
    prototypeFunction("includes", "jsBufferPrototypeFunction_includes"),
    prototypeFunction("indexOf", "jsBufferPrototypeFunction_indexOf"),
    prototypeFunctionWithAliases("inspect", "jsBufferPrototypeFunction_inspect", &.{
        b.surfaceSymbolAlias(.inspect_custom, .{}),
    }),
    prototypeFunction("lastIndexOf", "jsBufferPrototypeFunction_lastIndexOf"),
    prototypeFunction("latin1Slice", "jsBufferPrototypeFunction_latin1Slice"),
    prototypeFunction("latin1Write", "jsBufferPrototypeFunction_latin1Write"),
    b.surfaceBuiltinGetter("offset", buffer.schema.function("offset"), readonly_non_enumerable),
    b.surfaceBuiltinGetter("parent", buffer.schema.function("parent"), readonly_non_enumerable),
    prototypeFunction("readBigInt64", "readBigInt64"),
    prototypeFunction("readBigInt64BE", "readBigInt64BE"),
    prototypeFunction("readBigInt64LE", "readBigInt64LE"),
    prototypeFunction("readBigUInt64", "readBigUInt64"),
    prototypeFunctionWithAliases("readBigUInt64BE", "readBigUInt64BE", &.{
        b.surfaceAlias("readBigUint64BE", .{}),
    }),
    prototypeFunctionWithAliases("readBigUInt64LE", "readBigUInt64LE", &.{
        b.surfaceAlias("readBigUint64LE", .{}),
    }),
    prototypeFunction("readDouble", "readDouble"),
    prototypeFunction("readDoubleBE", "readDoubleBE"),
    prototypeFunction("readDoubleLE", "readDoubleLE"),
    prototypeFunction("readFloat", "readFloat"),
    prototypeFunction("readFloatBE", "readFloatBE"),
    prototypeFunction("readFloatLE", "readFloatLE"),
    prototypeFunction("readInt16", "readInt16"),
    prototypeFunction("readInt16BE", "readInt16BE"),
    prototypeFunction("readInt16LE", "readInt16LE"),
    prototypeFunction("readInt32", "readInt32"),
    prototypeFunction("readInt32BE", "readInt32BE"),
    prototypeFunction("readInt32LE", "readInt32LE"),
    prototypeFunction("readInt8", "readInt8"),
    prototypeFunction("readIntBE", "readIntBE"),
    prototypeFunction("readIntLE", "readIntLE"),
    prototypeFunctionWithAliases("readUInt16BE", "readUInt16BE", &.{
        b.surfaceAlias("readUint16BE", .{}),
    }),
    prototypeFunctionWithAliases("readUInt16LE", "readUInt16LE", &.{
        b.surfaceAlias("readUint16LE", .{}),
    }),
    prototypeFunctionWithAliases("readUInt32BE", "readUInt32BE", &.{
        b.surfaceAlias("readUint32BE", .{}),
    }),
    prototypeFunctionWithAliases("readUInt32LE", "readUInt32LE", &.{
        b.surfaceAlias("readUint32LE", .{}),
    }),
    prototypeFunctionWithAliases("readUInt8", "readUInt8", &.{
        b.surfaceAlias("readUint8", .{}),
    }),
    prototypeFunctionWithAliases("readUIntBE", "readUIntBE", &.{
        b.surfaceAlias("readUintBE", .{}),
    }),
    prototypeFunctionWithAliases("readUIntLE", "readUIntLE", &.{
        b.surfaceAlias("readUintLE", .{}),
    }),
    prototypeFunction("slice", "jsBufferPrototypeFunction_slice"),
    prototypeFunction("subarray", "jsBufferPrototypeFunction_slice"),
    prototypeFunction("swap16", "jsBufferPrototypeFunction_swap16"),
    prototypeFunction("swap32", "jsBufferPrototypeFunction_swap32"),
    prototypeFunction("swap64", "jsBufferPrototypeFunction_swap64"),
    prototypeFunction("toJSON", "toJSON"),
    prototypeFunctionWithAliases("toString", "jsBufferPrototypeFunction_toString", &.{
        b.surfaceAlias("toLocaleString", .{}),
    }),
    prototypeFunction("ucs2Slice", "jsBufferPrototypeFunction_utf16leSlice"),
    prototypeFunction("ucs2Write", "jsBufferPrototypeFunction_utf16leWrite"),
    prototypeFunction("utf16leSlice", "jsBufferPrototypeFunction_utf16leSlice"),
    prototypeFunction("utf16leWrite", "jsBufferPrototypeFunction_utf16leWrite"),
    prototypeFunction("utf8Slice", "jsBufferPrototypeFunction_utf8Slice"),
    prototypeFunction("utf8Write", "jsBufferPrototypeFunction_utf8Write"),
    prototypeFunction("write", "jsBufferPrototypeFunction_write"),
    prototypeFunction("writeBigInt64BE", "jsBufferPrototypeFunction_writeBigInt64BE"),
    prototypeFunction("writeBigInt64LE", "jsBufferPrototypeFunction_writeBigInt64LE"),
    prototypeFunctionWithAliases("writeBigUInt64BE", "jsBufferPrototypeFunction_writeBigUInt64BE", &.{
        b.surfaceAlias("writeBigUint64BE", .{}),
    }),
    prototypeFunctionWithAliases("writeBigUInt64LE", "jsBufferPrototypeFunction_writeBigUInt64LE", &.{
        b.surfaceAlias("writeBigUint64LE", .{}),
    }),
    prototypeFunction("writeDouble", "writeDouble"),
    prototypeFunction("writeDoubleBE", "writeDoubleBE"),
    prototypeFunction("writeDoubleLE", "writeDoubleLE"),
    prototypeFunction("writeFloat", "writeFloat"),
    prototypeFunction("writeFloatBE", "writeFloatBE"),
    prototypeFunction("writeFloatLE", "writeFloatLE"),
    prototypeFunction("writeInt16BE", "writeInt16BE"),
    prototypeFunction("writeInt16LE", "writeInt16LE"),
    prototypeFunction("writeInt32BE", "writeInt32BE"),
    prototypeFunction("writeInt32LE", "writeInt32LE"),
    prototypeFunction("writeInt8", "writeInt8"),
    prototypeFunction("writeIntBE", "writeIntBE"),
    prototypeFunction("writeIntLE", "writeIntLE"),
    prototypeFunctionWithAliases("writeUInt16", "writeUInt16", &.{
        b.surfaceAlias("writeUint16", .{}),
    }),
    prototypeFunctionWithAliases("writeUInt16BE", "writeUInt16BE", &.{
        b.surfaceAlias("writeUint16BE", .{}),
    }),
    prototypeFunctionWithAliases("writeUInt16LE", "writeUInt16LE", &.{
        b.surfaceAlias("writeUint16LE", .{}),
    }),
    prototypeFunctionWithAliases("writeUInt32", "writeUInt32", &.{
        b.surfaceAlias("writeUint32", .{}),
    }),
    prototypeFunctionWithAliases("writeUInt32BE", "writeUInt32BE", &.{
        b.surfaceAlias("writeUint32BE", .{}),
    }),
    prototypeFunctionWithAliases("writeUInt32LE", "writeUInt32LE", &.{
        b.surfaceAlias("writeUint32LE", .{}),
    }),
    prototypeFunctionWithAliases("writeUInt8", "writeUInt8", &.{
        b.surfaceAlias("writeUint8", .{}),
    }),
    prototypeFunctionWithAliases("writeUIntBE", "writeUIntBE", &.{
        b.surfaceAlias("writeUintBE", .{}),
    }),
    prototypeFunctionWithAliases("writeUIntLE", "writeUIntLE", &.{
        b.surfaceAlias("writeUintLE", .{}),
    }),
    b.surfaceSymbolString(.to_string_tag, "Uint8Array", .{
        .attributes = .{ .writable = false, .enumerable = false },
    }),
}, .{ .installation = .reified });

pub const schema = b.moduleWithSurfaces("JSBufferConstructorSurface", .{ constructor, prototype });
