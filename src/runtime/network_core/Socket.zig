const std = @import("std");
const builtin = @import("builtin");

pub const WriteResult = struct {
    wrote: i32 = 0,
    total: usize = 0,
    finish: bool = false,
};

pub const Flags = packed struct {
    is_active: bool = false,
    authorized: bool = false,
    handshake_complete: bool = false,
    empty_packet_pending: bool = false,
    end_after_flush: bool = false,
    is_paused: bool = false,
    allow_half_open: bool = false,
    bypass_tls: bool = false,
};

pub fn Socket(comptime ssl: bool, comptime Transport: type) type {
    return struct {
        const Self = @This();

        socket: Transport,
        allocator: std.mem.Allocator,
        flags: Flags = .{},
        buffered: std.ArrayList(u8) = .empty,
        bytes_written: u64 = 0,
        // Transport callbacks can write or close while the active buffer is borrowed.
        deferred: std.ArrayList(u8) = .empty,
        writing: bool = false,
        clear_after_write: bool = false,
        flush_after_write: bool = false,

        pub fn deinit(self: *Self) void {
            self.buffered.deinit(self.allocator);
            self.deferred.deinit(self.allocator);
        }

        pub fn bufferedLength(self: *const Self) usize {
            return if (self.clear_after_write) 0 else self.buffered.items.len + self.deferred.items.len;
        }

        pub fn memoryCost(self: *const Self) usize {
            return self.buffered.capacity + self.deferred.capacity;
        }

        pub fn clearBuffered(self: *Self) void {
            self.deferred.clearAndFree(self.allocator);
            if (self.writing) {
                self.clear_after_write = true;
            } else {
                self.buffered.clearAndFree(self.allocator);
                self.clear_after_write = false;
            }
        }

        fn clearAfterWrite(self: *Self) bool {
            if (!self.clear_after_write) return false;
            std.debug.assert(!self.writing);
            self.clearBuffered();
            return true;
        }

        fn promoteDeferred(self: *Self) void {
            if (self.buffered.items.len == 0 and self.deferred.items.len != 0)
                std.mem.swap(std.ArrayList(u8), &self.buffered, &self.deferred);
        }

        pub fn @"resume"(self: *Self) void {
            if (self.socket.isDetached()) return;

            // The raw half of a TLS upgrade shares flow control with the encrypted half.
            if (self.flags.bypass_tls) return;
            if (self.flags.is_paused) self.flags.is_paused = !self.socket.resumeStream();
        }

        pub fn pause(self: *Self) void {
            if (self.socket.isDetached()) return;

            if (self.flags.bypass_tls) return;
            if (!self.flags.is_paused) self.flags.is_paused = self.socket.pauseStream();
        }

        pub fn setKeepAlive(self: *Self, enabled: bool, initial_delay: u32) bool {
            return self.socket.setKeepAlive(enabled, initial_delay);
        }

        pub fn setNoDelay(self: *Self, enabled: bool) bool {
            return self.socket.setNoDelay(enabled);
        }

        pub fn getReadyState(self: *Self) i32 {
            if (self.socket.isDetached()) {
                return -1;
            } else if (self.socket.isClosed()) {
                return 0;
            } else if (self.socket.isEstablished()) {
                return 1;
            } else if (self.socket.isShutdown()) {
                return -2;
            } else {
                return 2;
            }
        }

        pub fn getAuthorized(self: *Self) bool {
            return self.flags.authorized;
        }

        pub fn timeout(self: *Self, seconds: i32) void {
            if (self.socket.isDetached()) return;
            std.debug.assert(seconds >= 0);

            self.socket.setTimeout(@intCast(seconds));
        }

        pub fn doSocketWrite(self: *Self, buffer: []const u8) i32 {
            if (self.writing) return 0;
            self.writing = true;
            defer self.writing = false;
            return if (self.flags.bypass_tls)
                self.socket.rawWrite(buffer)
            else
                self.socket.write(buffer);
        }

        pub fn writeMaybeCorked(self: *Self, buffer: []const u8) i32 {
            if (self.socket.isShutdown() or self.socket.isClosed()) {
                return -1;
            }

            const res = self.doSocketWrite(buffer);
            const uwrote: usize = @intCast(@max(res, 0));
            self.bytes_written += uwrote;

            return res;
        }

        pub fn writeOrEndBufferedBytes(self: *Self, bytes: []const u8, data_present: bool, comptime is_end: bool) std.mem.Allocator.Error!WriteResult {
            if (self.socket.isShutdown() or self.socket.isClosed()) {
                return .{
                    .wrote = -1,
                    .total = std.math.add(usize, bytes.len, self.bufferedLength()) catch return error.OutOfMemory,
                };
            }

            if (self.writing or self.deferred.items.len != 0) {
                const total = std.math.add(usize, self.bufferedLength(), bytes.len) catch return error.OutOfMemory;
                try self.deferred.appendSlice(self.allocator, bytes);
                if (is_end) {
                    self.flags.end_after_flush = true;
                    if (self.writing) self.flush_after_write = true;
                }
                if (self.writing) {
                    if (ssl and data_present and total == 0) {
                        self.flags.empty_packet_pending = true;
                        if (!self.tryWriteEmptyPacket()) return .{ .wrote = -1, .total = 0 };
                    }
                    return .{ .wrote = 0, .total = total };
                }
                const before = self.bytes_written;
                const finish = self.internalFlush();
                return .{
                    .wrote = @intCast(@min(self.bytes_written - before, std.math.maxInt(i32))),
                    .total = total,
                    .finish = finish,
                };
            }

            try self.buffered.ensureUnusedCapacity(self.allocator, bytes.len);
            const total_to_write: usize = bytes.len + self.buffered.items.len;
            if (is_end) self.flags.end_after_flush = true;
            if (total_to_write == 0) {
                if (ssl) {
                    if (data_present) {
                        self.flags.empty_packet_pending = true;
                        if (!self.tryWriteEmptyPacket()) {
                            return .{
                                .wrote = -1,
                                .total = total_to_write,
                            };
                        }
                    }
                }

                return .{};
            }

            const wrote: i32 = brk: {
                if (comptime !ssl and builtin.os.tag != .windows) {
                    if (self.socket.socket == .connected and bytes.len > 0) {
                        const buffered_len: usize = self.buffered.items.len;
                        const rc = self.socket.socket.connected.write2(self.buffered.items, bytes);
                        const written: usize = @intCast(@max(rc, 0));
                        std.debug.assert(written <= total_to_write);
                        self.bytes_written += written;
                        if (written == total_to_write) {
                            self.buffered.clearAndFree(self.allocator);
                            break :brk rc;
                        }

                        const buffered_written = @min(written, buffered_len);
                        const buffered_remaining = buffered_len - buffered_written;
                        const buffer = self.buffered.items;
                        std.mem.copyForwards(u8, buffer[0..buffered_remaining], buffer[buffered_written..]);
                        self.buffered.items.len = buffered_remaining;
                        self.buffered.appendSliceAssumeCapacity(bytes[written - buffered_written ..]);

                        break :brk rc;
                    }
                }

                self.buffered.appendSliceAssumeCapacity(bytes);
                const rc = self.writeMaybeCorked(self.buffered.items);
                if (self.clearAfterWrite()) break :brk rc;
                if (rc > 0) {
                    const wrote: usize = @intCast(@max(rc, 0));
                    if (wrote == self.buffered.items.len) {
                        self.buffered.clearAndFree(self.allocator);
                    } else {
                        const len = self.buffered.items.len - wrote;
                        std.debug.assert(len <= self.buffered.items.len);
                        std.debug.assert(len <= self.buffered.capacity);
                        std.mem.copyForwards(u8, self.buffered.items[0..len], self.buffered.items[wrote..][0..len]);
                        self.buffered.items.len = len;
                    }
                }

                break :brk rc;
            };

            const finish = if (self.flush_after_write or (self.buffered.items.len == 0 and self.deferred.items.len != 0))
                self.internalFlush()
            else
                false;
            return .{ .wrote = wrote, .total = total_to_write, .finish = finish };
        }

        pub fn finishWithoutWrite(self: *Self, comptime is_end: bool) WriteResult {
            if (is_end) {
                self.flags.end_after_flush = true;
                if (self.writing) self.flush_after_write = true;
            }

            return .{};
        }

        pub fn writeBytesOrEnd(
            self: *Self,
            bytes: []const u8,
            buffer_unwritten_data: bool,
            comptime is_end: bool,
        ) std.mem.Allocator.Error!WriteResult {
            if (self.socket.isShutdown() or self.socket.isClosed()) {
                return .{ .wrote = -1, .total = bytes.len };
            }
            if (self.writing) {
                if (buffer_unwritten_data) try self.deferred.appendSlice(self.allocator, bytes);
                if (is_end) {
                    self.flags.end_after_flush = true;
                    self.flush_after_write = true;
                }
                if (ssl and bytes.len == 0) {
                    self.flags.empty_packet_pending = true;
                    if (!self.tryWriteEmptyPacket()) return .{ .wrote = -1, .total = 0 };
                }
                return .{ .wrote = 0, .total = bytes.len };
            }
            self.promoteDeferred();
            if (self.buffered.items.len != 0) {
                if (buffer_unwritten_data) return self.writeOrEndBufferedBytes(bytes, true, is_end);
                if (self.internalFlush()) return .{ .wrote = -1, .total = bytes.len, .finish = true };
                if (self.socket.isShutdown() or self.socket.isClosed()) {
                    return .{ .wrote = -1, .total = bytes.len };
                }
                if (self.buffered.items.len != 0) {
                    if (bytes.len == 0) return self.finishWithoutWrite(is_end);
                    return .{ .wrote = 0, .total = bytes.len };
                }
            }
            if (buffer_unwritten_data)
                try self.buffered.ensureUnusedCapacity(self.allocator, bytes.len);
            if (!self.flags.end_after_flush and is_end) {
                self.flags.end_after_flush = true;
            }

            if (bytes.len == 0) {
                if (ssl) {
                    self.flags.empty_packet_pending = true;
                    if (!self.tryWriteEmptyPacket()) {
                        return .{
                            .wrote = -1,
                            .total = bytes.len,
                        };
                    }
                }
                return .{};
            }

            const wrote = self.writeMaybeCorked(bytes);
            if (self.clearAfterWrite()) return .{ .wrote = wrote, .total = bytes.len };
            const uwrote: usize = @intCast(@max(wrote, 0));
            if (buffer_unwritten_data) {
                const remaining = bytes[uwrote..];
                if (remaining.len > 0) {
                    self.buffered.appendSliceAssumeCapacity(remaining);
                }
            }

            const finish = if (self.flush_after_write or (self.buffered.items.len == 0 and self.deferred.items.len != 0))
                self.internalFlush()
            else
                false;
            return .{ .wrote = wrote, .total = bytes.len, .finish = finish };
        }

        pub fn tryWriteEmptyPacket(self: *Self) bool {
            if (ssl) {
                // A zero-length TLS write completes only after the handshake and buffered writes.
                if (!self.flags.handshake_complete or self.bufferedLength() > 0) return false;

                self.flags.empty_packet_pending = false;
                return true;
            }
            return false;
        }

        pub fn canEndAfterFlush(self: *Self) bool {
            return !self.writing and !self.socket.isDetached() and self.flags.is_active and self.flags.end_after_flush and !self.flags.empty_packet_pending and self.bufferedLength() == 0;
        }

        pub fn internalFlush(self: *Self) bool {
            if (self.writing or self.socket.isDetached()) return false;
            defer self.flush_after_write = false;
            _ = self.clearAfterWrite();
            while (true) {
                self.promoteDeferred();
                while (self.buffered.items.len > 0) {
                    const written: usize = @intCast(@max(self.doSocketWrite(self.buffered.items), 0));
                    self.bytes_written += written;
                    if (self.clearAfterWrite()) break;
                    std.debug.assert(written <= self.buffered.items.len);
                    if (written == 0) break;
                    const remaining = self.buffered.items[written..];
                    std.mem.copyForwards(u8, self.buffered.items[0..remaining.len], remaining);
                    self.buffered.items.len = remaining.len;
                    if (remaining.len != 0) break;
                    self.buffered.clearAndFree(self.allocator);
                    self.promoteDeferred();
                }
                _ = self.tryWriteEmptyPacket();
                self.writing = true;
                self.socket.flush();
                self.writing = false;
                _ = self.clearAfterWrite();
                if (self.socket.isClosed() or self.socket.isShutdown()) return false;
                if (self.buffered.items.len == 0 and self.deferred.items.len != 0) continue;
                return self.canEndAfterFlush();
            }
        }

        pub fn shutdown(self: *Self, read: bool) void {
            if (read) {
                self.socket.shutdownRead();
            } else {
                self.socket.shutdown();
            }
        }

        pub const Address = union(enum) { ipv4: [4]u8, ipv6: [16]u8 };
        pub const Endpoint = enum { local, remote };

        pub fn address(self: *const Self, comptime endpoint: Endpoint) ?Address {
            if (self.socket.isDetached()) return null;
            var buffer: [64]u8 = @splat(0);
            const bytes = switch (endpoint) {
                .local => self.socket.localAddress(&buffer),
                .remote => self.socket.remoteAddress(&buffer),
            } orelse return null;
            return switch (bytes.len) {
                4 => .{ .ipv4 = bytes[0..4].* },
                16 => .{ .ipv6 = bytes[0..16].* },
                else => null,
            };
        }

        pub fn port(self: *const Self, comptime endpoint: Endpoint) ?u16 {
            if (self.socket.isDetached()) return null;
            return std.math.cast(u16, switch (endpoint) {
                .local => self.socket.localPort(),
                .remote => self.socket.remotePort(),
            });
        }

        pub fn getFD(self: *Self) i64 {
            return self.socket.fd().number();
        }

        pub fn getBytesWritten(self: *Self) usize {
            return self.bytes_written + self.buffered.items.len;
        }
    };
}
