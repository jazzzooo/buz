pub const log = Output.scoped(.IPC, .visible);

const ReceiveState = struct {
    const RefCount = bun.ptr.RefCount(@This(), "ref_count", destroy, .{});
    const ref = RefCount.ref;
    const deref = RefCount.deref;

    ref_count: RefCount = .init(),
    buffer: IPCBuffer = .{},
    dispatching: bool = false,
    closed: bool = false,

    fn create() bun.OOM!*ReceiveState {
        const state = try bun.default_allocator.create(ReceiveState);
        state.* = .{};
        return state;
    }

    fn destroy(self: *ReceiveState) void {
        self.buffer.deinit(bun.default_allocator);
        bun.destroy(self);
    }
};

const IsInternal = enum { internal, external };
const SerializeAndSendResult = enum {
    success,
    failure,
    backoff,
    disconnected,
};

pub const Mode = IPCBuffer.Mode;

pub const DecodedIPCMessage = union(enum) {
    version: u32,
    data: bun.bindgen.EngineRoot,
    internal: bun.bindgen.EngineRoot,

    pub fn deinit(this: *DecodedIPCMessage) void {
        switch (this.*) {
            .version => {},
            .data, .internal => |*value| value.deinit(),
        }
    }
};

pub const DecodeIPCMessageResult = struct {
    bytes_consumed: usize,
    message: DecodedIPCMessage,
};

pub const IPCDecodeError = error{
    /// There werent enough bytes, recall this function again when new data is available.
    NotEnoughBytes,
    /// Format could not be recognized. Report an error and close the socket.
    InvalidFormat,
} || bun.JSError;

pub const IPCSerializationError = error{
    /// Value could not be serialized.
    SerializationFailed,
} || bun.JSError;

const advanced = struct {
    pub const header_length = IPCBuffer.advanced_header_length;
    pub const version: u32 = 1;

    pub const IPCMessageType = IPCBuffer.AdvancedMessageType;

    const version_packet = IPCBuffer.advancedHeader(.Version, version);

    pub fn decodeIPCMessage(data: []const u8, global: *jsc.JSGlobalObject) IPCDecodeError!DecodeIPCMessageResult {
        if (data.len < header_length) {
            log("Not enough bytes to decode IPC message header, have {d} bytes", .{data.len});
            return IPCDecodeError.NotEnoughBytes;
        }

        const message_type: IPCMessageType = @fromBackingInt(@intCast(data[0]));
        const message_len = std.mem.readInt(u32, data[1 .. @sizeOf(u32) + 1], .little);

        log("Received IPC message type {d} ({s}) len {d}", .{
            @backingInt(message_type),
            std.enums.tagName(IPCMessageType, message_type) orelse "unknown",
            message_len,
        });

        switch (message_type) {
            .Version => {
                return .{
                    .bytes_consumed = header_length,
                    .message = .{ .version = message_len },
                };
            },
            .SerializedMessage, .SerializedInternalMessage => |tag| {
                // `header_length + message_len` would be evaluated as u32; a peer-controlled
                // `message_len >= 0xFFFFFFFB` wraps the sum to a small value and defeats the
                // bounds check. Compare against the remaining bytes instead — `data.len >=
                // header_length` is already established above, so the subtraction cannot
                // underflow.
                if (data.len - header_length < message_len) {
                    log("Not enough bytes to decode IPC message body of len {d}, have {d} bytes", .{ message_len, data.len });
                    return IPCDecodeError.NotEnoughBytes;
                }

                const message = data[header_length..][0..message_len];
                var scope: bun.bindgen.FocusedEngineScope = undefined;
                scope.init(global);
                defer scope.deinit();
                var deserialized = try scope.engineIn("structured_serialization", "deserializeJSValue").call(.{ .data = bun.bindgen.BytesOperand.fromSlice(message) });
                defer deserialized.deinit();
                const retained = try deserialized.toRoot();

                return .{
                    .bytes_consumed = header_length + @as(usize, message_len),
                    .message = if (tag == .SerializedInternalMessage) .{ .internal = retained } else .{ .data = retained },
                };
            },
            _ => {
                return IPCDecodeError.InvalidFormat;
            },
        }
    }

    pub inline fn getVersionPacket() []const u8 {
        return &version_packet;
    }

    pub fn serialize(writer: *bun.io.StreamBuffer, context: anytype, value: anytype, is_internal: IsInternal) IPCSerializationError!usize {
        var serialized = try context.engineIn("structured_serialization", "serializeJSValue").call(.{
            .value = value.operand(context).asEngine(),
            .for_cross_process_transfer = true,
        });
        var bytes = serialized.takeByteResource();
        defer bytes.deinit();
        return writeSerializedPayload(writer, bytes.slice(), is_internal);
    }

    fn writeSerializedPayload(writer: *bun.io.StreamBuffer, data: []const u8, is_internal: IsInternal) IPCSerializationError!usize {
        const size = std.math.cast(u32, data.len) orelse return error.SerializationFailed;

        const payload_length = header_length + data.len;

        try writer.ensureUnusedCapacity(payload_length);

        const header = IPCBuffer.advancedHeader(switch (is_internal) {
            .internal => .SerializedInternalMessage,
            .external => .SerializedMessage,
        }, size);
        writer.writeAssumeCapacity(&header);
        writer.writeAssumeCapacity(data);

        return payload_length;
    }
};

