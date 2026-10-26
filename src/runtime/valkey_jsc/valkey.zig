// Entry point for Valkey client
//
// This file contains the core Valkey client implementation with protocol handling

pub const ValkeyContext = @import("./ValkeyContext.zig");

/// Connection flags to track Valkey client state
pub const ConnectionFlags = struct {
    // TODO(markovejnovic): I am not a huge fan of these flags. I would
    // consider refactoring them into an enumerated state machine, as that
    // feels significantly more natural compared to a bag of booleans.
    is_authenticated: bool = false,
    is_manually_closed: bool = false,
    is_selecting_db_internal: bool = false,
    enable_offline_queue: bool = true,
    needs_to_open_socket: bool = true,
    enable_auto_reconnect: bool = true,
    is_reconnecting: bool = false,
    failed: bool = false,
    enable_auto_pipelining: bool = true,
    finalized: bool = false,
};

/// Valkey connection status
pub const Status = enum {
    disconnected,
    connecting,
    connected,
};

pub fn isActive(this: *const Status) bool {
    return switch (this.*) {
        .connected, .connecting => true,
        else => false,
    };
}

pub const Command = @import("./ValkeyCommand.zig");

/// Valkey protocol types (standalone, TLS, Unix socket)
pub const Protocol = enum {
    standalone,
    standalone_unix,
    standalone_tls,
    standalone_tls_unix,

    pub const Map = bun.ComptimeStringMap(Protocol, .{
        .{ "valkey", .standalone },
        .{ "valkeys", .standalone_tls },
        .{ "valkey+tls", .standalone_tls },
        .{ "valkey+unix", .standalone_unix },
        .{ "valkey+tls+unix", .standalone_tls_unix },
        .{ "redis", .standalone },
        .{ "rediss", .standalone_tls },
        .{ "redis+tls", .standalone_tls },
        .{ "redis+unix", .standalone_unix },
        .{ "redis+tls+unix", .standalone_tls_unix },
    });

    pub fn isTLS(self: Protocol) bool {
        return switch (self) {
            .standalone_tls, .standalone_tls_unix => true,
            else => false,
        };
    }
};

pub const TLS = union(enum) {
    none,
    enabled,
    custom: SSLConfig,

    pub fn clone(this: *const TLS) bun.OOM!TLS {
        return switch (this.*) {
            .custom => |*ssl_config| .{ .custom = try ssl_config.clone() },
            else => this.*,
        };
    }

    pub fn deinit(this: *TLS) void {
        switch (this.*) {
            .custom => |*ssl_config| ssl_config.deinit(),
            else => {},
        }
    }

    pub fn rejectUnauthorized(this: *const TLS, default_value: bool) bool {
        return switch (this.*) {
            .custom => |*ssl_config| ssl_config.reject_unauthorized != 0,
            .enabled => default_value,
            else => false,
        };
    }
};

/// Connection options for Valkey client
pub const Options = struct {
    idle_timeout_ms: u32 = 0,
    connection_timeout_ms: u32 = 10000,
    enable_auto_reconnect: bool = true,
    max_retries: u32 = 20,
    enable_offline_queue: bool = true,
    enable_auto_pipelining: bool = true,

    tls: TLS = .none,
};

pub const Address = union(enum) {
    unix: []const u8,
    host: struct {
        host: []const u8,
        port: u16,
    },

    pub fn hostname(this: *const Address) []const u8 {
        return switch (this.*) {
            .unix => |unix_addr| unix_addr,
            .host => |h| h.host,
        };
    }
};

