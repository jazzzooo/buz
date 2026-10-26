const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const udp_socket = @import("binding_schema_UDPSocket");

const deferred_connect_operand = "UDP connect reports socket state and missing-argument errors before validating hostname and port";

const connect_errors = b.domainErrors(.{
    b.domainError("missing_arguments", b.none, .{
        .class = .type_error,
        .code = "ERR_MISSING_ARGS",
        .message = .{ .literal = "Expected hostname and port arguments" },
    }),
    b.domainError("already_connected", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Socket is already connected" },
    }),
    b.domainError("socket_closed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Socket is closed" },
    }),
    b.domainError("connect_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to connect socket" },
    }),
});

const disconnect_errors = b.domainErrors(.{
    b.domainError("not_connected", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Socket is not connected" },
    }),
    b.domainError("socket_closed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Socket is closed" },
    }),
    b.domainError("disconnect_failed", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Failed to disconnect socket" },
    }),
});

const port_range = b.IntegerRange{ .min = 1, .max = 65535 };

const functions = .{
    b.function(
        "connect",
        .{
            b.argument("hostname", b.lazy(b.dom_string), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_connect_operand }),
            archetypes.nodeInteger("port", b.lazy(b.uint16), port_range, .{
                .presence = .optional,
                .missing = .omitted,
                .deferred_reason = deferred_connect_operand,
            }),
        },
        b.none,
        .{ .backend = .zig, .errors = connect_errors, .length = 2, .profile = .node, .this_value_type = b.classRef(udp_socket.udp_socket) },
    ),
    b.function(
        "disconnect",
        .{},
        b.none,
        .{ .backend = .zig, .errors = disconnect_errors, .length = 0, .profile = .exact, .this_value_type = b.classRef(udp_socket.udp_socket) },
    ),
};

pub const schema = b.module("NodeDgram", functions);
