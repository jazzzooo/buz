const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const listener = @import("binding_schema_Listener");
const secure_context = @import("binding_schema_SecureContext");
const socket = @import("binding_schema_Socket");
const socket_config = @import("binding_schema_SocketConfig");
const ssl = @import("binding_schema_SSLConfig");

const auto_select_family_attempt_timeout_range = b.IntegerRange{
    .min = 1,
    .max = 2147483647,
};

const add_server_name_tls = b.unionType("NodeSocketAddServerNameTLS", .{
    b.unionMember("secure_context", b.classRef(secure_context.secure_context)),
    b.unionMember("options", ssl.ssl_config),
}, .{ .ordered = true });

const node_socket = socket_config.socket_ref;

const add_server_name_errors = b.domainErrors(.{
    b.domainError("ssl_required", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "addServerName requires SSL support" },
    }),
    b.domainError("empty_hostname", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "hostname pattern cannot be empty" },
    }),
} ++ ssl.ssl_config_error_list);

const upgrade_duplex_to_tls_errors = b.domainErrors(.{
    b.domainError("tls_required", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Expected \"tls\" or \"secureContext\" option" },
    }),
    socket_config.no_data_or_drain_error,
} ++ ssl.ssl_config_error_list);

const functions = .{
    b.function(
        "getDefaultAutoSelectFamily",
        .{},
        b.boolean,
        .{ .backend = .zig, .length = 0, .profile = .exact },
    ),
    b.function(
        "setDefaultAutoSelectFamily",
        .{b.argument("value", b.boolean, .{})},
        b.none,
        .{ .backend = .zig, .length = 1, .profile = .node },
    ),
    b.function(
        "getDefaultAutoSelectFamilyAttemptTimeout",
        .{},
        b.uint32,
        .{ .backend = .zig, .length = 0, .profile = .exact },
    ),
    b.function(
        "setDefaultAutoSelectFamilyAttemptTimeout",
        .{archetypes.nodeInteger("value", b.int32, auto_select_family_attempt_timeout_range, .{})},
        b.none,
        .{ .backend = .zig, .length = 1, .profile = .node },
    ),
    b.function(
        "addServerName",
        .{
            b.argument("listener", b.classRef(listener.listener), .{}),
            b.argument("hostname", b.dom_string, .{}),
            b.argument("tls", add_server_name_tls, .{}),
        },
        b.none,
        .{
            .backend = .zig,
            .errors = add_server_name_errors,
            .length = 3,
            .profile = .exact,
        },
    ),
    b.function(
        "getUseSystemCA",
        .{},
        b.boolean,
        .{ .backend = .zig, .length = 0, .profile = .exact },
    ),
    b.function(
        "doConnect",
        .{
            b.argument("previous_socket", b.optionalNullish(node_socket), .{}),
            b.argument("options", socket_config.socket_config, .{}),
        },
        node_socket,
        .{
            .backend = .zig,
            .errors = b.domainErrors(socket_config.connect_error_list),
            .length = 2,
            .profile = .exact,
            .completion = .{
                .retention = .strong,
                .sender_drop = .cancel,
                .delivery = .vm,
            },
        },
    ),
    b.function(
        "newDetachedSocket",
        .{archetypes.truthyBoolean("is_ssl", .{ .presence = .optional, .missing = .omitted })},
        node_socket,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "getBufferedAmount",
        .{b.argument("socket", node_socket, .{})},
        b.size,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
    b.function(
        "isNamedPipeSocket",
        .{b.argument("socket", node_socket, .{})},
        b.boolean,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
    b.function(
        "upgradeDuplexToTLS",
        .{
            b.argument("duplex", b.js_object, .{}),
            b.argument("options", socket_config.tls_upgrade_options, .{}),
        },
        b.js_array,
        .{
            .backend = .zig,
            .errors = upgrade_duplex_to_tls_errors,
            .length = 2,
            .profile = .exact,
        },
    ),
};

const engine_shims = .{
    b.engineShim("socketDuplexUpgradeResult", .{
        b.argument("socket", b.classRef(socket.tls_socket), .{}),
        b.argument("events", b.js_array, .{}),
    }, b.js_array, .current_realm_throwing),
};

pub const schema = b.moduleWithEngineShims("NodeSocket", functions, engine_shims);
