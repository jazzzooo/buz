pub fn WithOwner(comptime DevServer: type) type {
    return struct {
        const HmrSocket = @This();
        const RouteBundle = DevServer.RouteBundle;
        const SourceMapStore = DevServer.SourceMapStore;

        dev: *DevServer,
        underlying: ?AnyWebSocket = null,
        subscriptions: HmrTopic.Bits,
        // TODO: Audit HMR message authorization so sensitive actions require a local connection.
        /// Allows actions which inspect or mutate sensitive DevServer state.
        is_from_localhost: bool,
        /// By telling DevServer the active route, this enables receiving detailed
        /// `hot_update` events for when the route is updated.
        active_route: RouteBundle.Index.Optional,
        referenced_source_maps: std.AutoHashMapUnmanaged(SourceMapStore.Key, void),
        inspector_connection_id: i32 = -1,

        pub fn new(dev: *DevServer, res: anytype) bun.OOM!*HmrSocket {
            const socket = try dev.allocator().create(HmrSocket);
            socket.* = .{
                .dev = dev,
                .is_from_localhost = if (res.getRemoteSocketInfo()) |addr|
                    if (addr.is_ipv6)
                        bun.strings.eqlComptime(addr.ip, "::1")
                    else
                        bun.strings.eqlComptime(addr.ip, "127.0.0.1")
                else
                    false,
                .subscriptions = .{},
                .active_route = .none,
                .referenced_source_maps = .empty,
            };
            return socket;
        }

        pub fn onOpen(s: *HmrSocket, ws: AnyWebSocket) void {
            s.underlying = ws;
            s.dev.active_websocket_connections.putAssumeCapacityNoClobber(s, {});
            const send_status = ws.send(&(.{MessageId.version.char()} ++ s.dev.configuration_hash_key), .binary, false, true);

            if (send_status != .dropped) {
                // Notify inspector about client connection
                if (s.dev.inspector()) |agent| {
                    s.inspector_connection_id = agent.nextConnectionID();
                    agent.notifyClientConnected(s.dev.inspector_server_id, s.inspector_connection_id);
                }
            }
        }

        pub fn onMessage(s: *HmrSocket, ws: AnyWebSocket, msg: []const u8, opcode: uws.Opcode) void {
            _ = opcode;

            if (msg.len == 0)
                return ws.close();

            switch (@as(IncomingMessageId, @fromBackingInt(@intCast(msg[0])))) {
                .init => {
                    if (msg.len != 9) return ws.close();
                    var generation: u32 = undefined;
                    _ = std.fmt.hexToBytes(std.mem.asBytes(&generation), msg[1..]) catch
                        return ws.close();
                    const source_map_id = SourceMapStore.Key.init(@as(u64, generation) << 32);
                    if (s.referenced_source_maps.contains(source_map_id)) return;
                    s.referenced_source_maps.ensureUnusedCapacity(s.dev.allocator(), 1) catch return ws.close();
                    if (s.dev.source_maps.upgradeWeakRef(source_map_id) catch return ws.close()) {
                        s.referenced_source_maps.putAssumeCapacityNoClobber(source_map_id, {});
                    }
                },
                .subscribe => {
                    var new_bits: HmrTopic.Bits = .{};
                    const topics = msg[1..];
                    if (topics.len > HmrTopic.max_count) return;
                    outer: for (topics) |char| {
                        const enum_info = @typeInfo(HmrTopic).@"enum";
                        inline for (enum_info.field_names, enum_info.field_values) |field_name, field_value| {
                            if (char == field_value) {
                                @field(new_bits, field_name) = true;
                                continue :outer;
                            }
                        }
                    }
                    inline for (comptime std.enums.values(HmrTopic)) |field| {
                        if (@field(new_bits, @tagName(field)) and !@field(s.subscriptions, @tagName(field))) {
                            _ = ws.subscribe(&.{@backingInt(field)});

                            // on-subscribe hooks
                            if (bun.FeatureFlags.bake_debugging_features) switch (field) {
                                .incremental_visualizer => {
                                    s.dev.emit_incremental_visualizer_events += 1;
                                    s.dev.emitVisualizerMessageIfNeeded();
                                },
                                .memory_visualizer => {
                                    s.dev.emit_memory_visualizer_events += 1;
                                    s.dev.emitMemoryVisualizerMessage();
                                    if (s.dev.emit_memory_visualizer_events == 1) {
                                        bun.assert(s.dev.memory_visualizer_timer.state != .ACTIVE);
                                        s.dev.vm.timer.update(
                                            &s.dev.memory_visualizer_timer,
                                            &bun.timespec.msFromNow(.allow_mocked_time, 1000),
                                        );
                                    }
                                },
                                else => {},
                            };
                        } else if (!@field(new_bits, @tagName(field)) and @field(s.subscriptions, @tagName(field))) {
                            _ = ws.unsubscribe(&.{@backingInt(field)});
                        }
                    }
                    onUnsubscribe(s, bun.bits.@"and"(
                        HmrTopic.Bits,
                        bun.bits.invert(HmrTopic.Bits, new_bits),
                        s.subscriptions,
                    ));
                    s.subscriptions = new_bits;
                },
                .set_url => {
                    const pattern = msg[1..];
                    const maybe_rbi = s.dev.routeToBundleIndexSlow(pattern);
                    if (s.dev.inspector()) |agent| {
                        if (s.inspector_connection_id > -1) {
                            var pattern_str = bun.String.cloneUTF8(pattern);
                            defer pattern_str.deref();
                            agent.notifyClientNavigated(
                                s.dev.inspector_server_id,
                                s.inspector_connection_id,
                                &pattern_str,
                                maybe_rbi,
                            );
                        }
                    }
                    const rbi = maybe_rbi orelse return;
                    if (s.active_route.unwrap()) |old| {
                        if (old == rbi) return;
                        s.dev.routeBundlePtr(old).active_viewers -= 1;
                    }
                    s.dev.routeBundlePtr(rbi).active_viewers += 1;
                    s.active_route = rbi.toOptional();
                    var response: [5]u8 = .{MessageId.set_url_response.char()} ++ std.mem.toBytes(rbi.get());

                    _ = ws.send(&response, .binary, false, true);
                    s.notifyInspectorClientNavigation(pattern, rbi.toOptional());
                },
                .testing_batch_events => switch (s.dev.testing_batch_events) {
                    .disabled => {
                        if (s.dev.current_bundle != null) {
                            s.dev.testing_batch_events = .enable_after_bundle;
                        } else {
                            s.dev.testing_batch_events = .{ .enabled = .empty };
                            s.dev.publish(.testing_watch_synchronization, &.{
                                MessageId.testing_watch_synchronization.char(),
                                0,
                            }, .binary);
                        }
                    },
                    .enable_after_bundle => {
                        // do not expose a websocket event that panics a release build
                        bun.debugAssert(false);
                        ws.close();
                    },
                    .enabled => |event_const| {
                        var event = event_const;
                        s.dev.testing_batch_events = .disabled;

                        if (event.entry_points.set.count() == 0) {
                            s.dev.publish(.testing_watch_synchronization, &.{
                                MessageId.testing_watch_synchronization.char(),
                                2,
                            }, .binary);
                            return;
                        }

                        s.dev.startAsyncBundle(
                            event.entry_points,
                            true,
                            bun.SystemTimer.start() catch @panic("timers unsupported"),
                        ) catch |err| switch (err) {
                            error.OutOfMemory => bun.outOfMemory(),
                            else => Output.err(err, "Failed to start bundler", .{}),
                        };

                        event.entry_points.deinit(s.dev.allocator());
                    },
                },
                .console_log => {
                    if (msg.len < 2) {
                        ws.close();
                        return;
                    }

                    const kind: ConsoleLogKind = switch (msg[1]) {
                        'l' => .log,
                        'e' => .err,
                        else => {
                            ws.close();
                            return;
                        },
                    };

                    const data = msg[2..];

                    if (s.dev.inspector()) |agent| {
                        var log_str = bun.String.cloneUTF8(data);
                        defer log_str.deref();
                        agent.notifyConsoleLog(s.dev.inspector_server_id, kind, &log_str);
                    }

                    if (s.dev.broadcast_console_log_from_browser_to_server) {
                        switch (kind) {
                            .log => {
                                bun.Output.pretty("<r><d>[browser]<r> {s}<r>\n", .{data});
                            },
                            .err => {
                                bun.Output.prettyError("<r><d>[browser]<r> {s}<r>\n", .{data});
                            },
                        }
                        bun.Output.flush();
                    }
                },
                .unref_source_map => {
                    var reader = std.Io.Reader.fixed(msg[1..]);

                    const source_map_id = SourceMapStore.Key.init(reader.takeInt(u64, .little) catch
                        return ws.close());
                    const kv = s.referenced_source_maps.fetchRemove(source_map_id) orelse {
                        bun.Output.debugWarn("unref_source_map: no entry found: {x}\n", .{source_map_id.get()});
                        return; // no entry may happen.
                    };
                    s.dev.source_maps.unref(kv.key);
                },
                _ => ws.close(),
            }
        }

        fn onUnsubscribe(s: *HmrSocket, field: HmrTopic.Bits) void {
            if (bun.FeatureFlags.bake_debugging_features) {
                if (field.incremental_visualizer) {
                    s.dev.emit_incremental_visualizer_events -= 1;
                }
                if (field.memory_visualizer) {
                    s.dev.emit_memory_visualizer_events -= 1;
                    if (s.dev.emit_memory_visualizer_events == 0 and s.dev.memory_visualizer_timer.state == .ACTIVE) {
                        s.dev.vm.timer.remove(&s.dev.memory_visualizer_timer);
                    }
                }
            }
        }

        pub fn onClose(s: *HmrSocket, ws: AnyWebSocket, exit_code: i32, message: []const u8) void {
            _ = ws;
            _ = exit_code;
            _ = message;

            s.underlying = null;
            const removed = s.dev.active_websocket_connections.remove(s);
            bun.debugAssert(removed);
            s.onUnsubscribe(s.subscriptions);

            if (s.inspector_connection_id > -1) {
                // Notify inspector about client disconnection
                if (s.dev.inspector()) |agent| {
                    agent.notifyClientDisconnected(s.dev.inspector_server_id, s.inspector_connection_id);
                }
            }

            if (s.active_route.unwrap()) |old| {
                s.dev.routeBundlePtr(old).active_viewers -= 1;
            }

            var it = s.referenced_source_maps.keyIterator();
            while (it.next()) |key| {
                s.dev.source_maps.unref(key.*);
            }
            s.referenced_source_maps.deinit(s.dev.allocator());
            s.dev.allocator().destroy(s);
        }

        fn notifyInspectorClientNavigation(s: *const HmrSocket, pattern: []const u8, rbi: RouteBundle.Index.Optional) void {
            if (s.inspector_connection_id > -1) {
                if (s.dev.inspector()) |agent| {
                    var pattern_str = bun.String.cloneUTF8(pattern);
                    defer pattern_str.deref();
                    agent.notifyClientNavigated(
                        s.dev.inspector_server_id,
                        s.inspector_connection_id,
                        &pattern_str,
                        rbi.unwrap(),
                    );
                }
            }
        }
    };
}

const std = @import("std");

const bun = @import("bun");
const Output = bun.Output;
const assert = bun.assert;

const DevServerProtocol = @import("../DevServerProtocol.zig");
const ConsoleLogKind = DevServerProtocol.ConsoleLogKind;
const HmrTopic = DevServerProtocol.HmrTopic;
const IncomingMessageId = DevServerProtocol.IncomingMessageId;
const MessageId = DevServerProtocol.MessageId;
const uws = bun.uws;
const AnyWebSocket = uws.AnyWebSocket;
