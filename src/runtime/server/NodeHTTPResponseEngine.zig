const NodeHTTPResponse = @This();

const log = bun.Output.scoped(.NodeHTTPResponse, .visible);

pub const JSBinding = struct {
    bindgen_state: bindgen.ClassState = .{},
    response: bindgen.RefNative(NodeHTTPResponse, .vm),

    pub const destroy = @This().deinit;

    fn deinit(this: *JSBinding) void {
        this.response.get().wrapperFinalized();
        this.response.deinit();
        bun.destroy(this);
    }

    pub fn hasPendingActivity(this: *const JSBinding) bool {
        return this.response.get().core.flags.is_request_pending;
    }

    pub fn memoryUsage(_: *const JSBinding, _: bun.bindgen.MemoryUsageContext(.any)) usize {
        return @sizeOf(JSBinding) + @sizeOf(NodeHTTPResponse);
    }

    fn FlagGetter(comptime property: []const u8, comptime field: []const u8) type {
        const Schema = NodeHTTPResponseClassSchema.memberKind(property, .getter);
        return struct {
            pub fn call(this: *JSBinding, _: bindgen.CallContext(Schema), _: bindgen.Args(Schema)) bun.JSError!bool {
                return @field(this.response.get().core.flags, field);
            }
        };
    }

    fn PollReference(comptime acquire: bool) type {
        const Schema = NodeHTTPResponseClassSchema.memberKind(if (acquire) "ref" else "unref", .method);
        return struct {
            pub fn call(this: *JSBinding, context: bindgen.CallContext(Schema), _: bindgen.Args(Schema)) bun.JSError!void {
                const response = this.response.get();
                if (response.core.flags.isDone()) return;
                if (acquire)
                    response.poll_ref.acquire(context.vmIdentity())
                else
                    response.poll_ref.releaseForVM(context.vmIdentity());
            }
        };
    }

    pub fn bindAbort(
        this: *JSBinding,
        _: bindgen.CallContext(NodeHTTPResponseAbortSchema),
        args: bindgen.Args(NodeHTTPResponseAbortSchema),
    ) bun.JSError!void {
        try this.response.get().abort(args.bindingThis);
    }

    pub const bindGetAborted = FlagGetter("aborted", "socket_closed").call;

    pub fn bindGetBufferedAmount(
        this: *JSBinding,
        _: bindgen.CallContext(NodeHTTPResponseBufferedAmountSchema),
        _: bindgen.Args(NodeHTTPResponseBufferedAmountSchema),
    ) bun.JSError!u64 {
        return this.response.get().getBufferedAmount();
    }

    pub fn bindCork(
        this: *JSBinding,
        context: bindgen.CallContext(NodeHTTPResponseCorkSchema),
        args: bindgen.Args(NodeHTTPResponseCorkSchema),
    ) bindgen.CallError(NodeHTTPResponseCorkSchema)!bindgen.Return(NodeHTTPResponseCorkSchema) {
        const response = this.response.get();
        if (response.core.flags.request_has_completed or response.core.flags.socket_closed or response.core.flags.upgraded) {
            return context.fail(.stream_finished, {});
        }
        return response.cork(args.callback);
    }

    pub fn bindDrainRequestBody(
        this: *JSBinding,
        _: bindgen.CallContext(NodeHTTPResponseDrainRequestBodySchema),
        _: bindgen.Args(NodeHTTPResponseDrainRequestBodySchema),
    ) bun.JSError!bindgen.Return(NodeHTTPResponseDrainRequestBodySchema) {
        return try this.response.get().drainRequestBody();
    }

    pub fn bindDumpRequestBody(
        this: *JSBinding,
        _: bindgen.CallContext(NodeHTTPResponseDumpRequestBodySchema),
        args: bindgen.Args(NodeHTTPResponseDumpRequestBodySchema),
    ) bun.JSError!void {
        this.response.get().dumpRequestBody(args.bindingThis);
    }

    pub fn bindEnd(
        this: *JSBinding,
        context: bindgen.CallContext(NodeHTTPResponseEndSchema),
        args: bindgen.Args(NodeHTTPResponseEndSchema),
    ) bindgen.CallError(NodeHTTPResponseEndSchema)!?f64 {
        resumeSocket(this.response.get());
        return this.response.get().writeOrEnd(context, args, args.bindingThis, true);
    }

    pub const bindGetEnded = FlagGetter("ended", "ended").call;

    pub const bindGetFinished = FlagGetter("finished", "request_has_completed").call;

    pub fn bindGetFlags(
        this: *JSBinding,
        _: bindgen.CallContext(NodeHTTPResponseFlagsSchema),
        _: bindgen.Args(NodeHTTPResponseFlagsSchema),
    ) bun.JSError!u8 {
        return @bitCast(this.response.get().core.flags);
    }

    pub fn bindFlushHeaders(
        this: *JSBinding,
        _: bindgen.CallContext(NodeHTTPResponseFlushHeadersSchema),
        _: bindgen.Args(NodeHTTPResponseFlushHeadersSchema),
    ) bun.JSError!void {
        try this.response.get().flushHeaders();
    }

    pub fn bindGetBytesWritten(
        this: *JSBinding,
        _: bindgen.CallContext(NodeHTTPResponseGetBytesWrittenSchema),
        _: bindgen.Args(NodeHTTPResponseGetBytesWrittenSchema),
    ) bun.JSError!usize {
        return this.response.get().core.bytes_written;
    }

    pub fn bindGetHasBody(
        this: *JSBinding,
        _: bindgen.CallContext(NodeHTTPResponseHasBodySchema),
        _: bindgen.Args(NodeHTTPResponseHasBodySchema),
    ) bun.JSError!i32 {
        return this.response.get().getHasBody();
    }

    pub const bindGetHasCustomOnData = FlagGetter("hasCustomOnData", "hasCustomOnData").call;

    pub fn bindSetHasCustomOnData(
        this: *JSBinding,
        _: bindgen.CallContext(NodeHTTPResponseHasCustomOnDataSetterSchema),
        args: bindgen.Args(NodeHTTPResponseHasCustomOnDataSetterSchema),
    ) bun.JSError!void {
        this.response.get().core.flags.hasCustomOnData = args.value;
    }

    pub const bindGetOnAbort = CallbackProperty(.abort).get;
    pub const bindSetOnAbort = CallbackProperty(.abort).set;
    pub const bindGetOnData = CallbackProperty(.data).get;
    pub const bindSetOnData = CallbackProperty(.data).set;
    pub const bindGetOnWritable = CallbackProperty(.writable).get;
    pub const bindSetOnWritable = CallbackProperty(.writable).set;

    fn CallbackProperty(comptime kind: enum { abort, data, writable }) type {
        const name = switch (kind) {
            .abort => "onabort",
            .data => "ondata",
            .writable => "onwritable",
        };
        const Slot = switch (kind) {
            .abort => NodeHTTPResponseOnAbortedSlot,
            .data => NodeHTTPResponseOnDataSlot,
            .writable => NodeHTTPResponseOnWritableSlot,
        };
        const Getter = NodeHTTPResponseClassSchema.memberKind(name, .getter);
        const Setter = NodeHTTPResponseClassSchema.memberKind(name, .setter);
        return struct {
            pub fn get(this: *JSBinding, _: bindgen.CallContext(Getter), args: bindgen.Args(Getter)) bun.JSError!bindgen.Return(Getter) {
                if (kind == .abort) {
                    const flags = this.response.get().core.flags;
                    if (flags.socket_closed or flags.upgraded) return null;
                }
                return Slot.ownedCallbackFromView(args.bindingThis);
            }

            pub fn set(this: *JSBinding, _: bindgen.CallContext(Setter), args: bindgen.Args(Setter)) bun.JSError!void {
                const response = this.response.get();
                if (kind == .data) return response.setOnData(args.bindingThis, args.value);
                if (response.core.flags.isDone() or (kind == .abort and response.core.flags.upgraded)) {
                    Slot.clearView(args.bindingThis);
                    return;
                }
                switch (args.value) {
                    .callback => |callback| Slot.setView(args.bindingThis, callback),
                    .ignored => Slot.clearView(args.bindingThis),
                }
            }
        };
    }

    pub fn bindPause(
        this: *JSBinding,
        _: bindgen.CallContext(NodeHTTPResponsePauseSchema),
        _: bindgen.Args(NodeHTTPResponsePauseSchema),
    ) bun.JSError!bool {
        return this.response.get().doPause();
    }

    pub const bindRef = PollReference(true).call;

    pub fn bindResume(
        this: *JSBinding,
        _: bindgen.CallContext(NodeHTTPResponseResumeSchema),
        _: bindgen.Args(NodeHTTPResponseResumeSchema),
    ) bun.JSError!bindgen.Return(NodeHTTPResponseResumeSchema) {
        return try this.response.get().doResume();
    }

    pub const bindUnref = PollReference(false).call;

    pub const bindGetUpgraded = FlagGetter("upgraded", "upgraded").call;

    pub fn bindWrite(
        this: *JSBinding,
        context: bindgen.CallContext(NodeHTTPResponseWriteSchema),
        args: bindgen.Args(NodeHTTPResponseWriteSchema),
    ) bindgen.CallError(NodeHTTPResponseWriteSchema)!?f64 {
        return this.response.get().writeOrEnd(context, args, args.bindingThis, false);
    }

    pub fn bindWriteContinue(
        this: *JSBinding,
        context: bindgen.CallContext(NodeHTTPResponseWriteContinueSchema),
        _: bindgen.Args(NodeHTTPResponseWriteContinueSchema),
    ) bindgen.CallError(NodeHTTPResponseWriteContinueSchema)!void {
        try this.response.get().writeContinue(context);
    }

    pub fn bindWriteHead(
        this: *JSBinding,
        context: bindgen.CallContext(NodeHTTPResponseWriteHeadSchema),
        args: bindgen.Args(NodeHTTPResponseWriteHeadSchema),
    ) bindgen.CallError(NodeHTTPResponseWriteHeadSchema)!void {
        try this.response.get().writeHead(context, args);
    }
};

