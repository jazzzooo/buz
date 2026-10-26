const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub const drain_handler = b.callback(
    "ResumableSinkDrainHandler",
    .{},
    b.none,
    .{
        .receiver = null,
        .profile = .exact,
        .retains_async_context = true,
    },
);

pub const cancel_handler = b.callback(
    "ResumableSinkCancelHandler",
    .{
        b.argument("unused", b.undefined_literal, .{}),
        b.argument("reason", b.invocation_any, .{}),
    },
    b.none,
    .{
        .receiver = null,
        .profile = .exact,
        .retains_async_context = true,
    },
);

pub const start_options = b.dictionary("ResumableSinkStartOptions", .{
    b.dictionaryField("high_water_mark", b.int64, .{ .js_name = "highWaterMark" }),
});

pub const write_chunk = b.unionType("ResumableSinkWriteChunk", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("view", archetypes.copied_buffer),
}, .{ .ordered = true });

fn sinkClass(comptime name: []const u8) b.Class {
    return b.class(
        name,
        b.illegalConstructor(),
        .{
            b.method("start", .{b.argument("options", start_options, .{})}, b.none, .{}),
            b.method("write", .{b.argument("chunk", write_chunk, .{})}, b.boolean, .{}),
            b.method("end", .{b.argument("reason", b.invocation_any, .{
                .presence = .optional,
                .missing = .omitted,
            })}, b.none, .{}),
            b.method(
                "setHandlers",
                .{
                    b.argument("ondrain", drain_handler, .{}),
                    b.argument("oncancel", cancel_handler, .{}),
                },
                b.none,
                .{},
            ),
        },
        .{},
        .{
            .backend = .zig,
            .profile = .exact,
            .ownership = .shared,
            .identity = .fresh,
            .fresh_identity_reason = "each sink constructor creates a new native state with one wrapper",
            .reference_thread = .vm,
        },
    );
}

const resumable_fetch_sink_class = sinkClass("ResumableFetchSink");
const resumable_s3_upload_sink_class = sinkClass("ResumableS3UploadSink");

const engine_shims = .{
    b.engineShim(
        "assignStreamIntoFetchSink",
        .{
            b.argument("stream", b.readable_stream, .{}),
            b.argument("sink", b.classRefByName("resumable_sink", "ResumableFetchSink"), .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim(
        "assignStreamIntoS3UploadSink",
        .{
            b.argument("stream", b.readable_stream, .{}),
            b.argument("sink", b.classRefByName("resumable_sink", "ResumableS3UploadSink"), .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
};

pub const schema = b.moduleWithClassesAndEngineShims(
    "resumable_sink",
    .{},
    .{ resumable_fetch_sink_class, resumable_s3_upload_sink_class },
    engine_shims,
);
pub const resumable_fetch_sink = schema.class("ResumableFetchSink");
pub const resumable_s3_upload_sink = schema.class("ResumableS3UploadSink");
