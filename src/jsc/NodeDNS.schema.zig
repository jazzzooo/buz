const std = @import("std");

const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const dns_resolver = @import("binding_schema_DNSResolver");
const dns_types = @import("binding_schema_DNSTypes");

pub const record_type = dns_types.record_type;

const result_order = b.enumeration("DNSResultOrder", .{
    b.enumerationValue("verbatim", "verbatim"),
    b.enumerationValue("ipv4first", "ipv4first"),
    b.enumerationValue("ipv6first", "ipv6first"),
});

const resolver_options = b.dictionaryWithOptions("DNSResolverOptions", .{
    b.dictionaryField("timeout", b.int32, .{
        .integer_conversion = .{ .node_validate = .{ .min = -1, .max = std.math.maxInt(i32) } },
    }),
    b.dictionaryField("tries", b.int32, .{
        .integer_conversion = .{ .node_validate = .{ .min = 1, .max = std.math.maxInt(i32) } },
    }),
}, .{
    .node_allow_array = true,
    .node_allow_callable = true,
});

const lookup_family_name = b.enumeration("DNSLookupFamilyName", .{
    b.enumerationValue("unspecified", "any"),
    b.enumerationValueWithOptions("inet", "IPv4", .{ .aliases = &.{"ipv4"} }),
    b.enumerationValueWithOptions("inet6", "IPv6", .{ .aliases = &.{"ipv6"} }),
});

const lookup_family = b.unionType("DNSLookupFamily", .{
    b.unionMember("number", b.int32),
    b.unionMember("name", lookup_family_name),
}, .{});

const lookup_backend = b.enumeration("DNSLookupBackend", .{
    b.enumerationValueWithOptions("c_ares", "c-ares", .{ .aliases = &.{ "c_ares", "cares", "async" } }),
    b.enumerationValue("system", "system"),
    b.enumerationValueWithOptions("libc", "libc", .{ .aliases = &.{"getaddrinfo"} }),
});

const lookup_socket_type = b.enumeration("DNSLookupSocketType", .{
    b.enumerationValueWithOptions("stream", "stream", .{ .aliases = &.{"tcp"} }),
    b.enumerationValueWithOptions("dgram", "dgram", .{ .aliases = &.{"udp"} }),
});

const lookup_protocol = b.enumeration("DNSLookupProtocol", .{
    b.enumerationValue("tcp", "tcp"),
    b.enumerationValue("udp", "udp"),
});

const lookup_options = b.dictionaryWithOptions("DNSLookupOptions", .{
    b.dictionaryField("port", b.uint16, .{
        .default_value = .{ .unsigned = 0 },
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = 65535 } },
    }),
    b.dictionaryField("family", b.optionalNullish(lookup_family), .{ .default_value = .null }),
    b.dictionaryField("socketType", b.optionalNullish(lookup_socket_type), .{ .default_value = .null, .aliases = &.{"socktype"} }),
    b.dictionaryField("protocol", b.optionalNullish(lookup_protocol), .{ .default_value = .null }),
    b.dictionaryField("backend", b.optionalNullish(lookup_backend), .{ .default_value = .null }),
    b.dictionaryField("flags", b.int32, .{
        .default_value = .{ .signed = 0 },
        .integer_conversion = .coerce,
    }),
}, .{
    .node_allow_array = true,
    .node_allow_callable = true,
});

