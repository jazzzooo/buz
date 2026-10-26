const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const functions = .{
    b.function(
        "canonicalizeIP",
        .{b.argument("address", b.dom_string, .{ .presence = .optional, .missing = .omitted })},
        archetypes.optional_dom_string,
        .{
            .backend = .zig,
            .errors = b.domainErrors(.{b.domainError("missing_address", b.none, .{
                .class = .type_error,
                .code = "ERR_INVALID_ARG_TYPE",
                .message = .{ .literal = "canonicalizeIP() expects a string but received no arguments." },
            })}),
            .length = 1,
            .profile = .webidl,
        },
    ),
};

pub const schema = b.module("CanonicalizeIP", functions);
