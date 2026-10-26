const b = @import("bindgen_schema");

pub const node_http_response_promise_reaction_context = b.promiseReactionContext(
    "NodeHTTPResponsePromiseReactionContext",
    "node_http_response",
);

const functions = .{
    b.function(
        "onResolve",
        .{
            b.argument("result", b.discardAny(.ignored), .{}),
            b.argument("context", node_http_response_promise_reaction_context, .{}),
        },
        b.none,
        .{
            .backend = .zig,
            .profile = .exact,
            .promise_reaction_handler = true,
        },
    ),
    b.function(
        "onReject",
        .{
            b.argument("errorValue", b.engine_value, .{}),
            b.argument("context", node_http_response_promise_reaction_context, .{}),
        },
        b.none,
        .{
            .backend = .zig,
            .profile = .exact,
            .promise_reaction_handler = true,
        },
    ),
};

pub const schema = b.module("NodeHTTPResponseCallbacks", functions);
