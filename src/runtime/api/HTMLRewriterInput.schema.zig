const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const input_reaction_context = b.promiseReactionContext("HTMLRewriterInputContext", "html_rewriter_input");

pub const schema = b.module("HTMLRewriterInput", .{
    archetypes.promiseReactionWithTypes("onInput", "blob", b.classRefByName("Blob", "Blob"), "context", input_reaction_context),
    archetypes.promiseReactionWithTypes("onInputError", "errorValue", b.any, "context", input_reaction_context),
});