pub const Handle = struct {
    binding: NodeHTTPResponseClass.Handle,

    pub fn get(this: *const Handle) *NodeHTTPResponse {
        return this.binding.get().response.get();
    }

    pub fn deinit(this: *Handle) void {
        this.binding.deinit();
    }
};

const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

pub fn releasePromiseReactionRef(this: *NodeHTTPResponse) void {
    this.deref();
}

ref_count: RefCount,
wrapper: ?NodeHTTPResponseClass.ActivityWrapper = null,

core: ResponseCore.Response(uws.AnyResponse, uws.PreparedWrite),

poll_ref: bindgen.VMTaskActivity = .{},

body_read_ref: bindgen.VMTaskActivity = .{},
promise: ?bindgen.OwnedBrandedValue(bindgen.Module("promises").engineShim("promiseCreate").ReturnType) = null,
server: AnyServer,
routes: AnyServer.RouteLease = .none,

upgrade_context: UpgradeCTX = .{},

auto_flusher: AutoFlusher = .{},

pending_source: ?bun.api.node.StringOrBuffer = null,

pub const Flags = ResponseCore.Flags;

pub const UpgradeCTX = struct {
    context: ?*uws.WebSocketUpgradeContext = null,
    // request will be detached when go async
    request: ?*uws.Request = null,

    // we need to store this, if we wanna to enable async upgrade
    sec_websocket_key: []const u8 = "",
    sec_websocket_protocol: []const u8 = "",
    sec_websocket_extensions: []const u8 = "",

    // this can be called multiple times
    pub fn deinit(this: *UpgradeCTX) void {
        const sec_websocket_key = this.sec_websocket_key;
        const sec_websocket_protocol = this.sec_websocket_protocol;
        const sec_websocket_extensions = this.sec_websocket_extensions;
        this.* = .{};
        if (sec_websocket_extensions.len > 0) bun.default_allocator.free(sec_websocket_extensions);
        if (sec_websocket_protocol.len > 0) bun.default_allocator.free(sec_websocket_protocol);
        if (sec_websocket_key.len > 0) bun.default_allocator.free(sec_websocket_key);
    }

    pub fn preserveWebSocketHeadersIfNeeded(this: *UpgradeCTX) bun.OOM!void {
        const request = this.request orelse return;
        if (this.context == null) {
            this.request = null;
            return;
        }
        const allocator = bun.default_allocator;
        const key = try allocator.dupe(u8, request.header("sec-websocket-key") orelse "");
        errdefer allocator.free(key);
        const protocol = try allocator.dupe(u8, request.header("sec-websocket-protocol") orelse "");
        errdefer allocator.free(protocol);
        const extensions = try allocator.dupe(u8, request.header("sec-websocket-extensions") orelse "");

        this.sec_websocket_key = key;
        this.sec_websocket_protocol = protocol;
        this.sec_websocket_extensions = extensions;
        this.request = null;
    }
};

pub const BodyReadState = ResponseCore.BodyReadState;

fn wrapperRef(this: *const NodeHTTPResponse) bun.JSError!?bindgen.ClassRef(NodeHTTPResponseClassSchema) {
    if (this.wrapper) |*wrapper| return wrapper.toOwned();
    return null;
}

pub fn attachRequestPromiseHandlers(this: *NodeHTTPResponse, context: anytype, promise: anytype) bun.JSError!void {
    var owned_promise = try promise.toOwned();
    errdefer owned_promise.deinit();
    this.ref();
    try PromiseReaction.attach(
        context,
        promise.operand(context).asPromise(),
        this,
        NodeHTTPRequestOnResolveBinding,
        NodeHTTPRequestOnRejectBinding,
    );
    bun.assert(this.promise == null);
    this.promise = owned_promise.take();
}

fn clearRequestPromise(this: *NodeHTTPResponse) void {
    if (this.promise) |*promise| promise.deinit();
    this.promise = null;
}

fn wrapperFinalized(this: *NodeHTTPResponse) void {
    if (this.wrapper) |*wrapper| wrapper.deinit();
    this.wrapper = null;
}

pub fn hasServerSocket(this: *NodeHTTPResponse) bool {
    if (this.core.flags.socket_closed or this.core.flags.upgraded or this.core.raw_response == null) {
        return false;
    }
    return bun.bindgen.Engine(NodeHTTPServerSocketExistsForSocketSchema).call(this.server.globalThis(), .{
        .isSSL = this.core.raw_response.? == .SSL,
        .socket = @ptrCast(this.core.raw_response.?.socket()),
    });
}

pub fn pauseSocket(this: *NodeHTTPResponse) void {
    return this.core.pauseSocket();
}

pub fn resumeSocket(this: *NodeHTTPResponse) void {
    return this.core.resumeSocket();
}

pub fn prepareWebSocket(this: *NodeHTTPResponse, data: ?bindgen.AnyView) bun.JSError!?*ServerWebSocket {
    if (this.core.flags.socket_closed or this.core.flags.upgraded or this.core.raw_response == null or this.core.raw_response.?.isConnectRequest()) {
        return null;
    }
    if (this.upgrade_context.context == null) return null;
    const ws_handler = this.server.webSocketHandler() orelse return null;
    if (!this.hasServerSocket()) return null;

    return try ServerWebSocket.init(ws_handler, data);
}

