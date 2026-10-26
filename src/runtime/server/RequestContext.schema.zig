const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const response = @import("binding_schema_Response");

const response_or_ignored = b.unionType("RequestContextResponseOrIgnored", .{
    b.unionMember("response", b.classRef(response.response)),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const rejection_reason = b.optionalNullish(b.engine_value);

fn rejectionReaction(
    comptime name: []const u8,
    comptime context_name: []const u8,
    comptime context: b.Type,
) b.Function {
    return b.function(name, .{
        b.argument("result", rejection_reason, .{}),
        b.argument(context_name, context, .{}),
    }, b.none, .{
        .backend = .zig,
        .profile = .exact,
        .promise_reaction_handler = true,
    });
}

fn callbacks(comptime prefix: []const u8, comptime context: b.Type) type {
    const Result_ = struct {
        pub const declarations = .{
            archetypes.promiseReactionWithTypes(prefix ++ "OnResolve", "result", response_or_ignored, "context", context),
            archetypes.engineValuePromiseReactionWithContext(prefix ++ "OnReject", "result", "context", context),
            archetypes.discardedPromiseReactionWithContext(prefix ++ "OnResolveStream", "result", "context", context),
            rejectionReaction(prefix ++ "OnRejectStream", "context", context),
        };
    };
    return Result_;
}

pub const http_request_promise_reaction_context = b.promiseReactionContext("HTTPRequestPromiseReactionContext", "http_server_request_context");
pub const https_request_promise_reaction_context = b.promiseReactionContext("HTTPSRequestPromiseReactionContext", "https_server_request_context");
pub const h3_request_promise_reaction_context = b.promiseReactionContext("H3RequestPromiseReactionContext", "https_server_h3_request_context");

const functions = callbacks("http", http_request_promise_reaction_context).declarations ++
    callbacks("https", https_request_promise_reaction_context).declarations ++
    callbacks("h3", h3_request_promise_reaction_context).declarations;

pub const schema = b.module("RequestContext", functions);
