const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const write_body_reaction_context = b.promiseReactionContext("WriteBodyReactionContext", "write_body");

pub const schema = b.module("BlobWrite", .{
    archetypes.promiseReactionWithTypes("onBody", "blob", b.classRefByName("Blob", "Blob"), "context", write_body_reaction_context),
    archetypes.promiseReactionWithTypes("onBodyError", "errorValue", b.any, "context", write_body_reaction_context),
});
