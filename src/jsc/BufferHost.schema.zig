const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const buffer_allocation_range: b.IntegerRange = .{ .min = 0, .max = 4_294_967_296 };
const deferred_receiver_range = "the live Buffer receiver range is resolved before coercing optional indices";
const deferred_search = "an empty receiver and positional encoding selection can make later search conversions unobservable";
const deferred_allocation_fill = "a zero-length allocation returns before coercing an unused fill value";
const deferred_concat_length = "Buffer.concat returns an empty buffer for an empty list without validating an unused length override";
const deferred_copy_range = "Buffer.copy validates each live source and target range in Node's observable order";
const deferred_fill = "Buffer.fill resolves its live range and positional encoding before coercing the selected fill value";
const deferred_write = "Buffer.write resolves its overload and live receiver range before coercing only the selected operands";
const deferred_constructor_range = "Buffer construction checks detachment before coercing offset and checks the live offset range before coercing length";

fn bufferAllocationArgument(comptime name: []const u8) b.Argument {
    return archetypes.nodeTruncatedInteger(name, b.size, .{ .range = buffer_allocation_range, .range_error = .prose }, .{});
}

const buffer_receiver = b.brandedValueWithBrand(b.brandOf(b.js_uint8_array), .{
    .error_kind = .type,
    .expectation = "a Buffer",
    .node_requirement = "Buffer",
});
const validation_buffer = b.bufferWithOptions(.lease, .{
    .allow_detached = false,
    .detached_failure = .{
        .kind = .{ .code = "ERR_INVALID_STATE" },
        .message = "Invalid state: Cannot validate on a detached buffer",
    },
});

const attached_uint8_array = b.uint8ArrayWithOptions(.lease, .{ .allow_detached = false });
const attached_writable_uint8_array = b.writableUint8ArrayWithOptions(.lease, .{ .allow_detached = false });

const compare_errors = b.domainErrors(.{
    b.domainError("out_of_range", b.dom_string, .{
        .class = .range_error,
        .code = "ERR_OUT_OF_RANGE",
        .message = .payload,
    }),
});

const array_buffer_view_receiver = b.js_array_buffer_view;
const buffer_parent_value = b.unionType("BufferParentValue", .{
    b.unionMember("array_buffer", b.js_array_buffer_object),
    b.unionMember("shared_array_buffer", b.js_shared_array_buffer),
}, .{ .ordered = true });
const buffer_parent_result = b.optionalUndefined(buffer_parent_value);
const buffer_json_result = b.dictionary("BufferJSONResult", .{
    b.dictionaryField("type", b.dom_string, .{ .required = true }),
    b.dictionaryField("data", b.js_array, .{ .required = true }),
});

fn surfaceValue(comptime name: []const u8, comptime result: b.Type) b.Function {
    return b.function(name, .{}, result, .{ .backend = .cpp, .length = 0, .profile = .exact });
}

fn encodedSlice(comptime name: []const u8) b.Function {
    return b.function(
        name,
        .{
            archetypes.bufferSliceIndex("start", .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_receiver_range }),
            archetypes.bufferSliceIndex("end", .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_receiver_range }),
        },
        b.js_string,
        .{ .backend = .cpp, .length = 2, .profile = .exact, .this_value_type = array_buffer_view_receiver },
    );
}

fn encodedWrite(comptime name: []const u8) b.Function {
    return b.function(
        name,
        .{
            b.argument("text", archetypes.coerced_dom_string, .{}),
            b.argument("offset", b.double, .{ .presence = .optional, .missing = .undefined, .number_conversion = .coerce }),
            b.argument("length", b.double, .{ .presence = .optional, .missing = .undefined, .number_conversion = .coerce }),
        },
        b.size,
        .{
            .backend = .cpp,
            .length = 3,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
            .this_value_type = array_buffer_view_receiver,
        },
    );
}

fn bigintWrite(comptime name: []const u8, comptime value: b.Type) b.Function {
    return b.function(
        name,
        .{
            b.argument("value", value, .{}),
            archetypes.nodeInteger("offset", b.lazy(b.size), .{ .min = 0, .max = 9007199254740991 }, .{
                .presence = .optional,
                .missing = .undefined,
                .deferred_reason = "BigInt writes reject receivers smaller than eight bytes before validating the offset",
            }),
            b.argument("noAssert", b.discardAny(.ignored), .{ .presence = .optional, .missing = .omitted }),
        },
        b.size,
        .{
            .backend = .cpp,
            .length = 3,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
            .this_value_type = array_buffer_view_receiver,
        },
    );
}

