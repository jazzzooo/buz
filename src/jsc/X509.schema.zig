const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const node_crypto = @import("binding_schema_node_crypto_binding");

pub const x509_certificate_value = b.brandedValueWithBrand(b.cppDynamicCastBrand("X509CertificateValue", .{
    .type_name = "Bun::JSX509Certificate",
    .header = "JSX509Certificate.h",
}, "X509Certificate"), .{
    .expectation = "an X509Certificate",
    .node_requirement = "X509Certificate",
});

pub const certificate_handle = b.nominalHandle("X509Certificate", .{
    .cpp_type = .{ .pointer = &.{ .named = "X509" } },
    .cpp_declarations = &.{ .{ .structure = "x509_st" }, .{ .alias = .{ .name = "X509", .type = .{ .named = "x509_st" } } } },
    .access_thread = .vm,
});

const legacy_name_value = b.unionType("X509LegacyNameValue", .{
    b.unionMember("value", b.dom_string),
    b.unionMember("values", archetypes.dom_strings),
}, .{ .ordered = true });
const legacy_name = b.recordWithOptions(b.dom_string, legacy_name_value, .{ .result_prototype = .null });
const legacy_info_access = b.recordWithOptions(b.dom_string, archetypes.dom_strings, .{ .result_prototype = .null });
fn legacyCertificate(comptime name: []const u8, comptime bytes: b.Type) b.Type {
    return b.dictionary(name, .{
        b.dictionaryField("subject", b.optionalUndefined(legacy_name), .{ .required = true }),
        b.dictionaryField("issuer", b.optionalUndefined(legacy_name), .{ .required = true }),
        b.dictionaryField("subjectaltname", archetypes.optional_dom_string, .{ .required = true }),
        b.dictionaryField("infoAccess", b.optionalUndefined(legacy_info_access), .{ .required = true }),
        b.dictionaryField("modulus", b.dom_string, .{}),
        b.dictionaryField("exponent", b.dom_string, .{}),
        b.dictionaryField("bits", b.int32, .{}),
        b.dictionaryField("pubkey", bytes, .{}),
        b.dictionaryField("asn1Curve", b.dom_string, .{}),
        b.dictionaryField("nistCurve", b.dom_string, .{}),
        b.dictionaryField("valid_from", archetypes.optional_dom_string, .{ .required = true }),
        b.dictionaryField("valid_to", archetypes.optional_dom_string, .{ .required = true }),
        b.dictionaryField("fingerprint", archetypes.optional_dom_string, .{ .required = true }),
        b.dictionaryField("fingerprint256", archetypes.optional_dom_string, .{ .required = true }),
        b.dictionaryField("fingerprint512", archetypes.optional_dom_string, .{ .required = true }),
        b.dictionaryField("ext_key_usage", b.optionalUndefined(archetypes.dom_strings), .{ .required = true }),
        b.dictionaryField("serialNumber", archetypes.optional_dom_string, .{ .required = true }),
        b.dictionaryField("raw", bytes, .{ .required = true }),
        b.dictionaryField("ca", b.boolean, .{ .required = true }),
    });
}

pub const legacy_certificate = legacyCertificate("X509LegacyCertificate", b.node_buffer);
pub const legacy_certificate_data = legacyCertificate("X509LegacyCertificateData", b.sequence(b.uint8));

fn x509Receiver(comptime operation: []const u8) b.Type {
    _ = operation;
    return x509_certificate_value;
}

const x509_certificate = x509_certificate_value;
const x509_check_options = archetypes.x509_check_options;
const certificate_input = archetypes.copiedStringOrBufferInput(.{
    .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
    .message = "X509Certificate constructor argument must be a Buffer, TypedArray, or string",
});

fn requiredConvertedFunction(
    comptime name: []const u8,
    comptime operation: []const u8,
    comptime argument_name: []const u8,
    comptime argument_type: b.Type,
    comptime result: b.Type,
    comptime profile: b.Profile,
) b.Function {
    return b.function(
        name,
        .{b.argument(argument_name, argument_type, .{})},
        result,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = profile,
            .this_value_type = x509Receiver(operation),
            .missing_required_arguments = .convert_undefined,
        },
    );
}