pub fn upgrade(
    this: *NodeHTTPResponse,
    context: anytype,
    ws: *ServerWebSocket,
    sec_websocket_protocol: bun.TextView,
    sec_websocket_extensions: bun.TextView,
    headers: ?*jsc.WebCore.FetchHeaders,
) bindgen.CallError(@TypeOf(context))!bool {
    if (this.pending_source != null) return false;
    if (this.core.flags.isDone() or this.core.flags.upgraded or this.core.raw_response == null or this.core.raw_response.?.isConnectRequest()) {
        return false;
    }
    const upgrade_ctx = this.upgrade_context.context orelse return false;
    if (!this.hasServerSocket()) {
        return false;
    }
    this.ref();
    defer this.deref();

    var sec_websocket_protocol_str: ?bun.String.Slice = null;
    defer if (sec_websocket_protocol_str) |*str| str.deinit();
    var sec_websocket_extensions_str: ?bun.String.Slice = null;
    defer if (sec_websocket_extensions_str) |*str| str.deinit();

    const sec_websocket_protocol_value = brk: {
        if (sec_websocket_protocol.isEmpty()) {
            if (this.upgrade_context.request) |request| {
                break :brk request.header("sec-websocket-protocol") orelse "";
            } else {
                break :brk this.upgrade_context.sec_websocket_protocol;
            }
        }
        sec_websocket_protocol_str = try sec_websocket_protocol.toSlice(bun.default_allocator);
        break :brk sec_websocket_protocol_str.?.slice();
    };

    const sec_websocket_extensions_value = brk: {
        if (sec_websocket_extensions.isEmpty()) {
            if (this.upgrade_context.request) |request| {
                break :brk request.header("sec-websocket-extensions") orelse "";
            } else {
                break :brk this.upgrade_context.sec_websocket_extensions;
            }
        }
        sec_websocket_extensions_str = try sec_websocket_extensions.toSlice(bun.default_allocator);
        break :brk sec_websocket_extensions_str.?.slice();
    };

    const websocket_key = if (this.upgrade_context.request) |request|
        request.header("sec-websocket-key") orelse ""
    else
        this.upgrade_context.sec_websocket_key;

    if (this.core.raw_response) |raw_response| {
        var preparation = raw_response.prepareUpgrade(websocket_key, sec_websocket_protocol_value, sec_websocket_extensions_value, upgrade_ctx) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidWebSocketExtensions => context.fail(.invalid_websocket_extensions, {}),
            error.WebSocketCompressionInitializationFailed => context.fail(.websocket_compression_initialization_failed, {}),
            error.InvalidWebSocketKey => context.fail(.invalid_websocket_key, {}),
            error.InvalidWebSocketProtocol => context.fail(.invalid_websocket_protocol, {}),
            error.ResponseAlreadyStarted => false,
        };
        defer preparation.deinit();
        if (headers) |custom_headers| try custom_headers.appendToUpgrade(&preparation);
        var prepared = try preparation.finish();
        defer prepared.deinit();
        resumeSocket(this);
        var owned_upgrade_context = this.upgrade_context;
        this.upgrade_context = .{};
        defer owned_upgrade_context.deinit();
        this.core.raw_response = null;
        this.core.flags.upgraded = true;
        _ = prepared.upgrade(*ServerWebSocket, ws);
        this.onRequestComplete();
    }
    return true;
}
fn prepareStopReadingBody(this: *NodeHTTPResponse) bun.JSError!?bool {
    this.upgrade_context.deinit(); // we can discard the upgrade context now

    const has_on_data = has_on_data: {
        if (!this.core.flags.hasCustomOnData) break :has_on_data false;
        var wrapper = (try this.wrapperRef()) orelse break :has_on_data false;
        defer wrapper.deinit();
        break :has_on_data NodeHTTPResponseOnDataSlot.isSetOwned(&wrapper);
    };

    if ((this.core.flags.upgraded or this.core.flags.socket_closed or this.core.flags.ended) and
        (this.body_read_ref.isActive() or this.core.body_read_state == .pending) and
        !has_on_data)
    {
        const had_ref = this.body_read_ref.isActive();
        if (!this.core.flags.upgraded and !this.core.flags.socket_closed) {
            log("clearOnData", .{});
            if (this.core.raw_response) |raw_response| {
                raw_response.clearOnData();
            }
        }

        this.core.body_read_state = .done;
        return had_ref;
    }
    return null;
}

pub fn maybeStopReadingBody(this: *NodeHTTPResponse) void {
    const had_ref = (this.prepareStopReadingBody() catch |err| return this.server.globalThis().reportActiveExceptionAsUnhandled(err)) orelse return;
    this.body_read_ref.release();
    if (had_ref) this.markRequestAsDoneIfNecessary();
}

fn maybeStopReadingBodyFromBinding(
    this: *NodeHTTPResponse,
    context: anytype,
) bun.JSError!void {
    const had_ref = (try this.prepareStopReadingBody()) orelse return;
    this.body_read_ref.releaseForVM(context.vmIdentity());
    if (had_ref) this.markRequestAsDoneIfNecessary();
}

pub fn shouldRequestBePending(this: *const NodeHTTPResponse) bool {
    return this.core.shouldRequestBePending();
}

fn dumpRequestBody(
    this: *NodeHTTPResponse,
    receiver: bindgen.ClassRefView(NodeHTTPResponseClassSchema),
) void {
    if (this.core.buffered_body.capacity > 0) {
        this.core.clearBody();
    }
    if (!this.core.flags.request_has_completed) {
        this.clearOnDataCallbackView(receiver);
    }
}

fn markRequestAsDone(this: *NodeHTTPResponse) void {
    log("markRequestAsDone()", .{});
    defer this.deref();
    this.core.flags.is_request_pending = false;

    this.clearRequestPromise();
    this.clearOnDataCallbackOwned();
    this.body_read_ref.release();
    this.releaseRequestRouting();

    this.core.clearBody();
    const server = this.server;
    this.poll_ref.release();
    this.unregisterAutoFlush();

    server.onRequestComplete();
}

fn releaseRequestRouting(this: *NodeHTTPResponse) void {
    this.upgrade_context.deinit();
    this.routes.deinit();
}

fn markRequestAsDoneIfNecessary(this: *NodeHTTPResponse) void {
    if (this.core.flags.is_request_pending and !this.shouldRequestBePending()) {
        this.markRequestAsDone();
    }
}

pub fn requestHasBody(request: *uws.Request) bool {
    const method = HTTP.Method.which(request.method()) orelse HTTP.Method.OPTIONS;
    // Node.js accepts request bodies on GET.
    if (!method.hasRequestBody() and method != HTTP.Method.GET) return false;

    if (request.header("content-length")) |content_length| {
        log("content-length: {s}", .{content_length});
        if ((std.fmt.parseInt(usize, content_length, 10) catch 0) > 0) return true;
    }

    return request.header("transfer-encoding") != null;
}

fn create(
    any_server_handle: NodeHTTPResponseAnyServerHandle,
    context: anytype,
    has_body: bool,
    request: *uws.Request,
    is_ssl: bool,
    response_ptr: *anyopaque,
    upgrade_ctx: ?*uws.WebSocketUpgradeContext,
) bun.JSError!bindgen.ClassRef(NodeHTTPResponseClassSchema) {
    const server = AnyServer{ .ptr = AnyServer.Ptr.from(@ptrCast(any_server_handle)) };
    const response = try bun.tryNew(NodeHTTPResponse, .{
        .ref_count = .init(),

        .upgrade_context = .{
            .context = @ptrCast(upgrade_ctx),
            .request = request,
        },
        .server = server,
        .routes = server.retainRoutes(),
        .core = .{
            .allocator = bun.default_allocator,
            .flags = .{ .socket_closed = true, .is_request_pending = false },
            .raw_response = switch (is_ssl) {
                true => uws.AnyResponse{ .SSL = @ptrCast(response_ptr) },
                false => uws.AnyResponse{ .TCP = @ptrCast(response_ptr) },
            },
            .body_read_state = if (has_body) .pending else .none,
        },
    });

    const binding = bun.tryNew(JSBinding, .{ .response = .adopt(response) }) catch |failure| {
        response.deref();
        return failure;
    };
    var reference = try NodeHTTPResponseClass.adoptResult(binding, context);
    errdefer reference.deinit();
    response.wrapper = try NodeHTTPResponseClass.ActivityWrapper.initRef(&reference);
    return reference;
}

pub fn activateRequest(this: *NodeHTTPResponse, vm: bindgen.VMIdentity) void {
    bun.assert(this.core.flags.socket_closed and !this.core.flags.is_request_pending);
    this.core.flags.socket_closed = false;
    this.core.flags.is_request_pending = true;
    this.server.onPendingRequest();
    // The wrapper adopts the initial reference; the request lifecycle owns one more.
    this.ref();
    if (this.core.body_read_state == .pending) this.body_read_ref.acquire(vm);
    this.poll_ref.acquire(vm);
}

