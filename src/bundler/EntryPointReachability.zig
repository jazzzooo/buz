pub const EntryPointReachability = struct {
    matrix: DenseBitMatrix.Frozen = .empty,
    file_count: usize = 0,
    entry_point_count: usize = 0,

    pub const empty: EntryPointReachability = .{};

    pub fn deinit(self: *EntryPointReachability, allocator: std.mem.Allocator) void {
        self.matrix.deinit(allocator);
        self.* = .empty;
    }

    pub fn row(self: EntryPointReachability, source_index: usize) ConstRow {
        std.debug.assert(source_index < self.file_count);
        return self.matrix.row(source_index);
    }

    pub fn singleton(self: EntryPointReachability, entry_point_id: usize) ConstRow {
        std.debug.assert(entry_point_id < self.entry_point_count);
        return self.matrix.row(self.file_count + entry_point_id);
    }

    pub const Builder = struct {
        matrix: DenseBitMatrix = .empty,
        file_count: usize = 0,
        entry_point_count: usize = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            file_count: usize,
            entry_point_count: usize,
        ) !Builder {
            const row_count = std.math.add(usize, file_count, entry_point_count) catch return error.OutOfMemory;
            return .{
                .matrix = try .initEmpty(allocator, row_count, entry_point_count),
                .file_count = file_count,
                .entry_point_count = entry_point_count,
            };
        }

        pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
            self.matrix.deinit(allocator);
            self.* = .{};
        }

        pub fn row(self: Builder, source_index: usize) Row {
            std.debug.assert(source_index < self.file_count);
            return self.matrix.row(source_index);
        }

        pub fn finish(
            self: *Builder,
            entry_source_indices: []const u32,
            live_files: anytype,
        ) EntryPointReachability {
            std.debug.assert(entry_source_indices.len == self.entry_point_count);
            for (entry_source_indices, 0..) |source_index, entry_point_id| {
                std.debug.assert(source_index < self.file_count);
                const file_row = self.row(source_index);
                if (live_files.isSet(source_index)) std.debug.assert(file_row.isSet(entry_point_id));
                file_row.set(entry_point_id);
                self.matrix.row(self.file_count + entry_point_id).set(entry_point_id);
            }

            const result: EntryPointReachability = .{
                .matrix = self.matrix.freeze(),
                .file_count = self.file_count,
                .entry_point_count = self.entry_point_count,
            };
            self.* = .{};
            return result;
        }
    };

    pub const Row = DenseBitMatrix.Row;
    pub const ConstRow = DenseBitMatrix.ConstRow;
};

const DenseBitMatrix = @import("../collections/bit_matrix.zig").DenseBitMatrix;
const std = @import("std");