const json = struct {
    pub fn getVersionPacket() []const u8 {
        return &.{};
    }
    pub fn getAckPacket() []const u8 {
        return "{\"cmd\":\"NODE_HANDLE_ACK\"}\n";
    }
    pub fn getNackPacket() []const u8 {
        return "{\"cmd\":\"NODE_HANDLE_NACK\"}\n";
    }

    // In order to not have to do a property lookup internal messages sent from Bun will have a single u8 prepended to them
    // to be able to distinguish whether it is a regular json message or an internal one for cluster ipc communication.
    // 2 is internal
    // ["[{\d\.] is regular

    pub fn decodeIPCMessage(data: []const u8, globalThis: *jsc.JSGlobalObject, known_newline: ?u32) IPCDecodeError!DecodeIPCMessageResult {
        // <tag>{ "foo": "bar"} // tag is 1 or 2
        const idx: u32 = known_newline orelse idx: {
            const found = bun.strings.indexOfChar(data, '\n') orelse
                return IPCDecodeError.NotEnoughBytes;
            // Individual IPC messages should not exceed 4GB, and idx+1 must not overflow
            if (found >= std.math.maxInt(u32)) return IPCDecodeError.InvalidFormat;
            break :idx @intCast(found);
        };
        if (idx >= data.len or idx == std.math.maxInt(u32) or data[idx] != '\n') return error.InvalidFormat;

        var json_data = data[0..idx];
        // An empty payload (newline with no preceding data) is invalid JSON.
        if (json_data.len == 0) return error.InvalidFormat;

        var kind: enum { regular, internal } = .regular;
        if (json_data[0] == 2) {
            // internal message
            json_data = json_data[1..];
            kind = .internal;
        }

        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(globalThis);
        defer scope.deinit();
        var deserialized = (try scope.engine(ParseJSONMessageShim).call(.{
            .bytes = bun.bindgen.BytesOperand.fromSlice(json_data),
        })) orelse return error.InvalidFormat;
        defer deserialized.deinit();
        const retained = try deserialized.toRoot();

        return switch (kind) {
            .regular => .{
                .bytes_consumed = @as(usize, idx) + 1,
                .message = .{ .data = retained },
            },
            .internal => .{
                .bytes_consumed = @as(usize, idx) + 1,
                .message = .{ .internal = retained },
            },
        };
    }

    pub fn serialize(writer: *bun.io.StreamBuffer, context: anytype, value: anytype, is_internal: IsInternal) IPCSerializationError!usize {
        var out = (try context.engineIn("json_serialization", "jsonStringifyFast").call(.{ .value = value.operand(context).asEngine() })) orelse
            return error.SerializationFailed;
        defer out.deinit();
        const str = try out.toUTF8(bun.default_allocator);
        defer str.deinit();

        const slice = str.slice();

        const framing_length: usize = if (is_internal == .internal) 2 else 1;
        if (slice.len > std.math.maxInt(u32) - framing_length) return error.SerializationFailed;
        const result_len = slice.len + framing_length;

        try writer.ensureUnusedCapacity(result_len);

        if (is_internal == .internal) {
            writer.writeAssumeCapacity(&.{2});
        }
        writer.writeAssumeCapacity(slice);
        writer.writeAssumeCapacity("\n");

        return result_len;
    }
};

/// Given potentially unfinished buffer `data`, attempt to decode and process a message from it.
/// For JSON mode, `known_newline` can be provided to avoid re-scanning for the newline delimiter.
pub fn decodeIPCMessage(mode: Mode, data: []const u8, global: *jsc.JSGlobalObject, known_newline: ?u32) IPCDecodeError!DecodeIPCMessageResult {
    return switch (mode) {
        .advanced => advanced.decodeIPCMessage(data, global),
        .json => json.decodeIPCMessage(data, global, known_newline),
    };
}

/// Returns the initialization packet for the given mode. Can be zero-length.
pub fn getVersionPacket(mode: Mode) []const u8 {
    return switch (mode) {
        inline else => |t| @field(@This(), @tagName(t)).getVersionPacket(),
    };
}

pub fn serialize(mode: Mode, writer: *bun.io.StreamBuffer, context: anytype, value: anytype, is_internal: IsInternal) IPCSerializationError!usize {
    return switch (mode) {
        .advanced => advanced.serialize(writer, context, value, is_internal),
        .json => json.serialize(writer, context, value, is_internal),
    };
}

fn writeHandleReply(mode: Mode, writer: *bun.io.StreamBuffer, context: anytype, acknowledged: bool) bun.JSError!void {
    switch (mode) {
        .json => try writer.write(if (acknowledged) json.getAckPacket() else json.getNackPacket()),
        .advanced => {
            var serialized = try context.engineIn("IPC", "serializeHandleReply").call(.{
                .acknowledged = acknowledged,
            });
            var bytes = serialized.takeByteResource();
            defer bytes.deinit();
            _ = advanced.writeSerializedPayload(writer, bytes.slice(), .external) catch |err| switch (err) {
                error.SerializationFailed => {
                    var message = try bun.bindgen.DOMString.fromUTF8("IPC control message exceeds the size limit");
                    defer message.deinit();
                    var failure = try context.engineIn("errors", "createError").call(.{ .message = message.operand() });
                    defer failure.deinit();
                    return failure.throwException(context);
                },
                else => |js_error| return js_error,
            };
        },
    }
}

pub const Socket = uws.NewSocketHandler(false);

const PendingMessage = struct {
    data: bun.io.StreamBuffer = .{},
    callback: ?IPCSendCallback = null,
    is_version: bool = false,
    windows_write: if (Environment.isWindows) ?*WindowsWrite else void = if (Environment.isWindows) null else {},

    fn prepareWrite(self: *PendingMessage) bun.OOM!void {
        if (Environment.isWindows and self.data.list.items.len != 0 and self.windows_write == null) {
            const request = try bun.default_allocator.create(WindowsWrite);
            request.* = .{};
            self.windows_write = request;
        }
    }

    pub fn complete(self: *PendingMessage, global: *jsc.JSGlobalObject) void {
        defer self.deinit();
        if (self.callback) |*callback| {
            var invocation: IPCSendCallback.Invocation = undefined;
            callback.beginInvocation(&invocation);
            defer invocation.deinit();
            invocation.schedule(.{ .@"error" = null }) catch |err| global.reportActiveExceptionAsUnhandled(err);
        }
    }
    pub fn deinit(self: *PendingMessage) void {
        if (Environment.isWindows) {
            if (self.windows_write) |request| request.destroy();
        }
        self.data.deinit();
        if (self.callback) |*callback| callback.deinit();
        self.* = .{};
    }

    pub fn take(self: *PendingMessage) PendingMessage {
        const result = self.*;
        self.* = .{};
        return result;
    }
};

