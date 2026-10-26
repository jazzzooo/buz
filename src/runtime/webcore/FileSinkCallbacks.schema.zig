const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const file_sink_promise_reaction_context = b.promiseReactionContext("FileSinkPromiseReactionContext", "file_sink");
pub const file_stream_wrapper_promise_reaction_context = b.promiseReactionContext("FileStreamWrapperPromiseReactionContext", "file_stream_wrapper");

const functions = .{
    archetypes.discardedPromiseReactionWithContext("onResolveStream", "result", "context", file_sink_promise_reaction_context),
    archetypes.discardedPromiseReactionWithContext("onRejectStream", "errorValue", "context", file_sink_promise_reaction_context),
    archetypes.discardedPromiseReactionWithContext(
        "onResolveRequestStream",
        "result",
        "context",
        file_stream_wrapper_promise_reaction_context,
    ),
    archetypes.promiseReactionWithTypes(
        "onRejectRequestStream",
        "errorValue",
        b.any,
        "context",
        file_stream_wrapper_promise_reaction_context,
    ),
};

pub const schema = b.module("FileSink", functions);
