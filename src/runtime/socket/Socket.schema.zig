const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const listener = @import("binding_schema_Listener");
const request = @import("binding_schema_Request");
const response = @import("binding_schema_Response");
const socket_config = @import("binding_schema_SocketConfig");
const ssl = @import("binding_schema_SSLConfig");
const x509 = @import("binding_schema_X509");

const deferred_socket_operand = "socket state, operation mode, and backpressure determine which optional data and configuration operands are observed";

const optional_listener_ref = b.optionalUndefined(b.classRef(listener.listener));
const us_socket_handle = b.nominalHandle("USSocket", .{
    .cpp_type = .{ .pointer = &.{ .named = "us_socket_t" } },
    .cpp_declarations = &.{.{ .structure = "us_socket_t" }},
    .access_thread = .current,
});
const us_socket_stream_buffer_handle = b.nominalHandle("USSocketStreamBuffer", .{
    .cpp_type = .{ .pointer = &.{ .named = "us_socket_stream_buffer_t" } },
    .cpp_declarations = &.{.{ .structure = "us_socket_stream_buffer_t" }},
    .zig_type = "uws.us_socket_stream_buffer_t",
    .access_thread = .current,
});
const owned_socket_stream_buffer = b.nominalHandle("OwnedUSSocketStreamBuffer", .{
    .cpp_type = .{ .pointer = &.{ .named = "us_socket_stream_buffer_t" } },
    .cpp_declarations = &.{.{ .structure = "us_socket_stream_buffer_t" }},
    .zig_type = "uws.us_socket_stream_buffer_t",
    .ownership = .owned,
    .cpp_release = "releaseSocketStreamBuffer",
    .access_thread = .current,
    .destroy_thread = .any,
});

pub const socket_encoding = archetypes.socket_encoding;
const positional_socket_encoding = archetypes.positional_socket_encoding;

fn socketWriteData(comptime mode: b.BufferMode) b.Type {
    return b.unionType(if (mode == .copy) "SocketWriteDataCopy" else "SocketWriteData", .{
        b.unionMember("blob", b.blob),
        b.unionMember("buffer", b.buffer(mode)),
        b.unionMember("request", b.classRef(request.request)),
        b.unionMember("response", b.classRef(response.response)),
        b.unionMember("string", archetypes.string_like_dom_string),
    }, .{ .ordered = true, .fallback_member = "string" });
}

pub const socket_write_data = socketWriteData(.lease);
pub const socket_write_data_copy = socketWriteData(.copy);

const socket_write_position = b.unionType("SocketWritePosition", .{
    b.unionMember("encoding", positional_socket_encoding),
    b.unionMemberWithOptions("index", b.int64, .{
        .integer_conversion = .{ .matching = .{ .min = -9223372036854775808, .max = 9223372036854775807 } },
    }),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

const socket_buffered_write_data = b.unionType("SocketBufferedWriteData", .{
    b.unionMember("buffer", b.buffer(.lease)),
    b.unionMember("string", archetypes.string_like_dom_string),
}, .{ .ordered = true, .fallback_member = "string" });

const socket_tls_upgrade_result = b.optionalUndefined(
    b.js_array,
);

fn optionalLazyUndefined(comptime name: []const u8, comptime value_type: b.Type) b.Argument {
    return b.argument(name, b.lazy(b.optionalUndefined(value_type)), .{
        .presence = .optional,
        .missing = .omitted,
        .deferred_reason = deferred_socket_operand,
    });
}

const write_arguments = .{
    optionalLazyUndefined("data", socket_write_data),
    optionalLazyUndefined("offsetOrEncoding", socket_write_position),
    optionalLazyUndefined("lengthOrEncoding", socket_write_position),
    optionalLazyUndefined("encoding", socket_encoding),
};

const buffered_write_arguments = .{
    optionalLazyUndefined("data", socket_buffered_write_data),
    optionalLazyUndefined("encoding", socket_encoding),
};

const reload_options = b.dictionaryWithOptions("SocketReloadOptions", .{
    b.dictionaryField("handlers", socket_config.handlers, .{ .required = true, .js_name = "socket" }),
}, .{ .user_facing_name = "SocketReloadOptions" });

fn booleanDefault(comptime name: []const u8, comptime value: bool) b.Argument {
    return b.argument(name, b.boolean, .{
        .presence = .default_value,
        .missing = .undefined,
        .default_value = .{ .boolean = value },
        .boolean_conversion = .truthy,
    });
}

const initial_delay = archetypes.nodeInteger("initialDelay", b.uint32, .{ .min = 0, .max = 2147483647 }, .{
    .presence = .default_value,
    .missing = .undefined,
    .default_value = .{ .unsigned = 0 },
});

const export_keying_material_arguments = .{
    archetypes.nodeInteger("length", b.uint64, .{ .min = 1, .max = 4_294_967_296 }, .{}),
    b.argument("label", b.dom_string, .{}),
    b.argument("context", archetypes.string_or_buffer, .{ .presence = .optional, .missing = .omitted }),
};

const export_keying_material_error = b.domainError("export_keying_material_failed", b.dom_string, .{
    .class = .generic_error,
    .message = .payload,
});

pub const socket_write_data_error_list = .{
    b.domainError("socket_body_not_buffered", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Only buffered Request/Response bodies are supported for now." },
    }),
    b.domainError("socket_file_blob_unsupported", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "File blob not supported yet in this function." },
    }),
};

