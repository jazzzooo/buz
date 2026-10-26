const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const crypto = @import("binding_schema_node_crypto_binding");

const input_encoding = b.unionType("NodeCryptoECDHInputEncoding", .{
    b.unionMember("ignored", b.discard(b.js_object)),
    b.unionMember("encoding", archetypes.coerced_node_string_encoding),
}, .{ .ordered = true, .fallback_member = "encoding", .cpp_name = "NodeCryptoECDHInputEncoding" });

const point_format = b.enumerationWithOptions("NodeCryptoECDHPointFormat", .{
    b.enumerationValue("uncompressed", "uncompressed"),
    b.enumerationValue("compressed", "compressed"),
    b.enumerationValue("hybrid", "hybrid"),
}, .{
    .cpp_name = "NodeCryptoECDHPointFormat",
    .node_invalid_value = .{ .coerced_error = .{
        .code = "ERR_CRYPTO_ECDH_INVALID_FORMAT",
        .message_prefix = "Invalid ECDH format: ",
    } },
});

fn formatArgument() b.Argument {
    return b.argument("format", b.optionalFalsy(point_format), .{ .presence = .optional, .missing = .omitted });
}

fn methodOptions(comptime length: u16) b.ClassMemberOptions {
    return .{
        .backend = .cpp,
        .this_value_type = b.this_class_ref,
        .length = length,
        .configurable = true,
    };
}

fn keySetter(comptime name: []const u8) b.ClassMember {
    return b.method(name, .{
        b.argument("key", archetypes.node_string_or_copied_buffer, .{ .presence = .optional, .missing = .omitted }),
        archetypes.lazyOptionalNodeStringEncoding("encoding", "a missing key is rejected before using encoding for a string key"),
    }, b.this_class_ref, .{
        .this_value_type = b.this_class_ref,
        .length = 2,
        .configurable = true,
        .errors = b.domainErrors(.{b.domainError("missing_key", b.none, .{
            .class = .type_error,
            .code = "ERR_MISSING_ARGS",
            .message = .{ .literal = "ECDH.prototype." ++ name ++ " requires a key argument" },
        })}),
    });
}

const curve_argument = .{b.argument("curve", b.dom_string, .{})};
const ecdh = b.class("ECDH", b.constructor(curve_argument, .{
    .length = 2,
    .missing_required_arguments = .convert_undefined,
}), .{
    b.method("generateKeys", .{ archetypes.optionalNodeEncoding("encoding"), formatArgument() }, crypto.node_crypto_encoded_output, methodOptions(0)),
    b.method("getPublicKey", .{ archetypes.optionalNodeEncoding("encoding"), formatArgument() }, crypto.node_crypto_encoded_output, methodOptions(2)),
    b.method("getPrivateKey", .{archetypes.optionalNodeEncoding("encoding")}, crypto.node_crypto_encoded_output, methodOptions(1)),
    b.method("computeSecret", .{
        archetypes.optionalNodeStringOrBuffer("key"),
        archetypes.lazyOptionalNodeStringEncoding("inputEncoding", "a missing public key is rejected before using encoding for a string key"),
        archetypes.optionalNodeEncoding("outputEncoding"),
    }, crypto.node_crypto_encoded_output, methodOptions(3)),
    keySetter("setPublicKey"),
    keySetter("setPrivateKey"),
    b.staticMethod("convertKey", .{
        archetypes.optionalNodeStringOrBuffer("key"),
        b.argument("curve", b.dom_string, .{ .presence = .optional, .missing = .omitted }),
        b.argument("inputEncoding", b.lazy(b.optionalFalsy(input_encoding)), .{
            .presence = .optional,
            .missing = .omitted,
            .deferred_reason = "convertKey rejects a missing curve or key before using encoding for a string key",
        }),
        archetypes.optionalNodeEncoding("outputEncoding"),
        formatArgument(),
    }, crypto.node_crypto_encoded_output, .{
        .backend = .cpp,
        .length = 3,
        .configurable = true,
        .errors = b.domainErrors(.{b.domainError("invalid_point", b.none, .{
            .class = .generic_error,
            .code = "ERR_CRYPTO_OPERATION_FAILED",
            .message = .{ .literal = "Failed to convert Buffer to EC_POINT" },
        })}),
    }),
}, .{}, .{
    .profile = .node,
    .ownership = .unique,
    .constructor_call = b.constructorCall(curve_argument, b.classRefByName("NodeCryptoECDH", "ECDH"), .{
        .length = 2,
        .missing_required_arguments = .convert_undefined,
    }),
});

const native_key = b.nominalHandle("NodeECDHKey", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::ECDHKey" } },
    .cpp_declarations = &.{.{ .class = "Bun::ECDHKey" }},
    .cpp_header = "ECDHKey.h",
    .zig_type = "api.NodeCryptoECDH.NativeKey",
    .ownership = .owned,
    .cpp_release = "destroyECDHKey",
    .access_thread = .vm,
    .destroy_thread = .vm,
});
const borrowed_key = b.nominalHandle("NodeECDHKeyBorrow", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::ECDHKey" } },
    .cpp_declarations = &.{.{ .class = "Bun::ECDHKey" }},
    .zig_type = "api.NodeCryptoECDH.NativeKey",
    .access_thread = .vm,
});
const owner = b.nominalHandle("NodeECDHOwner", .{
    .cpp_type = .{ .pointer = &.{ .named = "BunBindgen_NodeCryptoECDH_ECDH_Native" } },
    .cpp_declarations = &.{.{ .structure = "BunBindgen_NodeCryptoECDH_ECDH_Native" }},
    .zig_type = "api.NodeCryptoECDH",
    .access_thread = .vm,
});
const key_input = b.unionType("NodeECDHKeyInput", .{
    b.unionMember("buffer", b.buffer(.copy)),
    b.unionMember("string", b.dom_string),
}, .{ .ordered = true });

fn setKeyShim(comptime name: []const u8) b.EngineShim {
    return b.engineShim(name, .{
        b.argument("key", native_key, .{}),
        b.argument("input", key_input, .{}),
        b.argument("encoding", b.optional(archetypes.node_string_encoding), .{}),
    }, b.none, .current_realm_node_throwing);
}

pub const schema = b.moduleWithDeclarations("NodeCryptoECDH", .{}, .{ecdh}, .{
    b.engineShim("create", curve_argument, native_key, .current_realm_throwing),
    setKeyShim("setPublicKey"),
    setKeyShim("setPrivateKey"),
}, .{
    b.nativeExport("nativeKey", .{b.argument("owner", owner, .{})}, borrowed_key),
});
