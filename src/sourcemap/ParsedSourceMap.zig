const ParsedSourceMap = @This();

const RefCount = bun.ptr.ThreadSafeRefCount(@This(), "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

/// ParsedSourceMap can be acquired by different threads via the thread-safe
/// source map store (SavedSourceMap), so the reference count must be thread-safe.
ref_count: RefCount,
allocator: std.mem.Allocator = bun.default_allocator,

input_line_count: usize = 0,
mappings: Mapping.List = .{},
/// Standalone blobs borrow the module graph's storage; other blobs are owned
/// by this map and freed with `allocator`.
internal: ?InternalSourceMap = null,

/// If this is empty, this implies that the source code is a single file
/// transpiled on-demand. If there are items, then it means this is a file
/// loaded without transpilation but with external sources. This array
/// maps `source_index` to the correct filename.
external_source_names: []const []const u8 = &.{},
/// Input data is retained; individual source contents are decoded on demand.
source_content: SourceContent = .none,

pub const SourceContent = union(enum) {
    none,
    input: Input,
    standalone_module_graph: *bun.StandaloneModuleGraph.SerializedSourceMap.Loaded,

    pub const Input = struct {
        data: *SourceMap.SourceMapInput,
        load_hint: SourceMapLoadHint,
    };
};

pub fn isExternal(psm: *ParsedSourceMap) bool {
    return psm.external_source_names.len != 0;
}

pub fn findMapping(this: *const ParsedSourceMap, line: bun.Ordinal, column: bun.Ordinal) ?Mapping {
    if (this.internal) |ism| return ism.find(line, column);
    return this.mappings.find(line, column);
}

pub fn internalCursor(this: *const ParsedSourceMap) ?InternalSourceMap.Cursor {
    return if (this.internal) |ism| ism.cursor() else null;
}

fn deinit(this: *ParsedSourceMap) void {
    const allocator = this.allocator;

    if (this.source_content == .standalone_module_graph) {
        this.source_content.standalone_module_graph.deinit();
    } else {
        if (this.source_content == .input) this.source_content.input.data.deref();
        if (this.internal) |ism| allocator.free(@constCast(ism.data[0..ism.totalLen()]));
        if (this.external_source_names.len > 0) {
            for (this.external_source_names) |name|
                allocator.free(name);
            allocator.free(this.external_source_names);
        }
    }
    this.mappings.deinit(allocator);

    allocator.destroy(this);
}

pub fn standaloneModuleGraphData(this: *ParsedSourceMap) *bun.StandaloneModuleGraph.SerializedSourceMap.Loaded {
    return switch (this.source_content) {
        .standalone_module_graph => |data| data,
        else => @panic("source map is not backed by a standalone module graph"),
    };
}

pub fn memoryCost(this: *const ParsedSourceMap) usize {
    const mappings_cost = if (this.internal) |ism| ism.memoryCost() else this.mappings.memoryCost();
    var bytes = @sizeOf(ParsedSourceMap) + mappings_cost + this.external_source_names.len * @sizeOf([]const u8);
    for (this.external_source_names) |name| bytes += name.len;
    if (this.source_content == .input) bytes += this.source_content.input.data.memoryCost();
    return bytes;
}

pub fn writeVLQs(map: *const ParsedSourceMap, writer: anytype) !void {
    if (map.internal) |ism| {
        var buf = bun.MutableString.initEmpty(bun.default_allocator);
        defer buf.deinit();
        try ism.appendVLQTo(&buf);
        try writer.writeAll(buf.list.items);
        return;
    }
    var last_col: i32 = 0;
    var last_src: i32 = 0;
    var last_ol: i32 = 0;
    var last_oc: i32 = 0;
    var current_line: i32 = 0;
    for (
        map.mappings.generated(),
        map.mappings.original(),
        map.mappings.sourceIndex(),
        0..,
    ) |gen, orig, source_index, i| {
        if (current_line != gen.lines.zeroBased()) {
            assert(gen.lines.zeroBased() > current_line);
            const inc = gen.lines.zeroBased() - current_line;
            try writer.splatByteAll(';', @intCast(inc));
            current_line = gen.lines.zeroBased();
            last_col = 0;
        } else if (i != 0) {
            try writer.writeByte(',');
        }
        try VLQ.encode(gen.columns.zeroBased() - last_col).writeTo(writer);
        last_col = gen.columns.zeroBased();
        try VLQ.encode(source_index - last_src).writeTo(writer);
        last_src = source_index;
        try VLQ.encode(orig.lines.zeroBased() - last_ol).writeTo(writer);
        last_ol = orig.lines.zeroBased();
        try VLQ.encode(orig.columns.zeroBased() - last_oc).writeTo(writer);
        last_oc = orig.columns.zeroBased();
    }
}

const std = @import("std");

const SourceMap = @import("./sourcemap.zig");
const InternalSourceMap = SourceMap.InternalSourceMap;
const Mapping = SourceMap.Mapping;
const SourceMapLoadHint = SourceMap.SourceMapLoadHint;
const VLQ = SourceMap.VLQ;

const bun = @import("bun");
const assert = bun.assert;