pub fn setOnAbortedHandler(this: *NodeHTTPResponse) void {
    if (this.core.flags.socket_closed) {
        return;
    }
    // Don't overwrite WebSocket user data
    if (!this.core.flags.upgraded) {
        if (this.core.raw_response) |raw_response| {
            raw_response.onTimeout(*NodeHTTPResponse, onTimeout, this);
        }
    }
}

pub fn prepareForAsync(this: *NodeHTTPResponse) bun.OOM!void {
    try this.upgrade_context.preserveWebSocketHeadersIfNeeded();
    this.setOnAbortedHandler();
}

pub fn getHasBody(this: *const NodeHTTPResponse) i32 {
    return this.core.getHasBody();
}

pub fn getBufferedAmount(this: *const NodeHTTPResponse) u64 {
    return this.core.getBufferedAmount();
}

fn handleEndedIfNecessary(state: uws.State, context: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
    if (!state.isResponsePending()) {
        return context.fail(.headers_ended, {});
    }
}

fn writeHead(this: *NodeHTTPResponse, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
    const initial_response = (this.core.checkHeaders() catch |err| return switch (err) {
        error.StreamFinished => context.fail(.stream_finished, {}),
        error.HeadersEnded => context.fail(.headers_ended, {}),
    }) orelse return;
    const state = initial_response.state();

    const converted_status_code = try args.statusCode.convert(context);
    const status_code = converted_status_code.value orelse 200;

    const converted_status_message = try args.statusMessage.convert(context);

    var stack_fallback_buffer: [256]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buffer, bun.default_allocator);
    const allocator = stack_fallback.allocator();
    const status_message_slice = if (converted_status_message.value) |*value|
        try value.toUTF8(allocator)
    else
        bun.String.Slice.empty;
    defer status_message_slice.deinit();

    if (state.isHttpStatusCalled()) {
        return context.fail(.headers_started, {});
    }

    @TypeOf(this.core).validateStatusMessage(status_message_slice.slice()) catch
        return context.fail(.invalid_status_message, {});

    const converted_headers = try args.headers.convert(context);
    const headers = if (converted_headers.value) |*value| value.get() else null;
    const response = this.core.raw_response orelse return;
    if (this.core.flags.socket_closed or this.core.flags.upgraded) return;
    const current_state = response.state();
    try handleEndedIfNecessary(current_state, context);
    if (current_state.isHttpStatusCalled()) return context.fail(.headers_started, {});

    do_it: {
        if (status_message_slice.length() == 0) {
            if (HTTPStatusText.get(@intCast(status_code))) |status_message| {
                writeHeadInternal(response, status_message, headers) catch |err| {
                    this.abortWrite(if (err == error.ConnectionClosed) null else response);
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                };
                break :do_it;
            }
        }

        const message = status_message_slice.slice();
        const status_message = try std.fmt.allocPrint(allocator, "{d} {s}", .{ status_code, message });
        defer allocator.free(status_message);
        writeHeadInternal(response, status_message, headers) catch |err| {
            this.abortWrite(if (err == error.ConnectionClosed) null else response);
            if (err == error.OutOfMemory) return error.OutOfMemory;
        };
        break :do_it;
    }
}

fn writeHeadInternal(
    response: uws.AnyResponse,
    status_message: []const u8,
    headers: ?*jsc.WebCore.FetchHeaders,
) uws.ResponseWriteError!void {
    log("writeHeadInternal({s})", .{status_message});
    const Operation = struct {
        response: uws.AnyResponse,
        status: []const u8,
        headers: ?*jsc.WebCore.FetchHeaders,
        result: uws.ResponseWriteError!void = {},

        fn run(operation: *@This()) void {
            operation.result = operation.write();
        }

        fn write(operation: *@This()) uws.ResponseWriteError!void {
            try operation.response.writeStatus(operation.status);
            if (operation.headers) |values| {
                if (values.fastHas(.ContentLength) and !values.fastHas(.Date)) try operation.response.writeMark();
                try values.writeToResponse(operation.response, .{});
            }
        }
    };
    var operation: Operation = .{ .response = response, .status = status_message, .headers = headers };
    try response.runCorkedWithType(*Operation, Operation.run, &operation);
    try operation.result;
}

fn writeContinue(this: *NodeHTTPResponse, context: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
    if (this.core.flags.isDone()) {
        return;
    }
    const raw_response = this.core.raw_response orelse return;
    const state = raw_response.state();
    try handleEndedIfNecessary(state, context);

    raw_response.writeContinue() catch |err| {
        this.abortWrite(if (err == error.ConnectionClosed) null else raw_response);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ConnectionClosed, error.WriteFailed => {},
        };
    };
}

pub const AbortEvent = enum(u8) {
    none = 0,
    abort = 1,
    timeout = 2,
};

fn clearResponseCallbacksView(receiver: bindgen.ClassRefView(NodeHTTPResponseClassSchema)) void {
    NodeHTTPResponseOnAbortedSlot.clearView(receiver);
    NodeHTTPResponseOnWritableSlot.clearView(receiver);
}

fn clearResponseCallbacksOwned(receiver: *const bindgen.ClassRef(NodeHTTPResponseClassSchema)) void {
    NodeHTTPResponseOnAbortedSlot.clearOwned(receiver);
    NodeHTTPResponseOnWritableSlot.clearOwned(receiver);
}

fn clearStoredResponseCallbacks(this: *const NodeHTTPResponse) void {
    var receiver = (this.wrapperRef() catch |err| return this.server.globalThis().reportActiveExceptionAsUnhandled(err)) orelse return;
    defer receiver.deinit();
    clearResponseCallbacksOwned(&receiver);
}

fn clearTerminalCallbacksView(receiver: bindgen.ClassRefView(NodeHTTPResponseClassSchema)) void {
    clearResponseCallbacksView(receiver);
    NodeHTTPResponseOnDataSlot.clearView(receiver);
}

fn clearTerminalCallbacksOwned(receiver: *const bindgen.ClassRef(NodeHTTPResponseClassSchema)) void {
    clearResponseCallbacksOwned(receiver);
    NodeHTTPResponseOnDataSlot.clearOwned(receiver);
}

fn handleAbortOrTimeout(this: *NodeHTTPResponse, comptime event: AbortEvent) void {
    this.ref();
    defer this.deref();
    if (event == .abort) {
        if (!this.core.beginAbort()) return;
        this.releasePendingWrite();
    } else if (this.core.flags.request_has_completed or this.core.flags.socket_closed or this.core.flags.upgraded) {
        return;
    }

    defer if (event == .abort) this.markRequestAsDoneIfNecessary();

    var receiver = this.wrapperRef() catch |err| failed: {
        this.server.globalThis().reportActiveExceptionAsUnhandled(err);
        break :failed null;
    };
    defer if (receiver) |*reference| reference.deinit();
    defer if (event == .abort) {
        if (receiver) |*reference| clearTerminalCallbacksOwned(reference);
    };

    if (!this.core.flags.request_has_completed) if (receiver) |*reference| {
        if (NodeHTTPResponseOnAbortedSlot.ownedCallback(reference) catch |err| failed: {
            this.server.globalThis().reportActiveExceptionAsUnhandled(err);
            break :failed null;
        }) |callback_| {
            var callback = callback_;
            defer callback.deinit();
            var invocation: @TypeOf(callback).Invocation = undefined;
            callback.beginInvocation(&invocation);
            defer invocation.deinit();
            invocation.dispatch(.{ .bindingThis = reference.operand(&invocation), .event = @backingInt(event) });
        }
    };

    if (event == .abort) {
        this.onDataOrAborted("", true, .abort);
    }
}

pub fn onAbort(this: *NodeHTTPResponse) void {
    log("onAbort", .{});
    this.handleAbortOrTimeout(.abort);
}