/// Core Valkey client implementation
pub fn ValkeyClient(comptime Integration: type) type {
    const Implementation = struct {
        const Self = @This();

        socket: uws.AnySocket,
        status: Status = Status.connecting,

        // Buffer management
        write_buffer: bun.OffsetByteList = .{},
        read_buffer: bun.OffsetByteList = .{},
        writer_state: std.Io.Writer = .{ .vtable = &.{ .drain = writerDrain }, .buffer = &.{} },
        writer_error: ?protocol.RedisError = null,

        /// In-flight commands, after the data has been written to the network socket
        in_flight: Command.InFlight.Queue,

        /// Commands that are waiting to be sent to the server. When pipelining is implemented, this usually will be empty.
        queue: Command.Entry.Queue,

        // Connection parameters
        password: []const u8 = "",
        username: []const u8 = "",
        database: u32 = 0,
        address: Address,
        protocol: Protocol,

        connection_strings: []u8 = &.{},

        // TLS support
        tls: TLS = .none,

        // Timeout and reconnection management
        idle_timeout_interval_ms: u32 = 0,
        connection_timeout_ms: u32 = 0,
        retry_attempts: u32 = 0,
        max_retries: u32 = 20, // Maximum retry attempts

        flags: ConnectionFlags = .{},
        allocator: std.mem.Allocator,

        // Auto-pipelining
        auto_flusher: AutoFlusher = .{},

        /// Clean up resources used by the Valkey client
        pub fn deinit(this: *Self) void {
            var pending = this.in_flight;
            this.in_flight = .init(this.allocator);
            defer pending.deinit();
            var commands = this.queue;
            this.queue = .init(this.allocator);
            defer commands.deinit();

            for (@constCast(pending.readableSlice(0))) |*pair| {
                pair.completion.release();
            }

            for (@constCast(commands.readableSlice(0))) |*command| {
                command.completion.release();
                command.deinit(this.allocator);
            }

            this.allocator.free(this.connection_strings);
            // Note there is no need to deallocate username, password and hostname since they are
            // within the this.connection_strings buffer.
            this.write_buffer.deinit(this.allocator);
            this.read_buffer.deinit(this.allocator);
            this.tls.deinit();
            this.unregisterAutoFlusher();
        }

        // ** Auto-pipelining **
        fn registerAutoFlusher(this: *Self) void {
            Integration.registerAutoFlusher(this, &this.auto_flusher);
        }

        fn unregisterAutoFlusher(this: *Self) void {
            Integration.unregisterAutoFlusher(this, &this.auto_flusher);
        }

        // Drain auto-pipelined commands
        pub fn onAutoFlush(this: *Self) bool {
            if (this.status != .connected) {
                return false;
            }
            if (this.in_flight.readableLength() > 0 and
                !this.in_flight.peekItem(0).meta.supports_auto_pipelining)
            {
                return false;
            }

            this.ref();
            defer this.deref();

            var total_bytelength: usize = 0;

            const pipelineable_commands: []Command.Entry = brk: {
                var to_process = @constCast(this.queue.readableSlice(0));
                var total: usize = 0;
                for (to_process) |*command| {
                    if (!command.meta.supports_auto_pipelining) {
                        break;
                    }
                    total += 1;
                    total_bytelength = std.math.add(usize, total_bytelength, command.serialized_data.len) catch {
                        this.outOfMemoryQueued(total);
                        return this.queue.readableLength() > 0;
                    };
                }
                break :brk to_process[0..total];
            };

            if (pipelineable_commands.len == 0) {
                this.unregisterAutoFlusher();
                if (this.in_flight.readableLength() == 0) _ = this.drain();
                return false;
            }

            this.in_flight.ensureUnusedCapacity(pipelineable_commands.len) catch {
                this.outOfMemoryQueued(pipelineable_commands.len);
                return this.queue.readableLength() > 0;
            };
            if (total_bytelength > @as(usize, std.math.maxInt(u32) - this.write_buffer.byte_list.len)) {
                this.outOfMemoryQueued(pipelineable_commands.len);
                return this.queue.readableLength() > 0;
            }
            this.write_buffer.byte_list.ensureUnusedCapacity(this.allocator, total_bytelength) catch {
                this.outOfMemoryQueued(pipelineable_commands.len);
                return this.queue.readableLength() > 0;
            };

            const output = this.write_buffer.byte_list.writableSlice(this.allocator, total_bytelength) catch unreachable;
            var output_offset: usize = 0;
            for (pipelineable_commands) |*command| {
                this.in_flight.writeItemAssumeCapacity(.{
                    .meta = command.meta,
                    .completion = command.completion,
                });
                @memcpy(output[output_offset..][0..command.serialized_data.len], command.serialized_data);
                output_offset += command.serialized_data.len;
                this.allocator.free(command.serialized_data);
            }

            this.queue.discard(pipelineable_commands.len);

            _ = this.flushData();

            const have_more = this.queue.readableLength() > 0;

            // Return true if we should schedule another flush
            return have_more;
        }

        fn outOfMemoryQueued(this: *Self, count: usize) void {
            const commands = @constCast(this.queue.readableSlice(0))[0..count];
            for (commands) |*command| {
                command.completion.outOfMemory();
                command.deinit(this.allocator);
            }
            this.queue.discard(count);
        }
        // ** End of auto-pipelining **

        /// Get the appropriate timeout interval based on connection state
        pub fn getTimeoutInterval(this: *const Self) u32 {
            if (this.flags.failed) return 0;
            return switch (this.status) {
                .connected => this.idle_timeout_interval_ms,
                else => this.connection_timeout_ms,
            };
        }

        pub fn hasAnyPendingCommands(this: *const Self) bool {
            return this.in_flight.readableLength() > 0 or
                this.queue.readableLength() > 0 or
                this.write_buffer.len() > 0 or
                this.read_buffer.len() > 0;
        }

        /// Calculate reconnect delay with exponential backoff
        pub fn getReconnectDelay(this: *const Self) u32 {
            const base_delay: u32 = 50; // Base delay in ms
            const max_delay: u32 = 2000; // Max delay in ms

            // Fixed backoff calculation to avoid integer overflow
            if (this.retry_attempts == 0) return base_delay;

            // Cap at 10 attempts for backoff calculation to avoid overflow
            const attempt = @min(this.retry_attempts, 10);

            // Use a safer exponential backoff calculation
            var delay: u32 = base_delay;
            var i: u32 = 1;
            while (i < attempt) : (i += 1) {
                // Double the delay up to max_delay
                delay = @min(delay * 2, max_delay);
            }

            return delay;
        }

        fn failAllPendingCommands(
            pending_ptr: *Command.InFlight.Queue,
            entries_ptr: *Command.Entry.Queue,
            allocator: std.mem.Allocator,
            failure: Completion.CommandFailure,
        ) void {
            var pending = pending_ptr.*;
            var entries = entries_ptr.*;
            defer pending.deinit();
            defer entries.deinit();
            pending_ptr.* = .init(allocator);
            entries_ptr.* = .init(allocator);

            for (@constCast(pending.readableSlice(0))) |*item| {
                failure.apply(&item.completion);
            }

            for (@constCast(entries.readableSlice(0))) |*item| {
                failure.apply(&item.completion);
                item.deinit(allocator);
            }
        }

        /// Flush pending data to the socket
        pub fn flushData(this: *Self) bool {
            const chunk = this.write_buffer.remaining();
            if (chunk.len == 0) return false;
            const wrote = this.socket.write(chunk);
            if (wrote > 0) {
                this.write_buffer.consume(@intCast(wrote));
            }
            const has_remaining = this.write_buffer.len() > 0;
            return has_remaining;
        }

        /// Mark the connection as failed with error message
        pub fn fail(this: *Self, message: []const u8, err: protocol.RedisError) void {
            debug("failed: {s}: {}", .{ message, err });
            this.failWith(.{ .protocol = .{ .kind = err, .message = message } });
        }

        pub fn failWith(this: *Self, failure: Completion.CommandFailure) void {
            if (this.flags.failed) return;

            if (this.flags.finalized) {
                bun.debugAssert(this.queue.count + this.in_flight.count == 0);
                return;
            }

            this.flags.failed = true;
            failAllPendingCommands(&this.in_flight, &this.queue, this.allocator, failure);

            if (!this.connectionReady()) {
                this.flags.is_manually_closed = true;
                this.close();
            }
        }

        pub fn close(this: *Self) void {
            const socket = this.socket;
            this.socket = .{ .SocketTCP = .detached };
            socket.close();
        }

        /// Handle connection closed event
        pub fn onClose(this: *Self) Integration.Error!void {
            this.unregisterAutoFlusher();
            this.write_buffer.clearAndFree(this.allocator);

            // If manually closing, don't attempt to reconnect
            if (this.flags.is_manually_closed) {
                debug("skip reconnecting since the connection is manually closed", .{});
                this.fail("Connection closed", protocol.RedisError.ConnectionClosed);
                try this.onValkeyClose();
                return;
            }

            // If auto reconnect is disabled, just fail
            if (!this.flags.enable_auto_reconnect) {
                debug("skip reconnecting since auto reconnect is disabled", .{});
                this.fail("Connection closed", protocol.RedisError.ConnectionClosed);
                try this.onValkeyClose();
                return;
            }

            // Calculate reconnection delay with exponential backoff
            this.retry_attempts += 1;
            const delay_ms = this.getReconnectDelay();

            if (delay_ms == 0 or this.retry_attempts > this.max_retries) {
                debug("Max retries reached or retry strategy returned 0, giving up reconnection", .{});
                this.fail("Max reconnection attempts reached", protocol.RedisError.ConnectionClosed);
                try this.onValkeyClose();
                return;
            }

            debug("reconnect in {d}ms (attempt {d}/{d})", .{ delay_ms, this.retry_attempts, this.max_retries });

            this.flags.is_reconnecting = true;
            this.flags.is_authenticated = false;
            this.flags.is_selecting_db_internal = false;

            // Signal reconnect timer should be started
            this.onValkeyReconnect();
        }

        pub fn sendNextCommand(this: *Self) void {
            if (this.write_buffer.remaining().len == 0 and this.connectionReady()) {
                if (this.queue.readableLength() > 0) {
                    const flags = &this.queue.peekItem(0).meta;
                    if (flags.supports_auto_pipelining and this.flags.enable_auto_pipelining) {
                        this.registerAutoFlusher();
                    } else if (this.in_flight.readableLength() == 0) {
                        _ = this.drain();
                        if (this.in_flight.readableLength() == 0 and
                            this.queue.readableLength() > 0 and
                            this.queue.peekItem(0).meta.supports_auto_pipelining and
                            this.flags.enable_auto_pipelining)
                        {
                            this.registerAutoFlusher();
                        }
                    }
                } else if (this.in_flight.readableLength() == 0) {
                    _ = this.drain();
                }
            }

            _ = this.flushData();
        }

        fn appendWriteBufferAssumeCapacity(this: *Self, data: []const u8) void {
            const output = this.write_buffer.byte_list.writableSlice(this.allocator, data.len) catch unreachable;
            @memcpy(output, data);
        }

        fn outOfMemoryHead(this: *Self) void {
            var command = this.queue.readItem() orelse return;
            command.completion.outOfMemory();
            command.deinit(this.allocator);
        }

        /// Process queued commands in the offline queue
        pub fn drain(this: *Self) bool {
            while (true) {
                if (this.in_flight.readableLength() > 0) {
                    const queue_slice = this.queue.readableSlice(0);
                    if (queue_slice.len > 0 and
                        (!queue_slice[0].meta.supports_auto_pipelining or !this.flags.enable_auto_pipelining))
                    {
                        return false;
                    }
                }

                const entry = this.queue.readableSlice(0);
                if (entry.len == 0) return false;
                const data_length = entry[0].serialized_data.len;

                this.in_flight.ensureUnusedCapacity(1) catch {
                    this.outOfMemoryHead();
                    continue;
                };
                if (data_length > @as(usize, std.math.maxInt(u32) - this.write_buffer.byte_list.len)) {
                    this.outOfMemoryHead();
                    continue;
                }
                this.write_buffer.byte_list.ensureUnusedCapacity(this.allocator, data_length) catch {
                    this.outOfMemoryHead();
                    continue;
                };

                const command = this.queue.readItem().?;
                const data = command.serialized_data;
                this.in_flight.writeItemAssumeCapacity(.{
                    .meta = command.meta,
                    .completion = command.completion,
                });

                if (this.connectionReady() and this.write_buffer.remaining().len == 0) {
                    defer this.allocator.free(data);
                    const wrote = this.socket.write(data);
                    const written: usize = if (wrote > 0) @min(@as(usize, @intCast(wrote)), data.len) else 0;
                    const unwritten = data[written..];
                    if (unwritten.len > 0) this.appendWriteBufferAssumeCapacity(unwritten);
                    return true;
                }

                this.appendWriteBufferAssumeCapacity(data);
                this.allocator.free(data);
                return true;
            }
        }

        pub fn onWritable(this: *Self) void {
            this.ref();
            defer this.deref();

            this.sendNextCommand();
        }

        fn enqueue(
            this: *Self,
            command: *const Command,
            completion: Completion.ResponseCompletions.Owned,
        ) bool {
            var entry = Command.Entry.create(this.allocator, command, completion) catch {
                var failed = completion;
                failed.outOfMemory();
                return false;
            };
            this.queue.ensureUnusedCapacity(1) catch {
                entry.completion.outOfMemory();
                entry.deinit(this.allocator);
                return false;
            };
            this.queue.writeItemAssumeCapacity(entry);

            if (this.status == .connected) this.sendNextCommand();
            return true;
        }

        pub fn send(
            this: *Self,
            command: *const Command,
            completion: Completion.ResponseCompletions.Owned,
        ) bool {
            var checked_command = command.*;
            checked_command.meta = command.meta.check(command);

            if (this.flags.failed) {
                var failed = completion;
                Completion.fail(&failed, error.ConnectionClosed, "Connection has failed");
                return false;
            }

            return switch (this.status) {
                .connected => this.enqueue(&checked_command, completion),
                .connecting, .disconnected => {
                    if (this.flags.enable_offline_queue) {
                        return this.enqueue(&checked_command, completion);
                    } else {
                        var failed = completion;
                        Completion.fail(
                            &failed,
                            error.ConnectionClosed,
                            "Connection is closed and offline queue is disabled",
                        );
                        return false;
                    }
                },
            };
        }

        /// Process data received from socket
        ///
        /// Caller refs / derefs.
        pub fn onData(this: *Self, data: []const u8) void {
            debug("Low-level onData called with {d} bytes: {s}", .{ data.len, data });
            // Path 1: Buffer already has data, append and process from buffer
            if (this.read_buffer.remaining().len > 0) {
                this.read_buffer.write(this.allocator, data) catch {
                    this.fail("Failed to buffer partial response", error.OutOfMemory);
                    return;
                };

                // Process as many complete messages from the buffer as possible
                while (true) {
                    const remaining_buffer = this.read_buffer.remaining();
                    if (remaining_buffer.len == 0) {
                        break; // Buffer processed completely
                    }

                    var reader = protocol.ValkeyReader.init(remaining_buffer);
                    const before_read_pos = reader.pos;

                    var value = reader.readValue(this.allocator) catch |err| {
                        if (err == error.InvalidResponse) {
                            // Need more data in the buffer, wait for next onData call
                            if (comptime bun.Environment.allow_assert) {
                                debug("read_buffer: needs more data ({d} bytes available)", .{remaining_buffer.len});
                            }
                            return;
                        } else {
                            this.fail("Failed to read data (buffer path)", err);
                            return;
                        }
                    };
                    defer value.deinit(this.allocator);

                    const bytes_consumed = reader.pos - before_read_pos;
                    if (bytes_consumed == 0 and remaining_buffer.len > 0) {
                        this.fail("Parser consumed 0 bytes unexpectedly (buffer path)", error.InvalidResponse);
                        return;
                    }

                    this.read_buffer.consume(@truncate(bytes_consumed));

                    this.handleResponse(&value);

                    if (this.status == .disconnected or this.flags.failed) {
                        return;
                    }
                    this.sendNextCommand();
                }
                return; // Finished processing buffered data for now
            }

            // Path 2: Buffer is empty, try processing directly from stack 'data'
            var current_data_slice = data; // Create a mutable view of the incoming data
            while (current_data_slice.len > 0) {
                var reader = protocol.ValkeyReader.init(current_data_slice);
                const before_read_pos = reader.pos;

                var value = reader.readValue(this.allocator) catch |err| {
                    if (err == error.InvalidResponse) {
                        // Partial message encountered on the stack-allocated path.
                        // Copy the *remaining* part of the stack data to the heap buffer
                        // and wait for more data.
                        if (comptime bun.Environment.allow_assert) {
                            debug("read_buffer: partial message on stack ({d} bytes), switching to buffer", .{current_data_slice.len - before_read_pos});
                        }
                        this.read_buffer.write(this.allocator, current_data_slice[before_read_pos..]) catch {
                            this.fail("Failed to buffer partial response", error.OutOfMemory);
                            return;
                        };
                        return; // Exit onData, next call will use the buffer path
                    } else {
                        // Any other error is fatal
                        this.fail("Failed to read data (stack path)", err);
                        return;
                    }
                };
                // Successfully read a full message from the stack data
                defer value.deinit(this.allocator);

                const bytes_consumed = reader.pos - before_read_pos;
                if (bytes_consumed == 0) {
                    // This case should ideally not happen if readValue succeeded and slice wasn't empty
                    this.fail("Parser consumed 0 bytes unexpectedly (stack path)", error.InvalidResponse);
                    return;
                }

                // Advance the view into the stack data slice for the next iteration
                current_data_slice = current_data_slice[bytes_consumed..];

                // Handle the successfully parsed response
                this.handleResponse(&value);

                // Check connection status after handling
                if (this.status == .disconnected or this.flags.failed) {
                    return;
                }

                // After handling a response, try to send the next command
                this.sendNextCommand();

                // Loop continues with the remainder of current_data_slice
            }

            // If the loop finishes, the entire 'data' was processed without needing the buffer.
        }

        /// Try handling this response as a subscriber-state response.
        /// Returns `handled` if we handled it, `fallthrough` if we did not.
        fn handleSubscribeResponse(
            this: *Self,
            value: *protocol.RESPValue,
            pair: ?*ValkeyCommand.InFlight,
        ) enum { handled, fallthrough } {
            debug("Handling a subscribe response: {f}", .{value.*});

            return switch (value.*) {
                .Error => |message| {
                    if (pair) |p| {
                        Completion.fail(&p.completion, error.InvalidResponse, message);
                    }
                    return .handled;
                },
                .Push => |push| {
                    const sub_count = Integration.subscriptionCount(this);

                    if (protocol.SubscriptionPushMessage.map.get(push.kind)) |msg_type| {
                        switch (msg_type) {
                            .message => {
                                this.onValkeyMessage(push.data);
                                return .handled;
                            },
                            .subscribe => {
                                Integration.addSubscription(this);
                                this.onValkeySubscribe(value);

                                // One command completion covers every confirmation in a multi-channel request.
                                if (pair) |req_pair| {
                                    Completion.completeInteger(&req_pair.completion, sub_count);
                                }
                                return .handled;
                            },
                            .unsubscribe => {
                                this.onValkeyUnsubscribe();
                                Integration.removeSubscription(this);

                                // Later confirmations have no command completion to consume.
                                if (pair) |req_pair| {
                                    Completion.completeUndefined(&req_pair.completion);
                                }
                                return .handled;
                            },
                        }
                    } else {
                        // We should rarely reach this point. If we're guaranteed to be handling a subscribe/unsubscribe,
                        // then this is an unexpected path.
                        @branchHint(.cold);
                        this.fail(
                            "Push message is not a subscription message.",
                            protocol.RedisError.InvalidResponseType,
                        );
                        return .handled;
                    }
                },
                else => {
                    // This may be a regular command response. Let's pass it down
                    // to the next handler.
                    return .fallthrough;
                },
            };
        }

        fn handleHelloResponse(this: *Self, value: *protocol.RESPValue) void {
            debug("Processing HELLO response", .{});

            switch (value.*) {
                .Error => |err| {
                    this.fail(err, protocol.RedisError.AuthenticationFailed);
                    return;
                },
                .SimpleString => |str| {
                    if (std.mem.eql(u8, str, "OK")) {
                        this.status = .connected;
                        this.flags.is_authenticated = true;
                        this.flags.is_reconnecting = false;
                        this.retry_attempts = 0;
                        this.onValkeyConnect(value);
                        return;
                    }
                    this.fail("Authentication failed (unexpected response)", protocol.RedisError.AuthenticationFailed);

                    return;
                },
                .Map => |map| {
                    // This is the HELLO response map
                    debug("Got HELLO response map with {d} entries", .{map.len});

                    // Process the Map response - find the protocol version
                    for (map) |*entry| {
                        switch (entry.key) {
                            .SimpleString => |key| {
                                if (std.mem.eql(u8, key, "proto")) {
                                    if (entry.value == .Integer) {
                                        const proto_version = entry.value.Integer;
                                        debug("Server protocol version: {d}", .{proto_version});
                                        if (proto_version != 3) {
                                            this.fail("Server does not support RESP3", protocol.RedisError.UnsupportedProtocol);
                                            return;
                                        }
                                    }
                                }
                            },
                            else => {},
                        }
                    }

                    // Authentication successful via HELLO
                    this.status = .connected;
                    this.flags.is_authenticated = true;
                    this.flags.is_reconnecting = false;
                    this.retry_attempts = 0;
                    this.onValkeyConnect(value);
                    return;
                },
                else => {
                    this.fail("Authentication failed with unexpected response", protocol.RedisError.AuthenticationFailed);
                    return;
                },
            }
        }

        /// Handle Valkey protocol response
        fn handleResponse(this: *Self, value: *protocol.RESPValue) void {
            // Special handling for the initial HELLO response
            if (!this.flags.is_authenticated) {
                this.handleHelloResponse(value);

                // We've handled the HELLO response without consuming anything from the command queue
                return;
            }

            // Handle initial SELECT response
            if (this.flags.is_selecting_db_internal) {
                this.flags.is_selecting_db_internal = false;

                return switch (value.*) {
                    .Error => |err_str| {
                        this.fail(err_str, protocol.RedisError.InvalidCommand);
                    },
                    .SimpleString => |ok_str| {
                        if (!std.mem.eql(u8, ok_str, "OK")) {
                            // SELECT returned something other than "OK"
                            this.fail("SELECT command failed with non-OK response", protocol.RedisError.InvalidResponse);
                            return;
                        }

                        // SELECT was successful.
                        debug("SELECT {d} successful", .{this.database});
                        // Connection is now fully ready on the specified database.
                        // If any commands were queued while waiting for SELECT, try to send them.
                        this.sendNextCommand();
                    },
                    else => { // Unexpected response type for SELECT
                        this.fail("Received non-SELECT response while in the SELECT state.", protocol.RedisError.InvalidResponse);
                    },
                };
            }
            var should_consume_completion = true;
            var pair_maybe: ?ValkeyCommand.InFlight = null;

            switch (value.*) {
                .Push => |push| {
                    if (protocol.SubscriptionPushMessage.map.get(push.kind)) |msg_type| {
                        switch (msg_type) {
                            .message => {
                                should_consume_completion = false;
                            },
                            .subscribe, .unsubscribe => {
                                if (this.in_flight.readableLength() == 0) {
                                    should_consume_completion = false;
                                }
                            },
                        }
                    }
                },
                else => {},
            }

            if (should_consume_completion) {
                pair_maybe = this.in_flight.readItem();
            }

            // We handle subscriptions specially because they are not regular commands and their failure will potentially
            // cause the client to drop out of subscriber mode.
            const request_is_subscribe = if (pair_maybe) |p| p.meta.subscription_request else false;
            if (Integration.isSubscriber(this) or request_is_subscribe) {
                debug("This client is a subscriber. Handling as subscriber...", .{});

                switch (value.*) {
                    .Error => |err| {
                        if (pair_maybe) |*pending| {
                            Completion.fail(&pending.completion, error.InvalidResponse, err);
                        }
                        this.fail(err, protocol.RedisError.InvalidResponse);
                        return;
                    },
                    .Push => |push| {
                        if (protocol.SubscriptionPushMessage.map.get(push.kind)) |_| {
                            if (this.handleSubscribeResponse(value, if (pair_maybe) |*pm| pm else null) == .handled) {
                                return;
                            }
                        } else {
                            @branchHint(.cold);
                            const message = "Unexpected push message kind without a command completion";
                            if (pair_maybe) |*pending| {
                                Completion.fail(&pending.completion, error.InvalidResponseType, message);
                            }
                            this.fail(
                                message,
                                protocol.RedisError.InvalidResponseType,
                            );
                            return;
                        }
                    },
                    else => {
                        // In the else case, we fall through to the regular
                        // handler. Subscribers can send .Push commands which have
                        // the same semantics as regular commands.
                    },
                }

                debug("Treating subscriber response as a regular command...", .{});
            }

            var pair = pair_maybe orelse {
                return;
            };

            const meta = pair.meta;

            // Handle the response based on command type
            if (meta.return_as_bool) {
                // EXISTS returns 1 if key exists, 0 if not - we convert to boolean
                if (value.* == .Integer) {
                    const int_value = value.Integer;
                    value.* = .{ .Boolean = int_value > 0 };
                }
            }

            switch (value.*) {
                .Error => |message| Completion.fail(&pair.completion, error.InvalidResponse, message),
                else => Completion.completeResponse(&pair.completion, value, meta.return_as_buffer),
            }
        }

        /// Send authentication command to Valkey server
        fn authenticate(this: *Self) void {
            // First send HELLO command for RESP3 protocol
            debug("Sending HELLO 3 command", .{});

            var hello_args_buf: [4][]const u8 = .{ "3", "AUTH", "", "" };
            var hello_args: []const []const u8 = undefined;

            if (this.username.len > 0 or this.password.len > 0) {
                hello_args_buf[0] = "3";
                hello_args_buf[1] = "AUTH";

                if (this.username.len > 0) {
                    hello_args_buf[2] = this.username;
                    hello_args_buf[3] = this.password;
                } else {
                    hello_args_buf[2] = "default";
                    hello_args_buf[3] = this.password;
                }

                hello_args = hello_args_buf[0..4];
            } else {
                hello_args = hello_args_buf[0..1];
            }

            // Format and send the HELLO command without adding to command queue
            // We'll handle this response specially in handleResponse
            var hello_cmd = Command{
                .command = "HELLO",
                .args = .{ .raw = hello_args },
            };

            hello_cmd.write(this.writer()) catch {
                this.fail("Failed to write HELLO command", this.writer_error orelse error.OutOfMemory);
                return;
            };

            // If using a specific database, send SELECT command
            if (this.database > 0) {
                var int_buf: [64]u8 = undefined;
                const db_str = std.mem.printSentinel(&int_buf, "{d}", .{this.database}, 0) catch unreachable;
                var select_cmd = Command{
                    .command = "SELECT",
                    .args = .{ .raw = &[_][]const u8{db_str} },
                };
                select_cmd.write(this.writer()) catch {
                    this.fail("Failed to write SELECT command", this.writer_error orelse error.OutOfMemory);
                    return;
                };
                this.flags.is_selecting_db_internal = true;
            }
        }

        /// Handle socket open event
        pub fn onOpen(this: *Self, socket: uws.AnySocket) void {
            this.socket = socket;
            this.write_buffer.clearAndFree(this.allocator);
            this.read_buffer.clearAndFree(this.allocator);
            // Authentication and failure state describe one socket lifetime and must not cross reconnects.
            this.flags.failed = false;
            this.flags.is_authenticated = false;
            this.flags.is_selecting_db_internal = false;
            if (this.socket == .SocketTCP) {
                // if is tcp, we need to start the connection process
                // if is tls, we need to wait for the handshake to complete
                this.start();
            }
        }

        /// Start the connection process
        pub fn start(this: *Self) void {
            this.authenticate();
            _ = this.flushData();
        }

        /// Test whether we are ready to run "normal" RESP commands, such as
        /// get/set, pub/sub, etc.
        fn connectionReady(this: *const Self) bool {
            return this.flags.is_authenticated and !this.flags.is_selecting_db_internal;
        }

        /// Close the Valkey connection
        pub fn disconnect(this: *Self) void {
            this.flags.is_manually_closed = true;
            this.unregisterAutoFlusher();
            if (this.status == .connected or this.status == .connecting) {
                this.close();
            }
        }

        /// Get a writer for the connected socket
        pub fn writer(this: *Self) *std.Io.Writer {
            this.writer_state.end = 0;
            this.writer_error = null;
            return &this.writer_state;
        }

        fn writerDrain(interface: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const this: *Self = @fieldParentPtr("writer_state", interface);
            for (data[0 .. data.len - 1]) |bytes| _ = this.write(bytes) catch |err| {
                this.writer_error = err;
                return error.WriteFailed;
            };
            for (0..splat) |_| _ = this.write(data[data.len - 1]) catch |err| {
                this.writer_error = err;
                return error.WriteFailed;
            };
            return std.Io.Writer.countSplat(data, splat);
        }

        /// Write data to the socket buffer
        fn write(this: *Self, data: []const u8) !usize {
            try this.write_buffer.write(this.allocator, data);
            return data.len;
        }

        pub fn connectSocket(
            this: *Self,
            group: *uws.SocketGroup,
            ssl_ctx: ?*uws.SslCtx,
            is_tls: bool,
        ) !uws.AnySocket {
            switch (is_tls) {
                inline else => |tls| {
                    const SocketType = if (tls) uws.SocketTLS else uws.SocketTCP;
                    const union_field = if (tls) "SocketTLS" else "SocketTCP";
                    const kind: uws.SocketKind = if (tls) .valkey_tls else .valkey;
                    return @unionInit(uws.AnySocket, union_field, switch (this.address) {
                        .unix => |path| try SocketType.connectUnixGroup(group, kind, ssl_ctx, path, this, false),
                        .host => |host| try SocketType.connectGroup(group, kind, ssl_ctx, host.host, host.port, this, false),
                    });
                },
            }
        }

        pub fn ref(this: *Self) void {
            Integration.ref(this);
        }

        pub fn deref(this: *Self) void {
            Integration.deref(this);
        }

        pub fn onValkeyConnect(this: *Self, value: *protocol.RESPValue) void {
            Integration.onValkeyConnect(this, value);
        }

        pub fn onValkeySubscribe(this: *Self, value: *protocol.RESPValue) void {
            Integration.onValkeySubscribe(this, value);
        }

        pub fn onValkeyUnsubscribe(this: *Self) void {
            Integration.onValkeyUnsubscribe(this);
        }

        pub fn onValkeyMessage(this: *Self, value: []protocol.RESPValue) void {
            Integration.onValkeyMessage(this, value);
        }

        pub fn onValkeyReconnect(this: *Self) void {
            Integration.onValkeyReconnect(this);
        }

        pub fn onValkeyClose(this: *Self) Integration.Error!void {
            return Integration.onValkeyClose(this);
        }
    };
    return Implementation;
}

// Auto-pipelining
const debug = bun.Output.scoped(.Redis, .visible);

const ValkeyCommand = @import("./ValkeyCommand.zig");
const Completion = @import("./ValkeyCompletion.zig");
const protocol = @import("../../valkey/valkey_protocol.zig");
const std = @import("std");

const bun = @import("bun");
const uws = bun.uws;
const AutoFlusher = @import("../../event_loop/AutoFlusher.zig");
const SSLConfig = @import("../socket/SSLConfig.zig");