const socket_write_error_list = .{
    b.domainError("socket_write_encoding_with_range", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Support encoding with offset and length altogether. Only either encoding or offset, length is supported, but not both combinations yet." },
        .name_override = "TODOError",
    }),
    b.domainError("socket_write_invalid_argument", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .payload,
    }),
    b.domainError("socket_write_out_of_range", b.dom_string, .{
        .class = .range_error,
        .code = "ERR_OUT_OF_RANGE",
        .message = .payload,
    }),
} ++ socket_write_data_error_list;

const missing_reload_options_error = b.domainError("missing_reload_options", b.none, .{
    .class = .generic_error,
    .message = .{ .literal = "Expected 1 argument" },
});

const timeout_out_of_range_error = b.domainError("timeout_out_of_range", b.none, .{
    .class = .generic_error,
    .message = .{ .literal = "Timeout must be a positive integer" },
});

const tls_server_sni_error = b.domainError("tls_server_sni", b.none, .{
    .class = .generic_error,
    .message = .{ .literal = "Cannot issue SNI from a TLS server-side socket" },
});

const tls_already_started_error = b.domainError("tls_already_started", b.none, .{
    .class = .generic_error,
    .message = .{ .literal = "Already started." },
});

const tls_operation_failed_error = b.domainError("tls_operation_failed", b.dom_string, .{
    .class = .generic_error,
    .message = .payload,
});

const authorization_error = b.optional(b.js_error_instance);
const legacy_certificate = b.optionalUndefined(x509.legacy_certificate);
const x509_certificate = b.optionalUndefined(x509.x509_certificate_value);
const cipher_info = b.dictionary("SocketCipherInfo", .{
    b.dictionaryField("name", b.optional(b.dom_string), .{ .required = true }),
    b.dictionaryField("standardName", b.optional(b.dom_string), .{ .required = true }),
    b.dictionaryField("version", b.optional(b.dom_string), .{ .required = true }),
});
const ephemeral_key_info = b.dictionary("SocketEphemeralKeyInfo", .{
    b.dictionaryField("type", b.dom_string, .{}),
    b.dictionaryField("name", b.dom_string, .{}),
    b.dictionaryField("size", b.int32, .{}),
});
const signature_algorithms = b.optional(archetypes.dom_strings);
const optional_node_buffer = b.optionalUndefined(b.node_buffer);

fn writeMethod(comptime name: []const u8, comptime implementation: []const u8) b.ClassMember {
    return b.method(name, write_arguments, b.int32, .{
        .errors = b.domainErrors(socket_write_error_list),
        .implementation = implementation,
        .length = 3,
    });
}

fn bufferedWriteMethod(
    comptime name: []const u8,
    comptime implementation: []const u8,
    comptime private_symbol: []const u8,
) b.ClassMember {
    return b.method(name, buffered_write_arguments, b.boolean, .{
        .implementation = implementation,
        .length = 2,
        .private_symbol = private_symbol,
        .display_name = name,
    });
}

fn reloadMethod() b.ClassMember {
    return b.method("reload", .{b.argument("options", b.lazy(reload_options), .{
        .presence = .optional,
        .missing = .omitted,
        .deferred_reason = deferred_socket_operand,
    })}, b.none, .{
        .errors = b.domainErrors(.{ missing_reload_options_error, socket_config.no_data_or_drain_error }),
        .implementation = "bindReload",
        .length = 1,
    });
}