fn cancelClose(this: *NodeHTTPResponse) void {
    this.ref();
    defer this.deref();
    const was_pending = this.core.flags.is_request_pending;
    this.core.flags.is_request_pending = false;
    this.core.abort_delivered = true;
    this.core.flags.socket_closed = true;
    this.core.raw_response = null;
    this.releasePendingWrite();
    this.clearRequestPromise();
    this.core.body_read_state = .done;
    this.body_read_ref.release();
    this.poll_ref.release();
    this.releaseRequestRouting();
    this.core.clearBody();
    this.unregisterAutoFlush();

    if (was_pending) {
        const server = this.server;
        this.deref();
        server.onRequestCancelled();
    }
}

pub fn onTimeout(this: *NodeHTTPResponse, _: uws.AnyResponse) void {
    log("onTimeout", .{});
    this.handleAbortOrTimeout(.timeout);
}

fn doPause(this: *NodeHTTPResponse) bool {
    log("doPause", .{});
    if (!this.core.canRead()) {
        return false;
    }
    this.core.flags.is_data_buffered_during_pause = true;
    this.core.raw_response.?.onData(*NodeHTTPResponse, onBufferRequestBodyWhilePaused, this);

    // TODO: figure out why windows is not emitting EOF with UV_DISCONNECT
    if (!Environment.isWindows) {
        pauseSocket(this);
    }
    return true;
}

fn drainRequestBody(this: *NodeHTTPResponse) bun.OOM!?bindgen.OwnedBytes {
    var bytes = this.takeBufferedRequestBodyFromPause() orelse return null;
    defer bytes.deinit(bun.default_allocator);
    return try bindgen.OwnedBytes.fromSlice(bytes.items);
}

fn takeBufferedRequestBodyFromPause(this: *NodeHTTPResponse) ?std.ArrayList(u8) {
    return this.core.takeBody();
}

fn doResume(this: *NodeHTTPResponse) bun.OOM!bindgen.Return(NodeHTTPResponseResumeSchema) {
    log("doResume", .{});
    if (!this.core.canRead()) {
        return .{ .boolean = false };
    }
    this.setOnAbortedHandler();
    this.core.raw_response.?.onData(*NodeHTTPResponse, onData, this);
    this.core.flags.is_data_buffered_during_pause = false;
    var result: bindgen.Return(NodeHTTPResponseResumeSchema) = .{ .boolean = true };

    if (this.takeBufferedRequestBodyFromPause()) |buffered| {
        var buffered_data = buffered;
        defer buffered_data.deinit(bun.default_allocator);
        result = .{ .buffer = try bindgen.OwnedBytes.fromSlice(buffered_data.items) };
    }

    resumeSocket(this);
    return result;
}

pub fn onRequestComplete(this: *NodeHTTPResponse) void {
    if (!this.core.finish()) return;
    this.poll_ref.release();
    this.markRequestAsDoneIfNecessary();
}

fn onResolve(
    context: bun.bindgen.CallContext(NodeHTTPRequestOnResolveSchema),
    args: bun.bindgen.Args(NodeHTTPRequestOnResolveSchema),
) bun.JSError!void {
    log("onResolve", .{});
    const this = PromiseReaction.take(args.context) orelse return;
    defer this.deref();
    this.clearRequestPromise();
    this.maybeStopReadingBodyFromBinding(context) catch |failure| {
        this.finishRequestWithError(true);
        return failure;
    };

    this.finishRequest(false, false);
}

fn onReject(
    context: bun.bindgen.CallContext(NodeHTTPRequestOnRejectSchema),
    args: bun.bindgen.Args(NodeHTTPRequestOnRejectSchema),
) bun.JSError!void {
    const this = PromiseReaction.take(args.context) orelse return;
    defer this.deref();
    this.clearRequestPromise();
    this.maybeStopReadingBodyFromBinding(context) catch |failure| {
        this.finishRequestWithError(true);
        return failure;
    };

    this.finishRequestWithError(false);
    _ = context.reportUncaughtException(args.errorValue.operand(context).asAny(), true);
}

pub fn finishRequestWithError(this: *NodeHTTPResponse, close_connection: bool) void {
    this.finishRequest(true, close_connection);
}

fn finishRequest(this: *NodeHTTPResponse, failed: bool, close_connection: bool) void {
    if (!this.core.flags.request_has_completed and !this.core.flags.socket_closed and !this.core.flags.upgraded) {
        this.clearStoredResponseCallbacks();
        this.clearOnDataCallbackOwned();
        if (failed) this.releasePendingWrite();
        log("clearOnData", .{});
        if (this.core.raw_response) |raw_response| {
            if (!failed) this.spillPendingWrite(raw_response) catch |err| {
                this.reportWriteFailure(raw_response, err);
                return;
            };
            this.core.finishRequest(raw_response, failed, close_connection) catch |err| {
                this.reportWriteFailure(raw_response, err);
                return;
            };
        } else {
            this.core.flags.ended = true;
            this.core.body_read_state = .done;
        }

        this.body_read_ref.release();
        this.onRequestComplete();
    }
}

fn abort(
    this: *NodeHTTPResponse,
    receiver: bindgen.ClassRefView(NodeHTTPResponseClassSchema),
) bun.JSError!void {
    if (this.core.flags.isDone() or this.core.flags.upgraded) {
        return;
    }

    this.ref();
    defer this.deref();
    clearTerminalCallbacksView(receiver);
    if (this.core.raw_response) |raw_response| {
        this.abortWrite(raw_response);
    } else {
        this.onAbort();
    }
    this.onRequestComplete();
}

fn onBufferRequestBodyWhilePaused(this: *NodeHTTPResponse, chunk: []const u8, last: bool) void {
    log("onBufferRequestBodyWhilePaused({d}, {})", .{ chunk.len, last });
    this.core.bufferBody(chunk) catch |err| {
        this.server.globalThis().reportActiveExceptionAsUnhandled(err);
        this.abortWrite(this.core.raw_response);
        return;
    };
    if (last) {
        this.core.flags.is_data_buffered_during_pause_last = true;
        if (this.body_read_ref.isActive()) {
            this.body_read_ref.release();
            this.markRequestAsDoneIfNecessary();
        }
    }
}

fn takeDataChunk(this: *NodeHTTPResponse, chunk: []const u8) bun.OOM!?bindgen.OwnedBytes {
    if (this.core.buffered_body.items.len > 0) {
        try this.core.bufferBody(chunk);
        var buffered = this.takeBufferedRequestBodyFromPause().?;
        defer buffered.deinit(bun.default_allocator);
        return try bindgen.OwnedBytes.fromSlice(buffered.items);
    }
    if (chunk.len == 0) return null;
    return try bindgen.OwnedBytes.fromSlice(chunk);
}

fn onDataOrAborted(this: *NodeHTTPResponse, chunk: []const u8, last: bool, event: AbortEvent) void {
    log("onDataOrAborted({d}, {})", .{ chunk.len, last });
    if (last) {
        this.ref();
        this.core.body_read_state = .done;
    }

    defer {
        if (last) {
            if (this.body_read_ref.isActive()) {
                this.body_read_ref.release();
                this.markRequestAsDoneIfNecessary();
            }

            this.deref();
        }
    }

    var receiver = (this.wrapperRef() catch |err| return this.server.globalThis().reportActiveExceptionAsUnhandled(err)) orelse return;
    defer receiver.deinit();
    var callback = (NodeHTTPResponseOnDataSlot.ownedCallback(&receiver) catch |err|
        return this.server.globalThis().reportActiveExceptionAsUnhandled(err)) orelse return;
    defer callback.deinit();

    var bytes = this.takeDataChunk(chunk) catch |err| bytes: {
        this.server.globalThis().reportUncaughtExceptionFromError(err);
        break :bytes null;
    };
    defer if (bytes) |*owned| owned.deinit();
    var invocation: @TypeOf(callback).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    invocation.dispatch(.{
        .chunk = if (bytes) |*value| value.operand() else null,
        .isLast = last,
        .event = @backingInt(event),
    });
}
pub fn onData(this: *NodeHTTPResponse, chunk: []const u8, last: bool) void {
    log("onData({d} bytes, is_last = {d})", .{ chunk.len, @intFromBool(last) });

    onDataOrAborted(this, chunk, last, .none);
}

