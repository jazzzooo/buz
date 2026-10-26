const b = @import("bindgen_schema");
const deferred_listener_reload = "listener state is validated before traversing reload options";
const archetypes = @import("binding_schema_archetypes");
const socket_config = @import("binding_schema_SocketConfig");

const listener_reload_options = b.dictionaryWithOptions("ListenerReloadOptions", .{
    b.dictionaryField("handlers", socket_config.handlers, .{ .required = true, .js_name = "socket" }),
}, .{ .user_facing_name = "ListenerReloadOptions" });

const listener_reload_errors = b.domainErrors(.{
    b.domainError("expected_options", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Expected 1 argument" },
    }),
    socket_config.no_data_or_drain_error,
});

const listener_socket_name = b.dictionary("ListenerSocketName", .{
    b.dictionaryField("family", b.dom_string, .{ .required = true }),
    b.dictionaryField("address", b.dom_string, .{ .required = true }),
    b.dictionaryField("port", b.uint16, .{ .required = true }),
});

const listener_class = b.class(
    "Listener",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("dispose", .{}, b.none, .{ .implementation = "bindDispose", .length = 0, .symbol = .dispose }),
        b.getter("data", b.any, .{ .implementation = "bindGetData" }),
        b.setter("data", b.retained_any, .{ .implementation = "bindSetData" }),
        b.getter("fd", b.int64, .{ .implementation = "bindGetFD" }),
        b.method("getSockNameNative", .{b.argument("result", b.js_object, .{})}, b.optionalUndefined(listener_socket_name), .{
            .implementation = "bindGetSockNameNative",
            .private_symbol = "getSockNameNative",
            .length = 1,
        }),
        b.method("getsockname", .{b.argument("result", b.js_object, .{})}, b.none, .{
            .backend = .builtin,
            .builtin = "listenerGetSockNameCodeGenerator",
            .length = 1,
        }),
        b.getter("hostname", archetypes.optional_dom_string, .{ .implementation = "bindGetHostname", .cache = "hostname" }),
        b.getter("port", archetypes.optional_network_port, .{ .implementation = "bindGetPort" }),
        b.method("ref", .{}, b.none, .{ .implementation = "bindRef", .length = 0, .this_value_type = b.this_class_ref }),
        b.method(
            "reload",
            .{b.argument("options", b.lazy(listener_reload_options), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_listener_reload })},
            b.none,
            .{ .errors = listener_reload_errors, .implementation = "bindReload", .length = 1 },
        ),
        b.method(
            "stop",
            .{b.argument("force", b.boolean, .{ .presence = .optional, .missing = .omitted })},
            b.none,
            .{ .implementation = "bindStop", .length = 1 },
        ),
        b.getter("unix", archetypes.optional_dom_string, .{ .implementation = "bindGetUnix", .cache = "unix" }),
        b.method("unref", .{}, b.none, .{ .implementation = "bindUnref", .length = 0 }),
    },
    .{
        b.cachedSlot("hostname", archetypes.optional_dom_string, .{}),
        b.cachedSlot("unix", archetypes.optional_dom_string, .{}),
    },
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
    },
);

pub const schema = b.moduleWithClasses("Listener", .{}, .{listener_class});
pub const listener = schema.class("Listener");
