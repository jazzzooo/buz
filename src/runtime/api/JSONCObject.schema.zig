const b = @import("bindgen_schema");
const value_graph = @import("binding_schema_ValueGraph");

const parse_errors = b.domainErrors(.{
    b.domainError("missing_input", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected a string to parse" },
    }),
    b.domainError("parse_error", b.dom_string, .{
        .class = .syntax_error,
        .message = .payload,
    }),
    b.domainError("input_too_large", b.dom_string, .{
        .class = .range_error,
        .code = "ERR_OUT_OF_RANGE",
        .message = .payload,
    }),
    b.domainError("unsupported_value", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "JSONC parser produced an unsupported value" },
    }),
});

const functions = .{
    b.function(
        "parseGraph",
        .{b.argument("input", b.dom_string, .{
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
            .builtin = "stringifyParseJSONCCodeGenerator",
            .length = 1,
            .profile = .exact,
        },
    ),
};

pub const schema = b.module("JSONCObject", functions);