fn onDrainCorked(
    this: *NodeHTTPResponse,
    callback: *const bindgen.Callback(NodeHTTPResponseOnWritableSlot.SemanticType),
    offset: u64,
) void {
    log("onDrainCorked({d})", .{offset});
    this.ref();
    defer this.deref();

    var invocation: @TypeOf(callback.*).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    invocation.call(.{ .offset = offset }) catch |err|
        this.server.globalThis().reportActiveExceptionAsUnhandled(err);
}

fn releasePendingWrite(this: *NodeHTTPResponse) void {
    this.core.discardPendingWrite();
    if (this.pending_source) |*source| source.deinit();
    this.pending_source = null;
}

fn spillPendingWrite(this: *NodeHTTPResponse, response: uws.AnyResponse) uws.ResponseWriteError!void {
    var source = this.pending_source orelse return;
    this.pending_source = null;
    defer source.deinit();
    try this.core.spill(response, source.slice());
}

fn abortWrite(this: *NodeHTTPResponse, response: ?uws.AnyResponse) void {
    this.ref();
    defer this.deref();
    this.releasePendingWrite();
    if (response) |live| {
        live.clearOnData();
        live.clearOnWritable();
        live.clearTimeout();
        live.clearAborted();
        live.forceClose();
    }
    this.onAbort();
}

fn reportWriteFailure(this: *NodeHTTPResponse, response: uws.AnyResponse, failure: uws.ResponseWriteError) void {
    this.ref();
    defer this.deref();
    this.abortWrite(if (failure == error.ConnectionClosed) null else response);
    if (failure == error.OutOfMemory) this.server.globalThis().reportActiveExceptionAsUnhandled(error.OutOfMemory);
}

fn failWriteFromBinding(this: *NodeHTTPResponse, response: uws.AnyResponse, failure: uws.ResponseWriteError, comptime is_end: bool) bun.OOM!?f64 {
    this.abortWrite(if (failure == error.ConnectionClosed) null else response);
    return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.ConnectionClosed, error.WriteFailed => if (is_end) null else 0,
    };
}

fn onDrain(this: *NodeHTTPResponse, offset: u64, response: uws.AnyResponse) bool {
    log("onDrain({d})", .{offset});

    response.clearOnWritable();
    if (this.core.flags.socket_closed or this.core.flags.request_has_completed or this.core.flags.upgraded) {
        this.releasePendingWrite();
        return false;
    }

    const bytes = if (this.pending_source) |*source| source.slice() else &.{};
    const result = this.core.drain(response, bytes) catch |err| {
        this.reportWriteFailure(response, err);
        return false;
    };
    switch (result) {
        .closed => {
            this.releasePendingWrite();
            return false;
        },
        .pending_body => {
            response.onWritable(*NodeHTTPResponse, onDrain, this);
            return false;
        },
        .pending_framing => {
            this.releasePendingWrite();
            response.onWritable(*NodeHTTPResponse, onDrain, this);
            return false;
        },
        .ready => this.releasePendingWrite(),
    }

    var receiver = (this.wrapperRef() catch |err| {
        this.server.globalThis().reportActiveExceptionAsUnhandled(err);
        return false;
    }) orelse return false;
    defer receiver.deinit();
    var callback = (NodeHTTPResponseOnWritableSlot.takeOwnedCallback(&receiver) catch |err| {
        this.server.globalThis().reportActiveExceptionAsUnhandled(err);
        return false;
    }) orelse return true;
    defer callback.deinit();

    response.corked(onDrainCorked, .{ this, &callback, offset }) catch |err| {
        this.reportWriteFailure(response, err);
        return false;
    };
    return true;
}

fn convertWriteOperand(context: anytype, argument: anytype, last: bool) @TypeOf(argument.convert(context)) {
    if (!last) return argument.convert(context);
    const forced = try argument.convertLast(context);
    try context.lease(forced.proof);
    return forced.converted;
}

fn writeOrEnd(
    this: *NodeHTTPResponse,
    context: anytype,
    args: anytype,
    receiver: bindgen.ClassRefView(NodeHTTPResponseClassSchema),
    comptime is_end: bool,
) bun.bindgen.CallError(@TypeOf(context))!?f64 {
    const raw_response = (this.core.checkWrite() catch return context.fail(.write_after_end, {})) orelse
        return if (is_end) null else 0;

    const converted_encoding_or_callback = if (args.encoding_or_callback) |value|
        try convertWriteOperand(context, value, args.input == null and args.callback == null)
    else
        null;

    var encoding: bun.api.node.Encoding = .utf8;
    var callback: ?*const bindgen.CallbackView(NodeHTTPResponseOnWritableSlot.SemanticType) = null;
    var second_argument_is_callback = false;
    if (converted_encoding_or_callback) |*converted| switch (converted.value) {
        .callback => |*value| {
            callback = value;
            second_argument_is_callback = true;
        },
        .encoding => |value| encoding = bun.api.node.Encoding.fromBindgen(value),
    };

    const converted_callback = callback: {
        if (args.callback) |value| {
            if (second_argument_is_callback) {
                if (args.input == null) {
                    try context.lease(try value.discardLast(context));
                } else {
                    try value.discard(context);
                }
                break :callback null;
            }
            break :callback try convertWriteOperand(context, value, args.input == null);
        }
        break :callback null;
    };
    if (converted_callback) |*value| callback = &value.value;

    const strict_content_length: ?u64 = if (args.strict_content_length) |value|
        switch (value) {
            .number => |number| number,
            .ignored => null,
        }
    else
        null;

    const converted_input = if (args.input) |value| try convertWriteOperand(context, value, true) else null;
    var string_or_buffer = if (converted_input) |*value|
        try bun.api.node.StringOrBuffer.fromBindgen(value.value, encoding)
    else
        bun.api.node.StringOrBuffer.empty;
    defer string_or_buffer.deinit();

    _ = (this.core.revalidateWrite(raw_response) catch return context.fail(.write_after_end, {})) orelse
        return if (is_end) null else 0;

    const bytes = string_or_buffer.slice();

    if (comptime is_end) {
        log("end('{s}', {d})", .{ bytes[0..@min(bytes.len, 128)], bytes.len });
    } else {
        log("write('{s}', {d})", .{ bytes[0..@min(bytes.len, 128)], bytes.len });
    }
    this.core.recordWrite(bytes.len, strict_content_length, is_end) catch
        return context.fail(.content_length_mismatch, {});

    this.spillPendingWrite(raw_response) catch |err| return this.failWriteFromBinding(raw_response, err, is_end);

    if (is_end) {

        // Discard the body read ref if it's pending and no onData callback is set at this point.
        // This is the equivalent of req._dump().
        if (this.body_read_ref.isActive() and this.core.body_read_state == .pending and
            (!this.core.flags.hasCustomOnData or !NodeHTTPResponseOnDataSlot.isSetView(receiver)))
        {
            this.body_read_ref.releaseForVM(context.vmIdentity());
            this.core.body_read_state = .none;
        }

        clearResponseCallbacksView(receiver);

        raw_response.clearAborted();
        raw_response.clearOnWritable();
        raw_response.clearTimeout();
        this.core.end(raw_response, bytes) catch |err| return this.failWriteFromBinding(raw_response, err, is_end);
        this.onRequestComplete();

        return @floatFromInt(bytes.len);
    } else {
        const result = this.core.write(raw_response, bytes) catch |err|
            return this.failWriteFromBinding(raw_response, err, is_end);
        switch (result) {
            .ready => |written| {
                raw_response.clearOnWritable();
                NodeHTTPResponseOnWritableSlot.clearView(receiver);
                return @floatFromInt(written);
            },
            .backpressure => |pending| {
                if (pending.retain_input) {
                    this.pending_source = string_or_buffer;
                    string_or_buffer = .empty;
                }
                if (callback) |value| NodeHTTPResponseOnWritableSlot.setView(receiver, value.*);
                if (this.pending_source != null or callback != null)
                    raw_response.onWritable(*NodeHTTPResponse, onDrain, this);
                return @floatFromInt(-@as(i64, @intCast(@min(pending.written, std.math.maxInt(i64)))));
            },
        }
    }
}

