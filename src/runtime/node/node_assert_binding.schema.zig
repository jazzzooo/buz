const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const diff_value = b.unionType("NodeAssertDiffValue", .{
    b.unionMember("code_unit", b.uint16),
    b.unionMember("text", b.dom_string),
}, .{ .ordered = true });

const diff_entry = b.dictionary("NodeAssertDiffEntry", .{
    b.dictionaryField("kind", b.uint8, .{ .required = true }),
    b.dictionaryField("value", diff_value, .{ .required = true }),
});

const functions = .{
    b.function(
        "myersDiff",
        .{
            b.argument("actual", b.dom_string, .{}),
            b.argument("expected", b.dom_string, .{}),
            archetypes.truthyBoolean("checkCommaDisparity", .{ .presence = .optional, .missing = .undefined }),
            archetypes.truthyBoolean("lines", .{ .presence = .optional, .missing = .undefined }),
        },
        b.sequence(diff_entry),
        .{
            .backend = .zig,
            .errors = b.domainErrors(.{
                b.domainError("diff_too_large", b.none, .{
                    .class = .type_error,
                    .code = "ERR_INVALID_ARG_TYPE",
                    .message = .{ .literal = "Diffing these two values would create a string that is too large. If this was intentional, please open a bug report on GitHub." },
                }),
                b.domainError("inputs_too_large", b.none, .{
                    .class = .type_error,
                    .code = "ERR_INVALID_ARG_TYPE",
                    .message = .{ .literal = "Input strings are too large to diff. Please open a bug report on GitHub." },
                }),
            }),
            .length = 2,
            .missing_required_arguments = .arity_error,
            .profile = .node,
        },
    ),
};

pub const schema = b.module("node_assert_binding", functions);
