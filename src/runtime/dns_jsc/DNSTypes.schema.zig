const b = @import("bindgen_schema");

pub const record_type = b.enumerationWithOptions("DNSRecordType", .{
    b.enumerationValue("A", "A"),
    b.enumerationValue("AAAA", "AAAA"),
    b.enumerationValue("ANY", "ANY"),
    b.enumerationValue("CAA", "CAA"),
    b.enumerationValue("CNAME", "CNAME"),
    b.enumerationValue("MX", "MX"),
    b.enumerationValue("NS", "NS"),
    b.enumerationValue("PTR", "PTR"),
    b.enumerationValue("SOA", "SOA"),
    b.enumerationValue("SRV", "SRV"),
    b.enumerationValue("TXT", "TXT"),
}, .{
    .ascii_case_insensitive = true,
    .node_invalid_value = .{ .invalid_property_value = .{
        .name = "record",
        .expected = "one of: A, AAAA, ANY, CAA, CNAME, MX, NS, PTR, SOA, SRV, TXT",
        .non_string_expected_type = "string",
    } },
});

pub const server = b.dictionaryWithOptions("DNSServer", .{
    b.dictionaryField("family", b.int32, .{
        .required = true,
        .aliases = &.{"0"},
        .integer_conversion = .{ .bounded_integer = .{
            .range = .{ .min = -2147483648, .max = 2147483647 },
            .invalid = .{ .kind = .type_error, .message = "DNS server family must be an int32" },
            .out_of_range = .{ .kind = .type_error, .message = "DNS server family must be an int32" },
        } },
    }),
    b.dictionaryField("address", b.dom_string, .{ .required = true, .aliases = &.{"1"} }),
    b.dictionaryField("port", b.uint16, .{
        .default_value = .{ .unsigned = 0 },
        .aliases = &.{"2"},
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = 65535 } },
    }),
}, .{ .node_allow_array = true });

pub const servers = b.sequenceWithOptions(server, .{
    .node_error = .{
        .container = .{ .expected = "Array" },
        .element = .{ .expected = "Object" },
    },
});

pub const server_strings = b.sequence(b.utf8_string);

pub const schema = b.module("DNSTypes", .{});
