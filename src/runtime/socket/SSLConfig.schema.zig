const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const ssl_config_single_file = b.unionType("SSLConfigSingleFile", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("buffer", archetypes.copied_buffer),
    b.unionMember("file", b.blob),
}, .{ .ordered = true });

const ssl_config_file_value = b.unionType("SSLConfigFileValue", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("buffer", archetypes.copied_buffer),
    b.unionMember("file", b.blob),
    b.unionMember("array", b.sequence(ssl_config_single_file)),
}, .{ .ordered = true });

pub const ssl_config_file = b.optionalNullish(ssl_config_file_value);

const alpn_protocols_value = b.unionType("ALPNProtocolsValue", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("buffer", archetypes.copied_buffer),
}, .{ .ordered = true });

pub const alpn_protocols = b.optionalNullish(alpn_protocols_value);

pub const tls_boringssl_error = archetypes.boringSSLErrorWithString("tls_boringssl", b.thread_safe_dom_string);

pub const ssl_config_error_list = .{
    b.domainError("tls_invalid_options", b.thread_safe_dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .payload,
    }),
    b.systemError("tls_system"),
    tls_boringssl_error,
};

fn SSLConfigType(comptime name: []const u8, comptime file_type: b.Type) b.Type {
    return b.dictionaryWithOptions(name, .{
        b.dictionaryField("passphrase", archetypes.nullable_dom_string, .{ .default_value = .null }),
        b.dictionaryField("dh_params_file", archetypes.nullable_dom_string, .{
            .default_value = .null,
            .js_name = "dhParamsFile",
        }),
        b.dictionaryField("server_name", archetypes.nullable_dom_string, .{
            .default_value = .null,
            .js_name = "serverName",
            .aliases = &.{"servername"},
        }),
        b.dictionaryField("low_memory_mode", b.boolean, .{
            .default_value = .{ .boolean = false },
            .js_name = "lowMemoryMode",
        }),
        b.dictionaryField("reject_unauthorized", b.optionalNullish(b.boolean), .{
            .default_value = .null,
            .js_name = "rejectUnauthorized",
        }),
        b.dictionaryField("request_cert", b.boolean, .{
            .default_value = .{ .boolean = false },
            .js_name = "requestCert",
        }),
        b.dictionaryField("ca", file_type, .{ .default_value = .null }),
        b.dictionaryField("cert", file_type, .{ .default_value = .null }),
        b.dictionaryField("key", file_type, .{ .default_value = .null }),
        b.dictionaryField("secure_options", b.uint32, .{
            .default_value = .{ .unsigned = 0 },
            .js_name = "secureOptions",
        }),
        b.dictionaryField("key_file", archetypes.nullable_dom_string, .{
            .default_value = .null,
            .js_name = "keyFile",
        }),
        b.dictionaryField("cert_file", archetypes.nullable_dom_string, .{
            .default_value = .null,
            .js_name = "certFile",
        }),
        b.dictionaryField("ca_file", archetypes.nullable_dom_string, .{
            .default_value = .null,
            .js_name = "caFile",
        }),
        b.dictionaryField("alpn_protocols", alpn_protocols, .{
            .default_value = .null,
            .js_name = "ALPNProtocols",
        }),
        b.dictionaryField("ciphers", archetypes.nullable_dom_string, .{ .default_value = .null }),
        b.dictionaryField("client_renegotiation_limit", b.uint32, .{
            .default_value = .{ .unsigned = 0 },
            .js_name = "clientRenegotiationLimit",
        }),
        b.dictionaryField("client_renegotiation_window", b.uint32, .{
            .default_value = .{ .unsigned = 0 },
            .js_name = "clientRenegotiationWindow",
        }),
    }, .{ .user_facing_name = "TLSOptions" });
}

pub const ssl_config = SSLConfigType("SSLConfig", ssl_config_file);
pub const schema = b.module("socket_ssl_config", .{});
