pub fn getSourceMap(
    io: std.Io,
    input: *SourceMap.SourceMapInput,
    source_filename: []const u8,
    load_hint: SourceMap.SourceMapLoadHint,
    result: SourceMap.ParseUrlResultHint,
) bun.OOM!?SourceMap.ParseUrl {
    return switch (try SourceMap.loadSourceMap(io, input, source_filename, load_hint, result)) {
        .parsed => |parsed| parsed,
        .missing => null,
        .invalid => {
            bun.jsc.SavedSourceMap.MissingSourceMapNoteInfo.seen_invalid = true;
            return null;
        },
    };
}

pub fn getSourceCode(io: std.Io, lookup: SourceMap.Mapping.Lookup, base_filename: []const u8) bun.OOM!?bun.String.Slice {
    const bytes = bytes: {
        if (lookup.prefetched_source_code) |code| break :bytes code;

        const source_map = lookup.source_map orelse return null;
        bun.assert(source_map.isExternal());

        const index = lookup.mapping.source_index;
        if (index < 0) return null;
        if (source_map.source_content == .standalone_module_graph) {
            const serialized = source_map.standaloneModuleGraphData();
            if (index >= source_map.external_source_names.len) return null;
            const contents = try serialized.sourceFileContents(io, @intCast(index)) orelse return null;
            return try bun.String.Slice.initDupe(bun.default_allocator, contents);
        }

        const input = switch (source_map.source_content) {
            .input => |value| value,
            else => return null,
        };
        if (try getSourceMap(
            io,
            input.data,
            base_filename,
            input.load_hint,
            .{ .source_only = @intCast(index) },
        )) |parsed|
            if (parsed.source_contents) |contents| break :bytes contents;

        if (index >= source_map.external_source_names.len) return null;
        const name = source_map.external_source_names[@intCast(index)];

        var buf: bun.PathBuffer = undefined;
        const normalized = bun.path.joinAbsStringBufZ(
            std.fs.path.dirname(base_filename) orelse "",
            &buf,
            &.{name},
            .auto,
        );
        break :bytes std.Io.Dir.cwd().readFileAlloc(io, normalized, bun.default_allocator, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    };

    return bun.String.Slice.init(bun.default_allocator, bytes);
}

const std = @import("std");

const bun = @import("bun");
const SourceMap = bun.SourceMap;