fn clearOnDataState(this: *NodeHTTPResponse) void {
    log("clearOnDataCallback", .{});
    if (this.core.body_read_state != .none) {
        if (!this.core.flags.socket_closed and !this.core.flags.upgraded) {
            log("clearOnData", .{});
            if (this.core.raw_response) |raw_response| {
                raw_response.clearOnData();
            }
        }
        if (this.core.body_read_state != .done) {
            this.core.body_read_state = .done;
        }
    }
}

fn clearOnDataCallbackView(
    this: *NodeHTTPResponse,
    receiver: bindgen.ClassRefView(NodeHTTPResponseClassSchema),
) void {
    NodeHTTPResponseOnDataSlot.clearView(receiver);
    this.clearOnDataState();
}

fn clearOnDataCallbackOwned(this: *NodeHTTPResponse) void {
    defer this.clearOnDataState();
    if (this.wrapperRef() catch |err| return this.server.globalThis().reportActiveExceptionAsUnhandled(err)) |wrapper_| {
        var wrapper = wrapper_;
        defer wrapper.deinit();
        NodeHTTPResponseOnDataSlot.clearOwned(&wrapper);
    }
}

fn setOnData(
    this: *NodeHTTPResponse,
    receiver: bindgen.ClassRefView(NodeHTTPResponseClassSchema),
    value: @FieldType(bindgen.Args(NodeHTTPResponseOnDataSetterSchema), "value"),
) bun.JSError!void {
    // Only `.pending` accepts a callback. `.done` means either uSockets delivered last=true or JS
    // previously cleared `ondata` (which already called clearOnData()); either way, there is no
    // more body to read, so don't re-register with uSockets or churn refs.
    const has_callback = switch (value) {
        .callback => true,
        .ignored => false,
    };
    if (!has_callback or this.core.flags.ended or this.core.flags.socket_closed or this.core.body_read_state != .pending or this.core.flags.is_data_buffered_during_pause_last or this.core.flags.upgraded) {
        this.clearOnDataCallbackView(receiver);
        defer {
            if (this.body_read_ref.isActive()) {
                this.body_read_ref.release();
            }
        }
        return;
    }

    switch (value) {
        .callback => |callback_value| NodeHTTPResponseOnDataSlot.setView(receiver, callback_value),
        .ignored => unreachable,
    }
    this.core.flags.hasCustomOnData = true;
    if (this.core.raw_response) |raw_response| {
        raw_response.onData(*NodeHTTPResponse, onData, this);
    }
    this.core.flags.is_data_buffered_during_pause = false;

    // Every release also transitions out of `.pending` or marks the final paused chunk, both of
    // which are rejected above, so this path still owns the reference acquired during creation.
    bun.debugAssert(this.body_read_ref.isActive());
}

pub fn onAutoFlush(this: *NodeHTTPResponse) bool {
    if (!this.core.flags.socket_closed and !this.core.flags.upgraded and this.core.raw_response != null) {
        const response = this.core.raw_response.?;
        response.uncork() catch |err| this.reportWriteFailure(response, err);
    }
    return false;
}

fn registerAutoFlush(this: *NodeHTTPResponse) void {
    if (this.auto_flusher.isRegistered()) return;
    AutoFlusherEngine.registerUnchecked(NodeHTTPResponse, this, &this.auto_flusher, jsc.VirtualMachine.get());
}

fn unregisterAutoFlush(this: *NodeHTTPResponse) void {
    if (!this.auto_flusher.isRegistered()) return;
    AutoFlusherEngine.unregisterUnchecked(NodeHTTPResponse, this, &this.auto_flusher, jsc.VirtualMachine.get());
}

fn flushHeaders(this: *NodeHTTPResponse) bun.OOM!void {
    if (!this.core.flags.socket_closed and !this.core.flags.upgraded and this.core.raw_response != null) {
        const raw_response = this.core.raw_response.?;
        // Don’t flush immediately; queue a microtask to uncork the socket.
        raw_response.flushHeaders(false) catch |err| {
            this.abortWrite(if (err == error.ConnectionClosed) null else raw_response);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ConnectionClosed, error.WriteFailed => {},
            };
        };
        if (raw_response.isCorked()) {
            this.registerAutoFlush();
        }
    }
}

pub fn setTimeout(this: *NodeHTTPResponse, seconds: u32) bool {
    return this.core.setTimeout(seconds);
}

fn cork(
    this: *NodeHTTPResponse,
    callback: bindgen.CallbackView(NodeHTTPResponseCorkCallbackType),
) bun.JSError!bindgen.Return(NodeHTTPResponseCorkCallbackType) {
    var result: ?bindgen.Return(NodeHTTPResponseCorkCallbackType) = null;
    var failure: ?bun.JSError = null;
    var write_failure: ?uws.ResponseWriteError = null;
    const Handler = struct {
        fn run(
            function: bindgen.CallbackView(NodeHTTPResponseCorkCallbackType),
            output: *?bindgen.Return(NodeHTTPResponseCorkCallbackType),
            error_value: *?bun.JSError,
        ) void {
            output.* = function.call(.{}) catch |err| {
                error_value.* = err;
                return;
            };
        }
    };

    this.ref();
    defer this.deref();

    if (this.core.raw_response) |raw_response| {
        raw_response.corked(Handler.run, .{ callback, &result, &failure }) catch |err| {
            write_failure = err;
        };
    } else {
        Handler.run(callback, &result, &failure);
    }
    if (failure) |err| return err;
    if (write_failure) |err| {
        this.abortWrite(if (err == error.ConnectionClosed) null else this.core.raw_response);
        if (err == error.OutOfMemory) return error.OutOfMemory;
    }
    return result orelse @panic("cork callback was not invoked");
}

fn deinit(this: *NodeHTTPResponse) void {
    bun.debugAssert(!this.body_read_ref.isActive());
    bun.debugAssert(!this.poll_ref.isActive());
    bun.debugAssert(!this.core.flags.is_request_pending);
    bun.debugAssert(this.core.flags.socket_closed or this.core.flags.request_has_completed);

    this.core.deinit();
    this.releasePendingWrite();
    this.poll_ref.release();
    this.body_read_ref.release();

    this.clearRequestPromise();
    this.releaseRequestRouting();
    bun.destroy(this);
}

comptime {
    _ = NodeHTTPResponseCreateForServerBinding;
    _ = NodeHTTPResponseOnCloseBinding;
    _ = NodeHTTPResponseSetClosedBinding;
    _ = NodeHTTPResponseRetainCloseStateBinding;
    _ = NodeHTTPResponseReleaseCloseStateBinding;
    _ = NodeHTTPResponseSetTimeoutBinding;
    _ = NodeHTTPRequestOnResolveBinding;
    _ = NodeHTTPRequestOnRejectBinding;
}

fn bindNodeHTTPResponseCreateForServer(
    context: bun.bindgen.CallContext(NodeHTTPResponseCreateForServerSchema),
    args: bun.bindgen.Args(NodeHTTPResponseCreateForServerSchema),
) bun.JSError!bun.bindgen.Return(NodeHTTPResponseCreateForServerSchema) {
    const request: *uws.Request = @ptrCast(@alignCast(args.request));
    const response: *anyopaque = @ptrCast(args.response);
    const upgrade_context: ?*uws.WebSocketUpgradeContext = if (args.upgradeContext) |value| @ptrCast(@alignCast(value)) else null;
    return create(
        args.anyServer,
        context,
        args.hasBody,
        request,
        args.isSSL,
        response,
        upgrade_context,
    );
}

fn bindNodeHTTPResponseOnClose(
    _: bun.bindgen.CallContext(NodeHTTPResponseOnCloseSchema),
    args: bun.bindgen.Args(NodeHTTPResponseOnCloseSchema),
) bun.bindgen.Return(NodeHTTPResponseOnCloseSchema) {
    args.response.onAbort();
}

