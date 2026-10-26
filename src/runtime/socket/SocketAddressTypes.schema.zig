const b = @import("bindgen_schema");

pub const family = b.enumeration("SocketAddressDTOFamily", .{
    b.enumerationValue("ipv4", "IPv4"),
    b.enumerationValue("ipv6", "IPv6"),
});

pub const dto = b.dictionary("SocketAddressDTO", .{
    b.dictionaryField("address", b.dom_string, .{ .required = true }),
    b.dictionaryField("family", family, .{ .required = true }),
    b.dictionaryField("port", b.uint16, .{ .required = true }),
});

pub const optional_dto = b.optionalUndefined(dto);
pub const nullable_dto = b.optionalNullish(dto);

const tcp_or_unix = b.unionType("TCPOrUnixServerAddress", .{
    b.unionMember("tcp", dto),
    b.unionMember("unix_path", b.dom_string),
}, .{ .ordered = true });

pub const server_address = b.optionalNullish(tcp_or_unix);

pub const schema = b.module("SocketAddressTypes", .{});