pub const WindowsWrite = struct {
    write_req: uv.uv_write_t = std.mem.zeroes(uv.uv_write_t),
    write_buffer: uv.uv_buf_t = uv.uv_buf_t.init(""),
    retained_data: bun.io.StreamBuffer = .{},
    write_length: usize = 0,
    owner: ?*SendQueue = null,
    pipe: ?*uv.Pipe = null,
    pub fn destroy(self: *WindowsWrite) void {
        bun.assert(self.owner == null and self.pipe == null);
        self.retained_data.deinit();
        bun.destroy(self);
    }
};
pub const SendQueue = struct {
    queue: std.array_list.Managed(PendingMessage),

    keep_alive: bun.Async.KeepAlive = .{},
    version_prepared: bool = false,
    mode: Mode,
    internal_msg_queue: NodeClusterEngine.InternalMsgHolder = .{},
    incoming: ?*ReceiveState = null,
    incoming_fd: ?bun.FD = null,

    socket: SocketUnion,
    owner: SendQueueOwner,

    close_next_tick: CancellableTask = .{},
    after_close_task: CancellableTask = .{},
    deinitializing: bool = false,
    write_in_progress: bool = false,
    write_length: usize = 0,
    draining: bool = false,
    write_blocked: bool = false,
    disconnect_requested: bool = false,
    write_errno: ?bun.sys.Error.Int = null,
    close_event_sent: bool = false,

    windows: switch (Environment.isWindows) {
        true => struct {
            is_server: bool = false,
            windows_write: ?*WindowsWrite = null,
            try_close_after_write: bool = false,
        },
        false => struct {},
    } = .{},

    pub const SendQueueOwner = union(enum) {
        subprocess: *bun.api.Subprocess,
        virtual_machine: *bun.jsc.VirtualMachine.IPCInstance,
    };
    pub const SocketType = switch (Environment.isWindows) {
        true => *uv.Pipe,
        false => Socket,
    };
    pub const SocketUnion = union(enum) {
        uninitialized,
        open: SocketType,
        closed,
    };

    pub fn init(mode: Mode, owner: SendQueueOwner, socket: SocketUnion) @This() {
        log("SendQueue#init", .{});
        return .{
            .queue = .init(bun.default_allocator),
            .mode = mode,
            .owner = owner,
            .socket = socket,
        };
    }
    pub fn deinit(self: *@This()) void {
        log("SendQueue#deinit", .{});
        if (self.deinitializing) return;
        self.deinitializing = true;
        self.close_next_tick.cancel();
        self.after_close_task.cancel();
        self.closeSocket(.failure, .deinit);

        var messages = self.queue;
        self.queue = .init(bun.default_allocator);
        for (messages.items) |*item| item.deinit();
        messages.deinit();
        self.internal_msg_queue.deinit();
        self.releaseIncoming();
        // An SCM_RIGHTS fd can be stashed by `onFd` and not yet consumed by
        // the `NODE_HANDLE` decoder when the socket closes.
        if (bun.take(&self.incoming_fd)) |fd| fd.close();
    }

    pub fn isConnected(this: *SendQueue) bool {
        if (Environment.isWindows and this.windows.try_close_after_write) return false;
        return this.socket == .open and !this.disconnect_requested;
    }

    fn ensureIncoming(this: *SendQueue) bun.OOM!*ReceiveState {
        if (this.incoming) |incoming| return incoming;
        const incoming = try ReceiveState.create();
        this.incoming = incoming;
        return incoming;
    }

    fn releaseIncoming(this: *SendQueue) void {
        if (bun.take(&this.incoming)) |incoming| {
            incoming.closed = true;
            incoming.deref();
        }
    }

    fn retainOwner(this: *SendQueue) ?bun.bindgen.RefNative(bun.api.Subprocess, .vm) {
        return switch (this.owner) {
            .subprocess => |subprocess| bun.bindgen.RefNative(bun.api.Subprocess, .vm).init(subprocess),
            .virtual_machine => null,
        };
    }

    fn closeSocket(this: *SendQueue, reason: enum { normal, failure }, from: enum { user, deinit }) void {
        log("SendQueue#closeSocket {s}", .{@tagName(from)});
        switch (this.socket) {
            .open => |s| switch (Environment.isWindows) {
                true => {
                    const pipe: *uv.Pipe = s;
                    const stream: *uv.uv_stream_t = pipe.asStream();
                    stream.readStop();

                    if (this.windows.windows_write != null and from != .deinit) {
                        log("SendQueue#closeSocket -> mark ready for close", .{});
                        // currently writing; wait for the write to complete
                        this.windows.try_close_after_write = true;
                    } else {
                        log("SendQueue#closeSocket -> close now", .{});
                        this._windowsClose();
                    }
                },
                false => {
                    s.close(switch (reason) {
                        .normal => .normal,
                        .failure => .failure,
                    });
                    this._socketClosed();
                },
            },
            else => {
                this._socketClosed();
            },
        }
    }
    fn _socketClosed(this: *SendQueue) void {
        log("SendQueue#_socketClosed", .{});
        this.close_next_tick.cancel();
        if (this.write_errno == null and this.queue.items.len != 0)
            this.write_errno = @intCast(@backingInt(bun.sys.E.PIPE));
        if (this.incoming) |incoming| incoming.closed = true;
        if (bun.take(&this.incoming_fd)) |fd| fd.close();
        if (Environment.isWindows) {
            if (this.windows.windows_write) |windows_write| {
                bun.assert(this.queue.items.len != 0);
                const first = &this.queue.items[0];
                bun.assert(first.windows_write == null);
                windows_write.retained_data = first.data;
                first.data = .{};
                windows_write.owner = null;
            }
            this.windows.windows_write = null;
        }
        this.keep_alive.disable();
        this.write_in_progress = false;
        this.write_length = 0;
        this.write_blocked = false;
        const was_open = this.socket == .open;
        this.socket = .closed;
        if (was_open and !this.deinitializing and !this.after_close_task.isScheduled()) {
            this.after_close_task.schedule(this.getGlobalThis().bunVM().eventLoop(), this, _onAfterIPCClosed);
        }
    }
    fn _windowsClose(this: *SendQueue) void {
        log("SendQueue#_windowsClose", .{});
        if (this.socket != .open) return;
        const pipe = this.socket.open;
        pipe.data = pipe;
        pipe.close(&_windowsOnClosed);
        this._socketClosed();
    }
    fn _windowsOnClosed(windows: *uv.Pipe) callconv(.c) void {
        log("SendQueue#_windowsOnClosed", .{});
        bun.default_allocator.destroy(windows);
    }

    pub fn closeSocketNextTick(this: *SendQueue, nextTick: bool) void {
        log("SendQueue#closeSocketNextTick", .{});
        if (this.socket != .open) {
            this.socket = .closed;
            return;
        }
        if (this.disconnect_requested) return;
        this.disconnect_requested = true;
        if (!nextTick) {
            this.drainAndClose();
            return;
        }
        this.close_next_tick.schedule(this.getGlobalThis().bunVM().eventLoop(), this, _closeSocketTask);
    }

    fn _closeSocketTask(this: *SendQueue) void {
        log("SendQueue#closeSocketTask", .{});
        this.drainAndClose();
    }

    fn drainAndClose(this: *SendQueue) void {
        this.continueSend(this.getGlobalThis(), .new_message_appended);
    }

    fn closeIfDrained(this: *SendQueue) void {
        if (this.disconnect_requested and !this.close_next_tick.isScheduled() and
            this.socket == .open and this.queue.items.len == 0 and !this.write_in_progress)
            this.closeSocket(.normal, .user);
    }

    fn _onAfterIPCClosed(this: *SendQueue) void {
        log("SendQueue#_onAfterIPCClosed", .{});
        if (this.close_event_sent) return;
        this.close_event_sent = true;
        var owner_reference = this.retainOwner();
        defer if (owner_reference) |*owner| owner.deinit();
        this.releaseIncoming();
        var messages = this.queue;
        this.queue = .init(bun.default_allocator);
        defer {
            for (messages.items) |*message| message.deinit();
            messages.deinit();
        }
        this.failPendingMessages(messages.items);
        switch (this.owner) {
            inline else => |owner| {
                owner.handleIPCClose();
            },
        }
    }

    fn failPendingMessages(this: *SendQueue, messages: []PendingMessage) void {
        const has_callbacks = for (messages) |message| {
            if (message.callback != null) break true;
        } else false;
        if (!has_callbacks) return;
        const global = this.getGlobalThis();
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(global);
        defer scope.deinit();
        const native_error = bun.sys.Error.fromCodeInt(this.write_errno orelse @panic("closed IPC queue has no write failure"), .write);
        var value = bun.bindgen.SystemError.createSysErrorInstance(&scope, native_error) catch |err| return global.reportActiveExceptionAsUnhandled(err);
        defer value.deinit();
        var failure = value.toOwned() catch |err| return global.reportActiveExceptionAsUnhandled(err);
        defer failure.deinit();
        for (messages) |*message| {
            if (message.callback) |*callback| {
                var invocation: IPCSendCallback.Invocation = undefined;
                callback.beginInvocation(&invocation);
                defer invocation.deinit();
                invocation.schedule(.{ .@"error" = failure.operand(&invocation) }) catch |err| global.reportActiveExceptionAsUnhandled(err);
            }
        }
    }

    fn insertMessage(this: *SendQueue, message: *PendingMessage) bun.OOM!void {
        log("SendQueue#insertMessage", .{});
        bun.assert(this.version_prepared);
        try message.prepareWrite();
        try this.queue.ensureUnusedCapacity(1);
        if ((this.queue.items.len == 0 or (!this.queue.items[0].is_version and this.queue.items[0].data.cursor == 0)) and !this.write_in_progress) {
            this.queue.insertAssumeCapacity(0, message.take());
        } else {
            this.queue.insertAssumeCapacity(1, message.take());
        }
    }

    fn shouldRef(this: *SendQueue) bool {
        return this.socket == .open and this.queue.items.len != 0;
    }
    pub fn updateRef(this: *SendQueue, global: *JSGlobalObject) void {
        switch (this.shouldRef()) {
            true => this.keep_alive.ref(global.bunVM()),
            false => this.keep_alive.unref(global.bunVM()),
        }
    }
    const ContinueSendReason = enum {
        new_message_appended,
        on_writable,
    };
    fn continueSend(this: *SendQueue, global: *jsc.JSGlobalObject, reason: ContinueSendReason) void {
        log("IPC continueSend: {s}", .{@tagName(reason)});
        this.debugLogMessageQueue();
        var owner_reference = this.retainOwner();
        defer if (owner_reference) |*owner| owner.deinit();
        defer this.updateRef(global);
        if (reason == .on_writable) this.write_blocked = false;
        if (this.draining) return;
        this.draining = true;
        defer {
            this.draining = false;
            this.closeIfDrained();
        }

        while (!this.deinitializing and this.socket == .open and this.write_errno == null and
            this.queue.items.len != 0 and !this.write_in_progress and !this.write_blocked)
        {
            const first = &this.queue.items[0];
            const to_send = first.data.list.items[first.data.cursor..];
            if (to_send.len == 0) {
                var item = this.queue.orderedRemove(0);
                item.complete(global);
                continue;
            }
            this.write_in_progress = true;
            this._write(to_send);
        }
    }
    fn failTransport(this: *SendQueue, err: bun.sys.Error) void {
        if (this.write_errno == null) this.write_errno = err.errno;
        this.closeSocket(.failure, .user);
    }

    fn _onWriteComplete(this: *SendQueue, written: usize) void {
        log("SendQueue#_onWriteComplete {d}", .{written});
        this.debugLogMessageQueue();
        if (!this.write_in_progress or this.queue.items.len < 1) {
            bun.debugAssert(false);
            return;
        }
        this.write_in_progress = false;
        const write_length = this.write_length;
        this.write_length = 0;
        var owner_reference = this.retainOwner();
        defer if (owner_reference) |*owner| owner.deinit();
        const globalThis = this.getGlobalThis();
        defer this.updateRef(globalThis);
        const was_draining = this.draining;
        this.draining = true;
        defer {
            this.draining = was_draining;
            if (!was_draining) this.continueSend(globalThis, .new_message_appended);
        }
        const first = &this.queue.items[0];
        const to_send = first.data.list.items[first.data.cursor..];
        bun.assert(written <= write_length and write_length <= to_send.len);
        if (written == to_send.len) {
            var item = this.queue.orderedRemove(0);
            item.complete(globalThis);
            return;
        } else if (written > 0 and written < to_send.len) {
            first.data.cursor += written;
            if (written == write_length)
                return;
            this.write_blocked = true;
            return;
        } else if (written == 0) {
            this.write_blocked = true;
            return;
        } else unreachable;
    }
    pub fn prepareVersionPacket(this: *SendQueue) bun.OOM!void {
        log("SendQueue#prepareVersionPacket", .{});
        bun.assert(!this.version_prepared);
        bun.debugAssert(this.queue.items.len == 0);
        const bytes = getVersionPacket(this.mode);
        if (bytes.len > 0) {
            var pending: PendingMessage = .{ .is_version = true };
            defer pending.deinit();
            try pending.data.write(bytes);
            try pending.prepareWrite();
            try this.queue.ensureUnusedCapacity(1);
            this.queue.appendAssumeCapacity(pending.take());
        }
        this.version_prepared = true;
    }

    pub fn start(this: *SendQueue, global: *JSGlobalObject) void {
        bun.assert(this.version_prepared);
        this.continueSend(global, .new_message_appended);
    }
    pub fn serializeAndSend(self: *SendQueue, context: anytype, value: anytype, is_internal: IsInternal, callback: ?*IPCSendCallback) bun.JSError!SerializeAndSendResult {
        log("SendQueue#serializeAndSend", .{});
        const global = context.viewToken().globalObject();
        if (!self.isConnected()) return .disconnected;
        var pending: PendingMessage = .{};
        defer pending.deinit();
        const payload_length = serialize(self.mode, &pending.data, context, value, is_internal) catch |err| switch (err) {
            error.SerializationFailed => return .failure,
            else => |js_error| return js_error,
        };
        bun.assert(pending.data.list.items.len == payload_length);
        if (!self.isConnected()) return .disconnected;
        try pending.prepareWrite();
        try self.queue.ensureUnusedCapacity(1);
        pending.callback = if (callback) |send_callback| send_callback.take() else null;
        self.queue.appendAssumeCapacity(pending.take());

        log("IPC call continueSend() from serializeAndSend", .{});
        self.continueSend(global, .new_message_appended);

        if (self.queue.items.len != 0) return .backoff;
        return .success;
    }
    fn debugLogMessageQueue(this: *SendQueue) void {
        if (!Environment.isDebug) return;
        log("IPC message queue ({d} items)", .{this.queue.items.len});
        for (this.queue.items) |item| {
            if (item.data.list.items.len > 100) {
                log(" {d}|{d}", .{ item.data.cursor, item.data.list.items.len - item.data.cursor });
            } else {
                log("  \"{f}\"|\"{f}\"", .{ std.zig.fmtString(item.data.list.items[0..item.data.cursor]), std.zig.fmtString(item.data.list.items[item.data.cursor..]) });
            }
        }
    }

    fn getSocket(this: *SendQueue) ?SocketType {
        return switch (this.socket) {
            .open => |s| s,
            else => return null,
        };
    }

    /// starts a write request. on posix, this always calls _onWriteComplete immediately. on windows, it may
    /// call _onWriteComplete later.
    fn _write(this: *SendQueue, data: []const u8) void {
        log("SendQueue#_write len {d}", .{data.len});
        const socket = this.getSocket() orelse {
            this.failTransport(bun.sys.Error.fromCode(.PIPE, .write));
            return;
        };
        const write_len = @min(data.len, std.math.maxInt(i32));
        this.write_length = write_len;
        return switch (Environment.isWindows) {
            true => {
                const pipe: *uv.Pipe = socket;
                const write_req = bun.take(&this.queue.items[0].windows_write).?;
                bun.assert(write_req.owner == null and write_req.pipe == null);
                write_req.owner = this;
                write_req.pipe = pipe;
                write_req.write_length = write_len;
                write_req.write_buffer = uv.uv_buf_t.init(data[0..write_len]);
                bun.assert(this.windows.windows_write == null);
                this.windows.windows_write = write_req;

                pipe.ref(); // ref on write
                if (this.windows.windows_write.?.write_req.write(pipe.asStream(), &this.windows.windows_write.?.write_buffer, write_req, &_windowsOnWriteComplete).asErr()) |err| {
                    _windowsOnWriteComplete(write_req, @fromBackingInt(@intCast(-@as(c_int, err.errno))));
                }
                // write request is queued. it will call _onWriteComplete when it completes.
            },
            false => {
                switch (socket.writeIPC(data[0..write_len])) {
                    .result => |written| this._onWriteComplete(written),
                    .err => |err| this.failTransport(err),
                }
            },
        };
    }
    fn _windowsOnWriteComplete(write_req: *WindowsWrite, status: uv.ReturnCode) void {
        log("SendQueue#_windowsOnWriteComplete", .{});
        const write_len = write_req.write_length;
        const pipe = bun.take(&write_req.pipe).?;
        pipe.unref();
        const this = bun.take(&write_req.owner) orelse {
            write_req.destroy();
            return;
        };
        bun.assert(this.windows.windows_write == write_req);
        this.windows.windows_write = null;
        bun.assert(this.queue.items.len != 0 and this.queue.items[0].windows_write == null);
        this.queue.items[0].windows_write = write_req;
        var owner_reference = this.retainOwner();
        defer if (owner_reference) |*owner| owner.deinit();

        const vm = jsc.VirtualMachine.get();
        vm.eventLoop().enter();
        defer vm.eventLoop().exit();

        if (status.toError(.write)) |err| {
            this.failTransport(err);
        } else {
            this._onWriteComplete(write_len);
        }

        if (this.windows.try_close_after_write) {
            this.closeSocket(.normal, .user);
        }
    }
    fn getGlobalThis(this: *SendQueue) *jsc.JSGlobalObject {
        return switch (this.owner) {
            inline else => |owner| owner.globalThis,
        };
    }

    pub fn windowsConfigureServer(this: *SendQueue, ipc_pipe: *uv.Pipe) bun.sys.Maybe(void) {
        log("configureServer", .{});
        ipc_pipe.data = this;
        ipc_pipe.unref();
        this.socket = .{ .open = ipc_pipe };
        this.windows.is_server = true;
        const pipe: *uv.Pipe = this.socket.open;
        pipe.data = this;

        const stream: *uv.uv_stream_t = pipe.asStream();

        const readStartResult = stream.readStart(this, IPCHandlers.WindowsNamedPipe.onReadAlloc, IPCHandlers.WindowsNamedPipe.onReadError, IPCHandlers.WindowsNamedPipe.onRead);
        if (readStartResult == .err) {
            this.closeSocket(.failure, .user);
            return readStartResult;
        }
        return .success;
    }

    pub fn windowsConfigureClient(this: *SendQueue, pipe_fd: bun.FD) !void {
        log("configureClient", .{});
        const ipc_pipe = try bun.default_allocator.create(uv.Pipe);
        ipc_pipe.* = std.mem.zeroes(uv.Pipe);
        ipc_pipe.init(uv.Loop.get(), true).unwrap() catch |err| {
            bun.destroy(ipc_pipe);
            return err;
        };
        ipc_pipe.open(pipe_fd).unwrap() catch |err| {
            ipc_pipe.closeAndDestroy();
            return err;
        };
        ipc_pipe.unref();
        this.socket = .{ .open = ipc_pipe };
        this.windows.is_server = false;

        const stream = ipc_pipe.asStream();

        stream.readStart(this, IPCHandlers.WindowsNamedPipe.onReadAlloc, IPCHandlers.WindowsNamedPipe.onReadError, IPCHandlers.WindowsNamedPipe.onRead).unwrap() catch |err| {
            this.closeSocket(.failure, .user);
            return err;
        };
    }
};

