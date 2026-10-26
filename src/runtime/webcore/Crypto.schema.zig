const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const subtle_crypto = @import("binding_schema_SubtleCryptoHost").subtle_crypto;
const subtle_crypto_result = b.plainClassResult(subtle_crypto);

const timing_safe_equal_errors = b.domainErrors(.{
    b.domainError("length_mismatch", b.none, .{
        .class = .range_error,
        .code = "ERR_CRYPTO_TIMING_SAFE_EQUAL_LENGTH",
        .message = .{ .literal = "Input buffers must have the same byte length" },
    }),
});

const crypto_class = b.class(
    "Crypto",
    b.illegalConstructor(),
    .{
        b.method(
            "getRandomValues",
            .{b.argument("data", b.writableIntegerTypedArray(.lease), .{})},
            b.any,
            .{
                .missing_required_arguments = .convert_undefined,
            },
        ),
        b.method("randomUUID", .{}, b.dom_string, .{
            .length = 1,
        }),
        b.getter("subtle", subtle_crypto_result, .{ .implementation = "getSubtle", .cache = "subtle" }),
        b.setter("subtle", b.discardAny(.ignored), .{ .implementation = "setSubtle" }),
        b.method(
            "timingSafeEqual",
            .{
                b.argument("buf1", b.buffer(.lease), .{}),
                b.argument("buf2", b.buffer(.lease), .{}),
            },
            b.boolean,
            .{ .errors = timing_safe_equal_errors, .length = 2, .profile = .node },
        ),
    },
    .{b.cachedSlot("subtle", subtle_crypto_result, .{ .exposed = false })},
    .{
        .illegal_constructor_errors = .{
            .call = archetypes.constructorRequiresNew("Crypto"),
            .construct = .{ .kind = .{ .code = "ERR_ILLEGAL_CONSTRUCTOR" }, .message = "Crypto is not constructable" },
        },
        .backend = .zig,
        .profile = .webidl,
        .ownership = .unique,
        .identity = .fresh,
    },
);

const native_exports = .{
    b.nativeExportWithOptions("cryptoObjectCreate", .{}, b.classRefByName("Crypto", "Crypto"), .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("Crypto", .{}, .{crypto_class}, .{}, native_exports);
pub const crypto = schema.class("Crypto");
