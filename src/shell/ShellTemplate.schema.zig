const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const blob = @import("binding_schema_Blob");
const response = @import("binding_schema_Response");

pub const strings = archetypes.dom_strings;

const atom_kind = b.enumerationWithOptions("ShellTemplateAtomKind", .{
    b.enumerationValue("escaped_text", "escaped-text"),
    b.enumerationValue("raw_text", "raw-text"),
    b.enumerationValue("object", "object"),
    b.enumerationValue("separator", "separator"),
}, .{ .cpp_name = "ShellTemplateAtomKind" });

pub const object_value = b.unionType("ShellTemplateObjectValue", .{
    b.unionMember("buffer", b.writableBuffer(.lease)),
    b.unionMember("blob", b.classRef(blob.blob)),
    b.unionMember("response", b.classRef(response.response)),
    b.unionMember("stream", b.readable_stream),
}, .{ .ordered = true });

const atom = b.dictionaryWithOptions("ShellTemplateAtom", .{
    b.dictionaryField("kind", atom_kind, .{ .required = true }),
    b.dictionaryField("text", b.dom_string, .{ .required = true }),
    b.dictionaryField("value", b.optionalUndefined(object_value), .{ .required = true, .missing = .absent }),
}, .{ .cpp_name = "ShellTemplateAtom" });

const value = b.dictionaryWithOptions("ShellTemplateValue", .{
    b.dictionaryField("atoms", b.sequence(atom), .{ .required = true }),
}, .{ .cpp_name = "ShellTemplateValue" });

pub const values = b.sequence(value);

pub const errors = b.domainErrors(.{
    b.domainError("invalid_argument", b.dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_VALUE",
        .message = .payload,
    }),
    b.domainError("parse", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

pub const schema = b.module("ShellTemplate", .{});
