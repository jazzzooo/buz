const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const serve_plugins_promise_reaction_context = b.promiseReactionContext(
    "ServePluginsPromiseReactionContext",
    "serve_plugins",
);

const functions = .{
    archetypes.discardedPromiseReactionWithContext("onResolve", "result", "plugins", serve_plugins_promise_reaction_context),
    archetypes.engineValuePromiseReactionWithContext(
        "onReject",
        "errorValue",
        "plugins",
        serve_plugins_promise_reaction_context,
    ),
};

pub const schema = b.module("ServePlugins", functions);
