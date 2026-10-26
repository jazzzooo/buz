const b = @import("bindgen_schema");

const archetypes = @import("binding_schema_archetypes");
const optional_socket_address = b.optionalMatch(b.classValueByNameWithOptions("SocketAddress", "SocketAddress", .{ .match = .initial_structure }));

const socket_address_json = b.dictionary("SocketAddressJSON", .{
    b.dictionaryField("address", b.dom_string, .{ .required = true }),
    b.dictionaryField("family", b.dom_string, .{ .required = true }),
    b.dictionaryField("port", b.uint16, .{ .required = true }),
    b.dictionaryField("flowlabel", b.uint32, .{ .required = true }),
});

const socket_address_family = b.enumerationWithOptions("SocketAddressFamily", .{
    b.enumerationValue("ipv4", "ipv4"),
    b.enumerationValue("ipv6", "ipv6"),
}, .{ .cpp_name = "SocketAddressFamily" });

const family_input = b.unionType("SocketAddressFamilyInput", .{
    b.unionMember("string", archetypes.string_like_dom_string),
    archetypes.matchingInt32Member("number"),
}, .{ .ordered = true, .cpp_name = "SocketAddressFamilyInput", .node_error = .{ .invalid_property_value = "a string or number" } });
const family_value = b.converted(socket_address_family, family_input, b.customConverter("bunBindgenSocketAddressFamily", .{
    .audit_reason = "maps case-insensitive family strings and platform AF constants to the portable family enum",
}), .{ .name = "options.family" });

const socket_address_options = b.dictionaryWithOptions("SocketAddressOptions", .{
    b.dictionaryField("address", b.dom_string, .{}),
    b.dictionaryField("family", family_value, .{ .default_value = .{ .string = "ipv4" } }),
    archetypes.numericPortField("port", .{ .default_value = .{ .unsigned = 0 } }),
    b.dictionaryField("flowlabel", b.uint32, .{
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = 4294967295 } },
    }),
}, .{ .user_facing_name = "options" });

pub const invalid_address_error = b.domainError("invalid_address", b.none, .{
    .class = .generic_error,
    .code = "ERR_INVALID_IP_ADDRESS",
    .message = .{ .literal = "Invalid socket address" },
});

const constructor_errors = b.domainErrors(.{invalid_address_error});

const socket_address_class = b.class(
    "SocketAddress",
    b.constructor(
        .{b.argument("options", socket_address_options, .{ .presence = .optional, .missing = .undefined })},
        .{ .errors = constructor_errors },
    ),
    .{
        b.getter("address", b.dom_string, .{
            .implementation = "getAddress",
            .cache = "address",
            .enumerable = false,
            .configurable = true,
        }),
        b.getter("addrfamily", b.int32, .{ .implementation = "getAddrFamily", .enumerable = false }),
        b.getter("family", b.dom_string, .{
            .implementation = "getFamily",
            .cache = "family",
            .enumerable = false,
            .configurable = true,
        }),
        b.getter("flowlabel", b.uint32, .{
            .implementation = "getFlowLabel",
            .enumerable = false,
            .configurable = true,
        }),
        b.getter("port", b.uint16, .{
            .implementation = "getPort",
            .enumerable = false,
            .configurable = true,
        }),
        b.method("toJSON", .{}, socket_address_json, .{
            .enumerable = false,
            .configurable = true,
        }),
        b.staticMethod(
            "isSocketAddress",
            .{b.argument("value", optional_socket_address, .{})},
            b.boolean,
            .{ .enumerable = false, .configurable = true },
        ),
        b.staticMethod(
            "parse",
            .{b.argument("input", b.dom_string, .{})},
            b.optionalUndefined(b.classRefByName("SocketAddress", "SocketAddress")),
            .{
                .enumerable = false,
                .configurable = true,
            },
        ),
    },
    .{
        b.cachedSlot("address", b.dom_string, .{}),
        b.cachedSlot("family", b.dom_string, .{}),
    },
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("SocketAddress"),
        .backend = .zig,
        .profile = .node,
        .ownership = .unique,
        .identity = .fresh,
        .memory_usage = .any,
    },
);

pub const schema = b.moduleWithClasses("SocketAddress", .{}, .{socket_address_class});
pub const socket_address = schema.class("SocketAddress");
