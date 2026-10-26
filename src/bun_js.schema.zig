const b = @import("bindgen_schema");

pub const entry_point_promise_reaction_context = b.promiseReactionContext(
    "EntryPointPromiseReactionContext",
    "entry_point_print",
);

const functions = .{
    b.function(
        "onResolveEntryPointResult",
        .{
            b.argument("result", b.engine_value, .{}),
            b.argument("context", entry_point_promise_reaction_context, .{}),
        },
        b.none,
        .{
            .backend = .zig,
            .profile = .exact,
            .promise_reaction_handler = true,
        },
    ),
    b.function(
        "onRejectEntryPointResult",
        .{
            b.argument("result", b.engine_value, .{}),
            b.argument("context", entry_point_promise_reaction_context, .{}),
        },
        b.none,
        .{
            .backend = .zig,
            .profile = .exact,
            .promise_reaction_handler = true,
        },
    ),
};

pub const schema = b.module("BunJS", functions);
