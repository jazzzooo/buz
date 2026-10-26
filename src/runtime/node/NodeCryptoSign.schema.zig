const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const crypto = @import("binding_schema_node_crypto_binding");

fn methodOptions(comptime length: u16) b.ClassMemberOptions {
    return .{
        .backend = .cpp,
        .this_value_type = b.this_class_ref,
        .missing_required_arguments = .convert_undefined,
        .length = length,
        .configurable = true,
    };
}

fn signatureClass(comptime name: []const u8, comptime constructor_length: u16, comptime finish: b.ClassMember, comptime options: b.ClassOptions) b.Class {
    return b.class(name, b.constructor(.{}, .{ .length = constructor_length }), .{
        b.method("init", .{b.argument("digest", b.dom_string, .{})}, b.none, methodOptions(1)),
        b.method("update", .{
            archetypes.optionalNodeStringOrBuffer("data"),
            archetypes.lazyOptionalNodeStringEncoding("encoding", "encoding is used only for string input after missing input validation"),
        }, b.none, methodOptions(2)),
        finish,
    }, .{}, options);
}

const sign = signatureClass("Sign", 0, b.method("sign", .{
    b.argument("options", crypto.node_crypto_asymmetric_key_input, .{}),
    archetypes.optionalNodeEncoding("outputEncoding"),
}, crypto.node_crypto_encoded_output, methodOptions(2)), .{
    .profile = .node,
    .ownership = .unique,
});

const verify = signatureClass("Verify", 1, b.method("verify", .{
    b.argument("options", crypto.node_crypto_asymmetric_key_input, .{}),
    archetypes.optionalNodeStringOrBuffer("signature"),
    archetypes.lazyOptionalNodeStringEncoding("signatureEncoding", "verification checks its digest state before using encoding for a string signature"),
}, b.boolean, methodOptions(3)), .{
    .profile = .node,
    .ownership = .unique,
    .constructor_call = b.constructorCall(.{}, b.classRefByName("NodeCryptoSign", "Verify"), .{}),
});

const signature = b.nominalHandle("NodeCryptoStreamingSignature", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::StreamingSignature" } },
    .cpp_declarations = &.{.{ .class = "Bun::StreamingSignature" }},
    .cpp_header = "CryptoSignature.h",
    .zig_type = "api.NodeCryptoSign.NativeSignature",
    .ownership = .owned,
    .cpp_release = "destroyStreamingSignature",
    .access_thread = .vm,
    .destroy_thread = .vm,
});
const borrowed_signature = b.nominalHandle("NodeCryptoStreamingSignatureBorrow", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::StreamingSignature" } },
    .cpp_declarations = &.{.{ .class = "Bun::StreamingSignature" }},
    .zig_type = "api.NodeCryptoSign.NativeSignature",
    .access_thread = .vm,
});

fn nativeSignature(comptime name: []const u8) b.NativeExport {
    const owner = b.nominalHandle("NodeCrypto" ++ name ++ "Owner", .{
        .cpp_type = .{ .pointer = &.{ .named = "BunBindgen_NodeCryptoSign_" ++ name ++ "_Native" } },
        .cpp_declarations = &.{.{ .structure = "BunBindgen_NodeCryptoSign_" ++ name ++ "_Native" }},
        .zig_type = "api.NodeCryptoSign." ++ name,
        .access_thread = .vm,
    });
    return b.nativeExport("get" ++ name, .{b.argument("owner", owner, .{})}, borrowed_signature);
}

pub const schema = b.moduleWithDeclarations("NodeCryptoSign", .{}, .{ sign, verify }, .{
    b.engineShim("create", .{}, signature, .vm_thread_allocating),
}, .{ nativeSignature("Sign"), nativeSignature("Verify") });
