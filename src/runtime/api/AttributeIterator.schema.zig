const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const dom_string_sequence_iterator_result = b.dictionary("DOMStringSequenceIteratorResult", .{
    b.dictionaryField("done", b.boolean, .{ .required = true }),
    b.dictionaryField("value", b.optionalUndefined(archetypes.dom_strings), .{ .required = true }),
});

const attribute_iterator_class = b.class(
    "AttributeIterator",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("iterator", .{}, archetypes.self_ref, .{
            .implementation = "getThis",
            .symbol = .iterator,
            .this_value_type = b.this_class_ref,
        }),
        b.method("next", .{}, dom_string_sequence_iterator_result, .{}),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .shared,
        .identity = .fresh,
        .fresh_identity_reason = "each attributes access creates a new iterator cursor with one wrapper",
        .reference_thread = .vm,
    },
);

pub const schema = b.moduleWithClasses("AttributeIterator", .{}, .{attribute_iterator_class});
pub const attribute_iterator = schema.class("AttributeIterator");
