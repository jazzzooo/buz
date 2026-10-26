const b = @import("bindgen_schema");
const blob_write = @import("binding_schema_BlobWrite");
const bun_js = @import("binding_schema_bun_js");
const bun_test = @import("binding_schema_BunTest");
const cron_job = @import("binding_schema_CronJob");
const dev_server = @import("binding_schema_DevServer");
const engine_types = @import("binding_schema_engine_types");
const file_sink = @import("binding_schema_FileSinkCallbacks");
const html_rewriter_input = @import("binding_schema_HTMLRewriterInput");
const bundler_plugin = @import("binding_schema_JSBundlerPlugin");
const node_http_response_callbacks = @import("binding_schema_NodeHTTPResponseCallbacks");
const request_context = @import("binding_schema_RequestContext");
const serve_plugins = @import("binding_schema_ServePlugins");

fn create(comptime context: b.Type) b.EngineShim {
    return b.engineShim(
        b.promiseReactionOf(context).name ++ "Create",
        .{},
        context,
        .current_realm_nonthrowing,
    );
}

fn adopt(comptime context: b.Type) b.EngineShim {
    return b.engineShim(
        b.promiseReactionOf(context).name ++ "Adopt",
        .{
            b.argument("context", context, .{}),
            b.argument("owner", b.promiseReactionOf(context).owner_reference, .{}),
        },
        b.none,
        .current_realm_unchecked,
    );
}

fn attach(comptime context: b.Type) b.EngineShim {
    return b.engineShim(
        b.promiseReactionOf(context).name ++ "Attach",
        .{
            b.argument("promise", b.js_promise, .{}),
            b.argument("context", context, .{}),
            b.argument("resolve", engine_types.host_function, .{}),
            b.argument("reject", engine_types.host_function, .{}),
        },
        b.none,
        .current_realm_throwing,
    );
}

fn take(comptime context: b.Type) b.EngineShim {
    return b.engineShim(
        b.promiseReactionOf(context).name ++ "Take",
        .{b.argument("context", context, .{})},
        b.optional(b.promiseReactionOf(context).owner_reference),
        .current_realm_unchecked,
    );
}

fn destroy(comptime context: b.Type) b.NativeExport {
    return b.nativeExport(b.promiseReactionOf(context).name ++ "Destroy", .{b.argument("owner", b.promiseReactionOf(context).owner_reference, .{})}, b.none);
}

const contexts = .{
    blob_write.write_body_reaction_context,
    html_rewriter_input.input_reaction_context,
    request_context.http_request_promise_reaction_context,
    request_context.https_request_promise_reaction_context,
    request_context.h3_request_promise_reaction_context,
    node_http_response_callbacks.node_http_response_promise_reaction_context,
    serve_plugins.serve_plugins_promise_reaction_context,
    file_sink.file_sink_promise_reaction_context,
    file_sink.file_stream_wrapper_promise_reaction_context,
    cron_job.cron_job_promise_reaction_context,
    bun_test.bun_test_promise_reaction_context,
    bun_js.entry_point_promise_reaction_context,
    dev_server.runtime_update_reaction,
    bundler_plugin.load_callback_context,
    bundler_plugin.resolve_callback_context,
};

const engine_shims = blk: {
    var result: [contexts.len * 4]b.EngineShim = undefined;
    for (contexts, 0..) |context, index| {
        result[index * 4] = create(context);
        result[index * 4 + 1] = adopt(context);
        result[index * 4 + 2] = attach(context);
        result[index * 4 + 3] = take(context);
    }
    break :blk result;
};

const native_exports = blk: {
    var result: [contexts.len]b.NativeExport = undefined;
    for (contexts, 0..) |context, index| result[index] = destroy(context);
    break :blk result;
};

pub const schema = b.moduleWithDeclarations("promise_reactions", .{}, .{}, engine_shims, native_exports);
