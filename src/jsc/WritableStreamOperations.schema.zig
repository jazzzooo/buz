const b = @import("bindgen_schema");
const streams = @import("binding_schema_WebCoreStreams");

fn builtin(comptime name: []const u8, comptime generator: []const u8, comptime arguments: anytype, comptime result: b.Type) b.Function {
    return b.function(name, arguments, result, .{
        .backend = .builtin,
        .builtin = generator,
        .profile = .exact,
    });
}

pub const schema = b.module("WritableStreamOperations", .{
    builtin("create", "writableStreamInternalsCreateInternalWritableStreamFromUnderlyingSinkCodeGenerator", .{
        b.argument("underlyingSink", b.optionalUndefined(b.js_object), .{}),
        b.argument("typePresent", b.boolean, .{}),
        b.argument("start", b.optionalUndefined(streams.writable_sink_start), .{}),
        b.argument("write", b.optionalUndefined(streams.writable_sink_write), .{}),
        b.argument("close", b.optionalUndefined(streams.writable_sink_close), .{}),
        b.argument("abort", b.optionalUndefined(streams.writable_sink_abort), .{}),
        b.argument("highWaterMark", b.double, .{}),
        b.argument("size", b.optionalUndefined(streams.writable_strategy_size), .{}),
    }, b.js_object),
    builtin("abort", "writableStreamInternalsWritableStreamAbortForBindingsCodeGenerator", .{
        b.argument("stream", b.js_object, .{}),
        b.argument("reason", b.any, .{ .presence = .optional, .missing = .undefined }),
    }, b.js_promise),
    builtin("close", "writableStreamInternalsWritableStreamCloseForBindingsCodeGenerator", .{
        b.argument("stream", b.js_object, .{}),
    }, b.js_promise),
    builtin("getWriter", "writableStreamInternalsAcquireWritableStreamDefaultWriterCodeGenerator", .{
        b.argument("stream", b.js_object, .{}),
    }, b.classValue(streams.writable_stream_default_writer)),
});