fn upgradeTLSMethod() b.ClassMember {
    return b.method("upgradeTLS", .{b.argument("options", b.lazy(socket_config.tls_upgrade_options), .{
        .presence = .optional,
        .missing = .omitted,
        .deferred_reason = deferred_socket_operand,
    })}, socket_tls_upgrade_result, .{
        .errors = b.domainErrors(.{
            b.domainError("missing_upgrade_options", b.none, .{
                .class = .generic_error,
                .message = .{ .literal = "Expected 1 arguments" },
            }),
            b.domainError("server_upgrade_unsupported", b.none, .{
                .class = .generic_error,
                .message = .{ .literal = "Server-side upgradeTLS is not supported. Use upgradeDuplexToTLS with isServer: true instead." },
            }),
            b.domainError("socket_not_established", b.none, .{
                .class = .type_error,
                .code = "ERR_INVALID_ARG_TYPE",
                .message = .{ .literal = "upgradeTLS requires an established socket" },
            }),
            b.domainError("tls_required", b.none, .{
                .class = .generic_error,
                .message = .{ .literal = "Expected \"tls\" option" },
            }),
            b.domainError("tls_upgrade_failed", b.none, .{
                .class = .generic_error,
                .message = .{ .literal = "Failed to upgrade socket from TCP -> TLS. Is the TLS config correct?" },
            }),
            socket_config.no_data_or_drain_error,
        } ++ ssl.ssl_config_error_list),
        .implementation = "bindUpgradeTLS",
        .length = 1,
    });
}

fn noArgsMethod(comptime name: []const u8, comptime implementation: []const u8, comptime return_type: b.Type) b.ClassMember {
    return b.method(name, .{}, return_type, .{
        .implementation = implementation,
        .length = 0,
    });
}