pub const FromEnum = enum { subprocess_exited, subprocess, process };

const BoundSendArguments = struct {
    message: bun.bindgen.BrandedValueView(ProcessSendSchema.overload_cases[0].args[0].ArgumentType.child.child),
    callback: ?IPCSendCallback,

    fn init(context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!BoundSendArguments {
        return switch (args) {
            inline else => |values, tag| .{
                .message = (try values.message.convert(context)).value orelse return context.fail(.missing_message, {}),
                .callback = switch (tag) {
                    .message_callback, .message_handle_callback => try values.callback.toOwned(),
                    .message_handle_options_callback => if (values.callback) |value| switch (value) {
                        .callback => |callback| try callback.toOwned(),
                        .ignored => null,
                    } else null,
                },
            },
        };
    }

    fn deinit(arguments: *BoundSendArguments) void {
        if (arguments.callback) |*callback| callback.deinit();
        arguments.callback = null;
    }
};

fn doSendErr(context: anytype, callback: ?*IPCSendCallback, reason: IPCSendFailure, from: FromEnum) bun.JSError!bool {
    if (callback) |function| {
        var invocation: IPCSendCallback.Invocation = undefined;
        function.beginInvocation(&invocation);
        defer invocation.deinit();
        var failure = try invocation.engineIn("IPC", "createSendError").call(.{ .reason = reason });
        defer failure.deinit();
        try invocation.schedule(.{ .@"error" = failure.operand(&invocation) });
        return false;
    }
    var failure = try context.engineIn("IPC", "createSendError").call(.{ .reason = reason });
    defer failure.deinit();
    if (from == .process) {
        try context.engineIn("NodeCluster", "scheduleProcessErrorEvent").call(.{ .errorValue = failure.operand(context).asEngine() });
        return false;
    }
    return failure.throwException(context);
}

fn disconnectedSend(context: anytype, callback: ?*IPCSendCallback, from: FromEnum) bun.JSError!bool {
    return doSendErr(context, callback, switch (from) {
        .process => .process_channel_closed,
        .subprocess => .subprocess_channel_closed,
        .subprocess_exited => .subprocess_exited,
    }, from);
}

fn doSend(context: anytype, ipc: ?*SendQueue, arguments: *BoundSendArguments, from: FromEnum) bun.JSError!bool {
    const message = arguments.message;
    const callback: ?*IPCSendCallback = if (arguments.callback) |*value| value else null;

    const connected = ipc != null and ipc.?.isConnected();
    if (!connected) return disconnectedSend(context, callback, from);

    const ipc_data = ipc.?;

    const status = try ipc_data.serializeAndSend(
        context,
        message,
        .external,
        callback,
    );

    if (status == .disconnected) return disconnectedSend(context, callback, from);

    if (status == .failure) {
        return doSendErr(context, callback, .write_failed, from);
    }

    // in the success or backoff case, serializeAndSend will handle calling the callback
    return status == .success;
}

pub fn processSendFromBinding(context: anytype, args: bun.bindgen.Args(ProcessSendSchema)) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    const global = context.viewToken().globalObject();
    var bound_arguments = try BoundSendArguments.init(context, args);
    defer bound_arguments.deinit();
    const vm = global.bunVM();
    return doSend(context, if (try vm.getIPCInstance()) |ipc| &ipc.data else null, &bound_arguments, .process);
}