fn bindNodeHTTPResponseSetClosed(
    args: bun.bindgen.Args(NodeHTTPResponseSetClosedSchema),
) bun.bindgen.Return(NodeHTTPResponseSetClosedSchema) {
    const binding = args.response;
    const node_response = binding.response.get();
    node_response.core.flags.socket_closed = true;
    node_response.core.raw_response = null;
    node_response.releasePendingWrite();
}

fn bindNodeHTTPResponseRetainCloseState(
    args: bun.bindgen.Args(NodeHTTPResponseRetainCloseStateSchema),
) bun.bindgen.Return(NodeHTTPResponseRetainCloseStateSchema) {
    const response = args.response.response.get();
    response.ref();
    return bun.bindgen.Return(NodeHTTPResponseRetainCloseStateSchema).initNative(response);
}

fn bindNodeHTTPResponseReleaseCloseState(
    args: bun.bindgen.Args(NodeHTTPResponseReleaseCloseStateSchema),
) bun.bindgen.Return(NodeHTTPResponseReleaseCloseStateSchema) {
    defer args.response.deref();
    args.response.cancelClose();
}

fn bindNodeHTTPResponseSetTimeout(
    _: bun.bindgen.CallContext(NodeHTTPResponseSetTimeoutSchema),
    args: bun.bindgen.Args(NodeHTTPResponseSetTimeoutSchema),
) bun.JSError!bun.bindgen.Return(NodeHTTPResponseSetTimeoutSchema) {
    const binding = args.response;
    return binding.response.get().setTimeout(args.seconds);
}

const std = @import("std");

const bun = @import("bun");
const bindgen = bun.bindgen;
const ResponseCore = @import("network_core").response;
const Environment = bun.Environment;
const HTTP = bun.http;
const uws = bun.uws;
const HTTPStatusText = bun.api.server.HTTPStatusText;

const jsc = bun.jsc;
const AutoFlusher = jsc.WebCore.AutoFlusher;
const AutoFlusherEngine = jsc.WebCore.AutoFlusherEngine;

const AnyServer = jsc.API.AnyServer;
const ServerWebSocket = jsc.API.ServerWebSocket;

const NodeHTTPBindings = bun.bindgen.Module("NodeHTTP");
const NodeHTTPResponseBindings = bun.bindgen.Module("NodeHTTPResponse");
const NodeHTTPResponseCallbackBindings = bun.bindgen.Module("NodeHTTPResponseCallbacks");
const NodeHTTPResponseClassSchema = NodeHTTPResponseBindings.class("NodeHTTPResponse");
const NodeHTTPResponseClass = bindgen.Class(NodeHTTPResponseClassSchema, JSBinding);
const NodeHTTPResponseAbortSchema = NodeHTTPResponseClassSchema.member("abort");
const NodeHTTPResponseBufferedAmountSchema = NodeHTTPResponseClassSchema.memberKind("bufferedAmount", .getter);
const NodeHTTPResponseCorkSchema = NodeHTTPResponseClassSchema.member("cork");
const NodeHTTPResponseCorkCallbackType = NodeHTTPResponseCorkSchema.args[0].ArgumentType;
const NodeHTTPResponseDrainRequestBodySchema = NodeHTTPResponseClassSchema.member("drainRequestBody");
const NodeHTTPResponseDumpRequestBodySchema = NodeHTTPResponseClassSchema.member("dumpRequestBody");
const NodeHTTPResponseEndSchema = NodeHTTPResponseClassSchema.member("end");
const NodeHTTPResponseFlagsSchema = NodeHTTPResponseClassSchema.memberKind("flags", .getter);
const NodeHTTPResponseFlushHeadersSchema = NodeHTTPResponseClassSchema.member("flushHeaders");
const NodeHTTPResponseGetBytesWrittenSchema = NodeHTTPResponseClassSchema.member("getBytesWritten");
const NodeHTTPResponseHasBodySchema = NodeHTTPResponseClassSchema.memberKind("hasBody", .getter);
const NodeHTTPResponseHasCustomOnDataSetterSchema = NodeHTTPResponseClassSchema.memberKind("hasCustomOnData", .setter);
const NodeHTTPResponseOnDataSetterSchema = NodeHTTPResponseClassSchema.memberKind("ondata", .setter);
const NodeHTTPResponsePauseSchema = NodeHTTPResponseClassSchema.member("pause");
const NodeHTTPResponseResumeSchema = NodeHTTPResponseClassSchema.member("resume");
const NodeHTTPResponseWriteSchema = NodeHTTPResponseClassSchema.member("write");
const NodeHTTPResponseWriteContinueSchema = NodeHTTPResponseClassSchema.member("writeContinue");
const NodeHTTPResponseWriteHeadSchema = NodeHTTPResponseClassSchema.member("writeHead");
const NodeHTTPResponseOnAbortedSlot = NodeHTTPResponseClass.CachedSlot("onAborted");
const NodeHTTPResponseOnWritableSlot = NodeHTTPResponseClass.CachedSlot("onWritable");
const NodeHTTPResponseOnDataSlot = NodeHTTPResponseClass.CachedSlot("onData");
const NodeHTTPServerSocketExistsForSocketSchema = NodeHTTPBindings.engineShim("nodeHTTPServerSocketExistsForSocket");
const NodeHTTPResponseCreateForServerSchema = NodeHTTPResponseBindings.nativeExport("createForServer");
const NodeHTTPResponseAnyServerHandle = @FieldType(bindgen.Args(NodeHTTPResponseCreateForServerSchema), "anyServer");
const NodeHTTPResponseOnCloseSchema = NodeHTTPResponseBindings.nativeExport("nodeHTTPResponseOnClose");
const NodeHTTPResponseSetClosedSchema = NodeHTTPResponseBindings.nativeExport("nodeHTTPResponseSetClosed");
const NodeHTTPResponseRetainCloseStateSchema = NodeHTTPResponseBindings.nativeExport("nodeHTTPResponseRetainCloseState");
const NodeHTTPResponseReleaseCloseStateSchema = NodeHTTPResponseBindings.nativeExport("nodeHTTPResponseReleaseCloseState");
const NodeHTTPResponseSetTimeoutSchema = NodeHTTPResponseBindings.nativeExport("nodeHTTPResponseSetTimeout");
const NodeHTTPRequestOnResolveSchema = NodeHTTPResponseCallbackBindings.function("onResolve");
const NodeHTTPRequestOnRejectSchema = NodeHTTPResponseCallbackBindings.function("onReject");
const PromiseReaction = bun.bindgen.PromiseReaction(NodeHTTPRequestOnResolveSchema.args[1].ArgumentType, NodeHTTPResponse);
const NodeHTTPResponseCreateForServerBinding = bun.bindgen.Fn(NodeHTTPResponseCreateForServerSchema, bindNodeHTTPResponseCreateForServer);
const NodeHTTPResponseOnCloseBinding = bun.bindgen.Fn(NodeHTTPResponseOnCloseSchema, bindNodeHTTPResponseOnClose);
const NodeHTTPResponseSetClosedBinding = bun.bindgen.Fn(NodeHTTPResponseSetClosedSchema, bindNodeHTTPResponseSetClosed);
const NodeHTTPResponseRetainCloseStateBinding = bun.bindgen.Fn(NodeHTTPResponseRetainCloseStateSchema, bindNodeHTTPResponseRetainCloseState);
const NodeHTTPResponseReleaseCloseStateBinding = bun.bindgen.Fn(NodeHTTPResponseReleaseCloseStateSchema, bindNodeHTTPResponseReleaseCloseState);
const NodeHTTPResponseSetTimeoutBinding = bun.bindgen.Fn(NodeHTTPResponseSetTimeoutSchema, bindNodeHTTPResponseSetTimeout);
pub const NodeHTTPRequestOnResolveBinding = bun.bindgen.Fn(NodeHTTPRequestOnResolveSchema, onResolve);
pub const NodeHTTPRequestOnRejectBinding = bun.bindgen.Fn(NodeHTTPRequestOnRejectSchema, onReject);

comptime {
    _ = NodeHTTPResponseClass;
}
