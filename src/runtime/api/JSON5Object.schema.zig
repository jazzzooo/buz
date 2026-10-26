const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const blob_types = @import("binding_schema_BlobTypes");
const value_graph = @import("binding_schema_ValueGraph");

const parse_errors = b.domainErrors(.{
    b.domainError("missing_input", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected a string to parse" },
    }),
    b.domainError("input_too_large", b.dom_string, .{
        .class = .range_error,
        .code = "ERR_OUT_OF_RANGE",
        .message = .payload,
    }),
    b.domainError("parse_error", b.dom_string, .{
        .class = .syntax_error,
        .message = .payload,
    }),
    b.domainError("unsupported_value", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "JSON5 parser produced an unsupported value" },
    }),
});

const functions = .{
    b.function(
        "parseGraph",
        .{b.argument("input", blob_types.or_string_or_buffer, .{
            .presence = .optional,
            .missing = .undefined_or_null,
        })},
        value_graph.parsed,
        .{
            .backend = .zig,
            .errors = parse_errors,
            .length = 1,
            .profile = .webidl,
        },
    ),
    b.function(
        "parse",
        .{b.argument("input", b.any, .{ .presence = .optional, .missing = .omitted })},
        b.any,
        .{
            .backend = .builtin,
            .builtin = "stringifyParseJSON5CodeGenerator",
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "stringify",
        .{
            b.argument("value", b.any, .{ .presence = .optional, .missing = .omitted }),
            b.argument("replacer", b.any, .{ .presence = .optional, .missing = .omitted }),
            b.argument("space", b.any, .{ .presence = .optional, .missing = .omitted }),
        },
        archetypes.optional_dom_string,
        .{
            .backend = .builtin,
            .builtin = "stringifyJson5CodeGenerator",
            .length = 3,
            .profile = .exact,
        },
    ),
};

pub const schema = b.module("JSON5Object", functions);