const parsed_buffer_encoding = archetypes.parsed_buffer_encoding;
const fill_buffer_encoding = archetypes.fill_buffer_encoding;

const buffer_byte_length_string = b.js_string;

const buffer_byte_length_view = b.js_array_buffer_view;

const buffer_byte_length_array_buffer = b.js_any_array_buffer_object;

const buffer_byte_length_source = b.unionType("BufferByteLengthSource", .{
    b.unionMember("string", buffer_byte_length_string),
    b.unionMember("view", buffer_byte_length_view),
    b.unionMember("array_buffer", buffer_byte_length_array_buffer),
}, .{
    .ordered = true,
    .cpp_name = "BufferByteLengthSource",
    .node_error = .{ .expected_type = "string or an instance of Buffer or ArrayBuffer" },
});

const optional_valid_buffer_encoding = archetypes.optional_valid_buffer_encoding;

const copy_bytes_view = b.js_typed_array;

const buffer_inspect_options = b.optionalFalsy(b.dictionaryWithOptions("BufferInspectOptions", .{
    b.dictionaryField("show_hidden", b.boolean, .{
        .boolean_conversion = .truthy,
        .default_value = .{ .boolean = false },
        .js_name = "showHidden",
    }),
}, .{ .cpp_name = "BufferInspectOptions" }));

const tolerant_coerced_buffer_encoding = archetypes.tolerant_coerced_buffer_encoding;

const buffer_fill_other_offset = b.unionType("BufferFillOtherOffset", .{
    b.unionMember("encoding", b.discard(b.dom_string)),
    b.unionMemberWithOptions("offset", b.size, .{
        .integer_conversion = .{ .node_validate = buffer_allocation_range },
    }),
}, .{ .cpp_name = "BufferFillOtherOffset", .node_error = .{ .expected_type = "number" } });

const buffer_fill_other_end = b.unionType("BufferFillOtherEnd", .{
    b.unionMember("encoding", b.discard(b.dom_string)),
    b.unionMemberWithOptions("end", b.size, .{ .integer_conversion = .{ .node_receiver_byte_length = .{ .mode = .to_length, .range_error = .prose } } }),
}, .{ .cpp_name = "BufferFillOtherEnd", .node_error = .{ .expected_type = "number" } });

const buffer_search_number_offset = b.unionType("BufferSearchNumberOffset", .{
    b.unionMember("encoding", b.discard(b.dom_string)),
    archetypes.bufferSearchOffsetMember("offset"),
}, .{
    .ordered = true,
    .fallback_member = "offset",
    .cpp_name = "BufferSearchNumberOffset",
});

const buffer_search_string_offset = b.unionType("BufferSearchStringOffset", .{
    b.unionMember("encoding", parsed_buffer_encoding),
    archetypes.bufferSearchOffsetMember("offset"),
}, .{
    .ordered = true,
    .fallback_member = "offset",
    .cpp_name = "BufferSearchStringOffset",
});

const buffer_search_view_offset = b.unionType("BufferSearchViewOffset", .{
    b.unionMember("encoding", tolerant_coerced_buffer_encoding),
    archetypes.bufferSearchOffsetMember("offset"),
}, .{
    .ordered = true,
    .fallback_member = "offset",
    .cpp_name = "BufferSearchViewOffset",
});

const buffer_concat_list = b.sequenceWithOptions(attached_uint8_array, .{
    .snapshot_elements = true,
    .node_error = .{
        .container = .{ .kind = .instance, .expected = "Array" },
        .element = .{ .kind = .instance, .expected = "Buffer or Uint8Array", .site = .element },
    },
});

const non_negative_safe_integer: b.IntegerRange = .{ .min = 0, .max = 9007199254740991 };
const buffer_index_range: b.IntegerRange = .{ .min = 0, .max = 4294967296 };