pub fn subprocessSend(
    context: bun.bindgen.CallContext(SubprocessSendSchema),
    subprocess: *jsc.Subprocess,
    args: bun.bindgen.Args(SubprocessSendSchema),
) bun.bindgen.CallError(SubprocessSendSchema)!bun.bindgen.Return(SubprocessSendSchema) {
    var bound_arguments = try BoundSendArguments.init(context, args);
    defer bound_arguments.deinit();
    return doSend(
        context,
        if (subprocess.ipc_data) |*ipc| ipc else null,
        &bound_arguments,
        if (subprocess.hasExited()) .subprocess_exited else .subprocess,
    );
}

pub fn sendHelperChild(context: anytype, args: bun.bindgen.Args(SendHelperChildSchema)) bun.JSError!bun.bindgen.Return(SendHelperChildSchema) {
    const global = context.viewToken().globalObject();
    const ipc = (try global.bunVM().getIPCInstance()) orelse return .unavailable;
    return switch (try ipc.data.serializeAndSend(context, args.message, .internal, null)) {
        .success => .success,
        .backoff => .backoff,
        .failure => .failure,
        .disconnected => .unavailable,
    };
}

pub fn sendHelperPrimary(context: anytype, args: bun.bindgen.Args(SendHelperPrimarySchema)) bun.JSError!bun.bindgen.Return(SendHelperPrimarySchema) {
    const subprocess = args.subprocess.get(jsc.Subprocess.JSBinding).subprocess.get();
    const ipc = subprocess.ipc() orelse return .unavailable;
    return switch (try ipc.serializeAndSend(context, args.message, .internal, null)) {
        .success => .success,
        .backoff => .backoff,
        .failure => .failure,
        .disconnected => .unavailable,
    };
}

