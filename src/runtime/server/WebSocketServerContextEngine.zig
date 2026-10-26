const WebSocketServerContext = @This();

const PendingCallback = @import("./ServerConfig.zig").PendingCallback;

handler: Handler = .{},

maxPayloadLength: u32 = 1024 * 1024 * 16, // 16MB
maxLifetime: u16 = 0,
idleTimeout: u16 = 120, // 2 minutes
compression: i32 = 0,
backpressureLimit: u32 = 1024 * 1024 * 16, // 16MB
sendPingsAutomatically: bool = true,
resetIdleTimeoutOnSend: bool = true,
closeOnBackpressureLimit: bool = false,

pub const Handler = struct {
    pub const State = struct {
        pub const IdleNotification = struct {
            context: bun.bindgen.NativeCallbackContext(.vm),
            callback: *const fn (bun.bindgen.NativeCallbackContext(.vm)) void,
        };

        pub const App = union(enum) {
            http: *bun.uws.NewApp(false),
            https: *bun.uws.NewApp(true),
        };
        app: ?App = null,
        server: ?AnyServer = null,
        vm: *jsc.VirtualMachine = undefined,
        globalObject: *jsc.JSGlobalObject = undefined,
        active_connections: usize = 0,
        active_dispatches: usize = 0,
        idle_notification: ?IdleNotification = null,
    };

    onOpen: PendingCallback("ServeWebSocketOpenCallback") = .{},
    onMessage: PendingCallback("ServeWebSocketMessageCallback") = .{},
    onClose: PendingCallback("ServeWebSocketCloseCallback") = .{},
    onDrain: PendingCallback("ServeWebSocketDrainCallback") = .{},
    onError: PendingCallback("ServeWebSocketErrorCallback") = .{},
    onPing: PendingCallback("ServeWebSocketPingCallback") = .{},
    onPong: PendingCallback("ServeWebSocketPongCallback") = .{},

    state: State = .{},

    /// used by publish()
    flags: packed struct(u8) {
        ssl: bool = false,
        publish_to_self: bool = false,
        _: u6 = 0,
    } = .{},

    fn notifyIfIdle(this: *Handler) void {
        const notification = this.state.idle_notification orelse return;
        if (this.state.active_connections > 0 or this.state.active_dispatches > 0) {
            return;
        }
        this.state.idle_notification = null;
        notification.callback(notification.context);
    }

    pub fn enterDispatch(this: *Handler) void {
        this.state.active_dispatches += 1;
    }

    pub fn leaveDispatch(this: *Handler) void {
        bun.debugAssert(this.state.active_dispatches > 0);
        this.state.active_dispatches -= 1;
        this.notifyIfIdle();
    }

    pub fn connectionOpened(this: *Handler) void {
        this.state.active_connections += 1;
    }

    pub fn connectionClosed(this: *Handler) void {
        bun.debugAssert(this.state.active_connections > 0);
        this.state.active_connections -= 1;
        this.notifyIfIdle();
    }

    pub fn notifyWhenIdle(this: *Handler, context: anytype, comptime callback: fn (@TypeOf(context)) void) void {
        bun.debugAssert(this.state.active_connections > 0 or this.state.active_dispatches > 0);
        const Adapter = struct {
            fn run(capture: bun.bindgen.NativeCallbackContext(.vm)) void {
                callback(capture.get(@TypeOf(context)));
            }
        };
        this.state.idle_notification = .{
            .context = .init(context),
            .callback = Adapter.run,
        };
    }

    pub fn runErrorCallbackFailure(this: *const Handler, invocation: anytype, failure: bun.JSError) void {
        const value = invocation.takeThrownValue(failure) catch return;
        this.runErrorCallbackView(invocation, value);
    }

    pub fn runErrorCallbackView(this: *const Handler, context: anytype, error_value: anytype) void {
        const globalObject = this.state.globalObject;
        if (this.state.server) |server| if (server.webSocketCallback("wsOnError") catch |err| return globalObject.reportActiveExceptionAsUnhandled(err)) |owned_callback| {
            var on_error = owned_callback;
            defer on_error.deinit();
            var rooted_error = error_value.toRoot() catch |err|
                return globalObject.reportActiveExceptionAsUnhandled(err);
            defer rooted_error.deinit();
            var invocation: @TypeOf(on_error).Invocation = undefined;
            on_error.beginInvocation(&invocation);
            defer invocation.deinit();
            invocation.call(.{
                .error_value = rooted_error.operand(&invocation),
            }) catch |err| globalObject.reportActiveExceptionAsUnhandled(err);
            return;
        };

        _ = context.reportUncaughtException(error_value.operand(context).asAny(), false);
    }

    pub fn fromSchema(
        globalObject: *jsc.JSGlobalObject,
        context: anytype,
        generated: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!Handler {
        var handler = Handler{ .state = .{ .globalObject = globalObject, .vm = globalObject.bunVM() } };
        errdefer handler.deinitPendingCallbacks();

        var valid = false;

        inline for (.{
            .{ "error_callback", "onError" },
            .{ "message", "onMessage" },
            .{ "open", "onOpen" },
            .{ "close", "onClose" },
            .{ "drain", "onDrain" },
            .{ "ping", "onPing" },
            .{ "pong", "onPong" },
        }, 0..) |entry, i| {
            if (@field(generated, entry[0])) |*converted| switch (converted.*) {
                .callback => {
                    try @field(handler, entry[1]).setView(converted.callback);
                    if (i > 0) {
                        // anything other than "error" is considered valid.
                        valid = true;
                    }
                },
                .nulled => {},
            };
        }

        if (valid)
            return handler;

        return context.fail(.websocket_missing_message_handler, {});
    }

    pub fn deinitPendingCallbacks(this: *Handler) void {
        inline for (.{ "onOpen", "onMessage", "onClose", "onDrain", "onError", "onPing", "onPong" }) |field| {
            @field(this, field).deinit();
        }
    }
};

pub fn toBehavior(this: WebSocketServerContext) uws.WebSocketBehavior {
    return .{
        .maxPayloadLength = this.maxPayloadLength,
        .idleTimeout = this.idleTimeout,
        .compression = this.compression,
        .maxBackpressure = this.backpressureLimit,
        .sendPingsAutomatically = this.sendPingsAutomatically,
        .maxLifetime = this.maxLifetime,
        .resetIdleTimeoutOnSend = this.resetIdleTimeoutOnSend,
        .closeOnBackpressureLimit = this.closeOnBackpressureLimit,
    };
}

fn compressionFlag(converted: anytype, comptime side: enum { compress, decompress }) i32 {
    return switch (converted) {
        .flag => |flag| if (flag)
            (if (side == .compress) uws.SHARED_COMPRESSOR else uws.SHARED_DECOMPRESSOR)
        else
            0,
        .mode => |mode| if (comptime side == .compress) switch (mode) {
            .disabled => 0,
            .shared => uws.SHARED_COMPRESSOR,
            .dedicated => uws.DEDICATED_COMPRESSOR,
            .kb3 => uws.DEDICATED_COMPRESSOR_3KB,
            .kb4 => uws.DEDICATED_COMPRESSOR_4KB,
            .kb8 => uws.DEDICATED_COMPRESSOR_8KB,
            .kb16 => uws.DEDICATED_COMPRESSOR_16KB,
            .kb32 => uws.DEDICATED_COMPRESSOR_32KB,
            .kb64 => uws.DEDICATED_COMPRESSOR_64KB,
            .kb128 => uws.DEDICATED_COMPRESSOR_128KB,
            .kb256 => uws.DEDICATED_COMPRESSOR_256KB,
        } else switch (mode) {
            .disabled => 0,
            .shared => uws.SHARED_DECOMPRESSOR,
            .dedicated => uws.DEDICATED_DECOMPRESSOR,
            .bytes512 => uws.DEDICATED_DECOMPRESSOR_512B,
            .kb1 => uws.DEDICATED_DECOMPRESSOR_1KB,
            .kb2 => uws.DEDICATED_DECOMPRESSOR_2KB,
            .kb4 => uws.DEDICATED_DECOMPRESSOR_4KB,
            .kb8 => uws.DEDICATED_DECOMPRESSOR_8KB,
            .kb16 => uws.DEDICATED_DECOMPRESSOR_16KB,
            .kb32 => uws.DEDICATED_DECOMPRESSOR_32KB,
        },
    };
}

pub fn fromSchema(
    globalObject: *jsc.JSGlobalObject,
    context: anytype,
    generated: anytype,
) bun.bindgen.CallError(@TypeOf(context))!WebSocketServerContext {
    var server = WebSocketServerContext{};
    server.handler = try Handler.fromSchema(globalObject, context, generated);

    if (generated.perMessageDeflate) |per_message_deflate| switch (per_message_deflate) {
        .flag => |flag| server.compression = if (flag) uws.SHARED_COMPRESSOR | uws.SHARED_DECOMPRESSOR else 0,
        .nulled => server.compression = 0,
        .options => |*options| {
            if (options.compress) |compress| {
                server.compression |= compressionFlag(compress, .compress);
            }
            if (options.decompress) |decompress| {
                server.compression |= compressionFlag(decompress, .decompress);
            }
        },
    };

    if (generated.maxPayloadLength) |value| {
        if (value) |resolved| {
            server.maxPayloadLength = resolved;
        }
    }

    if (generated.idleTimeout) |value| {
        if (value) |resolved| {
            // uws does not allow idleTimeout to be between (0, 8),
            // since its timer is not that accurate, therefore round up.
            server.idleTimeout = if (resolved > 0) @max(resolved, 8) else resolved;
        }
    }

    if (generated.backpressureLimit) |value| {
        if (value) |resolved| {
            server.backpressureLimit = resolved;
        }
    }

    if (generated.closeOnBackpressureLimit) |value| {
        if (value) |resolved| {
            server.closeOnBackpressureLimit = resolved;
        }
    }

    if (generated.sendPings) |value| {
        if (value) |resolved| {
            server.sendPingsAutomatically = resolved;
        }
    }

    if (generated.publishToSelf) |value| {
        if (value) |resolved| {
            server.handler.flags.publish_to_self = resolved;
        }
    }
    return server;
}

const std = @import("std");

const bun = @import("bun");
const JSError = bun.JSError;
const uws = bun.uws;

const jsc = bun.jsc;
const AnyServer = jsc.API.AnyServer;
const JSGlobalObject = jsc.JSGlobalObject;
const VirtualMachine = jsc.VirtualMachine;