fn socketClass(comptime name: []const u8, comptime tls: bool) b.Class {
    const declarations = if (tls) .{
        b.method("dispose", .{}, b.int32, .{ .implementation = "bindDispose", .length = 0, .symbol = .dispose }),
        b.getter("alpnProtocol", archetypes.dom_string_or_boolean, .{ .implementation = "bindGetALPNProtocol" }),
        b.getter("authorized", b.boolean, .{ .implementation = "bindGetAuthorized" }),
        b.getter("bytesWritten", b.size, .{ .implementation = "bindGetBytesWritten" }),
        b.method("close", .{}, b.none, .{
            .implementation = "bindClose",
            .length = 0,
        }),
        b.getter("data", b.retained_any, .{ .implementation = "bindGetData", .cache = "data", .writable = true }),
        noArgsMethod("disableRenegotiation", "bindDisableRenegotiation", b.none),
        writeMethod("end", "bindEnd"),
        bufferedWriteMethod("endBuffered", "bindEndBuffered", "end"),
        b.method("exportKeyingMaterial", export_keying_material_arguments, b.optionalUndefined(b.node_buffer), .{
            .errors = b.domainErrors(.{export_keying_material_error}),
            .implementation = "bindExportKeyingMaterial",
            .length = 3,
            .profile = .node,
        }),
        b.getter("fd", b.int64, .{ .implementation = "bindGetFD" }),
        noArgsMethod("flush", "bindFlush", b.none),
        b.method("getAuthorizationError", .{}, authorization_error, .{
            .implementation = "bindGetAuthorizationError",
            .length = 0,
        }),
        b.method("getCertificate", .{}, legacy_certificate, .{
            .implementation = "bindGetCertificate",
            .length = 0,
        }),
        noArgsMethod("getCipher", "bindGetCipher", b.optionalUndefined(cipher_info)),
        noArgsMethod("getEphemeralKeyInfo", "bindGetEphemeralKeyInfo", b.optional(ephemeral_key_info)),
        b.method("getPeerCertificate", .{b.argument("abbreviated", b.boolean, .{ .presence = .optional, .missing = .omitted })}, legacy_certificate, .{
            .implementation = "bindGetPeerCertificate",
            .length = 1,
        }),
        b.method("getPeerX509Certificate", .{}, x509_certificate, .{
            .implementation = "bindGetPeerX509Certificate",
            .length = 0,
        }),
        b.method("getServername", .{}, archetypes.optional_dom_string, .{ .implementation = "bindGetServername", .length = 0 }),
        noArgsMethod("getSession", "bindGetSession", optional_node_buffer),
        noArgsMethod("getSharedSigalgs", "bindGetSharedSigalgs", signature_algorithms),
        noArgsMethod("getTLSFinishedMessage", "bindGetTLSFinishedMessage", optional_node_buffer),
        noArgsMethod("getTLSPeerFinishedMessage", "bindGetTLSPeerFinishedMessage", optional_node_buffer),
        noArgsMethod("getTLSTicket", "bindGetTLSTicket", optional_node_buffer),
        b.method("getTLSVersion", .{}, archetypes.nullable_dom_string, .{ .implementation = "bindGetTLSVersion", .length = 0 }),
        b.method("getX509Certificate", .{}, x509_certificate, .{
            .implementation = "bindGetX509Certificate",
            .length = 0,
        }),
        b.method("isSessionReused", .{}, b.boolean, .{ .implementation = "bindIsSessionReused", .length = 0 }),
        b.getter("listener", optional_listener_ref, .{ .implementation = "bindGetListener" }),
        b.getter("localAddress", archetypes.optional_dom_string, .{ .implementation = "bindGetLocalAddress", .cache = "localAddress" }),
        b.getter("localFamily", archetypes.optional_dom_string, .{ .implementation = "bindGetLocalFamily", .cache = "localFamily" }),
        b.getter("localPort", archetypes.optional_network_port, .{ .implementation = "bindGetLocalPort", .cache = "localPort" }),
        noArgsMethod("pause", "bindPause", b.none),
        b.getter("readyState", b.int32, .{ .implementation = "bindGetReadyState" }),
        b.method("ref", .{}, b.none, .{
            .implementation = "bindRef",
            .length = 0,
        }),
        reloadMethod(),
        b.getter("remoteAddress", archetypes.optional_dom_string, .{ .implementation = "bindGetRemoteAddress", .cache = "remoteAddress" }),
        b.getter("remoteFamily", archetypes.optional_dom_string, .{ .implementation = "bindGetRemoteFamily", .cache = "remoteFamily" }),
        b.getter("remotePort", archetypes.optional_network_port, .{ .implementation = "bindGetRemotePort" }),
        b.method("renegotiate", .{}, b.none, .{
            .errors = b.domainErrors(.{tls_operation_failed_error}),
            .implementation = "bindRenegotiate",
            .length = 0,
        }),
        noArgsMethod("resume", "bindResume", b.none),
        b.method("setKeepAlive", .{ booleanDefault("enabled", false), initial_delay }, b.boolean, .{ .implementation = "bindSetKeepAlive", .length = 2, .profile = .node }),
        b.method("setMaxSendFragment", .{b.argument("size", b.double, .{})}, b.boolean, .{ .implementation = "bindSetMaxSendFragment", .length = 1 }),
        b.method("setNoDelay", .{booleanDefault("enabled", true)}, b.boolean, .{ .implementation = "bindSetNoDelay", .length = 1 }),
        b.method("setServername", .{b.argument("server_name", b.dom_string, .{})}, b.none, .{
            .errors = b.domainErrors(.{ tls_server_sni_error, tls_already_started_error, ssl.tls_boringssl_error }),
            .implementation = "bindSetServername",
            .length = 1,
        }),
        b.method("setSession", .{b.argument("session", archetypes.string_or_buffer, .{})}, b.none, .{
            .errors = b.domainErrors(.{tls_operation_failed_error}),
            .implementation = "bindSetSession",
            .length = 1,
        }),
        b.method("setVerifyMode", .{
            b.argument("request_cert", b.boolean, .{}),
            b.argument("reject_unauthorized", b.boolean, .{}),
        }, b.none, .{ .implementation = "bindSetVerifyMode", .length = 2 }),
        b.method("shutdown", .{booleanDefault("read", false)}, b.none, .{ .implementation = "bindShutdown", .length = 1 }),
        noArgsMethod("terminate", "bindTerminate", b.none),
        b.method("timeout", .{b.argument("seconds", b.int32, .{ .integer_conversion = .coerce })}, b.none, .{
            .errors = b.domainErrors(.{timeout_out_of_range_error}),
            .implementation = "bindTimeout",
            .length = 1,
        }),
        b.method("unref", .{}, b.none, .{
            .implementation = "bindUnref",
            .length = 0,
        }),
        upgradeTLSMethod(),
        writeMethod("write", "bindWrite"),
        bufferedWriteMethod("writeBuffered", "bindWriteBuffered", "write"),
    } else .{
        b.method("dispose", .{}, b.int32, .{ .implementation = "bindDispose", .length = 0, .symbol = .dispose }),
        b.getter("alpnProtocol", archetypes.dom_string_or_boolean, .{ .implementation = "bindGetALPNProtocol" }),
        b.getter("authorized", b.boolean, .{ .implementation = "bindGetAuthorized" }),
        b.getter("bytesWritten", b.size, .{ .implementation = "bindGetBytesWritten" }),
        b.method("close", .{}, b.none, .{
            .implementation = "bindClose",
            .length = 0,
        }),
        b.getter("data", b.retained_any, .{ .implementation = "bindGetData", .cache = "data", .writable = true }),
        noArgsMethod("disableRenegotiation", "bindDisableRenegotiation", b.none),
        writeMethod("end", "bindEnd"),
        bufferedWriteMethod("endBuffered", "bindEndBuffered", "end"),
        b.method("exportKeyingMaterial", export_keying_material_arguments, b.optionalUndefined(b.node_buffer), .{
            .errors = b.domainErrors(.{export_keying_material_error}),
            .implementation = "bindExportKeyingMaterial",
            .length = 3,
            .profile = .node,
        }),
        b.getter("fd", b.int64, .{ .implementation = "bindGetFD" }),
        noArgsMethod("flush", "bindFlush", b.none),
        b.method("getAuthorizationError", .{}, authorization_error, .{
            .implementation = "bindGetAuthorizationError",
            .length = 0,
        }),
        b.method("getCertificate", .{}, legacy_certificate, .{
            .implementation = "bindGetCertificate",
            .length = 0,
        }),
        noArgsMethod("getCipher", "bindGetCipher", b.optionalUndefined(cipher_info)),
        noArgsMethod("getEphemeralKeyInfo", "bindGetEphemeralKeyInfo", b.optional(ephemeral_key_info)),
        b.method("getPeerCertificate", .{b.argument("abbreviated", b.boolean, .{ .presence = .optional, .missing = .omitted })}, legacy_certificate, .{
            .implementation = "bindGetPeerCertificate",
            .length = 1,
        }),
        b.method("getServername", .{}, archetypes.optional_dom_string, .{ .implementation = "bindGetServername", .length = 0 }),
        noArgsMethod("getSession", "bindGetSession", optional_node_buffer),
        noArgsMethod("getSharedSigalgs", "bindGetSharedSigalgs", signature_algorithms),
        noArgsMethod("getTLSFinishedMessage", "bindGetTLSFinishedMessage", optional_node_buffer),
        noArgsMethod("getTLSPeerFinishedMessage", "bindGetTLSPeerFinishedMessage", optional_node_buffer),
        noArgsMethod("getTLSTicket", "bindGetTLSTicket", optional_node_buffer),
        b.method("getTLSVersion", .{}, archetypes.nullable_dom_string, .{ .implementation = "bindGetTLSVersion", .length = 0 }),
        b.method("isSessionReused", .{}, b.boolean, .{ .implementation = "bindIsSessionReused", .length = 0 }),
        b.getter("listener", optional_listener_ref, .{ .implementation = "bindGetListener" }),
        b.getter("localAddress", archetypes.optional_dom_string, .{ .implementation = "bindGetLocalAddress", .cache = "localAddress" }),
        b.getter("localFamily", archetypes.optional_dom_string, .{ .implementation = "bindGetLocalFamily", .cache = "localFamily" }),
        b.getter("localPort", archetypes.optional_network_port, .{ .implementation = "bindGetLocalPort", .cache = "localPort" }),
        noArgsMethod("pause", "bindPause", b.none),
        b.getter("readyState", b.int32, .{ .implementation = "bindGetReadyState" }),
        b.method("ref", .{}, b.none, .{
            .implementation = "bindRef",
            .length = 0,
        }),
        reloadMethod(),
        b.getter("remoteAddress", archetypes.optional_dom_string, .{ .implementation = "bindGetRemoteAddress", .cache = "remoteAddress" }),
        b.getter("remoteFamily", archetypes.optional_dom_string, .{ .implementation = "bindGetRemoteFamily", .cache = "remoteFamily" }),
        b.getter("remotePort", archetypes.optional_network_port, .{ .implementation = "bindGetRemotePort" }),
        b.method("renegotiate", .{}, b.none, .{
            .errors = b.domainErrors(.{tls_operation_failed_error}),
            .implementation = "bindRenegotiate",
            .length = 0,
        }),
        noArgsMethod("resume", "bindResume", b.none),
        b.method("setKeepAlive", .{ booleanDefault("enabled", false), initial_delay }, b.boolean, .{ .implementation = "bindSetKeepAlive", .length = 2, .profile = .node }),
        b.method("setMaxSendFragment", .{b.argument("size", b.double, .{})}, b.boolean, .{ .implementation = "bindSetMaxSendFragment", .length = 1 }),
        b.method("setNoDelay", .{booleanDefault("enabled", true)}, b.boolean, .{ .implementation = "bindSetNoDelay", .length = 1 }),
        b.method("setServername", .{b.argument("server_name", b.dom_string, .{})}, b.none, .{
            .errors = b.domainErrors(.{ tls_server_sni_error, tls_already_started_error, ssl.tls_boringssl_error }),
            .implementation = "bindSetServername",
            .length = 1,
        }),
        b.method("setSession", .{b.argument("session", archetypes.string_or_buffer, .{})}, b.none, .{
            .errors = b.domainErrors(.{tls_operation_failed_error}),
            .implementation = "bindSetSession",
            .length = 1,
        }),
        b.method("setVerifyMode", .{
            b.argument("request_cert", b.boolean, .{}),
            b.argument("reject_unauthorized", b.boolean, .{}),
        }, b.none, .{ .implementation = "bindSetVerifyMode", .length = 2 }),
        b.method("shutdown", .{booleanDefault("read", false)}, b.none, .{ .implementation = "bindShutdown", .length = 1 }),
        noArgsMethod("terminate", "bindTerminate", b.none),
        b.method("timeout", .{b.argument("seconds", b.int32, .{ .integer_conversion = .coerce })}, b.none, .{
            .errors = b.domainErrors(.{timeout_out_of_range_error}),
            .implementation = "bindTimeout",
            .length = 1,
        }),
        b.method("unref", .{}, b.none, .{
            .implementation = "bindUnref",
            .length = 0,
        }),
        upgradeTLSMethod(),
        writeMethod("write", "bindWrite"),
        bufferedWriteMethod("writeBuffered", "bindWriteBuffered", "write"),
    };

    return b.class(
        name,
        b.constructor(.{}, .{ .exposure = .never }),
        declarations,
        .{
            b.cachedSlot("data", b.retained_any, .{ .writable = true }),
            b.cachedSlot("localAddress", archetypes.optional_dom_string, .{}),
            b.cachedSlot("localFamily", archetypes.optional_dom_string, .{}),
            b.cachedSlot("localPort", archetypes.optional_network_port, .{}),
            b.cachedSlot("remoteAddress", archetypes.optional_dom_string, .{}),
            b.cachedSlot("remoteFamily", archetypes.optional_dom_string, .{}),
        },
        .{
            .backend = .zig,
            .profile = .exact,
            .ownership = .unique,
            .identity = .fresh,
            .reference_thread = .vm,
            .has_pending_activity = true,
            .memory_usage = .vm,
        },
    );
}

