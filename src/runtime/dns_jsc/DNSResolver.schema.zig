const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const dns_types = @import("binding_schema_DNSTypes");

pub const address_result = b.dictionary("DNSAddressResult", .{
    b.dictionaryField("address", b.dom_string, .{ .required = true }),
    b.dictionaryField("ttl", b.optionalUndefined(b.int32), .{ .required = true }),
});
pub const address_results = b.sequence(address_result);

pub const string_results = archetypes.dom_strings;

pub const srv_result = b.dictionary("DNSSrvResult", .{
    b.dictionaryField("priority", b.uint16, .{ .required = true }),
    b.dictionaryField("weight", b.uint16, .{ .required = true }),
    b.dictionaryField("port", b.uint16, .{ .required = true }),
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
});
pub const srv_results = b.sequence(srv_result);

pub const txt_entry = archetypes.dom_strings;
pub const txt_results = b.sequence(txt_entry);

pub const soa_result = b.dictionary("DNSSoaResult", .{
    b.dictionaryField("serial", b.uint32, .{ .required = true }),
    b.dictionaryField("refresh", b.uint32, .{ .required = true }),
    b.dictionaryField("retry", b.uint32, .{ .required = true }),
    b.dictionaryField("expire", b.uint32, .{ .required = true }),
    b.dictionaryField("minttl", b.uint32, .{ .required = true }),
    b.dictionaryField("nsname", b.dom_string, .{ .required = true }),
    b.dictionaryField("hostmaster", b.dom_string, .{ .required = true }),
});

pub const naptr_result = b.dictionary("DNSNaptrResult", .{
    b.dictionaryField("preference", b.uint16, .{ .required = true }),
    b.dictionaryField("order", b.uint16, .{ .required = true }),
    b.dictionaryField("flags", b.dom_string, .{ .required = true }),
    b.dictionaryField("service", b.dom_string, .{ .required = true }),
    b.dictionaryField("regexp", b.dom_string, .{ .required = true }),
    b.dictionaryField("replacement", b.dom_string, .{ .required = true }),
});
pub const naptr_results = b.sequence(naptr_result);

pub const mx_result = b.dictionary("DNSMxResult", .{
    b.dictionaryField("priority", b.uint16, .{ .required = true }),
    b.dictionaryField("exchange", b.dom_string, .{ .required = true }),
});
pub const mx_results = b.sequence(mx_result);

pub const caa_result = b.dictionary("DNSCaaNativeResult", .{
    b.dictionaryField("critical", b.int32, .{ .required = true }),
    b.dictionaryField("property", b.dom_string, .{ .required = true }),
    b.dictionaryField("value", b.dom_string, .{ .required = true }),
});
pub const caa_results = b.sequence(caa_result);

const any_record_type = b.enumeration("DNSAnyRecordType", .{
    b.enumerationValue("a", "A"),
    b.enumerationValue("aaaa", "AAAA"),
    b.enumerationValue("mx", "MX"),
    b.enumerationValue("ns", "NS"),
    b.enumerationValue("txt", "TXT"),
    b.enumerationValue("srv", "SRV"),
    b.enumerationValue("ptr", "PTR"),
    b.enumerationValue("naptr", "NAPTR"),
    b.enumerationValue("soa", "SOA"),
    b.enumerationValue("caa", "CAA"),
});

const any_address_result = b.dictionary("DNSAnyAddressResult", .{
    b.dictionaryField("address", b.dom_string, .{ .required = true }),
    b.dictionaryField("ttl", b.optionalUndefined(b.int32), .{ .required = true }),
    b.dictionaryField("type", any_record_type, .{ .required = true }),
});
const any_string_result = b.dictionary("DNSAnyStringResult", .{
    b.dictionaryField("value", b.dom_string, .{ .required = true }),
    b.dictionaryField("type", any_record_type, .{ .required = true }),
});
const any_mx_result = b.dictionary("DNSAnyMxResult", .{
    b.dictionaryField("priority", b.uint16, .{ .required = true }),
    b.dictionaryField("exchange", b.dom_string, .{ .required = true }),
    b.dictionaryField("type", any_record_type, .{ .required = true }),
});
const any_txt_result = b.dictionary("DNSAnyTxtResult", .{
    b.dictionaryField("entries", string_results, .{ .required = true }),
    b.dictionaryField("type", any_record_type, .{ .required = true }),
});
const any_srv_result = b.dictionary("DNSAnySrvResult", .{
    b.dictionaryField("priority", b.uint16, .{ .required = true }),
    b.dictionaryField("weight", b.uint16, .{ .required = true }),
    b.dictionaryField("port", b.uint16, .{ .required = true }),
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("type", any_record_type, .{ .required = true }),
});
const any_naptr_result = b.dictionary("DNSAnyNaptrResult", .{
    b.dictionaryField("preference", b.uint16, .{ .required = true }),
    b.dictionaryField("order", b.uint16, .{ .required = true }),
    b.dictionaryField("flags", b.dom_string, .{ .required = true }),
    b.dictionaryField("service", b.dom_string, .{ .required = true }),
    b.dictionaryField("regexp", b.dom_string, .{ .required = true }),
    b.dictionaryField("replacement", b.dom_string, .{ .required = true }),
    b.dictionaryField("type", any_record_type, .{ .required = true }),
});
const any_soa_result = b.dictionary("DNSAnySoaResult", .{
    b.dictionaryField("serial", b.uint32, .{ .required = true }),
    b.dictionaryField("refresh", b.uint32, .{ .required = true }),
    b.dictionaryField("retry", b.uint32, .{ .required = true }),
    b.dictionaryField("expire", b.uint32, .{ .required = true }),
    b.dictionaryField("minttl", b.uint32, .{ .required = true }),
    b.dictionaryField("nsname", b.dom_string, .{ .required = true }),
    b.dictionaryField("hostmaster", b.dom_string, .{ .required = true }),
    b.dictionaryField("type", any_record_type, .{ .required = true }),
});
const any_caa_result = b.dictionary("DNSAnyCaaNativeResult", .{
    b.dictionaryField("critical", b.int32, .{ .required = true }),
    b.dictionaryField("property", b.dom_string, .{ .required = true }),
    b.dictionaryField("value", b.dom_string, .{ .required = true }),
    b.dictionaryField("type", any_record_type, .{ .required = true }),
});

