pub const FileKind = enum(u2) {
    /// Missing files and files that failed to bundle remain in the graph as unknown.
    unknown,
    js,
    /// JavaScript source exporting one emitted asset path.
    asset,
    /// JavaScript source containing the public URL of an emitted stylesheet.
    css,
};

pub const ClientFileIndex = bun.GenericIndex(u30, opaque {});
pub const ServerFileIndex = bun.GenericIndex(u30, opaque {});

pub fn FileIndex(comptime side: BakeCore.Side) type {
    return switch (side) {
        .client => ClientFileIndex,
        .server => ServerFileIndex,
    };
}

pub const GraphTraceState = struct {
    allocator: Allocator,
    client_bits: std.bit_set.Dynamic,
    server_bits: std.bit_set.Dynamic,
    failed_files: std.ArrayListUnmanaged(FailedFile) = .empty,

    pub const FailedFile = union(enum) {
        client: ClientFileIndex,
        server: ServerFileIndex,
    };

    pub fn bits(state: *GraphTraceState, side: BakeCore.Side) *std.bit_set.Dynamic {
        return switch (side) {
            .client => &state.client_bits,
            .server => &state.server_bits,
        };
    }

    pub fn deinit(state: *GraphTraceState, allocator: Allocator) void {
        state.client_bits.deinit(allocator);
        state.server_bits.deinit(allocator);
        state.failed_files.deinit(allocator);
    }

    pub fn clear(state: *GraphTraceState) void {
        state.server_bits.unsetAll();
        state.client_bits.unsetAll();
        state.failed_files.clearRetainingCapacity();
    }

    pub fn resize(state: *GraphTraceState, side: BakeCore.Side, allocator: Allocator, new_size: usize) !void {
        const target_bits = state.bits(side);
        if (target_bits.capacity() < new_size) {
            try target_bits.resize(allocator, new_size, false);
        }
    }

    pub fn clearAndFree(state: *GraphTraceState, allocator: Allocator) void {
        state.client_bits.resize(allocator, 0, false) catch unreachable;
        state.server_bits.resize(allocator, 0, false) catch unreachable;
        state.failed_files.deinit(allocator);
        state.failed_files = .empty;
    }
};

pub const TraceImportGoal = enum {
    find_css,
    find_client_modules,
    find_errors,
};

pub const ChunkKind = enum(u1) {
    initial_response,
    hmr_chunk,
};

pub const EntryPointList = struct {
    set: bun.StringArrayHashMap(Flags),

    pub const empty: EntryPointList = .{ .set = .{} };

    pub const Flags = packed struct(u8) {
        client: bool = false,
        server: bool = false,
        ssr: bool = false,
        /// CSS entry points always belong to the client graph too.
        css: bool = false,
        unused: enum(u4) { unused = 0 } = .unused,
    };

    pub fn deinit(entry_points: *EntryPointList, allocator: Allocator) void {
        entry_points.set.deinit(allocator);
    }

    pub fn appendJs(
        entry_points: *EntryPointList,
        allocator: Allocator,
        absolute_path: []const u8,
        graph: BakeCore.Graph,
    ) !void {
        return entry_points.append(allocator, absolute_path, switch (graph) {
            .server => .{ .server = true },
            .client => .{ .client = true },
            .ssr => .{ .ssr = true },
        });
    }

    pub fn appendCss(entry_points: *EntryPointList, allocator: Allocator, absolute_path: []const u8) !void {
        return entry_points.append(allocator, absolute_path, .{
            .client = true,
            .css = true,
        });
    }

    pub fn append(entry_points: *EntryPointList, allocator: Allocator, absolute_path: []const u8, flags: Flags) !void {
        const entry = try entry_points.set.getOrPut(allocator, absolute_path);
        if (entry.found_existing) {
            const Int = @typeInfo(Flags).@"struct".backing_integer.?;
            entry.value_ptr.* = @bitCast(@as(Int, @bitCast(entry.value_ptr.*)) | @as(Int, @bitCast(flags)));
        } else {
            entry.value_ptr.* = flags;
        }
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;

const bun = @import("bun");
const BakeCore = @import("./BakeCore.zig");