pub fn setChannelRef(enabled: bool) void {
    const vm = jsc.VirtualMachine.get();
    vm.channel_ref_overridden = true;
    if (enabled) vm.channel_ref.ref(vm) else vm.channel_ref.unref(vm);
}

pub fn markChannelIgnoreOneDisconnectEventListener() bool {
    jsc.VirtualMachine.get().channel_ref_should_ignore_one_disconnect_event_listener = true;
    return false;
}

pub fn refChannelUnlessOverridden(globalThis: *jsc.JSGlobalObject) void {
    const vm = globalThis.bunVM();
    if (!vm.channel_ref_overridden) vm.channel_ref.ref(vm);
}

pub fn unrefChannelUnlessOverridden(globalThis: *jsc.JSGlobalObject) void {
    const vm = globalThis.bunVM();
    if (!vm.channel_ref_overridden) vm.channel_ref.unref(vm);
}

pub fn shouldIgnoreOneDisconnectEventListener(globalThis: *jsc.JSGlobalObject) bool {
    return globalThis.bunVM().channel_ref_should_ignore_one_disconnect_event_listener;
}

pub fn ensureProcessIPCInitialized(globalThis: *jsc.JSGlobalObject) bun.OOM!void {
    _ = try globalThis.bunVM().getIPCInstance();
}

