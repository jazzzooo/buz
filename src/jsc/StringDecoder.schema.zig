const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const string_decoder_brand = b.cppDynamicCastBrand("StringDecoderObject", .{
    .type_name = "WebCore::JSStringDecoder",
    .header = "JSStringDecoder.h",
}, "StringDecoder");

fn receiver(comptime name: []const u8, comptime is_getter: bool) b.Type {
    const failure: b.ConversionFailure = if (is_getter) .{
        .kind = .type_error,
        .message = "The StringDecoder." ++ name ++ " getter can only be used on instances of StringDecoder",
    } else .{
        .kind = .{ .code = "ERR_INVALID_THIS" },
        .message = "Can only call StringDecoder." ++ name ++ " on instances of StringDecoder",
    };
    const decoder = b.brandedValueWithBrand(string_decoder_brand, .{ .no_match_error = failure });
    const wrapper = b.dictionaryWithOptions("StringDecoderWrapper_" ++ name, .{
        b.dictionaryField("decoder", decoder, .{
            .private_symbol = "decode",
            .required = true,
            .missing_required = .convert_undefined,
        }),
    }, .{ .object_error = failure, .node_allow_array = true, .node_allow_callable = true });
    return b.unionType("StringDecoderReceiver_" ++ name, .{
        b.unionMember("decoder", decoder),
        b.unionMember("wrapper", wrapper),
    }, .{ .ordered = true, .fallback_member = "wrapper" });
}

fn method(comptime name: []const u8, comptime arguments: anytype, comptime length: u16) b.Function {
    return function(name, arguments, b.js_string, length, false);
}

fn getter(comptime name: []const u8, comptime result: b.Type) b.Function {
    return function(name, .{}, result, 0, true);
}

fn function(comptime name: []const u8, comptime arguments: anytype, comptime result: b.Type, comptime length: u16, comptime is_getter: bool) b.Function {
    return b.function(name, arguments, result, .{
        .backend = .cpp,
        .length = length,
        .profile = .node,
        .this_value_type = receiver(name, is_getter),
    });
}

pub const schema = b.module("StringDecoder", .{
    b.function(
        "construct",
        .{b.argument("encoding", b.optionalNullish(archetypes.coerced_node_string_encoding), .{})},
        b.js_object,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .node,
            .this_value_type = b.optionalMatch(b.js_object),
            .new_target_type = b.optionalMatch(b.js_object),
            .missing_required_arguments = .convert_undefined,
        },
    ),
    getter("lastChar", archetypes.node_buffer_value),
    getter("lastNeed", b.uint8),
    getter("lastTotal", b.uint8),
    getter("encoding", archetypes.coerced_node_string_encoding),
    method("write", .{b.argument("buf", archetypes.string_or_buffer_view, .{})}, 1),
    method("end", .{b.argument("buf", b.buffer(.lease), .{ .presence = .optional, .missing = .omitted })}, 1),
    method(
        "text",
        .{
            b.argument("buf", b.buffer(.lease), .{}),
            archetypes.rangedInteger("offset", b.int32, .{ .min = 0, .max = 2147483647 }, .{}),
        },
        2,
    ),
});
