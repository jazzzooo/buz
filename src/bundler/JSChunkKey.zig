pub const JSChunkKey = union(enum) {
    code_splitting: ConstRow,
    entry_point: u32,

    pub fn forCodeSplitting(entry_bits: ConstRow) JSChunkKey {
        return .{ .code_splitting = entry_bits };
    }

    pub fn forEntry(entry_point_id: u32) JSChunkKey {
        return .{ .entry_point = entry_point_id };
    }

    pub fn canonicalOrder(a: JSChunkKey, b: JSChunkKey) std.math.Order {
        return switch (a) {
            .code_splitting => |a_entry_bits| switch (b) {
                .code_splitting => |b_entry_bits| a_entry_bits.canonicalOrder(b_entry_bits),
                .entry_point => .lt,
            },
            .entry_point => |a_entry_point_id| switch (b) {
                .code_splitting => .gt,
                .entry_point => |b_entry_point_id| std.math.order(a_entry_point_id, b_entry_point_id),
            },
        };
    }

    pub const Context = struct {
        pub fn hash(_: Context, key: JSChunkKey) u32 {
            return switch (key) {
                .code_splitting => |entry_bits| @truncate(entry_bits.hash(0)),
                .entry_point => |entry_point_id| @truncate(std.hash.Wyhash.hash(1, std.mem.asBytes(&entry_point_id))),
            };
        }

        pub fn eql(_: Context, a: JSChunkKey, b: JSChunkKey, _: usize) bool {
            return switch (a) {
                .code_splitting => |a_entry_bits| switch (b) {
                    .code_splitting => |b_entry_bits| a_entry_bits.eql(b_entry_bits),
                    .entry_point => false,
                },
                .entry_point => |a_entry_point_id| switch (b) {
                    .code_splitting => false,
                    .entry_point => |b_entry_point_id| a_entry_point_id == b_entry_point_id,
                },
            };
        }
    };
};

const DenseBitMatrix = @import("../collections/bit_matrix.zig").DenseBitMatrix;
const ConstRow = DenseBitMatrix.ConstRow;
const std = @import("std");
