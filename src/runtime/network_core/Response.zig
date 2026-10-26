const std = @import("std");

pub const Flags = packed struct(u8) {
    socket_closed: bool = false,
    request_has_completed: bool = false,
    ended: bool = false,
    upgraded: bool = false,
    hasCustomOnData: bool = false,
    is_request_pending: bool = true,
    is_data_buffered_during_pause: bool = false,
    is_data_buffered_during_pause_last: bool = false,

    pub fn isRequestedCompletedOrEnded(self: Flags) bool {
        return self.request_has_completed or self.ended;
    }

    pub fn isDone(self: Flags) bool {
        return self.isRequestedCompletedOrEnded() or self.socket_closed;
    }
};

pub const BodyReadState = enum(u8) { none, pending, done };
pub const WriteError = error{ OutOfMemory, ConnectionClosed, WriteFailed };
pub const WriteResult = union(enum) {
    ready: usize,
    backpressure: struct { written: usize, retain_input: bool },
};
pub const DrainResult = enum { closed, pending_body, pending_framing, ready };

pub fn Response(comptime Transport: type, comptime Framing: type) type {
    return struct {
        const Self = @This();

        raw_response: ?Transport,
        allocator: std.mem.Allocator,
        flags: Flags = .{},
        abort_delivered: bool = false,
        body_read_state: BodyReadState = .none,
        buffered_body: std.ArrayList(u8) = .empty,
        bytes_written: u64 = 0,
        pending_write: ?PendingWrite = null,

        const PendingWrite = struct {
            length: usize,
            offset: usize,
            framing: Framing,
        };

        pub fn deinit(self: *Self) void {
            self.buffered_body.deinit(self.allocator);
        }

        pub fn shouldRequestBePending(self: *const Self) bool {
            if (self.flags.socket_closed or self.flags.upgraded) return false;
            if (self.flags.isRequestedCompletedOrEnded()) return self.body_read_state == .pending;
            return true;
        }

        pub fn canRead(self: *const Self) bool {
            return !self.flags.isDone() and !self.flags.upgraded and self.raw_response != null;
        }

        pub fn pauseSocket(self: *Self) void {
            if (self.flags.socket_closed or self.flags.upgraded) return;
            const response = self.raw_response orelse return;
            if (!response.isConnectRequest()) response.pause();
        }

        pub fn resumeSocket(self: *Self) void {
            if (self.flags.socket_closed or self.flags.upgraded) return;
            const response = self.raw_response orelse return;
            if (!response.isConnectRequest()) response.@"resume"();
        }

        pub fn setTimeout(self: *Self, seconds: u32) bool {
            if (self.flags.request_has_completed or self.flags.socket_closed or self.flags.upgraded) return false;
            const response = self.raw_response orelse return false;
            response.timeout(@intCast(@min(seconds, 255)));
            return true;
        }

        pub fn beginAbort(self: *Self) bool {
            if (self.abort_delivered or self.flags.upgraded) return false;
            self.abort_delivered = true;
            self.flags.socket_closed = true;
            self.raw_response = null;
            return true;
        }

        pub fn finish(self: *Self) bool {
            if (self.flags.request_has_completed) return false;
            std.debug.assert(self.pending_write == null);
            self.flags.request_has_completed = true;
            return true;
        }

        pub fn getHasBody(self: *const Self) i32 {
            var result: i32 = switch (self.body_read_state) {
                .none => 0,
                .pending => 1 << 1,
                .done => 1 << 2,
            };
            if (self.buffered_body.items.len > 0) result |= 1 << 3;
            if (self.flags.is_data_buffered_during_pause_last) result |= 1 << 2;
            return result;
        }

        pub fn getBufferedAmount(self: *const Self) u64 {
            if (self.flags.request_has_completed or self.flags.socket_closed) return 0;
            const response = self.raw_response orelse return 0;
            const pending = if (self.pending_write) |pending| pending.length - pending.offset else 0;
            return response.getBufferedAmount() +| pending;
        }

        pub fn bufferBody(self: *Self, bytes: []const u8) std.mem.Allocator.Error!void {
            try self.buffered_body.appendSlice(self.allocator, bytes);
        }

        pub fn takeBody(self: *Self) ?std.ArrayList(u8) {
            if (self.buffered_body.items.len == 0) return null;
            const result = self.buffered_body;
            self.buffered_body = .empty;
            return result;
        }

        pub fn clearBody(self: *Self) void {
            self.buffered_body.clearAndFree(self.allocator);
        }

        pub fn checkWrite(self: *const Self) error{WriteAfterEnd}!?Transport {
            if (self.flags.isRequestedCompletedOrEnded()) return error.WriteAfterEnd;
            if (self.flags.socket_closed or self.flags.upgraded) return null;
            const response = self.raw_response orelse return null;
            if (!response.state().isResponsePending()) return error.WriteAfterEnd;
            return response;
        }

        pub fn revalidateWrite(self: *const Self, expected: Transport) error{WriteAfterEnd}!?Transport {
            if (self.flags.socket_closed or self.flags.upgraded) return null;
            const response = self.raw_response orelse return null;
            if (!std.meta.eql(response, expected)) return null;
            return self.checkWrite();
        }

        pub fn checkHeaders(self: *const Self) error{ StreamFinished, HeadersEnded }!?Transport {
            if (self.flags.isRequestedCompletedOrEnded()) return error.StreamFinished;
            if (self.flags.socket_closed or self.flags.upgraded) return null;
            const response = self.raw_response orelse return null;
            if (!response.state().isResponsePending()) return error.HeadersEnded;
            return response;
        }

        pub fn validateStatusMessage(message: []const u8) error{InvalidStatusMessage}!void {
            for (message) |byte| {
                if (byte != '\t' and (byte < 0x20 or byte == 0x7f)) return error.InvalidStatusMessage;
            }
        }

        pub fn finishRequest(self: *Self, response: Transport, failed: bool, close_connection: bool) WriteError!void {
            response.clearOnData();
            response.clearOnWritable();
            response.clearTimeout();
            const state = response.state();
            if (state.isResponsePending()) {
                if (failed and !state.isHttpStatusCalled()) try response.writeStatus("500 Internal Server Error");
                if (failed) {
                    try response.endStream(close_connection or state.isHttpConnectionClose());
                } else try response.endWithoutBody(close_connection or state.isHttpConnectionClose());
            }
            self.flags.ended = true;
            self.body_read_state = .done;
        }

        pub fn recordWrite(self: *Self, length: usize, content_length: ?u64, comptime is_end: bool) error{ContentLengthMismatch}!void {
            if (content_length) |expected| {
                const total = std.math.add(u64, self.bytes_written, length) catch return error.ContentLengthMismatch;
                if (if (is_end) total != expected else total > expected) return error.ContentLengthMismatch;
                self.bytes_written = total;
            } else self.bytes_written +|= length;
        }

        pub fn write(self: *Self, response: Transport, bytes: []const u8) WriteError!WriteResult {
            std.debug.assert(self.pending_write == null);
            if (bytes.len >= 64 * 1024 and bytes.len <= std.math.maxInt(c_uint)) {
                const framing = (try response.prepareWrite(@intCast(bytes.len))) orelse unreachable;
                const written = try response.tryWriteBody(bytes);
                std.debug.assert(written <= bytes.len);
                if (written < bytes.len) {
                    self.pending_write = .{ .length = bytes.len, .offset = written, .framing = framing };
                    return .{ .backpressure = .{ .written = @max(written, 1), .retain_input = true } };
                }
                if (!try response.finishWrite(framing)) return .{ .backpressure = .{ .written = @max(written, 1), .retain_input = false } };
                return .{ .ready = written };
            }
            return switch (try response.write(bytes)) {
                .want_more => |written| .{ .ready = written },
                .backpressure => |written| .{ .backpressure = .{ .written = written, .retain_input = false } },
            };
        }

        pub fn drain(self: *Self, response: Transport, bytes: []const u8) WriteError!DrainResult {
            if (self.flags.socket_closed or self.flags.request_has_completed or self.flags.upgraded) return .closed;
            const pending = if (self.pending_write) |*value| value else return .ready;
            std.debug.assert(bytes.len == pending.length);
            const written = try response.tryWriteBody(bytes[pending.offset..]);
            std.debug.assert(written <= pending.length - pending.offset);
            pending.offset += written;
            if (pending.offset < pending.length) return .pending_body;
            const ready = try response.finishWrite(pending.framing);
            self.pending_write = null;
            return if (ready) .ready else .pending_framing;
        }

        pub fn discardPendingWrite(self: *Self) void {
            self.pending_write = null;
        }

        pub fn spill(self: *Self, response: Transport, bytes: []const u8) WriteError!void {
            const pending = self.pending_write orelse return;
            self.pending_write = null;
            std.debug.assert(bytes.len == pending.length);
            try response.writePreparedBody(bytes[pending.offset..]);
            _ = try response.finishWrite(pending.framing);
        }

        pub fn end(self: *Self, response: Transport, bytes: []const u8) WriteError!void {
            const state = response.state();
            self.flags.ended = true;
            if (!state.isHttpWriteCalled() or bytes.len > 0) {
                try response.end(bytes, state.isHttpConnectionClose());
            } else try response.endStream(state.isHttpConnectionClose());
        }
    };
}
