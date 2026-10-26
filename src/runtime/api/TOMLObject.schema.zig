const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const value_graph = @import("binding_schema_ValueGraph");

const stringify_date_input = b.unionType("TOMLStringifyDateInput", .{
    b.unionMember("date", b.js_date),
    b.unionMember("other", b.discarded),
}, .{ .ordered = true, .fallback_member = "other" });

const stringify_date_errors = b.domainErrors(.{
    b.domainError("invalid_date", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "TOML.stringify cannot serialize an invalid Date" },
    }),
    b.domainError("date_out_of_range", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "TOML.stringify cannot serialize a Date outside years 0000-9999" },
    }),
});

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
        .message = .{ .literal = "TOML parser produced an unsupported value" },
    }),
});

const functions = .{
    b.function(
        "stringifyDate",
        .{b.argument("value", stringify_date_input, .{})},
        b.optionalUndefined(b.byte_string),
        .{
            .backend = .zig,
            .errors = stringify_date_errors,
            .profile = .exact,
        },
    ),
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
            .builtin = "stringifyParseTOMLCodeGenerator",
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
            .builtin = "stringifyTomlCodeGenerator",
            .length = 3,
            .profile = .exact,
        },
    ),
};

pub const schema = b.module("TOMLObject", functions);
