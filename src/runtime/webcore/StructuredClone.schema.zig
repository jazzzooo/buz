const b = @import("bindgen_schema");

pub const transferable_sequence = b.sequenceWithOptions(b.js_object, .{ .container = .iterable });

pub const options = b.dictionary("StructuredSerializeOptions", .{
    b.dictionaryField("transfer", transferable_sequence, .{}),
});

pub const second = b.unionType("StructuredSerializeSecond", .{
    b.unionMember("transfer", transferable_sequence),
    b.unionMember("options", options),
}, .{ .ordered = true });

pub const transfer = b.optionalNullish(second);

pub const schema = b.module("StructuredClone", .{});