pub fn closeChildIPC(globalThis: *jsc.JSGlobalObject) bun.OOM!void {
    if (try globalThis.bunVM().getIPCInstance()) |current_ipc| {
        current_ipc.data.closeSocketNextTick(true);
    }
}

fn handleIPCMessage(send_queue: *SendQueue, message: *const DecodedIPCMessage, globalThis: *jsc.JSGlobalObject) void {
    log("Received IPC message: {s}", .{@tagName(message.*)});
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(globalThis);
    defer scope.deinit();
    const internal_command = if (message.* == .data)
        scope.engine(ClassifyIncomingCommandShim).call(.{
            .message = message.data.operand(&scope).asEngine(),
        }) catch |err| {
            send_queue.closeSocket(.failure, .deinit);
            return globalThis.reportActiveExceptionAsUnhandled(err);
        }
    else
        .message;
    if (send_queue.socket != .open) return;

    if (internal_command != .message) {
        switch (internal_command) {
            .handle => {
                var received_fd = bun.take(&send_queue.incoming_fd);
                defer if (received_fd) |fd| fd.close();
                const ack = received_fd != null;

                var response: PendingMessage = .{};
                defer response.deinit();
                writeHandleReply(send_queue.mode, &response.data, &scope, ack) catch |err| {
                    send_queue.closeSocket(.failure, .deinit);
                    return globalThis.reportActiveExceptionAsUnhandled(err);
                };

                // Insert at appropriate position in send queue
                send_queue.insertMessage(&response) catch |err| {
                    send_queue.closeSocket(.failure, .deinit);
                    return globalThis.reportActiveExceptionAsUnhandled(err);
                };

                // Send if needed
                log("IPC call continueSend() from handleIPCMessage", .{});
                send_queue.continueSend(globalThis, .new_message_appended);

                if (!ack) return;

                const fd: bun.FD = bun.take(&received_fd).?;
                fd.close();
                var error_message = bun.bindgen.DOMString.fromUTF8("Receiving handles over IPC is not supported") catch |err|
                    return globalThis.reportActiveExceptionAsUnhandled(err);
                defer error_message.deinit();
                scope.engineIn("ErrorCode", "throw").call(.{
                    .code = .ERR_METHOD_NOT_IMPLEMENTED,
                    .message = error_message.operand(),
                }) catch |err| globalThis.reportActiveExceptionAsUnhandled(err);
            },
            .ack, .nack => return,
            .message => unreachable,
        }
    } else {
        switch (send_queue.owner) {
            inline else => |owner| {
                owner.handleIPCMessage(message);
            },
        }
    }
}

fn onData2(send_queue: *SendQueue, all_data: []const u8) void {
    if (send_queue.socket != .open) return;
    const globalThis = send_queue.getGlobalThis();
    const incoming = send_queue.ensureIncoming() catch |err| return failReceive(send_queue, globalThis, err);
    incoming.buffer.append(bun.default_allocator, all_data) catch |err| return failReceive(send_queue, globalThis, err);
    dispatchIncoming(send_queue, incoming);
}

fn failReceive(send_queue: *SendQueue, global: *JSGlobalObject, err: IPCDecodeError) void {
    send_queue.closeSocket(.failure, .user);
    switch (err) {
        error.NotEnoughBytes, error.InvalidFormat => {},
        else => |js_error| global.reportActiveExceptionAsUnhandled(js_error),
    }
}

fn dispatchIncoming(send_queue: *SendQueue, incoming: *ReceiveState) void {
    if (incoming.closed or incoming.dispatching) return;
    incoming.ref();
    defer incoming.deref();
    incoming.dispatching = true;
    defer incoming.dispatching = false;
    const global = send_queue.getGlobalThis();
    const mode = send_queue.mode;
    while (!incoming.closed) {
        const frame = (incoming.buffer.next(mode) catch |err| return failReceive(send_queue, global, err)) orelse return;
        var result = decodeIPCMessage(mode, frame.bytes, global, frame.newline_pos) catch |err|
            return failReceive(send_queue, global, err);
        defer result.message.deinit();
        bun.assert(result.bytes_consumed == frame.bytes.len);
        incoming.buffer.consume(bun.default_allocator, result.bytes_consumed);
        handleIPCMessage(send_queue, &result.message, global);
    }
}

