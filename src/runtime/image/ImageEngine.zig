//! VM-thread scheduling endpoint for the native image pipeline.

pub fn schedule(
    image: *Image,
    comptime FunctionSchema: type,
    context: bindgen.CallContext(FunctionSchema),
    wrapper: bindgen.ClassRef(Image.ImageClassSchema),
    source_input: Image.SourceBufferInput,
    kind: Image.PipelineKind,
    destination_value: ?Image.OwnedWriteDestination,
) bindgen.CallError(FunctionSchema)!void {
    comptime requireAsyncPipelineContext(@TypeOf(context));
    const global = context.viewToken().globalObject();
    var owned_wrapper = wrapper;
    var destination = destination_value;
    defer {
        owned_wrapper.deinit();
        if (destination) |*value| value.deinit();
    }

    const input: ?bindgen.ScopedLease(u8) = if (source_input) |source| switch (source) {
        .buffer => |lease| lease,
        .wasm => null,
        .detached => {
            var completion = context.completion();
            completion.fail(.detached_source, {});
            return;
        },
    } else null;
    var snapshot: ?bindgen.OwnedBytes = if (source_input != null and source_input.? == .wasm)
        try context.engineIn("Image", "copyInput").call(.{ .image = try owned_wrapper.view(context) })
    else
        null;
    defer if (snapshot) |*bytes| bytes.deinit();
    const input_bytes: ?[]const u8 = if (input) |lease|
        lease.unsafePtr("The terminal entry frame holds the source lease throughout header probing and worker snapshot creation")
    else if (snapshot) |*bytes|
        bytes.slice()
    else
        null;

    const Pipeline = Image.AsyncPipeline(FunctionSchema);
    const background_tasks = &global.bunVM().background_tasks;
    if (kind == .metadata) {
        if (image.initialMetadataResult(input_bytes)) |result| {
            return Pipeline.start(
                image,
                background_tasks,
                context,
                owned_wrapper.take(),
                .none,
                null,
                kind,
                if (destination) |*value| value.take() else null,
                result,
                false,
            );
        }
    }

    if (image.source == .blob) {
        const prepared = try Pipeline.prepareBlobRead(
            image,
            background_tasks,
            context,
            owned_wrapper.take(),
            kind,
            if (destination) |*value| value.take() else null,
        );
        prepared.blob.readBytesToHandler(Pipeline.BlobReadChain, prepared.chain, global) catch |err| {
            prepared.abort();
            return err;
        };
        return;
    }

    // The lease preserves source attachment until completion; workers read an independent snapshot.
    var input_lease: ?bindgen.OwnedLease(u8) = if (input) |lease| try lease.toOwned() else null;
    errdefer if (input_lease) |*lease| lease.deinit();
    const pipeline_input = try image.copyInputForTask(input_bytes);
    const transferred_lease = if (input_lease) |*lease| lease.take() else null;
    input_lease = null;
    return Pipeline.start(
        image,
        background_tasks,
        context,
        owned_wrapper.take(),
        pipeline_input,
        transferred_lease,
        kind,
        if (destination) |*value| value.take() else null,
        null,
        false,
    );
}

fn requireAsyncPipelineContext(comptime Context: type) void {
    const implementation = bindgen.ContextImplementationName(Context);
    inline for (Image.async_pipeline_schemas) |Schema| {
        if (std.mem.eql(u8, implementation, Schema.implementation)) return;
    }
    @compileError("startImagePipeline requires an async Image terminal context");
}

const std = @import("std");

const bun = @import("bun");
const bindgen = bun.bindgen;
const jsc = bun.jsc;

const Image = @import("./Image.zig");
