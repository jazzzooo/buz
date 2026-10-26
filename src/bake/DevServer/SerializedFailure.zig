//! Owned serialized HMR errors keyed by their route or incremental-graph source.

pub fn WithTypes(
    comptime ClientFileIndex: type,
    comptime ServerFileIndex: type,
    comptime RouteBundleIndex: type,
) type {
    return struct {
        const SerializedFailure = @This();

        /// The first 32 bits encode the owner; the remaining bytes use the HMR error format.
        data: []u8,

        pub fn deinit(f: SerializedFailure, allocator: std.mem.Allocator) void {
            allocator.free(f.data);
        }

        /// The metaphorical owner of an incremental file error. The packed variant
        /// is given to the HMR runtime as an opaque handle.
        pub const Owner = union(enum) {
            none,
            route: RouteBundleIndex,
            client: ClientFileIndex,
            server: ServerFileIndex,

            pub fn encode(owner: Owner) Packed {
                return switch (owner) {
                    .none => .{ .kind = .none, .data = 0 },
                    .client => |data| .{ .kind = .client, .data = data.get() },
                    .server => |data| .{ .kind = .server, .data = data.get() },
                    .route => |data| .{ .kind = .route, .data = data.get() },
                };
            }

            pub const Packed = packed struct(u32) {
                data: u30,
                kind: enum(u2) { none, route, client, server },

                pub fn decode(owner: Packed) Owner {
                    return switch (owner.kind) {
                        .none => .none,
                        .client => .{ .client = ClientFileIndex.init(owner.data) },
                        .server => .{ .server = ServerFileIndex.init(owner.data) },
                        .route => .{ .route = RouteBundleIndex.init(owner.data) },
                    };
                }

                comptime {
                    assert(@as(u32, @bitCast(Packed{ .kind = .none, .data = 1 })) == 1);
                }
            };
        };

        pub fn getOwner(failure: SerializedFailure) Owner {
            return std.mem.bytesAsValue(Owner.Packed, failure.data[0..4]).decode();
        }

        /// This assumes the hash map contains only one SerializedFailure per owner.
        /// This is okay since SerializedFailure can contain more than one error.
        pub const ArrayHashContextViaOwner = struct {
            pub fn hash(_: ArrayHashContextViaOwner, k: SerializedFailure) u32 {
                return std.hash.int(@as(u32, @bitCast(k.getOwner().encode())));
            }

            pub fn eql(_: ArrayHashContextViaOwner, a: SerializedFailure, b: SerializedFailure, _: usize) bool {
                return @as(u32, @bitCast(a.getOwner().encode())) == @as(u32, @bitCast(b.getOwner().encode()));
            }
        };

        pub const ArrayHashAdapter = struct {
            pub fn hash(_: ArrayHashAdapter, own: Owner) u32 {
                return std.hash.int(@as(u32, @bitCast(own.encode())));
            }

            pub fn eql(_: ArrayHashAdapter, a: Owner, b: SerializedFailure, _: usize) bool {
                return @as(u32, @bitCast(a.encode())) == @as(u32, @bitCast(b.getOwner().encode()));
            }
        };

        pub const ErrorKind = enum(u8) {
            // A log message. The `logger.Kind` is encoded here.
            bundler_log_err = 0,
            bundler_log_warn = 1,
            bundler_log_note = 2,
            bundler_log_debug = 3,
            bundler_log_verbose = 4,

            /// new Error(message)
            js_error,
            /// new TypeError(message)
            js_error_type,
            /// new RangeError(message)
            js_error_range,
            /// Other forms of `Error` objects, including when an error has a
            /// `code`, and other fields.
            js_error_extra,
            /// Non-error with a stack trace
            js_primitive_exception,
            /// Non-error JS values
            js_primitive,
            /// new AggregateError(errors, message)
            js_aggregate,
        };

        pub fn initFromLog(
            allocator: std.mem.Allocator,
            owner: Owner,
            // for .client and .server, these are meant to be relative file paths
            owner_display_name: []const u8,
            messages: []const bun.logger.Msg,
        ) bun.OOM!SerializedFailure {
            assert(messages.len > 0);

            // Avoid small re-allocations without requesting so much from the heap
            var sfb_buffer: [65536]u8 = undefined;
            var sfb: std.heap.BufferFirstAllocator = .init(&sfb_buffer, allocator);
            var payload = std.array_list.Managed(u8).initCapacity(sfb.allocator(), 65536) catch
                unreachable; // enough space
            defer payload.deinit();
            var payload_writer = bun.ManagedWriter.init(&payload);
            const w = payload_writer.writer();

            w.writeInt(u32, @bitCast(owner.encode()), .little) catch return error.OutOfMemory;

            try writeString32(owner_display_name, w);

            w.writeInt(u32, @intCast(messages.len), .little) catch return error.OutOfMemory;

            for (messages) |*msg| {
                try writeLogMsg(msg, w);
            }
            payload_writer.finish();

            if (payload.items.ptr == sfb_buffer[0..].ptr) {
                return .{ .data = try allocator.dupe(u8, payload.items) };
            }
            var owned: std.array_list.Managed(u8) = .{
                .items = payload.items,
                .capacity = payload.capacity,
                .allocator = allocator,
            };
            payload = .init(sfb.allocator());
            defer owned.deinit();
            return .{ .data = try owned.toOwnedSlice() };
        }

        // All "write" functions get a corresponding "read" function in ./client/error.ts

        const Writer = *std.Io.Writer;

        fn writeLogMsg(msg: *const bun.logger.Msg, w: Writer) bun.OOM!void {
            w.writeByte(switch (msg.kind) {
                inline else => |k| @backingInt(@field(ErrorKind, "bundler_log_" ++ @tagName(k))),
            }) catch return error.OutOfMemory;
            try writeLogData(msg.data, w);
            const notes = msg.notes;
            w.writeInt(u32, @intCast(notes.len), .little) catch return error.OutOfMemory;
            for (notes) |note| {
                try writeLogData(note, w);
            }
        }

        fn writeLogData(data: bun.logger.Data, w: Writer) bun.OOM!void {
            try writeString32(data.text, w);
            if (data.location) |loc| {
                if (loc.line < 0) {
                    w.writeInt(u32, 0, .little) catch return error.OutOfMemory;
                    return;
                }
                assert(loc.column >= 0); // zero based and not negative

                w.writeInt(i32, @intCast(loc.line), .little) catch return error.OutOfMemory;
                w.writeInt(u32, @intCast(loc.column), .little) catch return error.OutOfMemory;
                w.writeInt(u32, @intCast(loc.length), .little) catch return error.OutOfMemory;

                // TODO: syntax highlighted line text + give more context lines
                try writeString32(loc.line_text orelse "", w);

                // The file is not specified here. Since the transpiler runs every file
                // in isolation, it would be impossible to reference any other file
                // in this Log. Thus, it is not serialized.
            } else {
                w.writeInt(u32, 0, .little) catch return error.OutOfMemory;
            }
        }

        fn writeString32(data: []const u8, w: Writer) bun.OOM!void {
            w.writeInt(u32, @intCast(data.len), .little) catch return error.OutOfMemory;
            w.writeAll(data) catch return error.OutOfMemory;
        }
    };
}

const std = @import("std");

const bun = @import("bun");
const assert = bun.assert;