pub const any_result = b.unionType("DNSAnyResult", .{
    b.unionMember("address", any_address_result),
    b.unionMember("string", any_string_result),
    b.unionMember("mx", any_mx_result),
    b.unionMember("txt", any_txt_result),
    b.unionMember("srv", any_srv_result),
    b.unionMember("naptr", any_naptr_result),
    b.unionMember("soa", any_soa_result),
    b.unionMember("caa", any_caa_result),
}, .{ .ordered = true });
pub const any_results = b.sequence(any_result);

pub const resolve_result = b.unionType("DNSResolveResult", .{
    b.unionMember("addresses", address_results),
    b.unionMember("strings", string_results),
    b.unionMember("mx", mx_results),
    b.unionMember("txt", txt_results),
    b.unionMember("srv", srv_results),
    b.unionMember("naptr", naptr_results),
    b.unionMember("soa", soa_result),
    b.unionMember("caa", caa_results),
    b.unionMember("any", any_results),
}, .{ .ordered = true });

fn resolveMethod(
    comptime name: []const u8,
    comptime implementation: []const u8,
    comptime result: b.Type,
) b.ClassMember {
    return b.method(name, .{b.argument("hostname", b.dom_string, .{})}, result, .{
        .completion = archetypes.vmCompletion(.queued),
        .implementation = implementation,
        .length = 1,
    });
}

const dns_resolver_class = b.class(
    "DNSResolver",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("cancel", .{}, b.none, .{
            .implementation = "bindCancel",
            .length = 0,
        }),
        b.method("getServers", .{}, dns_types.server_strings, .{
            .implementation = "bindGetServers",
            .length = 0,
        }),
        b.method(
            "resolve",
            .{
                b.argument("name", b.dom_string, .{}),
                b.argument("record", b.optionalMatch(dns_types.record_type), .{
                    .presence = .default_value,
                    .missing = .undefined_or_null,
                    .default_value = .{ .string = "A" },
                }),
            },
            resolve_result,
            .{
                .completion = archetypes.vmCompletion(.queued),
                .implementation = "bindResolve",
                .length = 2,
            },
        ),
        resolveMethod("resolveAny", "bindResolveAny", any_results),
        resolveMethod("resolveCaa", "bindResolveCaa", caa_results),
        resolveMethod("resolveCname", "bindResolveCname", string_results),
        resolveMethod("resolveMx", "bindResolveMx", mx_results),
        resolveMethod("resolveNaptr", "bindResolveNaptr", naptr_results),
        resolveMethod("resolveNs", "bindResolveNs", string_results),
        resolveMethod("resolvePtr", "bindResolvePtr", string_results),
        resolveMethod("resolveSoa", "bindResolveSoa", soa_result),
        resolveMethod("resolveSrv", "bindResolveSrv", srv_results),
        resolveMethod("resolveTxt", "bindResolveTxt", txt_results),
        b.method("reverse", .{b.argument("ip", b.dom_string, .{})}, string_results, .{
            .completion = archetypes.vmCompletion(.queued),
            .implementation = "bindReverse",
            .length = 1,
        }),
        b.method(
            "setLocalAddress",
            .{
                b.argument("first", b.dom_string, .{}),
                b.argument("second", b.dom_string, .{ .presence = .optional, .missing = .undefined }),
            },
            b.none,
            .{
                .implementation = "bindSetLocalAddress",
                .length = 1,
            },
        ),
        b.method("setServers", .{b.argument("servers", dns_types.servers, .{})}, b.none, .{
            .implementation = "bindSetServers",
            .length = 1,
        }),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .node,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
    },
);

pub const schema = b.moduleWithClasses("DNSResolver", .{}, .{dns_resolver_class});
pub const dns_resolver = schema.class("DNSResolver");
