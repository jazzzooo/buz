const b = @import("bindgen_schema");
const crypto = @import("binding_schema_node_crypto_binding");

const ordinary = b.SurfaceMemberOptions{ .attributes = .{} };
const non_enumerable = b.SurfaceMemberOptions{
    .attributes = .{ .enumerable = false },
};
const readonly = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false },
};
const tag = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .enumerable = false },
};

fn method(comptime property_name: []const u8, comptime declaration_name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(property_name, crypto.schema.function(declaration_name), ordinary);
}

fn hiddenMethod(comptime property_name: []const u8, comptime declaration_name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(property_name, crypto.schema.function(declaration_name), non_enumerable);
}

fn tagged(comptime name: []const u8, comptime members: anytype) b.ObjectSurface {
    return b.objectSurface(name, members ++ .{b.surfaceSymbolString(.to_string_tag, name[2 .. name.len - "Prototype".len], tag)}, .{ .installation = .reified });
}

const diffie_hellman = tagged("JSDiffieHellmanPrototype", .{
    method("generateKeys", "diffieHellmanGenerateKeys"),
    method("computeSecret", "diffieHellmanComputeSecret"),
    method("getPrime", "diffieHellmanGetPrime"),
    method("getGenerator", "diffieHellmanGetGenerator"),
    method("getPublicKey", "diffieHellmanGetPublicKey"),
    method("getPrivateKey", "diffieHellmanGetPrivateKey"),
    method("setPublicKey", "diffieHellmanSetPublicKey"),
    method("setPrivateKey", "diffieHellmanSetPrivateKey"),
});

const diffie_hellman_group = tagged("JSDiffieHellmanGroupPrototype", .{
    method("generateKeys", "diffieHellmanGroupGenerateKeys"),
    method("computeSecret", "diffieHellmanGroupComputeSecret"),
    method("getPrime", "diffieHellmanGroupGetPrime"),
    method("getGenerator", "diffieHellmanGroupGetGenerator"),
    method("getPublicKey", "diffieHellmanGroupGetPublicKey"),
    method("getPrivateKey", "diffieHellmanGroupGetPrivateKey"),
});

const cipher = tagged("JSCipherPrototype", .{
    method("update", "cipherUpdate"),
    method("final", "cipherFinal"),
    method("setAutoPadding", "cipherSetAutoPadding"),
    method("getAuthTag", "cipherGetAuthTag"),
    method("setAuthTag", "cipherSetAuthTag"),
    method("setAAD", "cipherSetAAD"),
});

const hash = tagged("JSHashPrototype", .{
    method("update", "hashUpdate"),
    method("digest", "hashDigest"),
});

const key_object = b.objectSurface("JSKeyObjectPrototype", .{
    hiddenMethod("equals", "keyObjectEquals"),
    b.surfaceFunctionGetter("type", crypto.schema.function("keyObjectType"), readonly),
    b.surfaceSymbolString(.to_string_tag, "KeyObject", tag),
}, .{ .installation = .reified });

const key_object_constructor = b.objectSurface("JSKeyObjectConstructor", .{
    hiddenMethod("from", "keyObjectFrom"),
}, .{ .installation = .reified });

const private_key = b.objectSurface("JSPrivateKeyObjectPrototype", .{
    hiddenMethod("export", "privateKeyObjectExport"),
    b.surfaceFunctionGetter("asymmetricKeyType", crypto.schema.function("privateKeyObjectAsymmetricKeyType"), readonly),
    b.surfaceFunctionGetter("asymmetricKeyDetails", crypto.schema.function("privateKeyObjectAsymmetricKeyDetails"), readonly),
}, .{ .installation = .reified });

const public_key = b.objectSurface("JSPublicKeyObjectPrototype", .{
    hiddenMethod("export", "publicKeyObjectExport"),
    b.surfaceFunctionGetter("asymmetricKeyType", crypto.schema.function("publicKeyObjectAsymmetricKeyType"), readonly),
    b.surfaceFunctionGetter("asymmetricKeyDetails", crypto.schema.function("publicKeyObjectAsymmetricKeyDetails"), readonly),
}, .{ .installation = .reified });

const secret_key = b.objectSurface("JSSecretKeyObjectPrototype", .{
    hiddenMethod("export", "secretKeyObjectExport"),
    b.surfaceFunctionGetter("symmetricKeySize", crypto.schema.function("secretKeyObjectSymmetricKeySize"), readonly),
}, .{ .installation = .reified });

const diffie_hellman_instance = b.objectSurface("JSDiffieHellmanInstance", .{
    b.surfaceFunctionGetter("verifyError", crypto.schema.function("diffieHellmanVerifyError"), readonly),
}, .{ .installation = .direct });

const diffie_hellman_group_instance = b.objectSurface("JSDiffieHellmanGroupInstance", .{
    b.surfaceFunctionGetter("verifyError", crypto.schema.function("diffieHellmanGroupVerifyError"), readonly),
}, .{ .installation = .direct });

pub const schema = b.moduleWithSurfaces("NodeCryptoSurfaces", .{
    diffie_hellman,
    diffie_hellman_group,
    cipher,
    hash,
    key_object,
    key_object_constructor,
    private_key,
    public_key,
    secret_key,
    diffie_hellman_instance,
    diffie_hellman_group_instance,
});
