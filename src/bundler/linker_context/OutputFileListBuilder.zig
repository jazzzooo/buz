//! Chunk slots retain chunk indices; supplementary and asset outputs follow them.
//! Reserved capacity is an estimate, while list entries represent owned outputs.
pub const OutputFileList = @This();

output_files: std.array_list.Managed(options.OutputFile),
index_for_chunk: u32 = 0,
chunk_count: u32,
additional_started: bool = false,

pub fn init(
    allocator: std.mem.Allocator,
    c: *const bun.bundle_v2.LinkerContext,
    chunks: []const bun.bundle_v2.Chunk,
) !@This() {
    const length = try OutputFileList.calculateOutputFileListCapacity(c, chunks);
    const chunk_count = std.math.cast(u32, chunks.len) orelse return error.OutOfMemory;
    var output_files = try std.array_list.Managed(options.OutputFile).initCapacity(
        allocator,
        length,
    );
    output_files.appendNTimesAssumeCapacity(OutputFile.zero_value, chunks.len);

    return .{
        .output_files = output_files,
        .chunk_count = chunk_count,
    };
}

pub fn take(this: *@This()) std.array_list.Managed(options.OutputFile) {
    bun.assert(this.index_for_chunk == this.chunk_count);
    const list = this.output_files;
    this.output_files = .init(list.allocator);
    this.chunk_count = 0;
    this.index_for_chunk = 0;
    this.additional_started = false;
    return list;
}

pub fn deinit(this: *OutputFileList) void {
    for (this.output_files.items) |*file| file.deinit();
    this.output_files.clearAndFree();
}

pub fn calculateOutputFileListCapacity(c: *const bun.bundle_v2.LinkerContext, chunks: []const bun.bundle_v2.Chunk) bun.OOM!u32 {
    const source_map_count = if (c.options.source_maps.hasExternalFiles()) brk: {
        var count: usize = 0;
        for (chunks) |*chunk| {
            if (chunk.content.sourcemap(c.options.source_maps).hasExternalFiles()) {
                count += 1;
            }
        }
        break :brk count;
    } else 0;
    const bytecode_count = if (c.options.generate_bytecode_cache) bytecode_count: {
        var bytecode_count: usize = 0;
        for (chunks) |*chunk| {
            const loader: bun.options.Loader = if (chunk.entry_point.is_entry_point)
                c.parse_graph.input_files.items(.loader)[
                    chunk.entry_point.source_index
                ]
            else
                .js;

            if (chunk.content == .javascript and loader.isJavaScriptLike()) {
                bytecode_count += 1;
            }
        }
        break :bytecode_count bytecode_count;
    } else 0;

    // module_info is generated for ESM bytecode in --compile builds
    const module_info_count = if (c.options.generate_bytecode_cache and c.options.output_format == .esm and c.options.compile) bytecode_count else 0;

    const additional_output_files_count = if (c.options.compile_to_standalone_html) 0 else c.parse_graph.additional_output_files.items.len;
    var length = chunks.len;
    for ([_]usize{ source_map_count, bytecode_count, module_info_count, additional_output_files_count }) |count| {
        length = std.math.add(usize, length, count) catch return error.OutOfMemory;
    }
    return std.math.cast(u32, length) orelse error.OutOfMemory;
}

pub fn insertForChunk(this: *OutputFileList, output_file: options.OutputFile) u32 {
    bun.assert(!this.additional_started);
    const index = this.index_for_chunk;
    bun.assert(index < this.chunk_count);
    this.index_for_chunk += 1;
    this.output_files.items[index] = output_file;
    return index;
}

pub fn insertForSourcemapOrBytecode(this: *OutputFileList, output_file: *options.OutputFile) bun.OOM!u32 {
    bun.assert(!this.additional_started);
    const index = this.output_files.items.len;
    try this.ensureUnusedCapacity(1);
    this.output_files.appendAssumeCapacity(output_file.take());
    return @intCast(index);
}

pub fn insertAdditionalOutputFiles(this: *OutputFileList, additional_output_files: []options.OutputFile) bun.OOM!void {
    bun.assert(this.index_for_chunk == this.chunk_count);
    try this.ensureUnusedCapacity(additional_output_files.len);
    this.additional_started = true;
    for (additional_output_files) |*file| this.output_files.appendAssumeCapacity(file.take());
}

fn ensureUnusedCapacity(this: *OutputFileList, count: usize) bun.OOM!void {
    const length = std.math.add(usize, this.output_files.items.len, count) catch return error.OutOfMemory;
    if (length > std.math.maxInt(u32)) return error.OutOfMemory;
    try this.output_files.ensureUnusedCapacity(count);
}

const bun = @import("bun");
const std = @import("std");

const options = bun.options;
const OutputFile = options.OutputFile;