fn getter(comptime name: []const u8, comptime result: b.Type) b.Function {
    return b.function(
        "certificateGetter_" ++ name,
        .{},
        result,
        .{ .backend = .cpp, .length = 0, .profile = .exact, .this_value_type = x509Receiver(name) },
    );
}

const functions = .{
    b.function(
        "certificateConstructorCall",
        .{},
        b.none,
        .{ .backend = .cpp, .length = 0, .profile = .exact },
    ),
    b.function(
        "certificateConstructorConstruct",
        .{b.argument("input", certificate_input, .{ .presence = .optional, .missing = .omitted })},
        x509_certificate_value,
        .{ .backend = .cpp, .length = 1, .profile = .exact, .new_target_type = b.js_object },
    ),
    b.function("certificateCheckEmail", .{ b.argument("email", b.dom_string, .{}), b.argument("options", x509_check_options, .{ .presence = .optional, .missing = .undefined }) }, archetypes.optional_dom_string, .{ .backend = .cpp, .length = 2, .profile = .node, .this_value_type = x509Receiver("checkEmail") }),
    b.function("certificateCheckHost", .{ b.argument("host", b.dom_string, .{}), b.argument("options", x509_check_options, .{ .presence = .optional, .missing = .undefined }) }, archetypes.optional_dom_string, .{ .backend = .cpp, .length = 2, .profile = .node, .this_value_type = x509Receiver("checkHost") }),
    b.function("certificateCheckIP", .{ b.argument("ip", b.dom_string, .{}), b.argument("options", x509_check_options, .{ .presence = .optional, .missing = .undefined }) }, archetypes.optional_dom_string, .{ .backend = .cpp, .length = 2, .profile = .node, .this_value_type = x509Receiver("checkIP") }),
    requiredConvertedFunction("certificateCheckIssued", "checkIssued", "issuer", x509_certificate, b.boolean, .exact),
    requiredConvertedFunction("certificateCheckPrivateKey", "checkPrivateKey", "privateKey", node_crypto.nodePrivateKeyObject("pkey"), b.boolean, .node),
    b.function("certificateToJSON", .{}, b.dom_string, .{ .backend = .cpp, .profile = .exact, .this_value_type = x509Receiver("toJSON") }),
    b.function("certificateToLegacyObject", .{}, legacy_certificate, .{ .backend = .cpp, .profile = .exact, .this_value_type = x509Receiver("toLegacyObject") }),
    b.function("certificateToString", .{}, b.dom_string, .{ .backend = .cpp, .profile = .exact, .this_value_type = x509Receiver("toString") }),
    requiredConvertedFunction("certificateVerify", "verify", "publicKey", node_crypto.nodePublicKeyObject("pkey"), b.boolean, .node),
    getter("ca", b.boolean),
    getter("fingerprint", b.js_string),
    getter("fingerprint256", b.js_string),
    getter("fingerprint512", b.js_string),
    getter("subject", b.js_string),
    getter("subjectAltName", b.optionalUndefined(b.js_string)),
    getter("infoAccess", b.optionalUndefined(b.js_string)),
    getter("keyUsage", b.optionalUndefined(b.js_array)),
    getter("issuer", b.js_string),
    getter("issuerCertificate", b.optionalUndefined(x509_certificate_value)),
    getter("publicKey", node_crypto.public_key_object),
    getter("raw", archetypes.node_buffer_value),
    getter("serialNumber", b.js_string),
    getter("validFrom", b.js_string),
    getter("validFromDate", b.js_date),
    getter("validTo", b.js_string),
    getter("validToDate", b.js_date),
    b.function(
        "isX509Certificate",
        .{b.argument("value", archetypes.object_or_ignored, .{})},
        b.boolean,
        .{ .backend = .cpp, .profile = .exact },
    ),
};

const engine_shims = .{
    b.engineShim("x509ToLegacyObject", .{b.argument("certificate", certificate_handle, .{})}, legacy_certificate_data, .current_realm_throwing),
    b.engineShim("x509CreateCertificateObject", .{b.argument("certificate", certificate_handle, .{})}, x509_certificate_value, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("X509", functions, .{}, engine_shims, .{});
