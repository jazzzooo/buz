const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const functions = .{
    b.function("getBundled", .{}, archetypes.dom_strings, .{ .backend = .cpp, .length = 1, .profile = .exact }),
    b.function("getExtra", .{}, archetypes.dom_strings, .{ .backend = .cpp, .length = 1, .profile = .exact }),
    b.function("getSystem", .{}, archetypes.dom_strings, .{ .backend = .cpp, .length = 1, .profile = .exact }),
};

pub const schema = b.module("TLSCertificates", functions);
