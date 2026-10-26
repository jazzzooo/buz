const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const socket_address_schema = @import("binding_schema_SocketAddress");

const deferred_address_family = "a pre-parsed SocketAddress bypasses family-string conversion while textual addresses require it";
const deferred_subnet_prefix = "the parsed address family determines the valid prefix range and its error ordering";

const optional_block_list = b.optionalMatch(b.classRefByName("BlockList", "BlockList"));

const block_list_address = b.unionType("BlockListAddress", .{
    b.unionMember("socket_address", b.classRef(socket_address_schema.socket_address)),
    b.unionMember("string", b.dom_string),
}, .{
    .ordered = true,
    .node_error = .{ .expected_type = "string" },
});

const block_list_family = b.enumerationWithOptions("BlockListFamily", .{
    b.enumerationValue("ipv4", "ipv4"),
    b.enumerationValue("ipv6", "ipv6"),
}, .{
    .ascii_case_insensitive = true,
    .node_invalid_value = .{ .invalid_argument_value = .{
        .name = "options.family",
        .reason = "is invalid",
        .non_string_expected_type = "string",
    } },
});

const start_after_end_error = b.domainError("start_after_end", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_VALUE",
    .message = .{ .literal = "The \"start\" argument must come before end." },
});

const prefix_out_of_range_error = b.domainError("prefix_out_of_range", b.dom_string, .{
    .class = .range_error,
    .code = "ERR_OUT_OF_RANGE",
    .message = .payload,
});

const address_errors = b.domainErrors(.{socket_address_schema.invalid_address_error});
const range_errors = b.domainErrors(.{ socket_address_schema.invalid_address_error, start_after_end_error });
const subnet_errors = b.domainErrors(.{ socket_address_schema.invalid_address_error, prefix_out_of_range_error });

fn address(comptime name: []const u8) b.Argument {
    return b.argument(name, block_list_address, .{});
}

fn family() b.Argument {
    return b.argument("family", b.lazy(block_list_family), .{ .presence = .optional, .deferred_reason = deferred_address_family });
}

const block_list_class = b.class(
    "BlockList",
    b.constructor(.{}, .{ .length = 0 }),
    .{
        b.method(
            "addAddress",
            .{
                address("address"),
                family(),
            },
            b.none,
            .{ .errors = address_errors, .length = 1 },
        ),
        b.method(
            "addRange",
            .{
                address("start"),
                address("end"),
                family(),
            },
            b.none,
            .{ .errors = range_errors, .length = 2 },
        ),
        b.method(
            "addSubnet",
            .{
                address("network"),
                archetypes.nodeInteger("prefix", b.lazy(b.int32), .{ .min = -2147483648, .max = 2147483647 }, .{
                    .deferred_reason = deferred_subnet_prefix,
                }),
                family(),
            },
            b.none,
            .{ .errors = subnet_errors, .length = 2 },
        ),
        b.method(
            "check",
            .{
                address("address"),
                family(),
            },
            b.boolean,
            .{ .length = 1 },
        ),
        b.getter("rules", archetypes.dom_strings, .{}),
        b.staticMethod(
            "isBlockList",
            .{b.argument("value", optional_block_list, .{})},
            b.boolean,
            .{ .length = 1 },
        ),
    },
    .{},
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("BlockList"),
        .backend = .zig,
        .profile = .node,
        .ownership = .shared,
        .identity = .fresh,
        .fresh_identity_reason = "construction and cloning each create a distinct VM-owned instance; clones share only the synchronized rule store",
        .memory_usage = .vm,
        .structured_clone = .{
            .tag = 251,
            .unsupported_context = .empty_object,
            .shared = .{
                .state = "RuleListType",
                .reason = "BlockList clones share mutations to an in-process rule store across workers",
            },
        },
    },
);

pub const schema = b.moduleWithClasses("BlockList", .{}, .{block_list_class});
pub const block_list = schema.class("BlockList");