/// Used on POSIX
pub const IPCHandlers = struct {
    pub const PosixSocket = struct {
        pub fn onOpen(
            _: *anyopaque,
            _: Socket,
        ) void {
            log("onOpen", .{});
        }

        pub fn onClose(
            send_queue: *SendQueue,
            _: Socket,
            _: c_int,
            _: ?*anyopaque,
        ) void {
            // uSockets has already freed the underlying socket
            log("NewSocketIPCHandler#onClose\n", .{});
            send_queue._socketClosed();
        }

        pub fn onData(
            send_queue: *SendQueue,
            _: Socket,
            all_data: []const u8,
        ) void {
            var owner_reference = send_queue.retainOwner();
            defer if (owner_reference) |*owner| owner.deinit();
            const globalThis = send_queue.getGlobalThis();
            const loop = globalThis.bunVM().eventLoop();
            loop.enter();
            defer loop.exit();
            onData2(send_queue, all_data);
        }

        pub fn onFd(
            send_queue: *SendQueue,
            _: Socket,
            fd: c_int,
        ) void {
            // SCM_RIGHTS is POSIX-only; on Windows this arm is unreachable but
            // still type-checked, and `FD.fromNative` takes `*anyopaque` there.
            if (comptime bun.Environment.isWindows) return;
            log("onFd: {d}", .{fd});
            if (send_queue.socket != .open or send_queue.incoming_fd != null) {
                bun.FD.fromNative(fd).close();
                send_queue.closeSocket(.failure, .deinit);
                return;
            }
            send_queue.incoming_fd = bun.FD.fromNative(fd);
        }

        pub fn onWritable(
            send_queue: *SendQueue,
            _: Socket,
        ) void {
            log("onWritable", .{});
            var owner_reference = send_queue.retainOwner();
            defer if (owner_reference) |*owner| owner.deinit();

            const globalThis = send_queue.getGlobalThis();
            const loop = globalThis.bunVM().eventLoop();
            loop.enter();
            defer loop.exit();
            log("IPC call continueSend() from onWritable", .{});
            send_queue.continueSend(globalThis, .on_writable);
        }

        pub fn onTimeout(
            _: *SendQueue,
            _: Socket,
        ) void {
            log("onTimeout", .{});
            // unref if needed
        }

        pub fn onLongTimeout(
            _: *SendQueue,
            _: Socket,
        ) void {
            log("onLongTimeout", .{});
            // onLongTimeout
        }

        pub fn onConnectError(
            send_queue: *SendQueue,
            _: Socket,
            _: uws.ConnectFailure,
        ) void {
            log("onConnectError", .{});
            // context has not been initialized
            send_queue.closeSocket(.failure, .user);
        }

        pub fn onEnd(
            send_queue: *SendQueue,
            _: Socket,
        ) void {
            log("onEnd", .{});
            send_queue.failTransport(bun.sys.Error.fromCode(.PIPE, .write));
        }
    };

    pub const WindowsNamedPipe = struct {
        fn onReadAlloc(send_queue: *SendQueue, suggested_size: usize) []u8 {
            if (send_queue.socket != .open) return &.{};
            const incoming = send_queue.ensureIncoming() catch return &.{};
            return incoming.buffer.reserve(bun.default_allocator, suggested_size) catch &.{};
        }

        fn onReadError(send_queue: *SendQueue, err: bun.sys.E) void {
            log("NewNamedPipeIPCHandler#onReadError {}", .{err});
            send_queue.failTransport(bun.sys.Error.fromCode(if (err == .EOF) .PIPE else err, .write));
        }

        fn onRead(send_queue: *SendQueue, buffer: []const u8) void {
            log("NewNamedPipeIPCHandler#onRead {d}", .{buffer.len});
            if (send_queue.socket != .open) return;
            var owner_reference = send_queue.retainOwner();
            defer if (owner_reference) |*owner| owner.deinit();
            const incoming = send_queue.incoming orelse return;
            bun.assert(buffer.ptr == incoming.buffer.data.unusedCapacitySlice().ptr);
            incoming.buffer.commit(buffer.len);
            const globalThis = send_queue.getGlobalThis();
            const loop = globalThis.bunVM().eventLoop();
            loop.enter();
            defer loop.exit();

            dispatchIncoming(send_queue, incoming);
        }

        pub fn onClose(send_queue: *SendQueue) void {
            log("NewNamedPipeIPCHandler#onClose\n", .{});
            // Currently unreferenced (only onReadAlloc/onReadError/onRead are
            // wired into readStart), but route through `_socketClosed` so any
            // future wiring tracks the `_onAfterIPCClosed` task for `deinit`
            // to cancel, matching every other close path.
            send_queue._socketClosed();
        }
    };
};

const string = []const u8;

const NodeClusterEngine = @import("../runtime/node/NodeClusterEngine.zig");
const std = @import("std");
const IPCBuffer = @import("../io/IPCBuffer.zig");

const bun = @import("bun");
const IPCBindings = bun.bindgen.Module("IPC");
const NodeClusterBindings = bun.bindgen.Module("NodeCluster");
const ProcessBindings = bun.bindgen.Module("Process");
const SubprocessBindings = bun.bindgen.Module("Subprocess");
const ClassifyIncomingCommandShim = IPCBindings.engineShim("classifyIncomingCommand");
const ParseJSONMessageShim = IPCBindings.engineShim("parseJSONMessage");
const ProcessSendSchema = ProcessBindings.function("send");
const SubprocessSendSchema = SubprocessBindings.class("Subprocess").member("send");
const SendHelperChildSchema = NodeClusterBindings.function("sendHelperChild");
const SendHelperPrimarySchema = NodeClusterBindings.function("sendHelperPrimary");
const SetRefSchema = NodeClusterBindings.function("setRef");
const ChannelIgnoreOneDisconnectEventListenerSchema = NodeClusterBindings.function("channelIgnoreOneDisconnectEventListener");
const RefChannelUnlessOverriddenSchema = NodeClusterBindings.nativeExport("refChannelUnlessOverridden");
const UnrefChannelUnlessOverriddenSchema = NodeClusterBindings.nativeExport("unrefChannelUnlessOverridden");
const ShouldIgnoreOneDisconnectEventListenerSchema = NodeClusterBindings.nativeExport("shouldIgnoreOneDisconnectEventListener");
const IPCSendCallbackType = bun.bindgen.CallbackSchema("NodeIPCSendCallback");
const IPCSendCallback = bun.bindgen.Callback(IPCSendCallbackType);
const Environment = bun.Environment;
const Output = bun.Output;
const strings = bun.strings;
const uws = bun.uws;
const uv = bun.windows.libuv;

const jsc = bun.jsc;
const CancellableTask = @import("../event_loop/CancellableTask.zig");
const JSGlobalObject = jsc.JSGlobalObject;

const CreateSendErrorSchema = IPCBindings.engineShim("createSendError");
const IPCSendFailure = @FieldType(bun.bindgen.Args(CreateSendErrorSchema), "reason");