const lookup_options_input = b.unionType("DNSLookupOptionsInput", .{
    b.unionMember("options", lookup_options),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub const servers = dns_types.servers;
pub const server_strings = dns_types.server_strings;

const cache_stats = b.dictionary("DNSCacheStats", .{
    b.dictionaryField("cacheHitsCompleted", b.double, .{ .required = true }),
    b.dictionaryField("cacheHitsInflight", b.double, .{ .required = true }),
    b.dictionaryField("cacheMisses", b.double, .{ .required = true }),
    b.dictionaryField("size", b.double, .{ .required = true }),
    b.dictionaryField("errors", b.double, .{ .required = true }),
    b.dictionaryField("totalCount", b.double, .{ .required = true }),
});

const lookup_service_result = b.sequence(archetypes.optional_dom_string);

const lookup_result = b.dictionary("DNSLookupResult", .{
    b.dictionaryField("address", b.dom_string, .{ .required = true }),
    b.dictionaryField("family", b.int32, .{ .required = true }),
    b.dictionaryField("ttl", b.int32, .{ .required = true }),
});
const lookup_results = b.sequence(lookup_result);

fn function(comptime name: []const u8, comptime arguments: anytype, comptime result: b.Type, comptime length: u16) b.Function {
    return b.function(name, arguments, result, .{
        .backend = .zig,
        .length = length,
        .profile = .node,
    });
}

fn resolveFunction(
    comptime name: []const u8,
    comptime record: bool,
    comptime result: b.Type,
) b.Function {
    const arguments = .{b.argument(if (record) "name" else "hostname", b.dom_string, .{})} ++ if (record) .{
        b.argument("record", b.optionalMatch(record_type), .{
            .presence = .default_value,
            .missing = .undefined_or_null,
            .default_value = .{ .string = "A" },
        }),
    } else .{};
    return b.function(name, arguments, result, .{
        .backend = .zig,
        .completion = archetypes.vmCompletion(.queued),
        .length = arguments.len,
        .profile = .node,
    });
}

const functions = .{
    b.function("getRuntimeDefaultResultOrderOption", .{}, result_order, .{
        .backend = .zig,
        .length = 0,
        .profile = .node,
    }),
    function("newResolver", .{
        b.argument("options", resolver_options, .{
            .presence = .optional,
            .missing = .undefined_or_null,
        }),
    }, b.classRef(dns_resolver.dns_resolver), 1),
    b.function("lookup", .{
        b.argument("hostname", b.dom_string, .{}),
        b.argument("options", lookup_options_input, .{
            .presence = .optional,
            .missing = .undefined_or_null,
        }),
    }, lookup_results, .{
        .backend = .zig,
        .completion = archetypes.vmCompletion(.queued),
        .errors = b.domainErrors(.{
            b.domainError("invalid_family", b.none, .{
                .class = .type_error,
                .code = "ERR_INVALID_ARG_TYPE",
                .message = .{ .literal = "Invalid address family" },
            }),
            b.domainError("invalid_flags", b.none, .{
                .class = .type_error,
                .code = "ERR_INVALID_ARG_TYPE",
                .message = .{ .literal = "Invalid DNS lookup flags" },
            }),
        }),
        .length = 2,
        .profile = .node,
    }),
    resolveFunction("resolve", true, dns_resolver.resolve_result),
    resolveFunction("resolveSrv", false, dns_resolver.srv_results),
    resolveFunction("resolveTxt", false, dns_resolver.txt_results),
    resolveFunction("resolveSoa", false, dns_resolver.soa_result),
    resolveFunction("resolveNaptr", false, dns_resolver.naptr_results),
    resolveFunction("resolveMx", false, dns_resolver.mx_results),
    resolveFunction("resolveCaa", false, dns_resolver.caa_results),
    resolveFunction("resolveNs", false, dns_resolver.string_results),
    resolveFunction("resolvePtr", false, dns_resolver.string_results),
    resolveFunction("resolveCname", false, dns_resolver.string_results),
    resolveFunction("resolveAny", false, dns_resolver.any_results),
    function("getServers", .{}, server_strings, 0),
    function("setServers", .{b.argument("servers", servers, .{})}, b.none, 1),
    b.function("reverse", .{b.argument("ip", b.dom_string, .{})}, dns_resolver.string_results, .{
        .backend = .zig,
        .completion = archetypes.vmCompletion(.queued),
        .length = 1,
        .profile = .node,
    }),
    b.function("lookupService", .{
        b.argument("address", b.dom_string, .{}),
        archetypes.nodePort("port", .{}),
    }, lookup_service_result, .{
        .backend = .zig,
        .completion = archetypes.vmCompletion(.queued),
        .length = 2,
        .profile = .node,
    }),
    b.function(
        "prefetch",
        .{
            b.argument("hostname", b.dom_string, .{}),
            archetypes.nodePort("port", .{
                .presence = .default_value,
                .missing = .undefined_or_null,
                .default_value = .{ .unsigned = 443 },
            }),
        },
        b.none,
        .{
            .backend = .zig,
            .length = 2,
            .profile = .node,
        },
    ),
    function("getCacheStats", .{}, cache_stats, 0),
};

pub const schema = b.module("NodeDNS", functions);
