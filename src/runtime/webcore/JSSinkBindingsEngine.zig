const BindingModule = bindgen.Module("JSSink");
const StartDirectStreamSchema = BindingModule.function("startDirectStream");
const PullCallback = bindgen.Callback(StartDirectStreamSchema.args[1].ArgumentType);
const CloseCallback = bindgen.Callback(StartDirectStreamSchema.args[2].ArgumentType);

const sink_apis = .{
    .array_buffer = ArrayBufferSink.JSSink,
    .file = FileSink.JSSink,
    .http_response = streams.HTTPResponseSink.JSSink,
    .https_response = streams.HTTPSResponseSink.JSSink,
    .h3_response = streams.H3ResponseSink.JSSink,
    .network = streams.NetworkSink.JSSink,
};

fn startDirectStream(
    context: bindgen.CallContext(StartDirectStreamSchema),
    args: bindgen.Args(StartDirectStreamSchema),
) bindgen.CallError(StartDirectStreamSchema)!void {
    var on_pull: ?PullCallback = if (args.on_pull) |value|
        if (args.async_context) |async_context|
            try value.toOwnedWithExplicitAsyncContext(async_context)
        else
            try value.toOwned()
    else
        null;
    defer if (on_pull) |*callback| callback.deinit();
    var on_close: ?CloseCallback = if (args.on_close) |value|
        if (args.async_context) |async_context|
            try value.toOwnedWithExplicitAsyncContext(async_context)
        else
            try value.toOwned()
    else
        null;
    defer if (on_close) |*callback| callback.deinit();

    var readable_stream = try args.readable_stream.toWeak();
    errdefer readable_stream.deinit();

    const started = try switch (args.bindingThis) {
        .other => return context.fail(.unknown_controller, {}),
        inline else => |reference, tag| startDirectStreamFor(@field(sink_apis, @tagName(tag)), reference, &readable_stream, &on_pull, &on_close),
    };
    if (!started) return context.fail(.closed_controller, {});
}

fn startDirectStreamFor(
    comptime SinkAPI: type,
    reference: anytype,
    readable_stream: *SinkAPI.ReadableStreamHandle,
    on_pull: *?PullCallback,
    on_close: *?CloseCallback,
) bun.JSError!bool {
    return SinkAPI.startDirectStream(
        reference.get(SinkAPI.Controller),
        reference,
        readable_stream,
        on_pull,
        on_close,
    );
}

comptime {
    _ = bindgen.Fn(StartDirectStreamSchema, startDirectStream);
    for (@typeInfo(@TypeOf(sink_apis)).@"struct".field_names) |name| {
        const SinkAPI = @field(sink_apis, name);
        _ = SinkAPI.Main.Binding;
        _ = SinkAPI.Controller.Binding;
    }
}

const ArrayBufferSink = @import("./ArrayBufferSink.zig");
const FileSink = @import("./FileSink.zig");
const streams = @import("./streams.zig");

const bun = @import("bun");
const bindgen = bun.bindgen;