fn bufferSearchFunction(comptime name: []const u8, comptime result: b.Type) b.Function {
    return b.function(
        name,
        b.overloads(.{
            b.overloadCaseWithOptions("number", .{
                b.argument("value", b.lazy(b.uint8), .{ .integer_conversion = .webidl, .deferred_reason = deferred_search }),
                b.argument("offset", b.lazy(buffer_search_number_offset), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_search }),
                b.rest("ignored", b.discarded),
            }, .{ .discriminants = &.{0} }),
            b.overloadCaseWithOptions("string", .{
                b.argument("value", b.lazy(b.dom_string), .{ .deferred_reason = deferred_search }),
                b.argument("offset", b.lazy(buffer_search_string_offset), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_search }),
                b.argument("encoding", b.lazy(parsed_buffer_encoding), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_search }),
                b.rest("ignored", b.discarded),
            }, .{ .discriminants = &.{0} }),
            b.overloadCaseWithOptions("view", .{
                b.argument("value", b.lazy(b.uint8Array(.lease)), .{ .deferred_reason = deferred_search }),
                b.argument("offset", b.lazy(buffer_search_view_offset), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_search }),
                b.argument("encoding", b.lazy(tolerant_coerced_buffer_encoding), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_search }),
                b.rest("ignored", b.discarded),
            }, .{ .discriminants = &.{0} }),
            b.overloadCase("invalid", .{
                b.argument("value", b.discardAny(.classification), .{}),
                b.rest("ignored", b.discarded),
            }),
        }, .{ .ordered = true }),
        result,
        .{ .backend = .cpp, .length = 3, .profile = .node, .this_value_type = buffer_receiver },
    );
}

fn bufferBuiltin(comptime name: []const u8, comptime generator: []const u8, comptime result: b.Type, comptime length: u16) b.Function {
    return b.function(name, .{}, result, .{
        .backend = .builtin,
        .builtin = generator,
        .length = length,
        .profile = .exact,
    });
}

fn bufferConstructor(comptime name: []const u8) b.Function {
    return b.function(name, b.overloads(.{
        b.overloadCaseWithOptions("number_encoding", .{
            b.argument("size", b.double, .{}),
            b.argument("encoding", b.discardWithPurpose(b.dom_string, .classification), .{}),
        }, .{ .discriminants = &.{ 0, 1 } }),
        b.overloadCaseWithOptions("number", .{bufferAllocationArgument("size")}, .{ .discriminants = &.{0} }),
        b.overloadCaseWithOptions("string", .{
            b.argument("text", archetypes.string_like_dom_string, .{}),
            b.argument("encoding", archetypes.buffer_encoding_or_ignored, .{ .presence = .optional, .missing = .undefined }),
        }, .{ .discriminants = &.{0} }),
        b.overloadCase("typed_array", .{b.argument("view", b.js_typed_array, .{})}),
        b.overloadCase("data_view", .{b.argument("view", b.js_data_view, .{})}),
        b.overloadCaseWithOptions("array", .{
            b.argument("values", b.sequenceWithOptions(b.uint8, .{
                .element_conversion = .{ .integer_conversion = .webidl },
            }), .{}),
        }, .{ .discriminants = &.{0} }),
        b.overloadCaseWithOptions("array_buffer", .{
            b.argument("buffer", b.js_any_array_buffer_object, .{}),
            b.argument("offset", b.lazy(b.double), .{
                .presence = .optional,
                .missing = .undefined,
                .number_conversion = .coerce,
                .deferred_reason = deferred_constructor_range,
            }),
            b.argument("length", b.lazy(b.double), .{
                .presence = .optional,
                .missing = .undefined,
                .number_conversion = .coerce,
                .deferred_reason = deferred_constructor_range,
            }),
        }, .{ .discriminants = &.{0} }),
        b.overloadCaseWithOptions("iterable", .{
            b.argument("values", b.sequenceWithOptions(b.uint8, .{
                .container = .iterable,
                .snapshot_elements = true,
                .element_conversion = .{ .integer_conversion = .webidl },
            }), .{}),
        }, .{ .discriminants = &.{0} }),
        b.overloadCase("array_like", .{
            b.argument("values", b.sequenceWithOptions(b.uint8, .{
                .container = .array_like,
                .element_conversion = .{ .integer_conversion = .webidl },
            }), .{ .presence = .optional, .missing = .omitted }),
        }),
    }, .{ .ordered = true, .accept_extra_arguments = true, .fallback_case = "array_like" }), archetypes.node_buffer_value, .{
        .backend = .cpp,
        .length = 3,
        .profile = .node,
    });
}

