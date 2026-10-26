const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const types = @import("binding_schema_WebCryptoTypes");

const key = b.class("CryptoKey", b.illegalConstructor(), .{
    b.getter("type", types.key_type, .{ .implementation = "getType", .configurable = true }),
    b.getter("extractable", b.boolean, .{ .implementation = "getExtractable", .configurable = true }),
    b.getter("algorithm", types.key_algorithm_result, .{ .implementation = "getAlgorithm", .cache = "algorithm", .configurable = true }),
    b.getter("usages", types.key_usages, .{ .implementation = "getUsages", .cache = "usages", .configurable = true }),
}, .{
    b.cachedSlot("algorithm", types.key_algorithm_result, .{ .exposed = false }),
    b.cachedSlot("usages", types.key_usages, .{ .exposed = false }),
}, .{
    .illegal_constructor_errors = archetypes.illegalConstructorNewSuggestion("CryptoKey", "ERR_ILLEGAL_CONSTRUCTOR"),
    .ownership = .unique,
    .identity = .fresh,
    .structured_clone = .{ .tag = 248, .storable = true },
});

const owner = b.nominalHandle("WebCryptoKeyOwner", .{
    .cpp_type = .{ .pointer = &.{ .named = "BunBindgen_WebCryptoKey_CryptoKey_Native" } },
    .cpp_declarations = &.{.{ .structure = "BunBindgen_WebCryptoKey_CryptoKey_Native" }},
    .zig_type = "api.WebCryptoKey",
    .access_thread = .vm,
});
const borrowed_key = b.nominalHandle("BorrowedWebCryptoKey", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::CryptoKey" } },
    .cpp_declarations = &.{.{ .class = "WebCore::CryptoKey" }},
    .zig_type = "api.WebCryptoKey.NativeKey",
    .access_thread = .any,
});
const key_arg = .{b.argument("key", types.native_key, .{})};

pub const schema = b.moduleWithDeclarations("WebCryptoKey", .{}, .{key}, .{
    b.engineShim("type", key_arg, types.key_type, .realm_independent),
    b.engineShim("extractable", key_arg, b.boolean, .realm_independent),
    b.engineShim("algorithm", key_arg, types.key_algorithm_result, .vm_thread_allocating),
    b.engineShim("usages", key_arg, types.key_usages, .realm_independent_allocating),
    b.engineShim("serialize", key_arg, b.buffer(.copy), .current_realm_throwing),
    b.engineShim("deserialize", .{b.argument("bytes", b.buffer(.copy), .{})}, b.optional(types.native_key), .realm_independent_allocating),
}, .{
    b.nativeExportWithOptions("adopt", .{
        b.argument("key", types.native_key, .{ .ownership = .transfer }),
    }, types.crypto_key, .current_realm_throwing),
    b.nativeExport("nativeKey", .{b.argument("owner", owner, .{})}, borrowed_key),
});

pub const crypto_key = schema.class("CryptoKey");
