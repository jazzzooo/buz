const mod_cpp_facts = @import("cpp_facts.zig");
const std = @import("std");
const ir = @import("bindgen_ir");
const normalize = @import("../normalize.zig");
const Normalizer = normalize.Normalizer;
const Error = std.mem.Allocator.Error;

pub fn signature(n: *const Normalizer, id: anytype) ?ir.CppConverterDeclaration {
    const converter = n.rawType(n.get(id).type).converted.converter;
    const types = mod_cpp_facts.Types.input(n, id);
    return .{
        .symbol = converter.name,
        .input = types.converter_input orelse return null,
        .result = types.converter_result orelse return null,
        .realm_free = converter.options.realm_free,
        .body = if (converter.brand_cast) |cast| .{ .brand_cast = .{
            .brand = n.irType(n.typeId(cast.match.*)).data.branded_value.brand.cpp_match,
            .value = if (cast.input == .boundary and cast.failure == .absent) .opaque_value else .javascript,
            .mismatch = switch (cast.failure) {
                .absent => .absent,
                .assert => .assert,
                .reject => return null,
            },
        } } else .external,
    };
}

pub fn declaration(n: *Normalizer, id: anytype) Error!ir.CppConverterDeclarationId {
    const value = signature(n, id).?;
    return .of((try n.cpp_converter_declarations.getOrPut(n.arena, value)).index);
}