pub const schema = b.module("BufferHost", .{
    surfaceValue("getJSBufferConstructor", archetypes.constructor_value),
    surfaceValue("getJSBufferPrototype", b.js_object),
    b.function("getInspectMaxBytes", .{}, b.double, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function(
        "setInspectMaxBytes",
        .{archetypes.nodeNumber("INSPECT_MAX_BYTES", .{ .min = 0 }, .{})},
        b.none,
        .{ .backend = .cpp, .length = 0, .profile = .node },
    ),
    b.function(
        "isUtf8",
        .{b.argument("buffer", validation_buffer, .{})},
        b.boolean,
        .{ .backend = .cpp, .length = 1, .profile = .node },
    ),
    b.function(
        "isAscii",
        .{b.argument("buffer", validation_buffer, .{})},
        b.boolean,
        .{ .backend = .cpp, .length = 1, .profile = .node },
    ),

    b.function(
        "constructSlowBuffer",
        .{bufferAllocationArgument("size")},
        archetypes.node_buffer_value,
        .{ .backend = .cpp, .length = 0, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "jsBufferConstructorFunction_alloc",
        b.overloads(.{
            b.overloadCaseWithOptions("string", .{
                bufferAllocationArgument("size"),
                b.argument("fill", b.lazy(b.dom_string), .{ .deferred_reason = deferred_allocation_fill }),
                b.argument("encoding", b.lazy(fill_buffer_encoding), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_allocation_fill }),
            }, .{ .discriminants = &.{1} }),
            b.overloadCaseWithOptions("view", .{
                bufferAllocationArgument("size"),
                b.argument("fill", b.lazy(b.bufferView(.lease)), .{ .deferred_reason = deferred_allocation_fill }),
            }, .{ .discriminants = &.{1} }),
            b.overloadCase("byte", .{
                bufferAllocationArgument("size"),
                b.argument("fill", b.lazy(b.uint8), .{
                    .presence = .optional,
                    .missing = .omitted,
                    .integer_conversion = .webidl,
                    .deferred_reason = deferred_allocation_fill,
                }),
            }),
        }, .{ .ordered = true, .accept_extra_arguments = true, .fallback_case = "byte" }),
        archetypes.node_buffer_value,
        .{ .backend = .cpp, .length = 1, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "jsBufferConstructorFunction_allocUnsafe",
        .{bufferAllocationArgument("size")},
        archetypes.node_buffer_value,
        .{ .backend = .cpp, .length = 1, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "jsBufferConstructorFunction_allocUnsafeSlow",
        .{bufferAllocationArgument("size")},
        archetypes.node_buffer_value,
        .{ .backend = .cpp, .length = 1, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "jsBufferConstructorFunction_byteLength",
        .{
            b.argument("string", buffer_byte_length_source, .{}),
            b.argument("encoding", optional_valid_buffer_encoding, .{}),
        },
        b.double,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "jsBufferConstructorFunction_isEncoding",
        .{b.argument("encoding", optional_valid_buffer_encoding, .{})},
        b.boolean,
        .{ .backend = .cpp, .length = 1, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "jsBufferConstructorFunction_compare",
        .{
            b.argument("first", attached_uint8_array, .{}),
            b.argument("second", attached_uint8_array, .{}),
        },
        b.int32,
        .{ .backend = .cpp, .length = 2, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "jsBufferConstructorFunction_concat",
        .{
            b.argument("list", buffer_concat_list, .{}),
            archetypes.nodeInteger("length", b.lazy(b.size), buffer_allocation_range, .{
                .presence = .optional,
                .missing = .undefined,
                .deferred_reason = deferred_concat_length,
            }),
        },
        archetypes.node_buffer_value,
        .{ .backend = .cpp, .length = 2, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "jsBufferConstructorFunction_copyBytesFrom",
        .{
            b.argument("view", copy_bytes_view, .{}),
            archetypes.nodeInteger("offset", b.size, non_negative_safe_integer, .{ .presence = .optional, .missing = .undefined }),
            archetypes.nodeInteger("length", b.size, non_negative_safe_integer, .{ .presence = .optional, .missing = .undefined }),
        },
        archetypes.node_buffer_value,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "from",
        .{},
        archetypes.node_buffer_value,
        .{
            .backend = .builtin,
            .builtin = "jsBufferConstructorFromCodeGenerator",
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "isBuffer",
        .{},
        b.boolean,
        .{
            .backend = .builtin,
            .builtin = "jsBufferConstructorIsBufferCodeGenerator",
            .length = 1,
            .profile = .exact,
        },
    ),

    bufferBuiltin("offset", "jsBufferPrototypeOffsetCodeGenerator", b.optionalUndefined(b.double), 0),
    bufferBuiltin("parent", "jsBufferPrototypeParentCodeGenerator", buffer_parent_result, 0),
    bufferBuiltin("readBigInt64", "jsBufferPrototypeReadBigInt64LECodeGenerator", b.js_big_int, 1),
    bufferBuiltin("readBigInt64BE", "jsBufferPrototypeReadBigInt64BECodeGenerator", b.js_big_int, 1),
    bufferBuiltin("readBigInt64LE", "jsBufferPrototypeReadBigInt64LECodeGenerator", b.js_big_int, 1),
    bufferBuiltin("readBigUInt64", "jsBufferPrototypeReadBigUInt64LECodeGenerator", b.js_big_int, 1),
    bufferBuiltin("readBigUInt64BE", "jsBufferPrototypeReadBigUInt64BECodeGenerator", b.js_big_int, 1),
    bufferBuiltin("readBigUInt64LE", "jsBufferPrototypeReadBigUInt64LECodeGenerator", b.js_big_int, 1),
    bufferBuiltin("readDouble", "jsBufferPrototypeReadDoubleLECodeGenerator", b.double, 1),
    bufferBuiltin("readDoubleBE", "jsBufferPrototypeReadDoubleBECodeGenerator", b.double, 1),
    bufferBuiltin("readDoubleLE", "jsBufferPrototypeReadDoubleLECodeGenerator", b.double, 1),
    bufferBuiltin("readFloat", "jsBufferPrototypeReadFloatLECodeGenerator", b.double, 1),
    bufferBuiltin("readFloatBE", "jsBufferPrototypeReadFloatBECodeGenerator", b.double, 1),
    bufferBuiltin("readFloatLE", "jsBufferPrototypeReadFloatLECodeGenerator", b.double, 1),
    bufferBuiltin("readInt16", "jsBufferPrototypeReadInt16LECodeGenerator", b.double, 1),
    bufferBuiltin("readInt16BE", "jsBufferPrototypeReadInt16BECodeGenerator", b.double, 1),
    bufferBuiltin("readInt16LE", "jsBufferPrototypeReadInt16LECodeGenerator", b.double, 1),
    bufferBuiltin("readInt32", "jsBufferPrototypeReadInt32LECodeGenerator", b.double, 1),
    bufferBuiltin("readInt32BE", "jsBufferPrototypeReadInt32BECodeGenerator", b.double, 1),
    bufferBuiltin("readInt32LE", "jsBufferPrototypeReadInt32LECodeGenerator", b.double, 1),
    bufferBuiltin("readInt8", "jsBufferPrototypeReadInt8CodeGenerator", b.double, 2),
    bufferBuiltin("readIntBE", "jsBufferPrototypeReadIntBECodeGenerator", b.double, 1),
    bufferBuiltin("readIntLE", "jsBufferPrototypeReadIntLECodeGenerator", b.double, 1),
    bufferBuiltin("readUInt16BE", "jsBufferPrototypeReadUInt16BECodeGenerator", b.double, 1),
    bufferBuiltin("readUInt16LE", "jsBufferPrototypeReadUInt16LECodeGenerator", b.double, 1),
    bufferBuiltin("readUInt32BE", "jsBufferPrototypeReadUInt32BECodeGenerator", b.double, 1),
    bufferBuiltin("readUInt32LE", "jsBufferPrototypeReadUInt32LECodeGenerator", b.double, 1),
    bufferBuiltin("readUInt8", "jsBufferPrototypeReadUInt8CodeGenerator", b.double, 1),
    bufferBuiltin("readUIntBE", "jsBufferPrototypeReadUIntBECodeGenerator", b.double, 1),
    bufferBuiltin("readUIntLE", "jsBufferPrototypeReadUIntLECodeGenerator", b.double, 1),
    bufferBuiltin("toJSON", "jsBufferPrototypeToJSONCodeGenerator", buffer_json_result, 1),
    bufferBuiltin("writeDouble", "jsBufferPrototypeWriteDoubleLECodeGenerator", b.double, 1),
    bufferBuiltin("writeDoubleBE", "jsBufferPrototypeWriteDoubleBECodeGenerator", b.double, 1),
    bufferBuiltin("writeDoubleLE", "jsBufferPrototypeWriteDoubleLECodeGenerator", b.double, 1),
    bufferBuiltin("writeFloat", "jsBufferPrototypeWriteFloatLECodeGenerator", b.double, 1),
    bufferBuiltin("writeFloatBE", "jsBufferPrototypeWriteFloatBECodeGenerator", b.double, 1),
    bufferBuiltin("writeFloatLE", "jsBufferPrototypeWriteFloatLECodeGenerator", b.double, 1),
    bufferBuiltin("writeInt16BE", "jsBufferPrototypeWriteInt16BECodeGenerator", b.double, 1),
    bufferBuiltin("writeInt16LE", "jsBufferPrototypeWriteInt16LECodeGenerator", b.double, 1),
    bufferBuiltin("writeInt32BE", "jsBufferPrototypeWriteInt32BECodeGenerator", b.double, 1),
    bufferBuiltin("writeInt32LE", "jsBufferPrototypeWriteInt32LECodeGenerator", b.double, 1),
    bufferBuiltin("writeInt8", "jsBufferPrototypeWriteInt8CodeGenerator", b.double, 1),
    bufferBuiltin("writeIntBE", "jsBufferPrototypeWriteIntBECodeGenerator", b.double, 1),
    bufferBuiltin("writeIntLE", "jsBufferPrototypeWriteIntLECodeGenerator", b.double, 1),
    bufferBuiltin("writeUInt16", "jsBufferPrototypeWriteUInt16LECodeGenerator", b.double, 1),
    bufferBuiltin("writeUInt16BE", "jsBufferPrototypeWriteUInt16BECodeGenerator", b.double, 1),
    bufferBuiltin("writeUInt16LE", "jsBufferPrototypeWriteUInt16LECodeGenerator", b.double, 1),
    bufferBuiltin("writeUInt32", "jsBufferPrototypeWriteUInt32LECodeGenerator", b.double, 1),
    bufferBuiltin("writeUInt32BE", "jsBufferPrototypeWriteUInt32BECodeGenerator", b.double, 1),
    bufferBuiltin("writeUInt32LE", "jsBufferPrototypeWriteUInt32LECodeGenerator", b.double, 1),
    bufferBuiltin("writeUInt8", "jsBufferPrototypeWriteUInt8CodeGenerator", b.double, 1),
    bufferBuiltin("writeUIntBE", "jsBufferPrototypeWriteUIntBECodeGenerator", b.double, 1),
    bufferBuiltin("writeUIntLE", "jsBufferPrototypeWriteUIntLECodeGenerator", b.double, 1),

    b.function(
        "jsBufferPrototypeFunction_compare",
        .{
            b.argument("target", attached_uint8_array, .{}),
            archetypes.nodeInteger("targetStart", b.size, buffer_index_range, .{ .presence = .optional, .missing = .undefined }),
            archetypes.nodeInteger("targetEnd", b.size, buffer_index_range, .{ .presence = .optional, .missing = .undefined }),
            archetypes.nodeInteger("sourceStart", b.size, buffer_index_range, .{ .presence = .optional, .missing = .undefined }),
            archetypes.nodeInteger("sourceEnd", b.size, buffer_index_range, .{ .presence = .optional, .missing = .undefined }),
        },
        b.int32,
        .{
            .backend = .cpp,
            .errors = compare_errors,
            .length = 5,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
            .this_value_type = attached_uint8_array,
        },
    ),
    b.function(
        "jsBufferPrototypeFunction_copy",
        .{
            b.argument("target", b.js_uint8_array, .{}),
            archetypes.bufferCopyIndex("targetStart", .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_copy_range }),
            archetypes.bufferCopyIndex("sourceStart", .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_copy_range }),
            archetypes.bufferCopyIndex("sourceEnd", .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_copy_range }),
            b.argument("sourceBytes", b.lazy(attached_uint8_array), .{
                .presence = .optional,
                .missing = .omitted,
                .source = .this_value,
                .deferred_reason = deferred_copy_range,
            }),
            b.argumentProjection("targetBytes", "target", attached_writable_uint8_array, deferred_copy_range),
        },
        b.size,
        .{
            .backend = .cpp,
            .length = 4,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
            .this_value_type = buffer_receiver,
        },
    ),
    b.function(
        "jsBufferPrototypeFunction_equals",
        .{b.argument("other", attached_uint8_array, .{})},
        b.boolean,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .node,
            .missing_required_arguments = .arity_error,
            .this_value_type = attached_uint8_array,
        },
    ),
    b.function(
        "jsBufferPrototypeFunction_fill",
        b.overloads(.{
            b.overloadCaseWithOptions("string_offset_encoding", .{
                b.argument("value", b.lazy(b.dom_string), .{ .deferred_reason = deferred_fill }),
                b.argument("encoding", b.lazy(fill_buffer_encoding), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_fill }),
                b.argument("end", b.lazy(b.size), .{ .presence = .optional, .missing = .undefined, .integer_conversion = .{ .node_receiver_byte_length = .{ .mode = .to_length, .bound = .at_preparation, .range_error = .prose } }, .deferred_reason = deferred_fill }),
            }, .{ .discriminants = &.{ 0, 1 } }),
            b.overloadCaseWithOptions("string_end_encoding", .{
                b.argument("value", b.lazy(b.dom_string), .{ .deferred_reason = deferred_fill }),
                b.argument("offset", b.lazy(b.size), .{ .presence = .optional, .missing = .undefined, .integer_conversion = .{ .node_validate_prose = buffer_allocation_range }, .deferred_reason = deferred_fill }),
                b.argument("encoding", b.lazy(fill_buffer_encoding), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_fill }),
            }, .{ .discriminants = &.{ 0, 2 } }),
            b.overloadCaseWithOptions("string", .{
                b.argument("value", b.lazy(b.dom_string), .{ .deferred_reason = deferred_fill }),
                b.argument("offset", b.lazy(b.size), .{ .presence = .optional, .missing = .undefined, .integer_conversion = .{ .node_validate_prose = buffer_allocation_range }, .deferred_reason = deferred_fill }),
                b.argument("end", b.lazy(b.size), .{ .presence = .optional, .missing = .undefined, .integer_conversion = .{ .node_receiver_byte_length = .{ .mode = .to_length, .bound = .at_preparation, .range_error = .prose } }, .deferred_reason = deferred_fill }),
                b.argument("encoding", b.lazy(fill_buffer_encoding), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_fill }),
            }, .{ .discriminants = &.{0} }),
            b.overloadCaseWithOptions("view", .{
                b.argument("value", b.lazy(b.bufferView(.lease)), .{ .deferred_reason = deferred_fill }),
                b.argument("offset", b.lazy(buffer_fill_other_offset), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_fill }),
                b.argument("end", b.lazy(buffer_fill_other_end), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_fill }),
            }, .{ .discriminants = &.{0} }),
            b.overloadCase("byte", .{
                b.argument("value", b.lazy(b.uint8), .{
                    .presence = .optional,
                    .missing = .omitted,
                    .integer_conversion = .webidl,
                    .deferred_reason = deferred_fill,
                }),
                b.argument("offset", b.lazy(buffer_fill_other_offset), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_fill }),
                b.argument("end", b.lazy(buffer_fill_other_end), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_fill }),
            }),
        }, .{ .ordered = true, .accept_extra_arguments = true, .fallback_case = "byte" }),
        b.js_uint8_array,
        .{ .backend = .cpp, .length = 4, .profile = .node, .this_value_type = buffer_receiver },
    ),
    bufferSearchFunction("jsBufferPrototypeFunction_includes", b.boolean),
    bufferSearchFunction("jsBufferPrototypeFunction_indexOf", b.int64),
    b.function(
        "jsBufferPrototypeFunction_inspect",
        .{
            b.argument("recurseTimes", b.discardAny(.ignored), .{}),
            b.argument("options", buffer_inspect_options, .{}),
        },
        b.js_string,
        .{
            .backend = .cpp,
            .length = 2,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
            .this_value_type = buffer_receiver,
        },
    ),
    bufferSearchFunction("jsBufferPrototypeFunction_lastIndexOf", b.int64),
    b.function("jsBufferPrototypeFunction_swap16", .{}, b.js_uint8_array, .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = buffer_receiver }),
    b.function("jsBufferPrototypeFunction_swap32", .{}, b.js_uint8_array, .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = buffer_receiver }),
    b.function("jsBufferPrototypeFunction_swap64", .{}, b.js_uint8_array, .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = buffer_receiver }),
    b.function(
        "jsBufferPrototypeFunction_slice",
        .{
            b.argument("start", b.lazy(b.double), .{ .presence = .optional, .missing = .undefined, .number_conversion = .coerce, .deferred_reason = deferred_receiver_range }),
            b.argument("end", b.lazy(b.double), .{ .presence = .optional, .missing = .undefined, .number_conversion = .coerce, .deferred_reason = deferred_receiver_range }),
        },
        archetypes.node_buffer_value,
        .{ .backend = .cpp, .length = 2, .profile = .exact, .this_value_type = buffer_receiver },
    ),
    b.function(
        "jsBufferPrototypeFunction_toString",
        .{
            b.argument("encoding", b.lazy(parsed_buffer_encoding), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_receiver_range }),
            b.argument("start", b.lazy(b.double), .{ .presence = .optional, .missing = .undefined, .number_conversion = .coerce, .deferred_reason = deferred_receiver_range }),
            b.argument("end", b.lazy(b.size), .{ .presence = .optional, .missing = .undefined, .integer_conversion = .to_length, .deferred_reason = deferred_receiver_range }),
            b.argument("noAssert", b.discardAny(.ignored), .{ .presence = .optional, .missing = .omitted }),
        },
        b.js_string,
        .{ .backend = .cpp, .length = 4, .profile = .node, .this_value_type = buffer_receiver },
    ),
    b.function(
        "jsBufferPrototypeFunction_write",
        b.overloads(.{
            b.overloadCase("encoding", .{
                b.argument("string", b.lazy(b.dom_string), .{ .deferred_reason = deferred_write }),
                b.argument("encoding", b.lazy(parsed_buffer_encoding), .{ .deferred_reason = deferred_write }),
                b.argument("missingLength", b.undefined_literal, .{ .presence = .optional, .missing = .omitted }),
                b.rest("ignored", b.discarded),
            }),
            b.overloadCase("length_encoding", .{
                b.argument("string", b.lazy(b.dom_string), .{ .deferred_reason = deferred_write }),
                b.argument("offset", b.lazy(b.size), .{ .integer_conversion = .{ .node_receiver_byte_length = .{ .mode = .integer } }, .deferred_reason = deferred_write }),
                b.argument("encoding", b.lazy(parsed_buffer_encoding), .{ .deferred_reason = deferred_write }),
                b.rest("ignored", b.discarded),
            }),
            b.overloadCase("range", .{
                b.argument("string", b.lazy(b.dom_string), .{ .deferred_reason = deferred_write }),
                b.argument("offset", b.lazy(b.size), .{ .integer_conversion = .{ .node_receiver_byte_length = .{ .mode = .integer } }, .presence = .optional, .missing = .undefined, .deferred_reason = deferred_write }),
                b.argument("length", b.lazy(b.size), .{ .integer_conversion = .{ .node_receiver_byte_length = .{ .mode = .integer } }, .presence = .optional, .missing = .undefined, .deferred_reason = deferred_write }),
                b.argument("encoding", b.lazy(b.optionalFalsy(parsed_buffer_encoding)), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_write }),
                b.rest("ignored", b.discarded),
            }),
        }, .{ .ordered = true, .fallback_case = "range" }),
        b.size,
        .{ .backend = .cpp, .length = 4, .profile = .node, .this_value_type = array_buffer_view_receiver },
    ),
    encodedWrite("jsBufferPrototypeFunction_utf16leWrite"),
    encodedWrite("jsBufferPrototypeFunction_utf8Write"),
    encodedWrite("jsBufferPrototypeFunction_latin1Write"),
    encodedWrite("jsBufferPrototypeFunction_asciiWrite"),
    encodedWrite("jsBufferPrototypeFunction_base64Write"),
    encodedWrite("jsBufferPrototypeFunction_base64urlWrite"),
    encodedWrite("jsBufferPrototypeFunction_hexWrite"),
    encodedSlice("jsBufferPrototypeFunction_utf8Slice"),
    encodedSlice("jsBufferPrototypeFunction_utf16leSlice"),
    encodedSlice("jsBufferPrototypeFunction_latin1Slice"),
    encodedSlice("jsBufferPrototypeFunction_asciiSlice"),
    encodedSlice("jsBufferPrototypeFunction_base64Slice"),
    encodedSlice("jsBufferPrototypeFunction_base64urlSlice"),
    encodedSlice("jsBufferPrototypeFunction_hexSlice"),
    bigintWrite("jsBufferPrototypeFunction_writeBigInt64LE", b.integerRepresentation(b.int64, .bigint)),
    bigintWrite("jsBufferPrototypeFunction_writeBigInt64BE", b.integerRepresentation(b.int64, .bigint)),
    bigintWrite("jsBufferPrototypeFunction_writeBigUInt64LE", b.integerRepresentation(b.uint64, .bigint)),
    bigintWrite("jsBufferPrototypeFunction_writeBigUInt64BE", b.integerRepresentation(b.uint64, .bigint)),

    bufferConstructor("callJSBuffer"),
    bufferConstructor("constructJSBuffer"),
});
