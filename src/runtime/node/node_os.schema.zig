const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const socket_address_types = @import("binding_schema_SocketAddressTypes");

const node_user_info_text = b.dictionary("NodeUserInfoText", .{
    b.dictionaryField("username", b.dom_string, .{ .required = true }),
    b.dictionaryField("uid", b.double, .{ .required = true }),
    b.dictionaryField("gid", b.double, .{ .required = true }),
    b.dictionaryField("shell", archetypes.nullable_dom_string, .{ .required = true }),
    b.dictionaryField("homedir", b.dom_string, .{ .required = true }),
});

const node_user_info_buffer = b.dictionary("NodeUserInfoBuffer", .{
    b.dictionaryField("username", b.node_buffer, .{ .required = true }),
    b.dictionaryField("uid", b.double, .{ .required = true }),
    b.dictionaryField("gid", b.double, .{ .required = true }),
    b.dictionaryField("shell", b.optionalNullish(b.node_buffer), .{ .required = true }),
    b.dictionaryField("homedir", b.node_buffer, .{ .required = true }),
});

const node_user_info = b.unionType("NodeUserInfo", .{
    b.unionMember("text", node_user_info_text),
    b.unionMember("buffer", node_user_info_buffer),
}, .{ .ordered = true });

const node_cpu_times = b.dictionary("NodeCPUTimes", .{
    b.dictionaryField("user", b.uint64, .{ .required = true }),
    b.dictionaryField("nice", b.uint64, .{ .required = true }),
    b.dictionaryField("sys", b.uint64, .{ .required = true }),
    b.dictionaryField("idle", b.uint64, .{ .required = true }),
    b.dictionaryField("irq", b.uint64, .{ .required = true }),
});

const node_cpu_info = b.dictionary("NodeCPUInfo", .{
    b.dictionaryField("model", b.dom_string, .{ .required = true }),
    b.dictionaryField("speed", b.uint64, .{ .required = true }),
    b.dictionaryField("times", node_cpu_times, .{ .required = true }),
});

const node_cpu_infos = b.sequence(node_cpu_info);

const node_network_interface = b.dictionary("NodeNetworkInterface", .{
    b.dictionaryField("address", b.dom_string, .{ .required = true }),
    b.dictionaryField("netmask", b.dom_string, .{ .required = true }),
    b.dictionaryField("family", socket_address_types.family, .{ .required = true }),
    b.dictionaryField("mac", b.dom_string, .{ .required = true }),
    b.dictionaryField("internal", b.boolean, .{ .required = true }),
    b.dictionaryField("cidr", archetypes.nullable_dom_string, .{ .required = true }),
    b.dictionaryField("scopeid", b.uint32, .{}),
});

const node_network_interfaces = b.record(b.dom_string, b.sequence(node_network_interface));

pub const user_info_options = b.dictionary("UserInfoOptions", .{
    b.dictionaryField("encoding", b.dom_string, .{ .default_value = .{ .string = "" } }),
});

const int32_validation = b.IntegerConversion{ .node_validate = .{
    .min = -2147483648,
    .max = 2147483647,
} };

const priority_validation = b.IntegerConversion{ .node_validate = .{
    .min = -20,
    .max = 19,
} };

const cpus_errors = b.domainErrors(.{
    b.domainError("query_failed", b.none, .{
        .class = .generic_error,
        .code = "ERR_SYSTEM_ERROR",
        .message = .{ .literal = "Failed to get CPU information" },
    }),
});

const network_interfaces_errors = b.domainErrors(.{
    b.domainError("query_failed", b.none, .{
        .class = .generic_error,
        .code = "ERR_SYSTEM_ERROR",
        .message = .{ .literal = "Failed to get network interface information" },
    }),
});

const system_errors = b.domainErrors(.{
    b.systemError("system"),
});

const priority_errors = b.domainErrors(.{
    b.systemErrorWithInfo("system"),
});

const functions = .{
    b.function("cpus", .{}, node_cpu_infos, .{
        .backend = .zig,
        .errors = cpus_errors,
        .profile = .node,
    }),
    b.function("freemem", .{}, b.uint64, .{ .backend = .zig, .profile = .node }),
    b.function(
        "getPriority",
        .{b.argument("pid", b.int32, .{
            .presence = .default_value,
            .missing = .undefined,
            .default_value = .{ .signed = 0 },
            .integer_conversion = int32_validation,
        })},
        b.int32,
        .{ .backend = .zig, .errors = priority_errors, .profile = .node },
    ),
    b.function("homedir", .{}, b.dom_string, .{ .backend = .zig, .errors = system_errors, .profile = .node }),
    b.function("hostname", .{}, b.dom_string, .{ .backend = .zig, .profile = .node }),
    b.function("loadavg", .{}, archetypes.doubles, .{ .backend = .zig, .profile = .node }),
    b.function("networkInterfaces", .{}, node_network_interfaces, .{
        .backend = .zig,
        .errors = network_interfaces_errors,
        .profile = .node,
    }),
    b.function(
        "release",
        .{},
        b.dom_string,
        .{ .backend = .zig, .profile = .node },
    ),
    b.function("totalmem", .{}, b.uint64, .{ .backend = .zig, .profile = .node }),
    b.function("uptime", .{}, b.double, .{
        .backend = .zig,
        .errors = system_errors,
        .profile = .node,
    }),
    b.function(
        "userInfo",
        .{b.argument("options", user_info_options, .{
            .presence = .optional,
            .missing = .undefined_or_null,
        })},
        node_user_info,
        .{ .backend = .zig, .errors = system_errors, .profile = .node },
    ),
    b.function("version", .{}, b.dom_string, .{ .backend = .zig, .profile = .node }),
    b.function(
        "setPriority",
        b.overloads(.{
            b.overloadCase("with_pid", .{
                b.argument("pid", b.int32, .{ .integer_conversion = int32_validation }),
                b.argument("priority", b.int32, .{ .integer_conversion = priority_validation }),
            }),
            b.overloadCase("current", .{
                b.argument("priority", b.int32, .{ .integer_conversion = priority_validation }),
            }),
        }, .{}),
        b.none,
        .{ .backend = .zig, .errors = priority_errors, .profile = .node },
    ),
};

pub const schema = b.module("node_os", functions);
pub const cpus = schema.function("cpus");
pub const freemem = schema.function("freemem");
pub const get_priority = schema.function("getPriority");
pub const homedir = schema.function("homedir");
pub const hostname = schema.function("hostname");
pub const loadavg = schema.function("loadavg");
pub const network_interfaces = schema.function("networkInterfaces");
pub const release = schema.function("release");
pub const totalmem = schema.function("totalmem");
pub const uptime = schema.function("uptime");
pub const user_info = schema.function("userInfo");
pub const version = schema.function("version");
pub const set_priority = schema.function("setPriority");
