const b = @import("bindgen_schema");
const blob_types = @import("binding_schema_BlobTypes");
const console_object = @import("binding_schema_ConsoleObject");

const build_artifact_ref = b.classRefByName("BuildArtifact", "BuildArtifact");
const optional_build_artifact_ref = b.optional(build_artifact_ref);
const optional_readable_stream = b.optionalUndefined(b.readable_stream);
const stream_result = b.dictionary("BuildArtifactStreamResult", .{
    b.dictionaryField("stream", b.readable_stream, .{ .required = true }),
    b.dictionaryField("cache", b.boolean, .{ .required = true }),
});

const build_artifact_class = b.class(
    "BuildArtifact",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("arrayBuffer", .{}, b.promise(b.js_array_buffer_object), .{
            .backend = .builtin,
            .builtin = "buildArtifactArrayBufferCodeGenerator",
            .length = 0,
        }),
        b.method("blobValue", .{}, b.classRefByName("Blob", "Blob"), .{
            .implementation = "getBlobValue",
            .length = 0,
            .private_symbol = "blobValue",
        }),
        b.getter("hash", b.dom_string, .{ .implementation = "getHash", .cache = "hash" }),
        b.method("json", .{}, b.promise(b.any), .{
            .backend = .builtin,
            .builtin = "buildArtifactJsonCodeGenerator",
            .length = 0,
        }),
        b.getter("kind", b.dom_string, .{ .implementation = "getOutputKind", .cache = "kind" }),
        b.getter("loader", b.dom_string, .{ .implementation = "getLoader", .cache = "loader" }),
        b.getter("path", b.dom_string, .{ .implementation = "getPath", .cache = "path" }),
        b.getter("size", blob_types.size, .{ .implementation = "getSize" }),
        b.method(
            "slice",
            blob_types.slice_arguments,
            b.classRefByName("Blob", "Blob"),
            .{ .implementation = "getSlice", .length = 2 },
        ),
        b.getter("sourcemap", optional_build_artifact_ref, .{ .implementation = "getSourceMap", .cache = "sourcemap" }),
        b.method(
            "streamNative",
            .{blob_types.streamChunkSize("chunkSize")},
            stream_result,
            .{
                .implementation = "getStreamNative",
                .length = 1,
                .private_symbol = "streamNative",
            },
        ),
        b.method(
            "stream",
            .{blob_types.streamChunkSize("chunkSize")},
            b.readable_stream,
            .{ .backend = .builtin, .builtin = "buildArtifactStreamCodeGenerator", .length = 1 },
        ),
        b.method("text", .{}, b.promise(b.dom_string), .{
            .backend = .builtin,
            .builtin = "buildArtifactTextCodeGenerator",
            .length = 0,
        }),
        b.getter("type", b.dom_string, .{ .implementation = "getMimeType", .cache = "type" }),
        console_object.native_inspect,
    },
    .{
        b.cachedSlot("hash", b.dom_string, .{}),
        b.cachedSlot("kind", b.dom_string, .{}),
        b.cachedSlot("loader", b.dom_string, .{}),
        b.cachedSlot("path", b.dom_string, .{}),
        b.cachedSlot("sourcemap", optional_build_artifact_ref, .{ .writable = true, .exposed = false }),
        b.cachedSlot("stream", optional_readable_stream, .{ .writable = true, .private_symbol = "streamCache" }),
        b.cachedSlot("type", b.dom_string, .{}),
    },
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .any,
    },
);

pub const schema = b.moduleWithClasses("BuildArtifact", .{}, .{build_artifact_class});
pub const build_artifact = schema.class("BuildArtifact");