const tcp_socket_class = socketClass("TCPSocket", false);
const tls_socket_class = socketClass("TLSSocket", true);

const engine_shims = .{b.engineShim("socketTLSUpgradeResult", .{
    b.argument("raw", b.classRefByName("Socket", "TLSSocket"), .{}),
    b.argument("tls", b.classRefByName("Socket", "TLSSocket"), .{}),
}, b.js_array, .current_realm_throwing)};

const native_exports = .{
    b.nativeExport("warnExtraCALoadFailed", .{
        b.argument("filename", b.nativeSlice(.uint8, .read_only), .{}),
        b.argument("message", b.nativeSlice(.uint8, .read_only), .{}),
    }, b.none),
    b.nativeExportWithOptions("socketStreamBufferCreate", .{}, owned_socket_stream_buffer, .current_realm_throwing),
    b.nativeExportWithOptions(
        "socketStreamBufferDeinit",
        .{b.argument("buffer", us_socket_stream_buffer_handle, .{})},
        b.none,
        .{ .throws = .never, .realm = .none, .standalone_header = "UWSRuntime" },
    ),
    b.nativeExport("socketStreamBufferSize", .{b.argument("buffer", us_socket_stream_buffer_handle, .{})}, b.size),
    b.nativeExport("socketStreamBufferTotalWritten", .{b.argument("buffer", us_socket_stream_buffer_handle, .{})}, b.size),
    b.nativeExportWithOptions("socketBufferedWrite", .{
        b.argument("socket", us_socket_handle, .{}),
        b.argument("ended", b.boolean, .{}),
        b.argument("buffer", us_socket_stream_buffer_handle, .{}),
        b.argument("data", b.buffer(.copy), .{}),
    }, b.boolean, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("Socket", .{}, .{ tcp_socket_class, tls_socket_class }, engine_shims, native_exports);
pub const tcp_socket = schema.class("TCPSocket");
pub const tls_socket = schema.class("TLSSocket");
