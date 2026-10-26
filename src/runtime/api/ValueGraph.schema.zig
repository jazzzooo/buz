const b = @import("bindgen_schema");

pub const node_kind = b.enumeration("ValueGraphNodeKind", .{
    b.enumerationValue("undefined", "undefined"),
    b.enumerationValue("nulled", "nulled"),
    b.enumerationValue("number", "number"),
    b.enumerationValue("boolean", "boolean"),
    b.enumerationValue("string", "string"),
    b.enumerationValue("array", "array"),
    b.enumerationValue("object", "object"),
});

const node = b.dictionary("ValueGraphNode", .{
    b.dictionaryField("kind", node_kind, .{ .required = true }),
    b.dictionaryField("number", b.double, .{ .required = true }),
    b.dictionaryField("boolean", b.boolean, .{ .required = true }),
    b.dictionaryField("text", b.dom_string, .{ .required = true }),
    b.dictionaryField("edge_start", b.uint32, .{ .required = true, .js_name = "edgeStart" }),
    b.dictionaryField("edge_count", b.uint32, .{ .required = true, .js_name = "edgeCount" }),
});

pub const nodes = b.sequence(node);

const parsed_edge = b.dictionary("ParsedValueGraphEdge", .{
    b.dictionaryField("key", b.uint32, .{ .required = true }),
    b.dictionaryField("target", b.uint32, .{ .required = true }),
});

pub const parsed_edges = b.sequence(parsed_edge);
pub const parsed = b.dictionary("ParsedValueGraph", .{
    b.dictionaryField("nodes", nodes, .{ .required = true }),
    b.dictionaryField("edges", parsed_edges, .{ .required = true }),
    b.dictionaryField("root", b.uint32, .{ .required = true }),
});

pub const schema = b.module("ValueGraph", .{});
