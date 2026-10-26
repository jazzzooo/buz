pub fn postProcessHTMLChunk(ctx: GenerateChunkCtx, worker: *Executor.Worker, chunk: *Chunk) !void {
    // This is where we split output into pieces
    const c = ctx.c;
    var j = StringJoiner{
        .allocator = worker.allocator,
    };
    defer j.deinit();

    const compile_results = chunk.compile_results_for_chunk;

    for (compile_results) |*compile_result| {
        try j.push(compile_result.takeCode(), bun.default_allocator);
    }

    try j.ensureNewlineAtEnd();

    chunk.intermediate_output = try c.breakOutputIntoPieces(
        worker.allocator,
        &j,
        std.math.cast(u32, ctx.chunks.len) orelse return error.OutOfMemory,
    );

    chunk.isolated_hash = c.generateIsolatedHash(chunk);
}

const bun = @import("bun");
const std = @import("std");
const StringJoiner = bun.StringJoiner;

const Chunk = bun.bundle_v2.Chunk;
const Executor = bun.bundle_v2.Executor;

const LinkerContext = bun.bundle_v2.LinkerContext;
const GenerateChunkCtx = bun.bundle_v2.LinkerContext.GenerateChunkCtx;
