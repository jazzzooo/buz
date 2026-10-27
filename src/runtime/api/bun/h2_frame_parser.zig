const H2Frame = @import("../../../http/H2Frame.zig");
const MAX_PAYLOAD_SIZE_WITHOUT_FRAME = H2Frame.max_payload_size_without_frame;
const BunSocket = union(enum) {
    none: void,
    tls: *TLSSocket,
    tls_writeonly: *TLSSocket,
    tcp: *TCPSocket,
    tcp_writeonly: *TCPSocket,
};

const MAX_WINDOW_SIZE = H2Frame.max_window_size;
const MAX_HEADER_TABLE_SIZE = H2Frame.max_header_table_size;
const MAX_STREAM_ID = H2Frame.max_stream_id;
const MAX_FRAME_SIZE = H2Frame.max_frame_size;
const DEFAULT_WINDOW_SIZE = H2Frame.default_window_size;
const MAX_WINDOW_SIZE_F64 = H2Frame.max_window_size_f64;
const MAX_HEADER_TABLE_SIZE_F64 = H2Frame.max_header_table_size_f64;
const MAX_FRAME_SIZE_F64 = H2Frame.max_frame_size_f64;
const HPACK_ENTRY_OVERHEAD = Hpack.entry_overhead;
const MAX_CUSTOM_SETTINGS = H2Frame.max_custom_settings;
const PaddingStrategy = H2Frame.PaddingStrategy;
const FrameType = H2Frame.FrameType;
const PingFrameFlags = H2Frame.PingFrameFlags;
const DataFrameFlags = H2Frame.DataFrameFlags;
const HeadersFrameFlags = H2Frame.HeadersFrameFlags;
const SettingsFlags = H2Frame.SettingsFlags;
const ErrorCode = H2Frame.ErrorCode;
const SettingsType = H2Frame.SettingsType;
const UInt31WithReserved = H2Frame.UInt31WithReserved;
const StreamPriority = H2Frame.StreamPriority;
const FrameHeader = H2Frame.FrameHeader;
const SettingsPayloadUnit = H2Frame.SettingsPayloadUnit;
const FullSettingsPayload = H2Frame.FullSettingsPayload;

const ValidResponsePseudoHeaders = H2Frame.valid_response_pseudo_headers;
const ValidRequestPseudoHeaders = H2Frame.valid_request_pseudo_headers;
const SingleValueHeaders = H2Frame.single_value_headers;

pub fn jsAssertSettings(
    context: bindgen.CallContext(AssertSettingsSchema),
    args: bindgen.Args(AssertSettingsSchema),
) bindgen.CallError(AssertSettingsSchema)!void {
    if (args.settings.custom_settings) |custom| {
        try H2FrameParser.validateCustomSettings(context, custom);
    }
}

const HandlerEvent = enum {
    onError,
    onWrite,
    onStreamError,
    onStreamStart,
    onStreamHeaders,
    onStreamEnd,
    onStreamData,
    onRemoteSettings,
    onLocalSettings,
    onWantTrailers,
    onPing,
    onEnd,
    onGoAway,
    onAborted,
    onAltSvc,
    onOrigin,
    onFrameError,
};

fn dictionaryFieldType(comptime Dictionary: type, comptime field_name: []const u8) type {
    inline for (Dictionary.dictionary_fields) |Field| {
        if (std.mem.eql(u8, Field.field_name, field_name)) return Field.FieldType;
    }
    @compileError("binding dictionary has no field named '" ++ field_name ++ "'");
}

fn handlerCallbackType(comptime field_name: []const u8) type {
    const Type = dictionaryFieldType(H2HandlersSchema, field_name);
    return if (Type.kind == .optional) Type.child else Type;
}

fn callbackTypeForEvent(comptime event: HandlerEvent) type {
    return handlerCallbackType(switch (event) {
        .onError => "on_error",
        .onWrite => "on_write",
        .onStreamError => "on_stream_error",
        .onStreamStart => "on_stream_start",
        .onStreamHeaders => "on_stream_headers",
        .onStreamEnd => "on_stream_end",
        .onStreamData => "on_stream_data",
        .onRemoteSettings => "on_remote_settings",
        .onLocalSettings => "on_local_settings",
        .onWantTrailers => "on_want_trailers",
        .onPing => "on_ping",
        .onEnd => "on_end",
        .onGoAway => "on_goaway",
        .onAborted => "on_aborted",
        .onAltSvc => "on_alt_svc",
        .onOrigin => "on_origin",
        .onFrameError => "on_frame_error",
    });
}

const H2SettingsSnapshot = @FieldType(
    bindgen.Args(callbackTypeForEvent(.onRemoteSettings)),
    "settings",
);
const H2StringSequence = @FieldType(bindgen.Args(callbackTypeForEvent(.onStreamHeaders)), "headers");
const H2OriginEvent = @FieldType(bindgen.Args(callbackTypeForEvent(.onOrigin)), "origins");
const H2BinaryArgument = @FieldType(bindgen.Args(callbackTypeForEvent(.onStreamData)), "chunk");
const H2BinaryPayload = union(enum) {
    buffer: bindgen.OwnedBytes,
    arraybuffer: bindgen.OwnedBytes,
    uint8array: bindgen.OwnedBytes,

    fn operand(payload: *const @This()) H2BinaryArgument {
        return switch (payload.*) {
            inline else => |*value, tag| @unionInit(H2BinaryArgument, @tagName(tag), value.operand()),
        };
    }
};
const H2ErrorArgument = std.meta.Elem(@FieldType(bindgen.Args(callbackTypeForEvent(.onError)), "arguments"));
const H2StreamContext = @FieldType(bindgen.Args(callbackTypeForEvent(.onStreamEnd)), "stream_context");

const DecodedStrings = struct {
    values: std.ArrayList(bindgen.DOMString) = .empty,

    fn deinit(this: *DecodedStrings, allocator: Allocator) void {
        for (this.values.items) |*value| value.deinit();
        this.values.deinit(allocator);
    }

    fn appendUTF8(this: *DecodedStrings, allocator: Allocator, bytes: []const u8) bun.OOM!void {
        try this.values.ensureUnusedCapacity(allocator, 1);
        this.values.appendAssumeCapacity(try bindgen.DOMString.fromUTF8(bytes));
    }

    fn appendClone(this: *DecodedStrings, allocator: Allocator, value: *const bindgen.DOMString) bun.OOM!void {
        try this.values.ensureUnusedCapacity(allocator, 1);
        this.values.appendAssumeCapacity(value.clone());
    }

    fn operands(this: *const DecodedStrings, allocator: Allocator) bun.OOM!H2StringSequence {
        const values = try allocator.alloc(std.meta.Elem(H2StringSequence), this.values.items.len);
        for (this.values.items, values) |*value, *operand| operand.* = value.operand();
        return values;
    }
};

fn releaseBinaryPayload(payload: *H2BinaryPayload) void {
    switch (payload.*) {
        inline else => |*bytes| bytes.deinit(),
    }
}

fn binaryPayloadBytes(payload: *const H2BinaryPayload) []const u8 {
    return switch (payload.*) {
        inline else => |*bytes| bytes.slice(),
    };
}

fn settingsCallbackValue(settings: *const FullSettingsPayload) H2SettingsSnapshot {
    const snapshot = settings.snapshot();
    return .{
        .header_table_size = snapshot.header_table_size,
        .enable_push = snapshot.enable_push,
        .max_concurrent_streams = snapshot.max_concurrent_streams,
        .initial_window_size = snapshot.initial_window_size,
        .max_frame_size = snapshot.max_frame_size,
        .max_header_list_size = snapshot.max_header_list_size,
        .max_header_size = snapshot.max_header_size,
        .enable_connect_protocol = snapshot.enable_connect_protocol,
    };
}

const Handlers = struct {
    binary_type: BinaryType = .buffer,

    vm: *jsc.VirtualMachine,
    globalObject: *jsc.JSGlobalObject,
    context: ?bindgen.Root = null,
    onError: ?bindgen.Callback(callbackTypeForEvent(.onError)) = null,
    onWrite: ?bindgen.Callback(callbackTypeForEvent(.onWrite)) = null,
    onStreamError: ?bindgen.Callback(callbackTypeForEvent(.onStreamError)) = null,
    onStreamStart: ?bindgen.Callback(callbackTypeForEvent(.onStreamStart)) = null,
    onStreamHeaders: ?bindgen.Callback(callbackTypeForEvent(.onStreamHeaders)) = null,
    onStreamEnd: ?bindgen.Callback(callbackTypeForEvent(.onStreamEnd)) = null,
    onStreamData: ?bindgen.Callback(callbackTypeForEvent(.onStreamData)) = null,
    onRemoteSettings: ?bindgen.Callback(callbackTypeForEvent(.onRemoteSettings)) = null,
    onLocalSettings: ?bindgen.Callback(callbackTypeForEvent(.onLocalSettings)) = null,
    onWantTrailers: ?bindgen.Callback(callbackTypeForEvent(.onWantTrailers)) = null,
    onPing: ?bindgen.Callback(callbackTypeForEvent(.onPing)) = null,
    onEnd: ?bindgen.Callback(callbackTypeForEvent(.onEnd)) = null,
    onGoAway: ?bindgen.Callback(callbackTypeForEvent(.onGoAway)) = null,
    onAborted: ?bindgen.Callback(callbackTypeForEvent(.onAborted)) = null,
    onAltSvc: ?bindgen.Callback(callbackTypeForEvent(.onAltSvc)) = null,
    onOrigin: ?bindgen.Callback(callbackTypeForEvent(.onOrigin)) = null,
    onFrameError: ?bindgen.Callback(callbackTypeForEvent(.onFrameError)) = null,

    fn optionalCallback(value: anytype) bun.JSError!?bindgen.Callback(@TypeOf(value.?).SemanticType) {
        return if (value) |stored_callback| try stored_callback.toOwned() else null;
    }

    pub fn fromBindgen(globalObject: *jsc.JSGlobalObject, context: bindgen.AnyView, opts: anytype) bun.JSError!Handlers {
        var result: Handlers = .{
            .vm = globalObject.bunVM(),
            .globalObject = globalObject,
            .binary_type = @fromBackingInt(@intCast(@backingInt(opts.binary_type))),
        };
        errdefer result.deinit();
        result.context = try context.toRoot();
        result.onError = try optionalCallback(opts.on_error);
        result.onWrite = try opts.on_write.toOwned();
        inline for (.{
            .{ "onStreamError", "on_stream_error" },
            .{ "onStreamStart", "on_stream_start" },
            .{ "onStreamHeaders", "on_stream_headers" },
            .{ "onStreamEnd", "on_stream_end" },
            .{ "onStreamData", "on_stream_data" },
            .{ "onRemoteSettings", "on_remote_settings" },
            .{ "onLocalSettings", "on_local_settings" },
            .{ "onWantTrailers", "on_want_trailers" },
            .{ "onPing", "on_ping" },
            .{ "onEnd", "on_end" },
            .{ "onGoAway", "on_goaway" },
            .{ "onAborted", "on_aborted" },
            .{ "onAltSvc", "on_alt_svc" },
            .{ "onOrigin", "on_origin" },
            .{ "onFrameError", "on_frame_error" },
        }) |field| {
            @field(result, field[0]) = try optionalCallback(@field(opts, field[1]));
        }
        return result;
    }

    fn handlerFor(this: *Handlers, comptime event: HandlerEvent) ?*bindgen.Callback(callbackTypeForEvent(event)) {
        const field = @tagName(event);
        return if (@field(this, field)) |*stored_callback| stored_callback else null;
    }

    fn invoke(
        this: *Handlers,
        context: anytype,
        comptime event: HandlerEvent,
        args: bindgen.Args(callbackTypeForEvent(event)),
    ) bool {
        const stored_callback = this.handlerFor(event) orelse return false;
        var callback = stored_callback.clone();
        defer callback.deinit();
        callback.dispatch(context, args);
        return true;
    }

    fn deinit(this: *Handlers) void {
        if (this.context) |*context| context.deinit();
        this.context = null;
        inline for (.{
            "onError",
            "onWrite",
            "onStreamError",
            "onStreamStart",
            "onStreamHeaders",
            "onStreamEnd",
            "onStreamData",
            "onRemoteSettings",
            "onLocalSettings",
            "onWantTrailers",
            "onPing",
            "onEnd",
            "onGoAway",
            "onAborted",
            "onAltSvc",
            "onOrigin",
            "onFrameError",
        }) |field| {
            if (@field(this, field)) |*stored_callback| stored_callback.deinit();
            @field(this, field) = null;
        }
    }
};

pub const H2FrameParser = struct {
    pub const log = Output.scoped(.H2FrameParser, .visible);
    const Self = @This();

    pub const JSBinding = struct {
        bindgen_state: bindgen.ClassState = .{},
        parser: bindgen.RefNative(Self, .vm),

        pub fn construct(
            context: bindgen.CallContext(H2FrameParserConstructorSchema),
            args: bindgen.Args(H2FrameParserConstructorSchema),
        ) bindgen.CallError(H2FrameParserConstructorSchema)!*JSBinding {
            const parser = try Self.construct(context, args);
            return bun.new(JSBinding, .{ .parser = .adopt(parser) });
        }

        pub const destroy = @This().finalize;

        pub fn wrapperCreated(this: *JSBinding, wrapper: bindgen.ClassRefView(H2FrameParserSchema)) bun.JSError!void {
            const parser = this.parser.get();
            try parser.strong_this.setStrongClassView(H2FrameParserSchema, wrapper);
            errdefer parser.strong_this.deinit();
            try parser.start();
        }

        fn finalize(this: *JSBinding) void {
            this.parser.take().finalize();
            bun.destroy(this);
        }

        fn Forward(comptime member_name: []const u8) type {
            const MemberSchema = H2FrameParserSchema.member(member_name);
            return struct {
                pub fn invoke(
                    this: *JSBinding,
                    context: bindgen.CallContext(MemberSchema),
                    args: bindgen.Args(MemberSchema),
                ) bindgen.CallError(MemberSchema)!bindgen.Return(MemberSchema) {
                    const implementation = @field(Self, bindgen.ContextImplementationName(@TypeOf(context)));
                    return @call(.auto, implementation, .{ this.parser.get(), context, args });
                }
            };
        }

        pub const altsvc = Forward("altsvc").invoke;
        pub const getBufferSize = Forward("bufferSize").invoke;
        pub const detachFromJS = Forward("detach").invoke;
        pub const emitAbortToAllStreams = Forward("emitAbortToAllStreams").invoke;
        pub const emitErrorToAllStreams = Forward("emitErrorToAllStreams").invoke;
        pub const flushFromJS = Forward("flush").invoke;
        pub const forEachStream = Forward("forEachStream").invoke;
        pub const getCurrentState = Forward("getCurrentState").invoke;
        pub const getEndAfterHeaders = Forward("getEndAfterHeaders").invoke;
        pub const getNextStream = Forward("getNextStream").invoke;
        pub const getStreamContext = Forward("getStreamContext").invoke;
        pub const getStreamState = Forward("getStreamState").invoke;
        pub const goaway = Forward("goaway").invoke;
        pub const hasNativeRead = Forward("hasNativeRead").invoke;
        pub const isStreamAborted = Forward("isStreamAborted").invoke;
        pub const noTrailers = Forward("noTrailers").invoke;
        pub const origin = Forward("origin").invoke;
        pub const ping = Forward("ping").invoke;
        pub const read = Forward("read").invoke;
        pub const request = Forward("request").invoke;
        pub const rstStream = Forward("rstStream").invoke;
        pub const sendTrailers = Forward("sendTrailers").invoke;
        pub const setLocalWindowSize = Forward("setLocalWindowSize").invoke;
        pub const setNativeSocketFromJS = Forward("setNativeSocket").invoke;
        pub const setNextStreamID = Forward("setNextStreamID").invoke;
        pub const setStreamContext = Forward("setStreamContext").invoke;
        pub const setStreamPriority = Forward("setStreamPriority").invoke;
        pub const updateSettings = Forward("settings").invoke;
        pub const writeStream = Forward("writeStream").invoke;
    };

    const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;
    const ENABLE_AUTO_CORK = false; // ENABLE CORK OPTIMIZATION
    const ENABLE_ALLOCATOR_POOL = true; // ENABLE HIVE ALLOCATOR OPTIMIZATION

    const MAX_BUFFER_SIZE = 32768;
    threadlocal var CORK_BUFFER: [16386]u8 = undefined;
    threadlocal var CORK_OFFSET: u16 = 0;
    threadlocal var CORKED_H2: ?*H2FrameParser = null;

    const H2FrameParserHiveAllocator = bun.HiveArray(H2FrameParser, 256).Fallback;
    pub threadlocal var pool: if (ENABLE_ALLOCATOR_POOL) ?*H2FrameParserHiveAllocator else u0 = if (ENABLE_ALLOCATOR_POOL) null else 0;

    strong_this: bindgen.WrapperReference(.{H2FrameParserSchema}) = .empty(),
    globalThis: *jsc.JSGlobalObject,
    allocator: Allocator,
    handlers: Handlers,
    native_socket: BunSocket = .{ .none = {} },
    localSettings: FullSettingsPayload = .{},
    // only available after receiving settings or ACK
    remoteSettings: ?FullSettingsPayload = null,
    // current frame being read
    currentFrame: ?FrameHeader = null,
    // remaining bytes to read for the current frame
    remainingLength: i32 = 0,
    // buffer if more data is needed for the current frame
    readBuffer: MutableString,
    header_block: std.ArrayList(u8) = .empty,
    pending_headers: ?struct { stream_id: u32, flags: u8 } = null,

    // local Window limits the download of data

    // current window size for the connection
    windowSize: u64 = DEFAULT_WINDOW_SIZE,
    // used window size for the connection
    usedWindowSize: u64 = 0,

    connectionSendWindow: i64 = DEFAULT_WINDOW_SIZE,

    maxHeaderListPairs: u32 = 128,
    maxRejectedStreams: u32 = 100,
    maxOutstandingSettings: u32 = 10,
    pendingSettings: std.ArrayList(FullSettingsPayload) = .empty,
    acknowledgedLocalSettings: FullSettingsPayload = .{},
    rejectedStreams: u32 = 0,
    maxSessionMemory: u32 = 10, //this limit is in MB
    queuedDataSize: u64 = 0, // this is in bytes
    maxOutstandingPings: u64 = 10,
    outStandingPings: u64 = 0,
    maxSendHeaderBlockLength: u64 = 0,
    lastStreamID: u32 = 0,
    isServer: bool = false,
    prefaceReceivedLen: u8 = 0,
    // we buffer requests until we get the first settings ACK
    writeBuffer: bun.ByteList = .{},
    writeBufferOffset: usize = 0,
    // TODO: this will be removed when I re-add header and data priorization
    outboundQueueSize: usize = 0,

    streams: bun.U32HashMap(*Stream),

    hpack: ?Hpack = null,

    has_nonnative_backpressure: bool = false,
    ref_count: RefCount,

    auto_flusher: AutoFlusher = .{},
    paddingStrategy: PaddingStrategy = .none,

    threadlocal var shared_request_buffer: [16384]u8 = undefined;

    fn beginHeaderBlock(
        this: *H2FrameParser,
        encoded_headers: *std.ArrayList(u8),
        alloc: std.mem.Allocator,
    ) !Hpack.EncoderBlock {
        const hpack = if (this.hpack) |*value| value else return error.UnableToEncode;
        return hpack.beginEncoderBlock(encoded_headers, alloc);
    }

    /// The streams hashmap may mutate when growing we use this when we need to make sure its safe to iterate over it
    pub const StreamResumableIterator = struct {
        parser: *H2FrameParser,
        index: u32 = 0,
        pub fn init(parser: *H2FrameParser) StreamResumableIterator {
            return .{ .index = 0, .parser = parser };
        }
        pub fn next(this: *StreamResumableIterator) ?*Stream {
            var it = this.parser.streams.iterator();
            if (it.index > it.hm.capacity() or this.index > it.hm.capacity()) return null;
            // resume the iterator from the same index if possible
            it.index = this.index;
            while (it.next()) |item| {
                this.index = it.index;
                return item.value_ptr.*;
            }
            this.index = it.index;
            return null;
        }
    };

    pub const FlushState = enum {
        no_action,
        flushed,
        backpressure,
    };

    const Stream = struct {
        id: u32 = 0,
        state: enum(u8) {
            IDLE = 1,
            RESERVED_LOCAL = 3,
            RESERVED_REMOTE = 4,
            OPEN = 2,
            HALF_CLOSED_LOCAL = 5,
            HALF_CLOSED_REMOTE = 6,
            CLOSED = 7,
        } = .IDLE,
        jsContext: bindgen.Root.Optional = .empty,
        waitForTrailers: bool = false,
        endAfterHeaders: bool = false,
        padding: ?u8 = null,
        paddingStrategy: PaddingStrategy = .none,
        rstCode: u32 = 0,
        streamDependency: u32 = 0,
        exclusive: bool = false,
        weight: u16 = 36,
        // current window size for the stream
        windowSize: u64 = 65535,
        // used window size for the stream
        usedWindowSize: u64 = 0,
        sendWindow: i64,
        signal: ?*SignalRef = null,

        // when we have backpressure we queue the data e round robin the Streams
        dataFrameQueue: PendingQueue,

        // Stream is heap-allocated and stored by pointer in the streams map so that
        // *Stream stays valid across re-entrant JS callbacks that may insert into
        // (and rehash) the map. Lifetime == H2FrameParser lifetime; freed in deinit().
        pub const new = bun.TrivialNew(Stream);

        const Identifier = union(enum) {
            context: bindgen.Root,
            stream_id: u32,

            fn deinit(identifier: *Identifier) void {
                switch (identifier.*) {
                    .context => |*context| context.deinit(),
                    .stream_id => {},
                }
            }

            fn operand(identifier: *const Identifier, context: anytype) H2StreamContext {
                return switch (identifier.*) {
                    .context => |*root| .{ .context = root.operand(context) },
                    .stream_id => |stream_id| .{ .stream_id = stream_id },
                };
            }
        };

        const SignalRef = struct {
            signal: *jsc.WebCore.AbortSignal,
            listener: jsc.WebCore.AbortSignal.Listener,
            parser: *H2FrameParser,
            stream_id: u32,

            pub const new = bun.TrivialNew(SignalRef);

            pub fn isAborted(this: *SignalRef) bool {
                return this.signal.aborted();
            }

            pub fn abortListener(this: *SignalRef, reason: bindgen.EngineValueView) void {
                log("abortListener", .{});
                const stream = this.parser.streams.get(this.stream_id) orelse return;
                if (stream.state != .CLOSED) {
                    var rooted_reason = reason.toRoot() catch |err|
                        return this.parser.globalThis.reportActiveExceptionAsUnhandled(err);
                    defer rooted_reason.deinit();
                    var abort_error = jsc.WebCore.AbortSignal.wrapAbortErrorRoot(this.parser.globalThis, &rooted_reason) catch return;
                    defer abort_error.deinit();
                    this.parser.abortStreamRoot(stream, &abort_error);
                }
            }

            pub fn deinit(this: *SignalRef) void {
                this.signal.detach(&this.listener);
                this.parser.deref();
                bun.destroy(this);
            }
        };
        const PendingQueue = struct {
            data: std.ArrayList(PendingFrame) = .empty,
            front: usize = 0,
            len: usize = 0,

            pub fn deinit(self: *PendingQueue, allocator: Allocator) void {
                self.front = 0;
                self.len = 0;
                var data = self.data;
                if (data.capacity > 0) {
                    self.data = .empty;
                    data.clearAndFree(allocator);
                }
            }

            pub fn enqueue(self: *PendingQueue, allocator: Allocator) *PendingFrame {
                const frame = bun.handleOom(self.data.addOne(allocator));
                frame.* = .{};
                self.len += 1;
                log("PendingQueue.enqueue {}", .{self.len});
                return frame;
            }

            pub fn peek(self: *PendingQueue) ?*PendingFrame {
                if (self.len == 0) {
                    return null;
                }
                return &self.data.items[0];
            }

            pub fn peekLast(self: *PendingQueue) ?*PendingFrame {
                if (self.len == 0) {
                    return null;
                }
                return &self.data.items[self.data.items.len - 1];
            }

            pub fn slice(self: *PendingQueue) []PendingFrame {
                if (self.len == 0) return &.{};
                return self.data.items[self.front..][0..self.len];
            }
            pub fn peekFront(self: *PendingQueue) ?*PendingFrame {
                if (self.len == 0) return null;
                return &self.data.items[self.front];
            }
            pub fn dequeue(self: *PendingQueue) ?PendingFrame {
                if (self.len == 0) {
                    log("PendingQueue.dequeue null", .{});
                    return null;
                }
                const value = self.data.items[self.front];
                self.data.items[self.front] = .{};
                self.len -= 1;
                if (self.len == 0) {
                    self.front = 0;
                    self.data.clearRetainingCapacity();
                } else {
                    self.front += 1;
                }
                log("PendingQueue.dequeue {}", .{self.len});

                return value;
            }

            pub fn isEmpty(self: *PendingQueue) bool {
                return self.len == 0;
            }
        };
        const PendingFrame = struct {
            end_stream: bool = false, // end_stream flag
            len: u32 = 0, // actually payload size
            offset: u32 = 0, // offset into the buffer (if partial flush due to flow control)
            buffer: []u8 = "", // allocated buffer if len > 0
            callback: ?bindgen.Callback(H2WriteCallbackType) = null,

            pub fn deinit(this: *PendingFrame, allocator: Allocator) void {
                if (this.buffer.len > 0) {
                    allocator.free(this.buffer);
                    this.buffer = "";
                }
                this.len = 0;
                if (this.callback) |*callback| callback.deinit();
                this.callback = null;
            }

            pub fn slice(this: *const PendingFrame) []u8 {
                return this.buffer[this.offset..this.len];
            }
        };

        pub fn getPadding(
            this: *Stream,
            frameLen: usize,
            maxLen: usize,
        ) u8 {
            switch (this.paddingStrategy) {
                .none => return 0,
                .aligned => {
                    const diff = (frameLen + 9) % 8;
                    // already multiple of 8
                    if (diff == 0) return 0;

                    var paddedLen = frameLen + (8 - diff);
                    // limit to maxLen
                    paddedLen = @min(maxLen, paddedLen);
                    return @min(paddedLen -| frameLen, 255);
                },
                .max => return @min(maxLen -| frameLen, 255),
            }
        }
        pub fn flushQueue(this: *Stream, client: *H2FrameParser, written: *usize) FlushState {
            if (this.canSendData()) {
                // try to flush one frame
                if (this.dataFrameQueue.peekFront()) |frame| {
                    const no_backpressure = brk: {
                        var is_flow_control_limited = false;
                        defer {
                            if (!is_flow_control_limited) {
                                // only call the callback + free the frame if we write to the socket the full frame
                                var _frame = this.dataFrameQueue.dequeue().?;
                                client.outboundQueueSize -= 1;

                                if (_frame.callback) |*callback| {
                                    var invocation: @TypeOf(callback.*).Invocation = undefined;
                                    callback.beginInvocation(&invocation);
                                    defer invocation.deinit();
                                    invocation.dispatch(.{});
                                }
                                if (this.dataFrameQueue.isEmpty()) {
                                    if (_frame.end_stream) {
                                        if (this.waitForTrailers) {
                                            client.dispatchWantTrailers(this.getIdentifier());
                                        } else {
                                            const identifier = this.getIdentifier();
                                            if (this.state == .HALF_CLOSED_REMOTE) {
                                                this.state = .CLOSED;
                                            } else {
                                                this.state = .HALF_CLOSED_LOCAL;
                                            }
                                            client.dispatchStreamEnd(identifier, @backingInt(this.state));
                                        }
                                    }
                                }
                                _frame.deinit(client.allocator);
                            }
                        }

                        const writer = client.toWriter();

                        if (frame.len == 0) {

                            // flush a zero payload frame
                            var dataHeader: FrameHeader = .{
                                .type = @backingInt(FrameType.HTTP_FRAME_DATA),
                                .flags = if (frame.end_stream and !this.waitForTrailers) @backingInt(DataFrameFlags.END_STREAM) else 0,
                                .streamIdentifier = @intCast(this.id),
                                .length = 0,
                            };
                            break :brk dataHeader.write(@TypeOf(writer), writer);
                        } else {
                            const frame_slice = frame.slice();
                            const available: usize = @intCast(@max(0, @min(this.sendWindow, client.connectionSendWindow)));
                            const max_size = @min(frame_slice.len, available, MAX_PAYLOAD_SIZE_WITHOUT_FRAME);
                            if (max_size == 0) {
                                is_flow_control_limited = true;
                                log("dataFrame flow control limited {} {} {} {}", .{ frame_slice.len, this.sendWindow, client.connectionSendWindow, max_size });
                                // we are flow control limited lets return backpressure if is limited in the connection so we short circuit the flush
                                return if (client.connectionSendWindow <= 0) .backpressure else .no_action;
                            }
                            if (max_size < frame_slice.len) {
                                is_flow_control_limited = true;
                                // we need to break the frame into smaller chunks
                                frame.offset += @intCast(max_size);
                                const able_to_send = frame_slice[0..max_size];
                                client.queuedDataSize -= able_to_send.len;
                                written.* += able_to_send.len;

                                const padding = this.getPadding(able_to_send.len, max_size - 1);
                                const payload_size = able_to_send.len + (if (padding != 0) @as(usize, @intCast(padding)) + 1 else 0);
                                log("padding: {d} size: {d} max_size: {d} payload_size: {d}", .{ padding, able_to_send.len, max_size, payload_size });
                                this.sendWindow -= @intCast(payload_size);
                                client.connectionSendWindow -= @intCast(payload_size);

                                var flags: u8 = 0; // we ignore end_stream for now because we know we have more data to send
                                if (padding != 0) {
                                    flags |= @backingInt(DataFrameFlags.PADDED);
                                }
                                var dataHeader: FrameHeader = .{
                                    .type = @backingInt(FrameType.HTTP_FRAME_DATA),
                                    .flags = flags,
                                    .streamIdentifier = @intCast(this.id),
                                    .length = @intCast(payload_size),
                                };
                                _ = dataHeader.write(@TypeOf(writer), writer);
                                if (padding != 0) {
                                    var buffer = shared_request_buffer[0..];
                                    bun.memmove(buffer[1..][0..able_to_send.len], able_to_send);
                                    buffer[0] = padding;
                                    break :brk (writer.write(buffer[0..payload_size]) catch 0) != 0;
                                } else {
                                    break :brk (writer.write(able_to_send) catch 0) != 0;
                                }
                            } else {

                                // flush with some payload
                                client.queuedDataSize -= frame_slice.len;
                                written.* += frame_slice.len;

                                const padding = this.getPadding(frame_slice.len, max_size - 1);
                                const payload_size = frame_slice.len + (if (padding != 0) @as(usize, @intCast(padding)) + 1 else 0);
                                log("padding: {d} size: {d} max_size: {d} payload_size: {d}", .{ padding, frame_slice.len, max_size, payload_size });
                                this.sendWindow -= @intCast(payload_size);
                                client.connectionSendWindow -= @intCast(payload_size);
                                var flags: u8 = if (frame.end_stream and !this.waitForTrailers) @backingInt(DataFrameFlags.END_STREAM) else 0;
                                if (padding != 0) {
                                    flags |= @backingInt(DataFrameFlags.PADDED);
                                }
                                var dataHeader: FrameHeader = .{
                                    .type = @backingInt(FrameType.HTTP_FRAME_DATA),
                                    .flags = flags,
                                    .streamIdentifier = @intCast(this.id),
                                    .length = @intCast(payload_size),
                                };
                                _ = dataHeader.write(@TypeOf(writer), writer);
                                if (padding != 0) {
                                    var buffer = shared_request_buffer[0..];
                                    bun.memmove(buffer[1..][0..frame_slice.len], frame_slice);
                                    buffer[0] = padding;
                                    break :brk (writer.write(buffer[0..payload_size]) catch 0) != 0;
                                } else {
                                    break :brk (writer.write(frame_slice) catch 0) != 0;
                                }
                            }
                        }
                    };

                    return if (no_backpressure) .flushed else .backpressure;
                }
            }
            // empty or cannot send data
            return .no_action;
        }

        pub fn queueFrame(
            this: *Stream,
            client: *H2FrameParser,
            bytes: []const u8,
            callback: *?bindgen.Callback(H2WriteCallbackType),
            end_stream: bool,
        ) void {
            if (this.dataFrameQueue.peekLast()) |last_frame| {
                if (bytes.len == 0) {
                    // just merge the end_stream
                    last_frame.end_stream = end_stream;
                    // we can only hold 1 callback at a time so we conclude the last one, and keep the last one as pending
                    // this is fine is like a per-stream CORKING in a frame level
                    if (last_frame.callback) |*old_callback| {
                        {
                            var invocation: @TypeOf(old_callback.*).Invocation = undefined;
                            old_callback.beginInvocation(&invocation);
                            defer invocation.deinit();
                            invocation.dispatch(.{});
                        }
                        old_callback.deinit();
                        last_frame.callback = null;
                    }
                    if (callback.*) |*new_callback| {
                        last_frame.callback = new_callback.take();
                        callback.* = null;
                    }
                    return;
                }
                if (last_frame.len == 0) {
                    // we have an empty frame with means we can just use this frame with a new buffer
                    last_frame.buffer = bun.handleOom(client.allocator.alloc(u8, MAX_PAYLOAD_SIZE_WITHOUT_FRAME));
                }
                const max_size = MAX_PAYLOAD_SIZE_WITHOUT_FRAME;
                const remaining = max_size - last_frame.len;
                if (remaining > 0) {
                    // ok we can cork frames
                    const consumed_len = @min(remaining, bytes.len);
                    const merge = bytes[0..consumed_len];
                    @memcpy(last_frame.buffer[last_frame.len .. last_frame.len + consumed_len], merge);
                    last_frame.len += @intCast(consumed_len);
                    log("dataFrame merged {}", .{consumed_len});

                    client.queuedDataSize += consumed_len;
                    //lets fallthrough if we still have some data
                    const more_data = bytes[consumed_len..];
                    if (more_data.len == 0) {
                        last_frame.end_stream = end_stream;
                        // we can only hold 1 callback at a time so we conclude the last one, and keep the last one as pending
                        // this is fine is like a per-stream CORKING in a frame level
                        if (last_frame.callback) |*old_callback| {
                            {
                                var invocation: @TypeOf(old_callback.*).Invocation = undefined;
                                old_callback.beginInvocation(&invocation);
                                defer invocation.deinit();
                                invocation.dispatch(.{});
                            }
                            old_callback.deinit();
                            last_frame.callback = null;
                        }
                        if (callback.*) |*new_callback| {
                            last_frame.callback = new_callback.take();
                            callback.* = null;
                        }
                        return;
                    }
                    // we keep the old callback because the new will be part of another frame
                    return this.queueFrame(client, more_data, callback, end_stream);
                }
            }
            log("{s} queued {} {}", .{ if (client.isServer) "server" else "client", bytes.len, end_stream });

            const frame = this.dataFrameQueue.enqueue(client.allocator);
            frame.* = .{
                .end_stream = end_stream,
                .len = @intCast(bytes.len),
                // we need to clone this data to send it later
                .buffer = if (bytes.len == 0) "" else bun.handleOom(client.allocator.alloc(u8, MAX_PAYLOAD_SIZE_WITHOUT_FRAME)),
                .callback = if (callback.*) |*owned| owned.take() else null,
            };
            callback.* = null;
            if (bytes.len > 0) {
                @memcpy(frame.buffer[0..bytes.len], bytes);
                client.globalThis.vm().reportExtraMemory(bytes.len);
            }
            log("dataFrame enqueued {}", .{frame.len});
            client.outboundQueueSize += 1;
            client.queuedDataSize += frame.len;
        }

        pub fn init(streamIdentifier: u32, initialWindowSize: u32, initialSendWindow: u32, paddingStrategy: PaddingStrategy) Stream {
            const stream = Stream{
                .id = streamIdentifier,
                .state = .OPEN,
                .windowSize = initialWindowSize,
                .sendWindow = initialSendWindow,
                .usedWindowSize = 0,
                .weight = 36,
                .dataFrameQueue = .{},
                .paddingStrategy = paddingStrategy,
            };
            return stream;
        }

        /// Returns true if the stream can still receive data from the remote peer.
        /// Per RFC 7540 Section 5.1:
        /// - OPEN: both endpoints can send and receive
        /// - HALF_CLOSED_LOCAL: local sent END_STREAM, but can still receive from remote
        /// - HALF_CLOSED_REMOTE: remote sent END_STREAM, no more data to receive
        /// - CLOSED: stream is finished
        pub fn canReceiveData(this: *Stream) bool {
            return switch (this.state) {
                .IDLE, .RESERVED_LOCAL, .RESERVED_REMOTE, .OPEN, .HALF_CLOSED_LOCAL => true,
                .HALF_CLOSED_REMOTE, .CLOSED => false,
            };
        }

        pub fn canSendData(this: *Stream) bool {
            return switch (this.state) {
                .IDLE, .RESERVED_LOCAL, .RESERVED_REMOTE, .OPEN, .HALF_CLOSED_REMOTE => true,
                .HALF_CLOSED_LOCAL, .CLOSED => false,
            };
        }

        pub fn setContext(this: *Stream, value: anytype) bun.JSError!void {
            var rooted = try value.toRoot();
            defer rooted.deinit();
            this.jsContext.setRoot(&rooted);
        }

        pub fn getIdentifier(this: *const Stream) Identifier {
            return if (this.jsContext.cloneRoot()) |context|
                .{ .context = context }
            else
                .{ .stream_id = this.id };
        }

        pub fn attachSignal(this: *Stream, parser: *H2FrameParser, signal: *jsc.WebCore.AbortSignal) bun.JSError!void {
            // we need a stable pointer to know what signal points to what stream_id + parser
            var signal_ref = SignalRef.new(.{
                .signal = signal,
                .listener = undefined,
                .parser = parser,
                .stream_id = this.id,
            });
            errdefer bun.destroy(signal_ref);
            const retained_signal = signal.ref();
            errdefer retained_signal.unref();
            signal_ref.signal = try retained_signal.listen(parser.globalThis, &signal_ref.listener, signal_ref, SignalRef.abortListener);
            //TODO: We should not need this ref counting here, since Parser owns Stream
            parser.ref();
            this.signal = signal_ref;
        }

        pub fn detachContext(this: *Stream) void {
            this.jsContext.deinit();
        }

        fn cleanQueue(this: *Stream, client: *H2FrameParser, comptime finalizing: bool) void {
            log("cleanQueue len: {} front: {} outboundQueueSize: {}", .{ this.dataFrameQueue.len, this.dataFrameQueue.front, client.outboundQueueSize });

            var queue = this.dataFrameQueue;
            this.dataFrameQueue = .{};
            defer {
                queue.deinit(client.allocator);
            }
            while (queue.dequeue()) |item| {
                var frame = item;
                const len = frame.slice().len;
                log("dataFrame dropped {}", .{len});
                client.queuedDataSize -= len;
                if (!finalizing) {
                    if (frame.callback) |*callback| {
                        var invocation: @TypeOf(callback.*).Invocation = undefined;
                        callback.beginInvocation(&invocation);
                        defer invocation.deinit();
                        invocation.dispatch(.{});
                    }
                }
                frame.deinit(client.allocator);
                client.outboundQueueSize -= 1;
            }
        }
        /// this can be called multiple times
        pub fn freeResources(this: *Stream, client: *H2FrameParser, comptime finalizing: bool) void {
            this.detachContext();
            this.cleanQueue(client, finalizing);
            if (this.signal) |signal| {
                this.signal = null;
                signal.deinit();
            }
            // unsafe to ask GC to run if we are already inside GC
            if (!finalizing) {
                jsc.VirtualMachine.get().eventLoop().processGCTimer();
            }
        }
    };

    /// Calculate the new window size for the connection and the stream
    /// https://datatracker.ietf.org/doc/html/rfc7540#section-6.9.1
    fn adjustWindowSize(this: *H2FrameParser, stream: ?*Stream, payloadSize: u32) void {
        this.usedWindowSize +|= payloadSize;
        log("adjustWindowSize {} {} {} {}", .{ this.usedWindowSize, this.windowSize, this.isServer, payloadSize });
        if (this.usedWindowSize > this.windowSize) {
            // we are receiving more data than we are allowed to
            this.sendGoAway(0, .FLOW_CONTROL_ERROR, "Window size overflow", this.lastStreamID, true);
            this.usedWindowSize -= payloadSize;
        }

        if (stream) |s| {
            s.usedWindowSize += payloadSize;
            if (s.usedWindowSize > s.windowSize) {
                // we are receiving more data than we are allowed to
                this.sendGoAway(s.id, .FLOW_CONTROL_ERROR, "Window size overflow", this.lastStreamID, true);
                s.usedWindowSize -= payloadSize;
            }
        }
    }

    fn incrementWindowSizeIfNeeded(this: *H2FrameParser) void {
        var it = this.streams.valueIterator();
        while (it.next()) |item| {
            const stream = item.*;
            log("incrementWindowSizeIfNeeded stream {} {} {} {}", .{ stream.id, stream.usedWindowSize, stream.windowSize, this.isServer });
            if (stream.usedWindowSize >= stream.windowSize / 2 and stream.usedWindowSize > 0) {
                const consumed = stream.usedWindowSize;
                stream.usedWindowSize = 0;
                log("incrementWindowSizeIfNeeded stream {} {} {}", .{ stream.id, stream.windowSize, this.isServer });
                this.sendWindowUpdate(stream.id, UInt31WithReserved.init(@truncate(consumed), false));
            }
        }
        log("incrementWindowSizeIfNeeded connection {} {} {}", .{ this.usedWindowSize, this.windowSize, this.isServer });
        if (this.usedWindowSize >= this.windowSize / 2 and this.usedWindowSize > 0) {
            const consumed = this.usedWindowSize;
            this.usedWindowSize = 0;
            this.sendWindowUpdate(0, UInt31WithReserved.init(@truncate(consumed), false));
        }
    }

    pub fn setSettings(this: *H2FrameParser, settings: FullSettingsPayload) bun.OOM!bool {
        log("HTTP_FRAME_SETTINGS ack false", .{});

        if (this.pendingSettings.items.len >= @as(usize, this.maxOutstandingSettings)) {
            this.sendGoAway(0, .MAX_PENDING_SETTINGS_ACK, "Maximum number of pending settings acknowledgements", this.lastStreamID, true);
            return false;
        }
        try this.pendingSettings.append(this.allocator, settings);

        var buffer: [FrameHeader.byteSize + FullSettingsPayload.byteSize]u8 = undefined;
        @memset(&buffer, 0);
        var writer_state = std.Io.Writer.fixed(&buffer);
        const writer = &writer_state;
        var settingsHeader: FrameHeader = .{
            .type = @backingInt(FrameType.HTTP_FRAME_SETTINGS),
            .flags = 0,
            .streamIdentifier = 0,
            .length = FullSettingsPayload.byteSize,
        };
        _ = settingsHeader.write(@TypeOf(writer), writer);

        this.localSettings = settings;
        _ = this.localSettings.write(@TypeOf(writer), writer);
        _ = this.write(&buffer);
        return true;
    }

    pub fn abortStreamRoot(this: *H2FrameParser, stream: *Stream, abortReason: *const bindgen.Root) void {
        this.abortStreamWithReason(stream, abortReason);
    }

    fn abortStreamWithReason(
        this: *H2FrameParser,
        stream: *Stream,
        abort_reason: *const bindgen.Root,
    ) void {
        log("HTTP_FRAME_RST_STREAM id: {} code: CANCEL", .{stream.id});

        var buffer: [FrameHeader.byteSize + 4]u8 = undefined;
        @memset(&buffer, 0);
        var writer_state = std.Io.Writer.fixed(&buffer);
        const writer = &writer_state;

        var frame: FrameHeader = .{
            .type = @backingInt(FrameType.HTTP_FRAME_RST_STREAM),
            .flags = 0,
            .streamIdentifier = @intCast(stream.id),
            .length = 4,
        };
        _ = frame.write(@TypeOf(writer), writer);
        stream.rstCode = @backingInt(ErrorCode.CANCEL);
        const value = H2Frame.encodeU32(stream.rstCode);
        _ = writer.write(&value) catch 0;
        const old_state = stream.state;
        stream.state = .CLOSED;
        const identifier = stream.getIdentifier();
        stream.freeResources(this, false);
        this.dispatchAborted(identifier, abort_reason, @backingInt(old_state));
        _ = this.write(&buffer);
    }

    pub fn endStream(this: *H2FrameParser, stream: *Stream, rstCode: ErrorCode) void {
        log("HTTP_FRAME_RST_STREAM id: {} code: {}", .{ stream.id, @backingInt(rstCode) });
        if (stream.state == .CLOSED) {
            return;
        }
        var buffer: [FrameHeader.byteSize + 4]u8 = undefined;
        @memset(&buffer, 0);
        var writer_state = std.Io.Writer.fixed(&buffer);
        const writer = &writer_state;

        var frame: FrameHeader = .{
            .type = @backingInt(FrameType.HTTP_FRAME_RST_STREAM),
            .flags = 0,
            .streamIdentifier = @intCast(stream.id),
            .length = 4,
        };
        _ = frame.write(@TypeOf(writer), writer);
        stream.rstCode = @backingInt(rstCode);
        const value = H2Frame.encodeU32(stream.rstCode);
        _ = writer.write(&value) catch 0;

        stream.state = .CLOSED;
        const identifier = stream.getIdentifier();
        stream.freeResources(this, false);
        if (rstCode == .NO_ERROR) {
            this.dispatchStreamEnd(identifier, @backingInt(stream.state));
        } else {
            this.dispatchStreamError(identifier, @backingInt(rstCode));
        }

        _ = this.write(&buffer);
    }

    pub fn sendGoAway(this: *H2FrameParser, errorStreamIdentifier: u32, rstCode: ErrorCode, debug_data: []const u8, lastStreamID: u32, emitError: bool) void {
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        log("HTTP_FRAME_GOAWAY {} code {} debug_data {s} emitError {}", .{ errorStreamIdentifier, rstCode, debug_data, emitError });
        var chunk = this.binaryPayload(debug_data) catch |err| {
            const thrown = scope.takeThrownValue(err) catch return;
            this.dispatchError(&scope, &.{.{ .exception = thrown.operand(&scope) }});
            return;
        };
        defer releaseBinaryPayload(&chunk);
        var buffer: [FrameHeader.byteSize + 8]u8 = undefined;
        @memset(&buffer, 0);
        var writer_state = std.Io.Writer.fixed(&buffer);
        const writer = &writer_state;

        var frame: FrameHeader = .{
            .type = @backingInt(FrameType.HTTP_FRAME_GOAWAY),
            .flags = 0,
            .streamIdentifier = 0,
            .length = @intCast(8 + debug_data.len),
        };
        _ = frame.write(@TypeOf(writer), writer);
        var last_id = UInt31WithReserved.init(@truncate(lastStreamID), false);
        _ = last_id.write(@TypeOf(writer), writer);
        const value = H2Frame.encodeU32(@backingInt(rstCode));
        _ = writer.write(&value) catch 0;

        _ = this.write(&buffer);
        if (debug_data.len > 0) {
            _ = this.write(binaryPayloadBytes(&chunk));
        }

        if (emitError) {
            if (rstCode != .NO_ERROR) {
                this.dispatchError(&scope, &.{
                    .{ .code = @backingInt(rstCode) },
                    .{ .code = this.lastStreamID },
                    .{ .binary = chunk.operand() },
                });
            }
            this.dispatchEnd(this.lastStreamID, chunk);
        }
    }

    pub fn sendAltSvc(this: *H2FrameParser, streamIdentifier: u32, origin_str: []const u8, alt: []const u8) void {
        log("HTTP_FRAME_ALTSVC stream {} origin {s} alt {s}", .{ streamIdentifier, origin_str, alt });

        var buffer: [FrameHeader.byteSize + 2]u8 = undefined;
        @memset(&buffer, 0);
        var writer_state = std.Io.Writer.fixed(&buffer);
        const writer = &writer_state;

        var frame: FrameHeader = .{
            .type = @backingInt(FrameType.HTTP_FRAME_ALTSVC),
            .flags = 0,
            .streamIdentifier = @intCast(streamIdentifier),
            .length = @intCast(origin_str.len + alt.len + 2),
        };
        _ = frame.write(@TypeOf(writer), writer);
        _ = writer.writeInt(u16, @intCast(origin_str.len), .big) catch 0;
        _ = this.write(&buffer);
        if (origin_str.len > 0) {
            _ = this.write(origin_str);
        }
        if (alt.len > 0) {
            _ = this.write(alt);
        }
    }

    pub fn sendPing(this: *H2FrameParser, ack: bool, payload: []const u8) void {
        log("HTTP_FRAME_PING ack {} payload {s}", .{ ack, payload });

        var buffer: [FrameHeader.byteSize + 8]u8 = undefined;
        @memset(&buffer, 0);
        var writer_state = std.Io.Writer.fixed(&buffer);
        const writer = &writer_state;
        if (!ack) {
            this.outStandingPings += 1;
        }
        var frame = FrameHeader{
            .type = @backingInt(FrameType.HTTP_FRAME_PING),
            .flags = if (ack) @backingInt(PingFrameFlags.ACK) else 0,
            .streamIdentifier = 0,
            .length = 8,
        };
        _ = frame.write(@TypeOf(writer), writer);
        _ = writer.write(payload) catch 0;
        _ = this.write(&buffer);
    }

    pub fn sendPrefaceAndSettings(this: *H2FrameParser) bun.OOM!void {
        log("sendPrefaceAndSettings", .{});
        // PREFACE + Settings Frame
        var preface_buffer: [24 + FrameHeader.byteSize + FullSettingsPayload.byteSize]u8 = undefined;
        @memset(&preface_buffer, 0);
        var writer_state = std.Io.Writer.fixed(&preface_buffer);
        const writer = &writer_state;
        _ = writer.write("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n") catch 0;
        var settingsHeader: FrameHeader = .{
            .type = @backingInt(FrameType.HTTP_FRAME_SETTINGS),
            .flags = 0,
            .streamIdentifier = 0,
            .length = FullSettingsPayload.byteSize,
        };
        try this.pendingSettings.append(this.allocator, this.localSettings);
        _ = settingsHeader.write(@TypeOf(writer), writer);
        _ = this.localSettings.write(@TypeOf(writer), writer);
        _ = this.write(&preface_buffer);
    }

    pub fn sendSettingsACK(this: *H2FrameParser) void {
        log("send HTTP_FRAME_SETTINGS ack true", .{});
        var buffer: [FrameHeader.byteSize]u8 = undefined;
        @memset(&buffer, 0);
        var writer_state = std.Io.Writer.fixed(&buffer);
        const writer = &writer_state;
        var settingsHeader: FrameHeader = .{
            .type = @backingInt(FrameType.HTTP_FRAME_SETTINGS),
            .flags = @backingInt(SettingsFlags.ACK),
            .streamIdentifier = 0,
            .length = 0,
        };
        _ = settingsHeader.write(@TypeOf(writer), writer);
        _ = this.write(&buffer);
    }

    pub fn sendWindowUpdate(this: *H2FrameParser, streamIdentifier: u32, windowSize: UInt31WithReserved) void {
        log("HTTP_FRAME_WINDOW_UPDATE stream {} size {}", .{ streamIdentifier, windowSize.uint31 });
        var buffer: [FrameHeader.byteSize + 4]u8 = undefined;
        @memset(&buffer, 0);
        var writer_state = std.Io.Writer.fixed(&buffer);
        const writer = &writer_state;
        var settingsHeader: FrameHeader = .{
            .type = @backingInt(FrameType.HTTP_FRAME_WINDOW_UPDATE),
            .flags = 0,
            .streamIdentifier = @intCast(streamIdentifier),
            .length = 4,
        };
        _ = settingsHeader.write(@TypeOf(writer), writer);
        _ = windowSize.write(@TypeOf(writer), writer);
        _ = this.write(&buffer);
    }

    fn handlerContext(this: *H2FrameParser, scope: anytype) ?bindgen.AnyOperand {
        const context = if (this.handlers.context) |*value| value else return null;
        return context.operand(scope);
    }

    fn binaryPayload(this: *H2FrameParser, bytes: []const u8) bun.OOM!H2BinaryPayload {
        const owned = try bindgen.OwnedBytes.fromSlice(bytes);
        return switch (this.handlers.binary_type) {
            .buffer => .{ .buffer = owned },
            .arraybuffer => .{ .arraybuffer = owned },
            .uint8array => .{ .uint8array = owned },
        };
    }

    fn dispatchWantTrailers(this: *H2FrameParser, stream_identifier: Stream.Identifier) void {
        var identifier = stream_identifier;
        defer identifier.deinit();
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const context = this.handlerContext(&scope) orelse return;
        _ = this.handlers.invoke(&scope, .onWantTrailers, .{
            .bindingThis = context,
            .context = context,
            .stream_context = identifier.operand(&scope),
        });
    }

    fn dispatchStreamEnd(this: *H2FrameParser, stream_identifier: Stream.Identifier, state: u32) void {
        var identifier = stream_identifier;
        defer identifier.deinit();
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const context = this.handlerContext(&scope) orelse return;
        _ = this.handlers.invoke(&scope, .onStreamEnd, .{
            .bindingThis = context,
            .context = context,
            .stream_context = identifier.operand(&scope),
            .state = state,
        });
    }

    fn dispatchStreamError(this: *H2FrameParser, stream_identifier: Stream.Identifier, code: u32) void {
        var identifier = stream_identifier;
        defer identifier.deinit();
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const context = this.handlerContext(&scope) orelse return;
        _ = this.handlers.invoke(&scope, .onStreamError, .{
            .bindingThis = context,
            .context = context,
            .stream_context = identifier.operand(&scope),
            .code = code,
        });
    }

    fn dispatchStreamData(this: *H2FrameParser, stream_identifier: Stream.Identifier, chunk: H2BinaryPayload) void {
        var identifier = stream_identifier;
        defer identifier.deinit();
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const context = this.handlerContext(&scope) orelse return;
        _ = this.handlers.invoke(&scope, .onStreamData, .{
            .bindingThis = context,
            .context = context,
            .stream_context = identifier.operand(&scope),
            .chunk = chunk.operand(),
        });
    }

    fn dispatchStreamStart(this: *H2FrameParser, stream_id: u32) void {
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const context = this.handlerContext(&scope) orelse return;
        _ = this.handlers.invoke(&scope, .onStreamStart, .{
            .bindingThis = context,
            .context = context,
            .stream_id = stream_id,
        });
    }

    fn dispatchStreamHeaders(
        this: *H2FrameParser,
        stream_identifier: Stream.Identifier,
        headers: H2StringSequence,
        sensitive_headers: ?H2StringSequence,
        flags: u32,
    ) void {
        var identifier = stream_identifier;
        defer identifier.deinit();
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const context = this.handlerContext(&scope) orelse return;
        _ = this.handlers.invoke(&scope, .onStreamHeaders, .{
            .bindingThis = context,
            .context = context,
            .stream_context = identifier.operand(&scope),
            .headers = headers,
            .sensitive_headers = sensitive_headers,
            .flags = flags,
        });
    }

    fn dispatchSettings(this: *H2FrameParser, comptime event: HandlerEvent, settings_value: H2SettingsSnapshot) void {
        comptime {
            if (event != .onLocalSettings and event != .onRemoteSettings) {
                @compileError("dispatchSettings requires a settings handler");
            }
        }
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const context = this.handlerContext(&scope) orelse return;
        _ = this.handlers.invoke(&scope, event, .{
            .bindingThis = context,
            .context = context,
            .settings = settings_value,
        });
    }

    fn dispatchPing(this: *H2FrameParser, payload: H2BinaryPayload, ack: bool) void {
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const context = this.handlerContext(&scope) orelse return;
        _ = this.handlers.invoke(&scope, .onPing, .{
            .bindingThis = context,
            .context = context,
            .payload = payload.operand(),
            .ack = ack,
        });
    }

    fn dispatchEnd(this: *H2FrameParser, last_stream_id: u32, debug_data: H2BinaryPayload) void {
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const context = this.handlerContext(&scope) orelse return;
        _ = this.handlers.invoke(&scope, .onEnd, .{
            .bindingThis = context,
            .context = context,
            .last_stream_id = last_stream_id,
            .debug_data = debug_data.operand(),
        });
    }

    fn dispatchGoAway(this: *H2FrameParser, error_code: u32, last_stream_id: u32, debug_data: H2BinaryPayload) void {
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const context = this.handlerContext(&scope) orelse return;
        _ = this.handlers.invoke(&scope, .onGoAway, .{
            .bindingThis = context,
            .context = context,
            .error_code = error_code,
            .last_stream_id = last_stream_id,
            .debug_data = debug_data.operand(),
        });
    }

    fn dispatchAborted(
        this: *H2FrameParser,
        stream_identifier: Stream.Identifier,
        reason: ?*const bindgen.Root,
        state: u32,
    ) void {
        var identifier = stream_identifier;
        defer identifier.deinit();
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const context = this.handlerContext(&scope) orelse return;
        _ = this.handlers.invoke(&scope, .onAborted, .{
            .bindingThis = context,
            .context = context,
            .stream_context = identifier.operand(&scope),
            .reason = if (reason) |value| value.operand(&scope) else null,
            .state = state,
        });
    }

    fn dispatchOrigin(this: *H2FrameParser, origins: H2OriginEvent) void {
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const context = this.handlerContext(&scope) orelse return;
        _ = this.handlers.invoke(&scope, .onOrigin, .{
            .bindingThis = context,
            .context = context,
            .origins = origins,
        });
    }

    fn dispatchAltSvc(this: *H2FrameParser, origin_bytes: []const u8, value: []const u8, stream_id: u32) bun.OOM!void {
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const context = this.handlerContext(&scope) orelse return;
        var origin_string = try bindgen.DOMString.fromUTF8(origin_bytes);
        defer origin_string.deinit();
        var value_string = try bindgen.DOMString.fromUTF8(value);
        defer value_string.deinit();
        _ = this.handlers.invoke(&scope, .onAltSvc, .{
            .bindingThis = context,
            .context = context,
            .origin = origin_string.operand(),
            .value = value_string.operand(),
            .stream_id = stream_id,
        });
    }

    fn dispatchFrameError(
        this: *H2FrameParser,
        stream_identifier: Stream.Identifier,
        frame_type: u8,
        error_code: u32,
    ) void {
        var identifier = stream_identifier;
        defer identifier.deinit();
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const context = this.handlerContext(&scope) orelse return;
        _ = this.handlers.invoke(&scope, .onFrameError, .{
            .bindingThis = context,
            .context = context,
            .stream_context = identifier.operand(&scope),
            .frame_type = frame_type,
            .error_code = error_code,
        });
    }

    fn dispatchError(this: *H2FrameParser, scope: anytype, values: []const H2ErrorArgument) void {
        const context = this.handlerContext(scope) orelse return;
        _ = this.handlers.invoke(scope, .onError, .{
            .bindingThis = context,
            .context = context,
            .arguments = values,
        });
    }

    fn callWriteHandler(
        this: *H2FrameParser,
        chunk: H2BinaryPayload,
    ) ?bindgen.Return(callbackTypeForEvent(.onWrite)) {
        const callback = this.handlers.handlerFor(.onWrite) orelse return null;
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalThis);
        defer scope.deinit();
        const context = this.handlerContext(&scope) orelse return null;
        var receiver = (this.strong_this.toOwnedClassRef(H2FrameParserSchema) catch |err| {
            this.handlers.globalObject.reportActiveExceptionAsUnhandled(err);
            return null;
        }) orelse @panic("binding wrapper receiver is unavailable");
        defer receiver.deinit();
        return callback.call(&scope, .{
            .bindingThis = receiver.operand(&scope),
            .context = context,
            .chunk = chunk.operand(),
        }) catch |err| {
            this.handlers.globalObject.reportActiveExceptionAsUnhandled(err);
            return null;
        };
    }

    fn cork(this: *H2FrameParser) void {
        if (CORKED_H2) |corked| {
            if (corked == this) {
                // already corked
                return;
            }
            // force uncork
            corked.uncork();
        }
        // cork
        CORKED_H2 = this;
        this.ref();
        this.registerAutoFlush();
        log("cork {*}", .{this});
        CORK_OFFSET = 0;
    }

    pub fn _genericFlush(this: *H2FrameParser, comptime T: type, socket: T) usize {
        const buffer = this.writeBuffer.slice()[this.writeBufferOffset..];
        if (buffer.len > 0) {
            const result: i32 = socket.writeMaybeCorked(buffer);
            const written: u32 = if (result < 0) 0 else @intCast(result);

            if (written < buffer.len) {
                this.writeBufferOffset += written;
                log("_genericFlush {}", .{written});
                return written;
            }

            // all the buffer was written! reset things
            this.writeBufferOffset = 0;
            this.writeBuffer.len = 0;
            // lets keep size under control
            if (this.writeBuffer.cap > MAX_BUFFER_SIZE) {
                this.writeBuffer.len = MAX_BUFFER_SIZE;
                this.writeBuffer.shrinkAndFree(this.allocator, MAX_BUFFER_SIZE);
                this.writeBuffer.clearRetainingCapacity();
            }
            log("_genericFlush {}", .{buffer.len});
        } else {
            log("_genericFlush 0", .{});
        }
        return buffer.len;
    }

    pub fn _genericWrite(this: *H2FrameParser, comptime T: type, socket: T, bytes: []const u8) bool {
        log("_genericWrite {}", .{bytes.len});

        const buffer = this.writeBuffer.slice()[this.writeBufferOffset..];
        if (buffer.len > 0) {
            {
                const result: i32 = socket.writeMaybeCorked(buffer);
                const written: u32 = if (result < 0) 0 else @intCast(result);
                if (written < buffer.len) {
                    this.writeBufferOffset += written;

                    // we still have more to buffer and even more now
                    _ = bun.handleOom(this.writeBuffer.write(this.allocator, bytes));
                    this.globalThis.vm().reportExtraMemory(bytes.len);

                    log("_genericWrite flushed {} and buffered more {}", .{ written, bytes.len });
                    return false;
                }
            }
            // all the buffer was written!
            this.writeBufferOffset = 0;
            this.writeBuffer.len = 0;
            {
                const result: i32 = socket.writeMaybeCorked(bytes);
                const written: u32 = if (result < 0) 0 else @intCast(result);
                if (written < bytes.len) {
                    const pending = bytes[written..];
                    // ops not all data was sent, lets buffer again
                    _ = bun.handleOom(this.writeBuffer.write(this.allocator, pending));
                    this.globalThis.vm().reportExtraMemory(pending.len);

                    log("_genericWrite buffered more {}", .{pending.len});
                    return false;
                }
            }
            // lets keep size under control
            if (this.writeBuffer.cap > MAX_BUFFER_SIZE) {
                this.writeBuffer.len = MAX_BUFFER_SIZE;
                this.writeBuffer.shrinkAndFree(this.allocator, MAX_BUFFER_SIZE);
                this.writeBuffer.clearRetainingCapacity();
            }
            return true;
        }
        const result: i32 = socket.writeMaybeCorked(bytes);
        const written: u32 = if (result < 0) 0 else @intCast(result);
        if (written < bytes.len) {
            const pending = bytes[written..];
            // ops not all data was sent, lets buffer again
            _ = bun.handleOom(this.writeBuffer.write(this.allocator, pending));
            this.globalThis.vm().reportExtraMemory(pending.len);

            return false;
        }
        return true;
    }

    /// be sure that we dont have any backpressure/data queued on writerBuffer before calling this
    fn flushStreamQueue(this: *H2FrameParser) usize {
        log("flushStreamQueue {}", .{this.outboundQueueSize});
        var written: usize = 0;
        var something_was_flushed = true;

        // try to send as much as we can until we reach backpressure or until we can't flush anymore
        while (this.outboundQueueSize > 0 and something_was_flushed) {
            var it = StreamResumableIterator.init(this);
            something_was_flushed = false;
            while (it.next()) |stream| {
                // reach backpressure
                const result = stream.flushQueue(this, &written);
                switch (result) {
                    .flushed => something_was_flushed = true,
                    .no_action => continue, // we can continue
                    .backpressure => return written, // backpressure we need to return
                }
            }
        }
        return written;
    }

    pub fn flush(this: *H2FrameParser) usize {
        log("flush", .{});
        this.ref();
        defer this.deref();
        this.uncork();
        var written = switch (this.native_socket) {
            .tls_writeonly, .tls => |socket| this._genericFlush(*TLSSocket, socket),
            .tcp_writeonly, .tcp => |socket| this._genericFlush(*TCPSocket, socket),
            else => {
                // consider that backpressure is gone and flush data queue
                this.has_nonnative_backpressure = false;
                const bytes = this.writeBuffer.slice();
                if (bytes.len > 0) {
                    defer {
                        // all the buffer was written/queued! reset things
                        this.writeBufferOffset = 0;
                        this.writeBuffer.len = 0;
                        // lets keep size under control
                        if (this.writeBuffer.cap > MAX_BUFFER_SIZE) {
                            this.writeBuffer.len = MAX_BUFFER_SIZE;
                            this.writeBuffer.shrinkAndFree(this.allocator, MAX_BUFFER_SIZE);
                            this.writeBuffer.clearRetainingCapacity();
                        }
                    }
                    var output_value = this.binaryPayload(bytes) catch |e| {
                        this.handlers.globalObject.reportActiveExceptionAsUnhandled(e);
                        this.has_nonnative_backpressure = true;
                        return bytes.len;
                    };
                    defer releaseBinaryPayload(&output_value);
                    if (this.callWriteHandler(output_value)) |result| {
                        switch (result) {
                            .flag => |flag| if (!flag) {
                                this.has_nonnative_backpressure = true;
                                return bytes.len;
                            },
                            .code, .ignored => {},
                        }
                    }
                }

                return this.flushStreamQueue();
            },
        };
        // if no backpressure flush data queue
        if (!this.hasBackpressure()) {
            written += this.flushStreamQueue();
        }
        return written;
    }

    pub fn _write(this: *H2FrameParser, bytes: []const u8) bool {
        this.ref();
        defer this.deref();
        return switch (this.native_socket) {
            .tls_writeonly, .tls => |socket| this._genericWrite(*TLSSocket, socket, bytes),
            .tcp_writeonly, .tcp => |socket| this._genericWrite(*TCPSocket, socket, bytes),
            else => {
                if (this.has_nonnative_backpressure) {
                    // we should not invoke JS when we have backpressure is cheaper to keep it queued here
                    _ = bun.handleOom(this.writeBuffer.write(this.allocator, bytes));
                    this.globalThis.vm().reportExtraMemory(bytes.len);

                    return false;
                }
                // fallback to onWrite non-native callback
                var output_value = this.binaryPayload(bytes) catch |e| {
                    this.handlers.globalObject.reportActiveExceptionAsUnhandled(e);
                    _ = bun.handleOom(this.writeBuffer.write(this.allocator, bytes));
                    this.globalThis.vm().reportExtraMemory(bytes.len);
                    this.has_nonnative_backpressure = true;
                    return false;
                };
                defer releaseBinaryPayload(&output_value);
                const result = this.callWriteHandler(output_value);
                const code: i32 = if (result) |value| switch (value) {
                    .code => |code| code,
                    .flag, .ignored => -1,
                } else -1;
                switch (code) {
                    -1 => {
                        // dropped
                        _ = bun.handleOom(this.writeBuffer.write(this.allocator, binaryPayloadBytes(&output_value)));
                        this.globalThis.vm().reportExtraMemory(bytes.len);
                        this.has_nonnative_backpressure = true;
                    },
                    0 => {
                        // queued
                        this.has_nonnative_backpressure = true;
                    },
                    else => {
                        // sended!
                        return true;
                    },
                }
                return false;
            },
        };
    }

    fn hasBackpressure(this: *H2FrameParser) bool {
        return this.writeBuffer.len > 0 or this.has_nonnative_backpressure;
    }

    fn uncork(_: *H2FrameParser) void {
        if (CORKED_H2) |corked| {
            defer corked.deref();
            corked.unregisterAutoFlush();
            log("uncork {*}", .{corked});

            const bytes = CORK_BUFFER[0..CORK_OFFSET];
            CORK_OFFSET = 0;
            CORKED_H2 = null;

            if (bytes.len > 0) {
                _ = corked._write(bytes);
            }
        }
    }

    fn registerAutoFlush(this: *H2FrameParser) void {
        if (this.auto_flusher.isRegistered()) return;
        AutoFlusherEngine.registerUnchecked(H2FrameParser, this, &this.auto_flusher, this.globalThis.bunVM());
    }

    fn unregisterAutoFlush(this: *H2FrameParser) void {
        if (!this.auto_flusher.isRegistered()) return;
        AutoFlusherEngine.unregisterUnchecked(H2FrameParser, this, &this.auto_flusher, this.globalThis.bunVM());
    }

    pub fn onAutoFlush(this: *@This()) bool {
        this.ref();
        defer this.deref();
        _ = this.flush();
        // we will unregister ourselves when the buffer is empty
        return true;
    }

    pub fn write(this: *H2FrameParser, bytes: []const u8) bool {
        log("write {}", .{bytes.len});
        if (comptime ENABLE_AUTO_CORK) {
            this.cork();
            const available = CORK_BUFFER[CORK_OFFSET..];
            if (bytes.len > available.len) {
                // not worth corking
                if (CORK_OFFSET != 0) {
                    // clean already corked data
                    this.uncork();
                }
                return this._write(bytes);
            } else {
                // write at the cork buffer
                CORK_OFFSET += @truncate(bytes.len);
                @memcpy(available[0..bytes.len], bytes);
                return true;
            }
        } else {
            return this._write(bytes);
        }
    }

    const Payload = struct {
        data: []const u8,
        end: usize,
    };

    // Default handling for payload is buffering it
    // for data frames we use another strategy
    pub fn handleIncommingPayload(this: *H2FrameParser, data: []const u8, streamIdentifier: u32) ?Payload {
        const end: usize = @min(@as(usize, @intCast(this.remainingLength)), data.len);
        const payload = data[0..end];
        this.remainingLength -= @intCast(end);
        if (this.remainingLength > 0) {
            // buffer more data
            _ = bun.handleOom(this.readBuffer.appendSlice(payload));
            this.globalThis.vm().reportExtraMemory(payload.len);

            return null;
        } else if (this.remainingLength < 0) {
            this.sendGoAway(streamIdentifier, ErrorCode.FRAME_SIZE_ERROR, "Invalid frame size", this.lastStreamID, true);
            return null;
        }

        this.currentFrame = null;

        if (this.readBuffer.list.items.len > 0) {
            // return buffered data
            _ = bun.handleOom(this.readBuffer.appendSlice(payload));
            this.globalThis.vm().reportExtraMemory(payload.len);

            return .{
                .data = this.readBuffer.list.items,
                .end = end,
            };
        }

        return .{
            .data = payload,
            .end = end,
        };
    }

    pub fn handleWindowUpdateFrame(this: *H2FrameParser, frame: FrameHeader, data: []const u8, stream: ?*Stream) usize {
        log("handleWindowUpdateFrame {}", .{frame.streamIdentifier});
        // must be always 4 bytes (https://datatracker.ietf.org/doc/html/rfc7540#section-6.9)
        if (frame.length != 4) {
            this.sendGoAway(frame.streamIdentifier, ErrorCode.FRAME_SIZE_ERROR, "Invalid dataframe frame size", this.lastStreamID, true);
            return data.len;
        }

        if (handleIncommingPayload(this, data, frame.streamIdentifier)) |content| {
            // at this point we try to send more data because we received a window update
            defer _ = this.flush();
            const payload = content.data;
            const windowSizeIncrement = UInt31WithReserved.fromBytes(payload);
            this.readBuffer.reset();
            if (windowSizeIncrement.uint31 == 0) {
                if (stream) |s| {
                    this.endStream(s, .PROTOCOL_ERROR);
                } else {
                    this.sendGoAway(0, .PROTOCOL_ERROR, "Zero connection window increment", this.lastStreamID, true);
                }
                return content.end;
            }
            if (stream) |s| {
                const next = s.sendWindow + windowSizeIncrement.uint31;
                if (next > MAX_WINDOW_SIZE) {
                    this.endStream(s, .FLOW_CONTROL_ERROR);
                    return content.end;
                }
                s.sendWindow = next;
            } else {
                const next = this.connectionSendWindow + windowSizeIncrement.uint31;
                if (next > MAX_WINDOW_SIZE) {
                    this.sendGoAway(0, .FLOW_CONTROL_ERROR, "Connection window overflow", this.lastStreamID, true);
                    return content.end;
                }
                this.connectionSendWindow = next;
            }
            log("windowSizeIncrement stream {} value {}", .{ frame.streamIdentifier, windowSizeIncrement });
            return content.end;
        }
        // needs more data
        return data.len;
    }

    pub fn decodeHeaderBlock(this: *H2FrameParser, payload: []const u8, stream: *Stream, flags: u8) bun.JSError!?*Stream {
        log("decodeHeaderBlock isSever: {}", .{this.isServer});

        if (this.handlers.vm.isShuttingDown()) {
            return null;
        }
        var decoder = if (this.hpack) |*hpack| hpack.decodeBlock(payload) else return null;

        const stream_id = stream.id;
        var headers: DecodedStrings = .{};
        defer headers.deinit(this.allocator);
        var sensitive_headers: DecodedStrings = .{};
        defer sensitive_headers.deinit(this.allocator);
        var count: usize = 0;
        var headerListSize: usize = 0;
        var rejected = false;

        while (true) {
            const header = (decoder.next() catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                this.sendGoAway(stream_id, .COMPRESSION_ERROR, "Invalid HPACK header block", this.lastStreamID, true);
                return null;
            }) orelse break;
            log("header {s} {s}", .{ header.name, header.value });
            if (this.isServer and strings.eqlComptime(header.name, ":status")) {
                this.sendGoAway(stream_id, ErrorCode.PROTOCOL_ERROR, "Server received :status header", this.lastStreamID, true);

                return null;
            }

            // Rejected streams still consume the complete block to keep the connection's dynamic table in sync.
            if (rejected) continue;
            headerListSize +|= header.name.len + header.value.len + HPACK_ENTRY_OVERHEAD;
            count += 1;
            if (headerListSize > this.localSettings.maxHeaderListSize or this.maxHeaderListPairs < count) {
                rejected = true;
                continue;
            }

            try headers.appendUTF8(this.allocator, header.name);
            if (header.never_index) {
                try sensitive_headers.appendClone(this.allocator, &headers.values.items[headers.values.items.len - 1]);
            }
            try headers.appendUTF8(this.allocator, header.value);
        }

        if (rejected) {
            this.rejectedStreams +|= 1;
            if (this.maxRejectedStreams <= this.rejectedStreams) {
                this.sendGoAway(stream_id, .ENHANCE_YOUR_CALM, "ENHANCE_YOUR_CALM", this.lastStreamID, true);
            } else {
                this.endStream(stream, .ENHANCE_YOUR_CALM);
            }
            return null;
        }

        const headers_value = try headers.operands(this.allocator);
        defer this.allocator.free(headers_value);
        const sensitive_headers_value = if (sensitive_headers.values.items.len > 0) try sensitive_headers.operands(this.allocator) else null;
        defer if (sensitive_headers_value) |value| this.allocator.free(value);
        this.dispatchStreamHeaders(stream.getIdentifier(), headers_value, sensitive_headers_value, flags);
        return this.streams.get(stream_id);
    }

    pub fn handleDataFrame(this: *H2FrameParser, frame: FrameHeader, data: []const u8, stream_: ?*Stream) usize {
        log("handleDataFrame {s} data.len: {d}", .{ if (this.isServer) "server" else "client", data.len });
        this.readBuffer.reset();

        var stream = stream_ orelse {
            log("received data frame on stream that does not exist", .{});
            this.sendGoAway(frame.streamIdentifier, ErrorCode.PROTOCOL_ERROR, "Data frame on connection stream", this.lastStreamID, true);
            return data.len;
        };

        const end: usize = @min(@as(usize, @intCast(this.remainingLength)), data.len);
        var payload = data[0..end];
        // window size considering the full frame.length received so far
        this.adjustWindowSize(stream, @truncate(payload.len));
        const previous_remaining_length: isize = this.remainingLength;

        this.remainingLength -= @intCast(end);
        var padding: u8 = 0;
        const padded = frame.flags & @backingInt(DataFrameFlags.PADDED) != 0;
        if (padded) {
            if (frame.length < 1) {
                // PADDED flag set but no room for the Pad Length octet
                this.sendGoAway(frame.streamIdentifier, ErrorCode.FRAME_SIZE_ERROR, "Invalid data frame size", this.lastStreamID, true);
                return data.len;
            }
            if (stream.padding) |p| {
                padding = p;
            } else {
                if (payload.len == 0) {
                    // await more data because we need to know the padding length
                    return data.len;
                }
                padding = payload[0];
                stream.padding = payload[0];
            }
            // RFC 7540 Section 6.1: If the length of the padding is the length of
            // the frame payload or greater, the recipient MUST treat this as a
            // connection error of type PROTOCOL_ERROR. Validate before computing
            // `data_region_end = frame.length - padding` below to avoid underflow.
            if (@as(usize, padding) >= frame.length) {
                this.sendGoAway(frame.streamIdentifier, ErrorCode.PROTOCOL_ERROR, "Invalid data frame padding", this.lastStreamID, true);
                return data.len;
            }
        }
        if (this.remainingLength < 0) {
            this.sendGoAway(frame.streamIdentifier, ErrorCode.FRAME_SIZE_ERROR, "Invalid data frame size", this.lastStreamID, true);
            return data.len;
        }
        var emitted = false;

        const start_idx = frame.length - @as(usize, @intCast(previous_remaining_length));
        if (start_idx < 1 and padded and payload.len > 0) {
            // Skip the Pad Length octet. Keyed on the PADDED flag rather than
            // `padding > 0` because Pad Length = 0 is valid (RFC 7540 Section 6.1)
            // and must still be stripped.
            payload = payload[1..];
        }

        if (payload.len > 0) {
            // amount of data received so far
            const received_size = frame.length - this.remainingLength;
            // The data region of this frame, in frame-relative offsets, is
            // `[padded ? 1 : 0, frame.length - padding)`. This chunk begins at
            // offset `start_idx` (and the Pad Length octet has already been
            // stripped above when `start_idx == 0`), so the number of data bytes
            // it can contribute is `data_region_end - max(start_idx, data_region_start)`.
            // Saturate to 0 for chunks that land entirely in the trailing padding.
            const data_region_end: usize = frame.length - @as(usize, padding);
            const data_region_start: usize = if (padded) @max(start_idx, 1) else start_idx;
            const max_payload_size: usize = data_region_end -| data_region_start;
            payload = payload[0..@min(payload.len, max_payload_size)];
            log("received_size: {d} max_payload_size: {d} padding: {d} payload.len: {d}", .{
                received_size,
                max_payload_size,
                padding,
                payload.len,
            });

            if (payload.len > 0) {
                // no padding, just emit the data
                if (this.binaryPayload(payload)) |value| {
                    var chunk = value;
                    defer releaseBinaryPayload(&chunk);
                    this.dispatchStreamData(stream.getIdentifier(), chunk);
                    emitted = true;
                } else |e| {
                    this.handlers.globalObject.reportActiveExceptionAsUnhandled(e);
                }
            }
        }
        if (this.remainingLength == 0) {
            this.currentFrame = null;
            stream.padding = null;
            if (emitted) {
                stream = this.streams.get(frame.streamIdentifier) orelse return end;
            }
            if (frame.flags & @backingInt(DataFrameFlags.END_STREAM) != 0) {
                const identifier = stream.getIdentifier();

                if (stream.state == .HALF_CLOSED_LOCAL) {
                    stream.state = .CLOSED;
                    stream.freeResources(this, false);
                } else {
                    stream.state = .HALF_CLOSED_REMOTE;
                }
                this.dispatchStreamEnd(identifier, @backingInt(stream.state));
            }
        }

        return end;
    }

    pub fn handleGoAwayFrame(this: *H2FrameParser, frame: FrameHeader, data: []const u8, stream_: ?*Stream) usize {
        log("handleGoAwayFrame {} {s}", .{ frame.streamIdentifier, data });
        if (stream_ != null) {
            this.sendGoAway(frame.streamIdentifier, ErrorCode.PROTOCOL_ERROR, "GoAway frame on stream", this.lastStreamID, true);
            return data.len;
        }
        const settings = this.remoteSettings orelse this.localSettings;

        if (frame.length < 8 or frame.length > settings.maxFrameSize) {
            this.sendGoAway(frame.streamIdentifier, ErrorCode.FRAME_SIZE_ERROR, "invalid GoAway frame size", this.lastStreamID, true);
            return data.len;
        }

        if (handleIncommingPayload(this, data, frame.streamIdentifier)) |content| {
            const payload = content.data;
            const error_code = H2Frame.decodeU32(payload[4..8]);
            var chunk = this.binaryPayload(payload[8..]) catch |e| {
                this.handlers.globalObject.reportActiveExceptionAsUnhandled(e);
                this.readBuffer.reset();
                return content.end;
            };
            defer releaseBinaryPayload(&chunk);
            this.readBuffer.reset();
            this.dispatchGoAway(error_code, this.lastStreamID, chunk);
            return content.end;
        }
        return data.len;
    }

    pub fn handleOriginFrame(this: *H2FrameParser, frame: FrameHeader, data: []const u8, _: ?*Stream) bun.JSError!usize {
        log("handleOriginFrame {s}", .{data});
        if (this.isServer) {
            this.sendGoAway(frame.streamIdentifier, ErrorCode.PROTOCOL_ERROR, "ORIGIN frame on server", this.lastStreamID, true);
            return data.len;
        }
        if (frame.streamIdentifier != 0) {
            this.sendGoAway(frame.streamIdentifier, ErrorCode.PROTOCOL_ERROR, "ORIGIN frame on stream", this.lastStreamID, true);
            return data.len;
        }
        if (handleIncommingPayload(this, data, frame.streamIdentifier)) |content| {
            var payload = content.data;
            var origins: DecodedStrings = .{};
            defer origins.deinit(this.allocator);
            this.readBuffer.reset();

            while (payload.len > 0) {
                var reader = std.Io.Reader.fixed(payload);
                const origin_length = reader.takeInt(u16, .big) catch |err| {
                    log("error reading ORIGIN frame size: {s}", .{@errorName(err)});
                    // origin length is the first 2 bytes of the payload
                    this.sendGoAway(frame.streamIdentifier, ErrorCode.FRAME_SIZE_ERROR, "invalid ORIGIN frame size", this.lastStreamID, true);
                    return content.end;
                };
                var origin_str = payload[2..];
                if (origin_str.len < origin_length) {
                    this.sendGoAway(frame.streamIdentifier, ErrorCode.FRAME_SIZE_ERROR, "invalid ORIGIN frame size", this.lastStreamID, true);
                    return content.end;
                }
                origin_str = origin_str[0..origin_length];
                try origins.appendUTF8(this.allocator, origin_str);
                payload = payload[origin_length + 2 ..];
            }

            switch (origins.values.items.len) {
                0 => this.dispatchOrigin(null),
                1 => this.dispatchOrigin(.{ .single = origins.values.items[0].operand() }),
                else => {
                    const values = try origins.operands(this.allocator);
                    defer this.allocator.free(values);
                    this.dispatchOrigin(.{ .multiple = values });
                },
            }
            return content.end;
        }
        return data.len;
    }

    pub fn handleAltsvcFrame(this: *H2FrameParser, frame: FrameHeader, data: []const u8, stream_: ?*Stream) bun.JSError!usize {
        log("handleAltsvcFrame {s}", .{data});
        if (this.isServer) {
            // client should not send ALTSVC frame
            this.sendGoAway(frame.streamIdentifier, ErrorCode.PROTOCOL_ERROR, "ALTSVC frame on server", this.lastStreamID, true);
            return data.len;
        }
        if (handleIncommingPayload(this, data, frame.streamIdentifier)) |content| {
            const payload = content.data;

            var reader = std.Io.Reader.fixed(payload);
            this.readBuffer.reset();

            const origin_length = reader.takeInt(u16, .big) catch {
                // origin length is the first 2 bytes of the payload
                this.sendGoAway(frame.streamIdentifier, ErrorCode.FRAME_SIZE_ERROR, "invalid ALTSVC frame size", this.lastStreamID, true);
                return content.end;
            };
            const origin_and_value = payload[2..];

            if (origin_and_value.len < origin_length) {
                this.sendGoAway(frame.streamIdentifier, ErrorCode.FRAME_SIZE_ERROR, "invalid ALTSVC frame size", this.lastStreamID, true);
                return content.end;
            }
            if (frame.streamIdentifier != 0 and stream_ == null) {
                // dont error but stream dont exist so we can ignore it
                return content.end;
            }

            try this.dispatchAltSvc(origin_and_value[0..origin_length], origin_and_value[origin_length..], frame.streamIdentifier);
            return content.end;
        }
        return data.len;
    }

    pub fn handleRSTStreamFrame(this: *H2FrameParser, frame: FrameHeader, data: []const u8, stream_: ?*Stream) usize {
        log("handleRSTStreamFrame {s}", .{data});
        var stream = stream_ orelse {
            this.sendGoAway(frame.streamIdentifier, ErrorCode.PROTOCOL_ERROR, "RST_STREAM frame on connection stream", this.lastStreamID, true);
            return data.len;
        };

        if (frame.length != 4) {
            this.sendGoAway(frame.streamIdentifier, ErrorCode.FRAME_SIZE_ERROR, "invalid RST_STREAM frame size", this.lastStreamID, true);
            return data.len;
        }

        if (handleIncommingPayload(this, data, frame.streamIdentifier)) |content| {
            const payload = content.data;
            const rst_code = H2Frame.decodeU32(payload);
            stream.rstCode = rst_code;
            this.readBuffer.reset();
            stream.state = .CLOSED;
            const identifier = stream.getIdentifier();
            stream.freeResources(this, false);
            if (rst_code == @backingInt(ErrorCode.NO_ERROR)) {
                this.dispatchStreamEnd(identifier, @backingInt(stream.state));
            } else {
                this.dispatchStreamError(identifier, rst_code);
            }
            return content.end;
        }
        return data.len;
    }

    pub fn handlePingFrame(this: *H2FrameParser, frame: FrameHeader, data: []const u8, stream_: ?*Stream) usize {
        if (stream_ != null) {
            this.sendGoAway(frame.streamIdentifier, ErrorCode.PROTOCOL_ERROR, "Ping frame on stream", this.lastStreamID, true);
            return data.len;
        }

        if (frame.length != 8) {
            this.sendGoAway(frame.streamIdentifier, ErrorCode.FRAME_SIZE_ERROR, "Invalid ping frame size", this.lastStreamID, true);
            return data.len;
        }

        if (handleIncommingPayload(this, data, frame.streamIdentifier)) |content| {
            const payload = content.data;
            const isNotACK = frame.flags & @backingInt(PingFrameFlags.ACK) == 0;
            var buffer = this.binaryPayload(payload) catch |e| {
                this.handlers.globalObject.reportActiveExceptionAsUnhandled(e);
                this.readBuffer.reset();
                return content.end;
            };
            defer releaseBinaryPayload(&buffer);
            var ping_payload: [8]u8 = undefined;
            @memcpy(&ping_payload, payload);
            this.readBuffer.reset();

            // if is not ACK send response
            if (isNotACK) {
                this.sendPing(true, &ping_payload);
            } else {
                this.outStandingPings -|= 1;
            }
            this.dispatchPing(buffer, !isNotACK);
            return content.end;
        }
        return data.len;
    }

    pub fn handlePriorityFrame(this: *H2FrameParser, frame: FrameHeader, data: []const u8, stream_: ?*Stream) usize {
        var stream = stream_ orelse {
            this.sendGoAway(frame.streamIdentifier, ErrorCode.PROTOCOL_ERROR, "Priority frame on connection stream", this.lastStreamID, true);
            return data.len;
        };

        if (frame.length != StreamPriority.byteSize) {
            this.sendGoAway(frame.streamIdentifier, ErrorCode.FRAME_SIZE_ERROR, "invalid Priority frame size", this.lastStreamID, true);
            return data.len;
        }

        if (handleIncommingPayload(this, data, frame.streamIdentifier)) |content| {
            const payload = content.data;

            const priority = StreamPriority.decode(payload);
            this.readBuffer.reset();

            const stream_identifier = UInt31WithReserved.from(priority.streamIdentifier);
            if (stream_identifier.uint31 == stream.id) {
                this.sendGoAway(stream.id, ErrorCode.PROTOCOL_ERROR, "Priority frame with self dependency", this.lastStreamID, true);
                return content.end;
            }
            stream.streamDependency = stream_identifier.uint31;
            stream.exclusive = stream_identifier.reserved;
            stream.weight = priority.weight;

            return content.end;
        }
        return data.len;
    }

    fn appendHeaderFragment(this: *H2FrameParser, stream_id: u32, fragment: []const u8) bun.OOM!bool {
        const limit = @as(usize, this.maxSessionMemory) * 1024 * 1024;
        if (fragment.len > limit -| this.header_block.items.len) {
            this.header_block.clearAndFree(this.allocator);
            this.pending_headers = null;
            this.sendGoAway(stream_id, .ENHANCE_YOUR_CALM, "Header block exceeds session memory limit", this.lastStreamID, true);
            return false;
        }
        try this.header_block.appendSlice(this.allocator, fragment);
        return true;
    }

    fn finishHeaderBlock(this: *H2FrameParser, payload: []const u8, stream: *Stream, flags: u8) bun.JSError!void {
        const end_stream = flags & @backingInt(HeadersFrameFlags.END_STREAM) != 0;
        stream.endAfterHeaders = end_stream;
        const current = (try this.decodeHeaderBlock(payload, stream, flags)) orelse return;
        if (!end_stream or current.state == .CLOSED) return;
        const identifier = current.getIdentifier();
        if (current.state == .HALF_CLOSED_LOCAL) {
            current.state = .CLOSED;
            current.freeResources(this, false);
        } else {
            current.state = .HALF_CLOSED_REMOTE;
        }
        this.dispatchStreamEnd(identifier, @backingInt(current.state));
    }

    pub fn handleContinuationFrame(this: *H2FrameParser, frame: FrameHeader, data: []const u8, stream_: ?*Stream) bun.JSError!usize {
        log("handleContinuationFrame", .{});
        const stream = stream_ orelse {
            this.sendGoAway(frame.streamIdentifier, ErrorCode.PROTOCOL_ERROR, "Continuation on connection stream", this.lastStreamID, true);
            return data.len;
        };

        const pending = this.pending_headers orelse {
            this.sendGoAway(frame.streamIdentifier, ErrorCode.PROTOCOL_ERROR, "Continuation without headers", this.lastStreamID, true);
            return data.len;
        };
        if (handleIncommingPayload(this, data, frame.streamIdentifier)) |content| {
            const payload = content.data;
            this.readBuffer.reset();
            if (!try this.appendHeaderFragment(stream.id, payload)) return content.end;
            if (frame.flags & @backingInt(HeadersFrameFlags.END_HEADERS) == 0) return content.end;
            var block = this.header_block;
            this.header_block = .empty;
            this.pending_headers = null;
            defer block.deinit(this.allocator);
            try this.finishHeaderBlock(block.items, stream, pending.flags | @backingInt(HeadersFrameFlags.END_HEADERS));
            return content.end;
        }

        // needs more data
        return data.len;
    }

    pub fn handleHeadersFrame(this: *H2FrameParser, frame: FrameHeader, data: []const u8, stream_: ?*Stream) bun.JSError!usize {
        log("handleHeadersFrame {s}", .{if (this.isServer) "server" else "client"});
        const stream = stream_ orelse {
            this.sendGoAway(frame.streamIdentifier, ErrorCode.PROTOCOL_ERROR, "Headers frame on connection stream", this.lastStreamID, true);
            return data.len;
        };

        if (handleIncommingPayload(this, data, frame.streamIdentifier)) |content| {
            const payload = content.data;
            var offset: usize = 0;
            var padding: usize = 0;
            this.readBuffer.reset();

            if (frame.flags & @backingInt(HeadersFrameFlags.PADDED) != 0) {
                if (payload.len < 1) {
                    // PADDED flag set but no room for the Pad Length octet
                    this.sendGoAway(frame.streamIdentifier, ErrorCode.FRAME_SIZE_ERROR, "invalid Headers frame size", this.lastStreamID, true);
                    return content.end;
                }
                // padding length
                padding = payload[0];
                offset += 1;
            }
            if (frame.flags & @backingInt(HeadersFrameFlags.PRIORITY) != 0) {
                // skip priority (client dont need to care about it)
                offset += 5;
            }
            // RFC 7540 Section 4.2: A frame that is too small to contain mandatory
            // frame data (here: the Pad Length octet and/or the 5-byte priority
            // block) MUST be treated as a FRAME_SIZE_ERROR.
            if (offset > payload.len) {
                this.sendGoAway(frame.streamIdentifier, ErrorCode.FRAME_SIZE_ERROR, "invalid Headers frame size", this.lastStreamID, true);
                return content.end;
            }
            // RFC 7540 Section 6.2: Padding that exceeds the size remaining for the
            // header block fragment MUST be treated as a connection error of type
            // PROTOCOL_ERROR. Validate before subtracting to avoid underflowing
            // `payload.len - padding` when a peer sends Pad Length > payload length.
            if (padding > payload.len - offset) {
                this.sendGoAway(frame.streamIdentifier, ErrorCode.PROTOCOL_ERROR, "invalid Headers frame padding", this.lastStreamID, true);
                return content.end;
            }
            const end = payload.len - padding;
            if (frame.flags & @backingInt(HeadersFrameFlags.END_HEADERS) == 0) {
                if (!try this.appendHeaderFragment(stream.id, payload[offset..end])) return content.end;
                this.pending_headers = .{ .stream_id = stream.id, .flags = frame.flags };
            } else {
                try this.finishHeaderBlock(payload[offset..end], stream, frame.flags);
            }
            return content.end;
        }

        // needs more data
        return data.len;
    }

    fn applyRemoteSetting(this: *H2FrameParser, settings: *FullSettingsPayload, unit: SettingsPayloadUnit) bool {
        switch (@as(SettingsType, @fromBackingInt(@intCast(unit.type)))) {
            .SETTINGS_HEADER_TABLE_SIZE => {
                if (this.hpack) |*hpack| hpack.setEncoderMaxCapacity(unit.value);
            },
            .SETTINGS_ENABLE_PUSH => {
                if (unit.value > 1) {
                    this.sendGoAway(0, .PROTOCOL_ERROR, "Invalid SETTINGS_ENABLE_PUSH", this.lastStreamID, true);
                    return false;
                }
            },
            .SETTINGS_INITIAL_WINDOW_SIZE => {
                if (unit.value > MAX_WINDOW_SIZE) {
                    this.sendGoAway(0, .FLOW_CONTROL_ERROR, "Invalid initial stream window", this.lastStreamID, true);
                    return false;
                }
                const delta = @as(i64, unit.value) - settings.initialWindowSize;
                var it = this.streams.valueIterator();
                while (it.next()) |item| {
                    const stream = item.*;
                    if (!stream.canSendData()) continue;
                    if (stream.sendWindow + delta > MAX_WINDOW_SIZE) {
                        this.sendGoAway(0, .FLOW_CONTROL_ERROR, "Initial stream window overflow", this.lastStreamID, true);
                        return false;
                    }
                }
                it = this.streams.valueIterator();
                while (it.next()) |item| {
                    const stream = item.*;
                    if (stream.canSendData()) stream.sendWindow += delta;
                }
            },
            .SETTINGS_MAX_FRAME_SIZE => {
                if (unit.value < 16384 or unit.value > MAX_FRAME_SIZE) {
                    this.sendGoAway(0, .PROTOCOL_ERROR, "Invalid maximum frame size", this.lastStreamID, true);
                    return false;
                }
            },
            else => {},
        }
        settings.updateWith(unit);
        return true;
    }

    pub fn handleSettingsFrame(this: *H2FrameParser, frame: FrameHeader, data: []const u8) usize {
        const isACK = frame.flags & @backingInt(SettingsFlags.ACK) != 0;

        log("handleSettingsFrame {s} isACK {}", .{ if (this.isServer) "server" else "client", isACK });
        if (frame.streamIdentifier != 0) {
            this.sendGoAway(frame.streamIdentifier, ErrorCode.PROTOCOL_ERROR, "Settings frame on connection stream", this.lastStreamID, true);
            return data.len;
        }
        const settingByteSize = SettingsPayloadUnit.byteSize;
        if (frame.length > 0) {
            if (isACK or frame.length % settingByteSize != 0) {
                log("invalid settings frame size", .{});
                this.sendGoAway(frame.streamIdentifier, ErrorCode.FRAME_SIZE_ERROR, "Invalid settings frame size", this.lastStreamID, true);
                return data.len;
            }
        } else {
            if (isACK) {
                // we received an ACK
                log("settings frame ACK", .{});

                // we can now write any request
                if (this.pendingSettings.items.len > 0) {
                    const acknowledged = this.pendingSettings.orderedRemove(0);
                    const old_size: i64 = this.acknowledgedLocalSettings.initialWindowSize;
                    const new_size: i64 = acknowledged.initialWindowSize;
                    const delta = new_size - old_size;
                    this.acknowledgedLocalSettings = acknowledged;
                    if (this.hpack) |*hpack| hpack.setDecoderMaxCapacity(acknowledged.headerTableSize);
                    if (delta != 0) {
                        var it = this.streams.valueIterator();
                        while (it.next()) |item| {
                            const stream = item.*;
                            if (delta >= 0) {
                                stream.windowSize +|= @intCast(@as(u64, @intCast(delta)));
                            } else {
                                stream.windowSize -|= @intCast(@as(u64, @intCast(-delta)));
                            }
                        }
                        log("adjusted stream windows by delta {} (old: {}, new: {})", .{ delta, old_size, new_size });
                    }
                    this.dispatchSettings(.onLocalSettings, settingsCallbackValue(&acknowledged));
                }
            } else {
                const remoteSettings = this.remoteSettings orelse FullSettingsPayload{};
                this.remoteSettings = remoteSettings;
                this.sendSettingsACK();
                this.dispatchSettings(.onRemoteSettings, settingsCallbackValue(&remoteSettings));
                _ = this.flush();
            }

            this.currentFrame = null;
            return 0;
        }
        if (handleIncommingPayload(this, data, frame.streamIdentifier)) |content| {
            defer this.readBuffer.reset();
            var remoteSettings: FullSettingsPayload = this.remoteSettings orelse .{};
            var i: usize = 0;
            const payload = content.data;
            while (i < payload.len) {
                defer i += settingByteSize;
                const unit = SettingsPayloadUnit.decode(payload[i .. i + settingByteSize]);
                if (!this.applyRemoteSetting(&remoteSettings, unit)) return content.end;
                log("remoteSettings: {} {} isServer: {}", .{ @as(SettingsType, @fromBackingInt(@intCast(unit.type))), unit.value, this.isServer });
            }
            this.remoteSettings = remoteSettings;
            this.sendSettingsACK();
            this.dispatchSettings(.onRemoteSettings, settingsCallbackValue(&remoteSettings));
            _ = this.flush();
            this.incrementWindowSizeIfNeeded();
            return content.end;
        }
        // needs more data
        return data.len;
    }

    /// Returned *Stream is heap-allocated and stable for the lifetime of this H2FrameParser.
    fn handleReceivedStreamID(this: *H2FrameParser, streamIdentifier: u32) ?*Stream {
        // connection stream
        if (streamIdentifier == 0) {
            return null;
        }

        // already exists
        if (this.streams.get(streamIdentifier)) |stream| {
            return stream;
        }

        if (streamIdentifier > this.lastStreamID) {
            this.lastStreamID = streamIdentifier;
        }

        // new stream open
        // Per RFC 7540 Section 6.5.1: The sender of SETTINGS can only rely on the
        // setting being applied AFTER receiving SETTINGS_ACK. Until then, the peer
        // hasn't seen our settings and uses the default window size.
        // So we must accept data up to DEFAULT_WINDOW_SIZE until our SETTINGS is ACKed.
        const local_window_size = this.acknowledgedLocalSettings.initialWindowSize;
        const stream = Stream.new(Stream.init(
            streamIdentifier,
            local_window_size,
            if (this.remoteSettings) |s| s.initialWindowSize else DEFAULT_WINDOW_SIZE,
            this.paddingStrategy,
        ));
        bun.handleOom(this.streams.put(streamIdentifier, stream));

        this.dispatchStreamStart(streamIdentifier);
        return stream;
    }

    fn readBytes(this: *H2FrameParser, bytes: []const u8) bun.JSError!usize {
        log("read {}", .{bytes.len});
        if (this.isServer and this.prefaceReceivedLen < 24) {
            // Handle Server Preface
            const preface_missing: usize = 24 - this.prefaceReceivedLen;
            const preface_available = @min(preface_missing, bytes.len);
            if (!strings.eql(bytes[0..preface_available], "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"[this.prefaceReceivedLen .. preface_available + this.prefaceReceivedLen])) {
                // invalid preface
                log("invalid preface", .{});
                this.sendGoAway(0, ErrorCode.PROTOCOL_ERROR, "Invalid preface", this.lastStreamID, true);
                return preface_available;
            }
            this.prefaceReceivedLen += @intCast(preface_available);
            return preface_available;
        }
        if (this.currentFrame) |header| {
            log("current frame {s} {} {} {} {}", .{ if (this.isServer) "server" else "client", header.type, header.length, header.flags, header.streamIdentifier });
            return this.dispatchFrame(header, bytes);
        }

        // nothing to do
        if (bytes.len == 0) return bytes.len;

        const buffered_data = this.readBuffer.list.items.len;

        var header: FrameHeader = undefined;
        // we can have less than 9 bytes buffered
        if (buffered_data > 0) {
            const total = buffered_data + bytes.len;
            if (total < FrameHeader.byteSize) {
                // buffer more data
                _ = bun.handleOom(this.readBuffer.appendSlice(bytes));
                this.globalThis.vm().reportExtraMemory(bytes.len);

                return bytes.len;
            }
            const needed = FrameHeader.byteSize - buffered_data;
            var header_bytes: [FrameHeader.byteSize]u8 = undefined;
            @memcpy(header_bytes[0..buffered_data], this.readBuffer.list.items[0..buffered_data]);
            @memcpy(header_bytes[buffered_data..], bytes[0..needed]);
            header = FrameHeader.decode(&header_bytes);
            // reset for later use
            this.readBuffer.reset();

            this.currentFrame = header;
            this.remainingLength = header.length;
            log("new frame {} {} {} {}", .{ header.type, header.length, header.flags, header.streamIdentifier });
            return try this.dispatchFrame(header, bytes[needed..]) + needed;
        }

        if (bytes.len < FrameHeader.byteSize) {
            // buffer more dheaderata
            bun.handleOom(this.readBuffer.appendSlice(bytes));
            this.globalThis.vm().reportExtraMemory(bytes.len);

            return bytes.len;
        }

        header = FrameHeader.decode(bytes[0..FrameHeader.byteSize]);

        log("new frame {s} {} {} {} {}", .{ if (this.isServer) "server" else "client", header.type, header.length, header.flags, header.streamIdentifier });
        this.currentFrame = header;
        this.remainingLength = header.length;
        return try this.dispatchFrame(header, bytes[FrameHeader.byteSize..]) + FrameHeader.byteSize;
    }

    fn dispatchFrame(this: *H2FrameParser, header: FrameHeader, payload: []const u8) bun.JSError!usize {
        if (this.pending_headers) |pending| {
            if (header.type != @backingInt(FrameType.HTTP_FRAME_CONTINUATION) or header.streamIdentifier != pending.stream_id) {
                this.sendGoAway(header.streamIdentifier, .PROTOCOL_ERROR, "Expected CONTINUATION on the active header stream", this.lastStreamID, true);
                return payload.len;
            }
        } else if (header.type == @backingInt(FrameType.HTTP_FRAME_CONTINUATION)) {
            this.sendGoAway(header.streamIdentifier, .PROTOCOL_ERROR, "Continuation without headers", this.lastStreamID, true);
            return payload.len;
        }
        const frame_limit = @max(this.localSettings.maxFrameSize, this.acknowledgedLocalSettings.maxFrameSize);
        if (header.length > frame_limit) {
            this.sendGoAway(header.streamIdentifier, .FRAME_SIZE_ERROR, "Frame exceeds the receive size limit", this.lastStreamID, true);
            return payload.len;
        }
        const stream = this.handleReceivedStreamID(header.streamIdentifier);
        return switch (header.type) {
            @backingInt(FrameType.HTTP_FRAME_SETTINGS) => this.handleSettingsFrame(header, payload),
            @backingInt(FrameType.HTTP_FRAME_WINDOW_UPDATE) => this.handleWindowUpdateFrame(header, payload, stream),
            @backingInt(FrameType.HTTP_FRAME_HEADERS) => this.handleHeadersFrame(header, payload, stream),
            @backingInt(FrameType.HTTP_FRAME_DATA) => this.handleDataFrame(header, payload, stream),
            @backingInt(FrameType.HTTP_FRAME_CONTINUATION) => this.handleContinuationFrame(header, payload, stream),
            @backingInt(FrameType.HTTP_FRAME_PRIORITY) => this.handlePriorityFrame(header, payload, stream),
            @backingInt(FrameType.HTTP_FRAME_PING) => this.handlePingFrame(header, payload, stream),
            @backingInt(FrameType.HTTP_FRAME_GOAWAY) => this.handleGoAwayFrame(header, payload, stream),
            @backingInt(FrameType.HTTP_FRAME_RST_STREAM) => this.handleRSTStreamFrame(header, payload, stream),
            @backingInt(FrameType.HTTP_FRAME_ALTSVC) => this.handleAltsvcFrame(header, payload, stream),
            @backingInt(FrameType.HTTP_FRAME_ORIGIN) => this.handleOriginFrame(header, payload, stream),
            else => {
                this.sendGoAway(header.streamIdentifier, ErrorCode.PROTOCOL_ERROR, "Unknown frame type", this.lastStreamID, true);
                return payload.len;
            },
        };
    }

    const DirectWriterStruct = struct {
        writer: *H2FrameParser,
        pub fn write(this: *const DirectWriterStruct, data: []const u8) !usize {
            return if (this.writer.write(data)) data.len else 0;
        }
    };

    fn toWriter(this: *H2FrameParser) DirectWriterStruct {
        return DirectWriterStruct{ .writer = this };
    }

    fn validateCustomSettings(context: anytype, custom_settings: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
        if (custom_settings.len() > MAX_CUSTOM_SETTINGS) {
            return context.fail(.too_many_custom_settings, {});
        }
        for (0..custom_settings.len()) |index| {
            const entry = custom_settings.at(index).?;
            const key = try entry.key.toUTF8(bun.default_allocator);
            defer key.deinit();
            const setting_id = std.fmt.parseInt(u32, key.slice(), 10) catch {
                return context.fail(.invalid_custom_setting_identifier, {});
            };
            if (setting_id > 0xFFFF) {
                return context.fail(.invalid_custom_setting_identifier, {});
            }
        }
    }

    fn applySettings(this: *H2FrameParser, context: anytype, options: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
        if (options.header_table_size) |value| this.localSettings.headerTableSize = value;
        if (options.enable_push) |value| this.localSettings.enablePush = @intFromBool(value);
        if (options.initial_window_size) |value| {
            log("initialWindowSize: {d}", .{value});
            this.localSettings.initialWindowSize = value;
        }
        if (options.max_frame_size) |value| this.localSettings.maxFrameSize = value;
        if (options.max_concurrent_streams) |value| this.localSettings.maxConcurrentStreams = value;
        if (options.max_header_list_size) |value| this.localSettings.maxHeaderListSize = value;
        if (options.max_header_size) |value| this.localSettings.maxHeaderListSize = value;
        if (options.custom_settings) |custom| try validateCustomSettings(context, custom);
    }

    pub fn updateSettings(this: *H2FrameParser, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!bool {
        try this.applySettings(context, args.settings);
        return try this.setSettings(this.localSettings);
    }

    fn requireStream(this: *H2FrameParser, context: anytype, stream_id: u32) bun.bindgen.CallError(@TypeOf(context))!*Stream {
        if (stream_id == 0 or stream_id > MAX_STREAM_ID) return context.fail(.invalid_stream, {});
        return this.streams.get(stream_id) orelse return context.fail(.invalid_stream, {});
    }

    pub fn setLocalWindowSize(this: *H2FrameParser, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
        const windowSizeValue = args.window_size;
        if (this.usedWindowSize > windowSizeValue) {
            return context.fail(.window_size_too_small, {});
        }
        const oldWindowSize = this.windowSize;
        this.windowSize = windowSizeValue;
        if (this.localSettings.initialWindowSize < windowSizeValue) {
            this.localSettings.initialWindowSize = windowSizeValue;
        }
        // Send a connection-level WINDOW_UPDATE frame to the peer so it knows
        // about the increased window.  Per RFC 9113 Section 6.9, the
        // INITIAL_WINDOW_SIZE setting only applies to stream-level windows;
        // the connection-level window must be updated explicitly.
        if (windowSizeValue > oldWindowSize) {
            const increment: u31 = @truncate(windowSizeValue - oldWindowSize);
            this.sendWindowUpdate(0, UInt31WithReserved.init(increment, false));
        }
        var it = this.streams.valueIterator();
        while (it.next()) |item| {
            const stream = item.*;
            if (stream.usedWindowSize > windowSizeValue) {
                continue;
            }
            stream.windowSize = windowSizeValue;
        }
    }

    pub fn getCurrentState(this: *H2FrameParser, _: anytype, _: anytype) bun.JSError!bindgen.Return(H2FrameParserSchema.member("getCurrentState")) {
        const settings: FullSettingsPayload = this.remoteSettings orelse .{};
        return .{
            .effective_local_window_size = this.windowSize,
            .effective_recv_data_length = this.windowSize - this.usedWindowSize,
            .next_stream_id = this.getNextStreamID(),
            .last_proc_stream_id = this.lastStreamID,
            .remote_window_size = settings.initialWindowSize,
            .local_window_size = this.localSettings.initialWindowSize,
            .deflate_dynamic_table_size = if (this.hpack) |*hpack| hpack.encoderMaxCapacity() else H2Frame.default_header_table_size,
            .inflate_dynamic_table_size = if (this.hpack) |*hpack| hpack.decoderMaxCapacity() else H2Frame.default_header_table_size,
            .outbound_queue_size = this.outboundQueueSize,
        };
    }

    pub fn goaway(this: *H2FrameParser, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
        const last_stream_id = args.last_stream_id orelse this.lastStreamID;
        if (last_stream_id > MAX_STREAM_ID) {
            return context.fail(.invalid_last_stream_id, {});
        }
        this.sendGoAway(
            0,
            @fromBackingInt(args.error_code),
            if (args.opaque_data) |data| data.unsafePtr("the generated entry frame owns the debug-data lease until sendGoAway copies the payload") else "",
            last_stream_id,
            false,
        );
    }

    pub fn ping(this: *H2FrameParser, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
        if (this.outStandingPings >= this.maxOutstandingPings) {
            return context.fail(.ping_cancelled, {});
        }
        this.sendPing(false, args.payload.unsafePtr("the generated entry frame owns the payload lease until sendPing copies it into the frame buffer"));
    }

    pub fn origin(this: *H2FrameParser, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
        const origins = args.origins orelse {
            // empty origin frame
            var buffer: [FrameHeader.byteSize]u8 = undefined;
            @memset(&buffer, 0);
            var writer_state = std.Io.Writer.fixed(&buffer);
            const writer = &writer_state;

            var frame: FrameHeader = .{
                .type = @backingInt(FrameType.HTTP_FRAME_ORIGIN),
                .flags = 0,
                .streamIdentifier = 0,
                .length = 0,
            };
            _ = frame.write(@TypeOf(writer), writer);
            _ = this.write(&buffer);
            return;
        };

        switch (origins) {
            .string => |origin_value| {
                const origin_string = try origin_value.toUTF8(bun.default_allocator);
                defer origin_string.deinit();
                const slice = origin_string.slice();
                if (slice.len + 2 > 16384) {
                    return context.fail(.origin_too_long, {});
                }

                var buffer: [FrameHeader.byteSize + 2]u8 = undefined;
                @memset(&buffer, 0);
                var writer_state = std.Io.Writer.fixed(&buffer);
                const writer = &writer_state;

                var frame: FrameHeader = .{
                    .type = @backingInt(FrameType.HTTP_FRAME_ORIGIN),
                    .flags = 0,
                    .streamIdentifier = 0,
                    .length = @intCast(slice.len + 2),
                };
                _ = frame.write(@TypeOf(writer), writer);
                _ = writer.writeInt(u16, @intCast(slice.len), .big) catch 0;
                _ = this.write(&buffer);
                if (slice.len > 0) _ = this.write(slice);
            },
            .array => |values| {
                var buffer: [FrameHeader.byteSize + 16384]u8 = undefined;
                @memset(&buffer, 0);
                var writer_state = std.Io.Writer.fixed(&buffer);
                const writer = &writer_state;
                writer.end = FrameHeader.byteSize;

                for (0..values.len()) |index| {
                    const origin_string = try values.at(index).?.toUTF8(bun.default_allocator);
                    defer origin_string.deinit();
                    const slice = origin_string.slice();
                    if (slice.len > std.math.maxInt(u16)) {
                        return context.fail(.origin_too_long, {});
                    }
                    writer.writeInt(u16, @intCast(slice.len), .big) catch {
                        return context.fail(.origin_too_long, {});
                    };
                    writer.writeAll(slice) catch {
                        return context.fail(.origin_too_long, {});
                    };
                }

                const total_length: u32 = @intCast(writer.end);
                var frame: FrameHeader = .{
                    .type = @backingInt(FrameType.HTTP_FRAME_ORIGIN),
                    .flags = 0,
                    .streamIdentifier = 0,
                    .length = @intCast(total_length - FrameHeader.byteSize),
                };
                writer.end = 0;
                _ = frame.write(@TypeOf(writer), writer);
                _ = this.write(buffer[0..total_length]);
            },
        }
    }

    pub fn altsvc(this: *H2FrameParser, _: anytype, args: anytype) bun.JSError!void {
        const origin_slice = if (args.origin) |value| try value.toUTF8(bun.default_allocator) else null;
        defer if (origin_slice) |value| value.deinit();
        const alt_value = if (args.value) |value| try value.toUTF8(bun.default_allocator) else null;
        defer if (alt_value) |value| value.deinit();
        const stream_id = args.stream_id orelse 0;
        if (stream_id > 0) {
            // dont error but dont send frame to invalid stream id
            _ = this.streams.get(stream_id) orelse return;
        }
        this.sendAltSvc(
            stream_id,
            if (origin_slice) |value| value.slice() else "",
            if (alt_value) |value| value.slice() else "",
        );
    }

    pub fn getEndAfterHeaders(this: *H2FrameParser, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!bool {
        const stream = try this.requireStream(context, args.stream_id);
        return stream.endAfterHeaders;
    }

    pub fn isStreamAborted(this: *H2FrameParser, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!bool {
        const stream = try this.requireStream(context, args.stream_id);

        if (stream.signal) |signal_ref| {
            return signal_ref.isAborted();
        }
        // closed with cancel = aborted
        return stream.state == .CLOSED and stream.rstCode == @backingInt(ErrorCode.CANCEL);
    }

    pub fn getStreamState(this: *H2FrameParser, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!bindgen.Return(H2FrameParserSchema.member("getStreamState")) {
        const stream = try this.requireStream(context, args.stream_id);
        return .{
            .local_window_size = stream.windowSize,
            .state = @backingInt(stream.state),
            .local_close = if (stream.canSendData()) 0 else 1,
            .remote_close = if (stream.canReceiveData()) 0 else 1,
            .sum_dependency_weight = 0,
            .weight = stream.weight,
        };
    }

    pub fn setStreamPriority(this: *H2FrameParser, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!bool {
        const stream = try this.requireStream(context, args.stream_id);

        if (!stream.canSendData() and !stream.canReceiveData()) {
            return false;
        }

        var weight = stream.weight;
        var exclusive = stream.exclusive;
        var parent_id = stream.streamDependency;
        if (args.options.weight) |value| {
            if (value > 255) return context.fail(.invalid_weight, {});
            weight = @intCast(value);
        }
        if (args.options.parent) |value| {
            if (value == 0 or value > MAX_STREAM_ID) return context.fail(.invalid_stream, {});
            parent_id = value;
        }
        if (args.options.exclusive) |value| exclusive = value;
        if (parent_id == stream.id) {
            this.sendGoAway(stream.id, ErrorCode.PROTOCOL_ERROR, "Stream with self dependency", this.lastStreamID, true);
            return false;
        }

        stream.streamDependency = parent_id;
        stream.exclusive = exclusive;
        stream.weight = @intCast(weight);

        if (!(args.options.silent orelse false)) {
            var stream_identifier: UInt31WithReserved = .{
                .reserved = stream.exclusive,
                .uint31 = @truncate(stream.streamDependency),
            };

            var priority: StreamPriority = .{
                .streamIdentifier = stream_identifier.toUInt32(),
                .weight = @truncate(stream.weight),
            };
            var frame: FrameHeader = .{
                .type = @backingInt(FrameType.HTTP_FRAME_PRIORITY),
                .flags = 0,
                .streamIdentifier = @intCast(stream.id),
                .length = @intCast(StreamPriority.byteSize),
            };

            const writer = this.toWriter();
            _ = frame.write(@TypeOf(writer), writer);
            _ = priority.write(@TypeOf(writer), writer);
        }
        return true;
    }

    pub fn rstStream(this: *H2FrameParser, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!bool {
        log("rstStream", .{});
        const stream = try this.requireStream(context, args.stream_id);
        this.endStream(stream, @fromBackingInt(args.error_code));
        return true;
    }

    const MemoryWriter = struct {
        buffer: []u8,
        offset: usize = 0,
        pub fn slice(this: *MemoryWriter) []const u8 {
            return this.buffer[0..this.offset];
        }
        pub fn write(this: *MemoryWriter, data: []const u8) !usize {
            const pending = this.buffer[this.offset..];
            bun.debugAssert(pending.len >= data.len);
            @memcpy(pending[0..data.len], data);
            this.offset += data.len;
            return data.len;
        }
    };

    // get memory usage in MB
    fn getSessionMemoryUsage(this: *H2FrameParser) usize {
        return (this.writeBuffer.len + this.queuedDataSize + this.readBuffer.list.items.len + this.header_block.items.len) / 1024 / 1024;
    }

    // get memory in bytes
    pub fn getBufferSize(this: *H2FrameParser, _: anytype, _: anytype) bun.JSError!usize {
        return this.writeBuffer.len + this.queuedDataSize;
    }

    fn sendData(
        this: *H2FrameParser,
        stream: *Stream,
        payload: []const u8,
        close: bool,
        callback: ?bindgen.Callback(H2WriteCallbackType),
    ) void {
        log("HTTP_FRAME_DATA {s} sendData({}, {}, {})", .{ if (this.isServer) "server" else "client", stream.id, payload.len, close });

        const writer = this.toWriter();
        const stream_id = stream.id;
        var enqueued = false;
        var completion = callback;
        defer if (completion) |*owned| owned.deinit();
        this.ref();

        defer {
            if (!enqueued) {
                if (completion) |*owned| {
                    var invocation: @TypeOf(owned.*).Invocation = undefined;
                    owned.beginInvocation(&invocation);
                    defer invocation.deinit();
                    invocation.dispatch(.{});
                }
                if (close) {
                    if (stream.waitForTrailers) {
                        this.dispatchWantTrailers(stream.getIdentifier());
                    } else {
                        const identifier = stream.getIdentifier();
                        if (stream.state == .HALF_CLOSED_REMOTE) {
                            stream.state = .CLOSED;
                            stream.freeResources(this, false);
                        } else {
                            stream.state = .HALF_CLOSED_LOCAL;
                        }
                        this.dispatchStreamEnd(identifier, @backingInt(stream.state));
                    }
                }
            }
            this.deref();
        }
        const can_close = close and !stream.waitForTrailers;
        if (payload.len == 0) {
            // empty payload we still need to send a frame
            var dataHeader: FrameHeader = .{
                .type = @backingInt(FrameType.HTTP_FRAME_DATA),
                .flags = if (can_close) @backingInt(DataFrameFlags.END_STREAM) else 0,
                .streamIdentifier = @intCast(stream_id),
                .length = 0,
            };
            if (this.hasBackpressure() or this.outboundQueueSize > 0) {
                enqueued = true;
                stream.queueFrame(this, "", &completion, close);
            } else {
                _ = dataHeader.write(@TypeOf(writer), writer);
            }
        } else {
            var offset: usize = 0;

            while (offset < payload.len) {
                // max frame size will always be at least 16384 (but we need to respect the flow control)
                const available: usize = @intCast(@max(0, @min(this.connectionSendWindow, stream.sendWindow)));
                var max_size = @min(MAX_PAYLOAD_SIZE_WITHOUT_FRAME, available);
                var is_flow_control_limited = false;
                if (max_size == 0) {
                    is_flow_control_limited = true;
                    // this will be handled later if cannot send the entire payload in one frame
                    max_size = MAX_PAYLOAD_SIZE_WITHOUT_FRAME;
                }
                const size = @min(payload.len - offset, max_size);

                const slice = payload[offset..(size + offset)];
                offset += size;
                const end_stream = offset >= payload.len and can_close;

                if (this.hasBackpressure() or this.outboundQueueSize > 0 or is_flow_control_limited) {
                    enqueued = true;
                    // write the full frame in memory and queue the frame
                    // the callback will only be called after the last frame is sended
                    if (offset >= payload.len) {
                        stream.queueFrame(this, slice, &completion, close);
                    } else {
                        var no_completion: ?bindgen.Callback(H2WriteCallbackType) = null;
                        stream.queueFrame(this, slice, &no_completion, false);
                    }
                } else {
                    const padding = stream.getPadding(size, max_size - 1);
                    const payload_size = size + (if (padding != 0) @as(usize, @intCast(padding)) + 1 else 0);
                    log("padding: {d} size: {d} max_size: {d} payload_size: {d}", .{ padding, size, max_size, payload_size });
                    stream.sendWindow -= @intCast(payload_size);
                    this.connectionSendWindow -= @intCast(payload_size);
                    var flags: u8 = if (end_stream) @backingInt(DataFrameFlags.END_STREAM) else 0;
                    if (padding != 0) {
                        flags |= @backingInt(DataFrameFlags.PADDED);
                    }
                    var dataHeader: FrameHeader = .{
                        .type = @backingInt(FrameType.HTTP_FRAME_DATA),
                        .flags = flags,
                        .streamIdentifier = @intCast(stream_id),
                        .length = @truncate(payload_size),
                    };
                    _ = dataHeader.write(@TypeOf(writer), writer);
                    if (padding != 0) {
                        var buffer = shared_request_buffer[0..];
                        bun.memmove(buffer[1..][0..slice.len], slice);
                        buffer[0] = padding;
                        _ = writer.write(buffer[0..payload_size]) catch 0;
                    } else {
                        _ = writer.write(slice) catch 0;
                    }
                }
            }
        }
    }

    pub fn noTrailers(this: *H2FrameParser, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
        const stream = try this.requireStream(context, args.stream_id);

        stream.waitForTrailers = false;
        // sendData() drives the close itself: when the frame goes out
        // immediately the defer at its top advances state and dispatches
        // onStreamEnd; when it queues under backpressure, flushQueue() does
        // the same once the frame is actually written. Doing it again here
        // (the old code did) sets HALF_CLOSED_LOCAL/CLOSED before the queued
        // frame is flushed, so canSendData() rejects it / freeResources()
        // drops it and the peer never receives END_STREAM.
        this.sendData(stream, "", true, null);
    }

    fn isSensitiveHeader(sensitive: anytype, normalized_name: []const u8, original_name: []const u8) bool {
        for (0..sensitive.len()) |index| {
            const entry = sensitive.at(index).?;
            if (entry.key.eqlUTF8(normalized_name) or entry.key.eqlUTF8(original_name)) return entry.value;
        }
        return false;
    }

    fn invalidPseudoheader(context: anytype, name: []const u8) bun.bindgen.CallError(@TypeOf(context)) {
        const message = try bun.String.createFormat("\"{s}\" is an invalid pseudoheader or is used incorrectly", .{name});
        return context.fail(.invalid_pseudoheader, try bindgen.DOMString.fromBunString(message));
    }

    fn invalidHeaderName(context: anytype, name: []const u8, comptime quote: bool) bun.bindgen.CallError(@TypeOf(context)) {
        const message = try bun.String.createFormat(
            if (quote)
                "The arguments Header name is invalid. Received \"{s}\""
            else
                "The arguments Header name is invalid. Received {s}",
            .{name},
        );
        return context.fail(.invalid_header_name, try bindgen.DOMString.fromBunString(message));
    }

    fn singleValueHeader(context: anytype, name: []const u8) bun.bindgen.CallError(@TypeOf(context)) {
        const message = try bun.String.createFormat("Header field \"{s}\" must only have a single value", .{name});
        return context.fail(.single_value_header, try bindgen.DOMString.fromBunString(message));
    }

    fn headerValueCount(values: anytype) usize {
        return switch (values) {
            .values => |items| items.len(),
            .value => 1,
        };
    }

    fn headerValueAt(context: anytype, name: []const u8, values: anytype, index: usize) bindgen.CallError(@TypeOf(context))!bindgen.DOMStringView {
        const input = switch (values) {
            .values => |items| items.at(index).?,
            .value => |value| value,
        };
        const converted = try input.convert(context);
        if (converted.value) |value| return value;
        const message = try bun.String.createFormat("Invalid value for header \"{s}\"", .{name});
        return context.fail(.invalid_header_value, try bindgen.DOMString.fromBunString(message));
    }

    const PreparedHeader = struct {
        name: []const u8,
        value: []const u8,
        never_index: bool,
    };

    fn prepareHeaders(this: *H2FrameParser, context: anytype, headers: anytype, sensitive: anytype, comptime trailers: bool, allocator: std.mem.Allocator) bun.bindgen.CallError(@TypeOf(context))![]PreparedHeader {
        var result: std.ArrayList(PreparedHeader) = .empty;
        var name_buffer: [4096]u8 = undefined;
        var seen_single: [SingleValueHeaders.keys().len]bool = @splat(false);
        for (0..(if (trailers) @as(usize, 1) else 2)) |pass| {
            for (0..headers.len()) |index| {
                const header = headers.at(index).?;
                const name_slice = try header.key.toUTF8(bun.default_allocator);
                defer name_slice.deinit();
                const name = name_slice.slice();
                if (name.len == 0) continue;
                if (trailers and name[0] == ':') return invalidPseudoheader(context, name);
                if (name.len > name_buffer.len) return invalidHeaderName(context, name, !trailers);
                const normalized = H2Frame.normalizeHeaderName(name, name_buffer[0..name.len]) catch
                    return invalidHeaderName(context, name, !trailers);
                if (!trailers) {
                    if (name[0] == ':') {
                        if (pass == 1) continue;
                        if (!(if (this.isServer) ValidResponsePseudoHeaders.has(normalized) else ValidRequestPseudoHeaders.has(normalized)))
                            return invalidPseudoheader(context, name);
                    } else if (pass == 0) continue;
                }
                const stored_name = try allocator.dupe(u8, normalized);
                const never_index = isSensitiveHeader(sensitive, stored_name, name);
                const converted = try header.value.convert(context);
                const values = converted.value;
                if (SingleValueHeaders.getIndex(stored_name)) |single_index| {
                    if (headerValueCount(values) > 1 or seen_single[single_index])
                        return singleValueHeader(context, stored_name);
                    seen_single[single_index] = true;
                }
                for (0..headerValueCount(values)) |value_index| {
                    const value = try headerValueAt(context, if (values == .value) name else stored_name, values, value_index);
                    const bytes = try value.toOwnedSliceZ(allocator);
                    try result.append(allocator, .{ .name = stored_name, .value = bytes, .never_index = never_index });
                }
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn sendTrailers(this: *H2FrameParser, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
        _ = try this.requireStream(context, args.stream_id);
        var preparation = std.heap.ArenaAllocator.init(bun.default_allocator);
        defer preparation.deinit();
        const prepared_headers = try this.prepareHeaders(context, args.headers, args.sensitive_headers, true, preparation.allocator());
        const stream = try this.requireStream(context, args.stream_id);

        // Use shared buffer when possible, fall back to heap for large headers
        var buf_fallback: std.heap.BufferFirstAllocator = .init(&shared_request_buffer, bun.default_allocator);
        const alloc = buf_fallback.allocator();
        // Use ArrayList with initial capacity of shared buffer size, doubling when needed
        var encoded_headers = std.ArrayList(u8).empty;
        // IMPORTANT: defer cleanup immediately after init to prevent memory leaks on early returns
        defer encoded_headers.deinit(alloc);
        // Pre-allocate to the shared buffer size.
        encoded_headers.ensureTotalCapacity(alloc, shared_request_buffer.len) catch return error.OutOfMemory;
        var encoder_block = this.beginHeaderBlock(&encoded_headers, alloc) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            stream.state = .CLOSED;
            const identifier = stream.getIdentifier();
            stream.freeResources(this, false);
            stream.rstCode = @backingInt(ErrorCode.FRAME_SIZE_ERROR);
            this.dispatchFrameError(
                identifier,
                @backingInt(FrameType.HTTP_FRAME_HEADERS),
                @backingInt(ErrorCode.FRAME_SIZE_ERROR),
            );
            this.dispatchStreamError(identifier, stream.rstCode);
            return;
        };
        defer encoder_block.deinit();
        for (prepared_headers) |header| {
            _ = encoder_block.encodeIntoList(&encoded_headers, alloc, header.name, header.value, header.never_index) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                stream.state = .CLOSED;
                const identifier = stream.getIdentifier();
                stream.freeResources(this, false);
                stream.rstCode = @backingInt(ErrorCode.FRAME_SIZE_ERROR);
                this.dispatchFrameError(
                    identifier,
                    @backingInt(FrameType.HTTP_FRAME_HEADERS),
                    @backingInt(ErrorCode.FRAME_SIZE_ERROR),
                );
                this.dispatchStreamError(identifier, stream.rstCode);
                return;
            };
        }
        const encoded_data = encoded_headers.items;
        const encoded_size = encoded_data.len;

        // RFC 7540 Section 8.1: Trailers are sent as a HEADERS frame with END_STREAM flag
        const base_flags: u8 = @backingInt(HeadersFrameFlags.END_STREAM);
        // RFC 7540 Section 4.2: SETTINGS_MAX_FRAME_SIZE determines max frame payload
        const actual_max_frame_size = (this.remoteSettings orelse this.localSettings).maxFrameSize;

        log("trailers encoded_size {}", .{encoded_size});

        encoder_block.commit();
        const writer = this.toWriter();

        // RFC 7540 Section 6.2 & 6.10: Check if we need CONTINUATION frames
        if (encoded_size <= actual_max_frame_size) {
            // Single HEADERS frame - header block fits in one frame
            var frame: FrameHeader = .{
                .type = @backingInt(FrameType.HTTP_FRAME_HEADERS),
                .flags = base_flags | @backingInt(HeadersFrameFlags.END_HEADERS),
                .streamIdentifier = @intCast(stream.id),
                .length = @intCast(encoded_size),
            };
            _ = frame.write(@TypeOf(writer), writer);
            _ = writer.write(encoded_data) catch 0;
        } else {
            // RFC 7540 Section 6.2 & 6.10: Header block exceeds MAX_FRAME_SIZE.
            // Must split into HEADERS frame followed by one or more CONTINUATION frames.
            // Note: CONTINUATION frames cannot have padding (Section 6.10) - they carry
            // only header block fragments. END_HEADERS must be set on the last frame.
            log("Using CONTINUATION frames for trailers: encoded_size={d} max_frame_size={d}", .{ encoded_size, actual_max_frame_size });

            // RFC 7540 Section 6.2: First chunk goes in HEADERS frame (without END_HEADERS flag)
            // Trailers use END_STREAM but NOT END_HEADERS when more frames follow
            const first_chunk_size = actual_max_frame_size;

            var headers_frame: FrameHeader = .{
                .type = @backingInt(FrameType.HTTP_FRAME_HEADERS),
                .flags = base_flags, // END_STREAM but NOT END_HEADERS
                .streamIdentifier = @intCast(stream.id),
                .length = @intCast(first_chunk_size),
            };
            _ = headers_frame.write(@TypeOf(writer), writer);
            _ = writer.write(encoded_data[0..first_chunk_size]) catch 0;

            // RFC 7540 Section 6.10: CONTINUATION frames carry remaining header block fragments.
            // They have no padding, no priority - just frame header + header block fragment.
            var offset: usize = first_chunk_size;
            while (offset < encoded_size) {
                const remaining = encoded_size - offset;
                const chunk_size = @min(remaining, actual_max_frame_size);
                const is_last = (offset + chunk_size >= encoded_size);

                // RFC 7540 Section 6.10: END_HEADERS flag must be set on the last frame
                var cont_frame: FrameHeader = .{
                    .type = @backingInt(FrameType.HTTP_FRAME_CONTINUATION),
                    .flags = if (is_last) @backingInt(HeadersFrameFlags.END_HEADERS) else 0,
                    .streamIdentifier = @intCast(stream.id),
                    .length = @intCast(chunk_size),
                };
                _ = cont_frame.write(@TypeOf(writer), writer);
                _ = writer.write(encoded_data[offset..][0..chunk_size]) catch 0;

                offset += chunk_size;
            }
        }
        const identifier = stream.getIdentifier();
        if (stream.state == .HALF_CLOSED_REMOTE) {
            stream.state = .CLOSED;
            stream.freeResources(this, false);
        } else {
            stream.state = .HALF_CLOSED_LOCAL;
        }
        this.dispatchStreamEnd(identifier, @backingInt(stream.state));
    }

    pub fn writeStream(this: *H2FrameParser, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!bool {
        const stream = try this.requireStream(context, args.stream_id);
        var callback = if (args.callback) |value| try value.toOwned() else null;
        defer if (callback) |*owned| owned.deinit();
        if (!stream.canSendData()) {
            if (callback) |*owned| {
                var invocation: @TypeOf(owned.*).Invocation = undefined;
                owned.beginInvocation(&invocation);
                defer invocation.deinit();
                invocation.dispatch(.{});
            }
            return false;
        }

        const encoding = if (args.encoding) |value| bun.api.node.Encoding.fromBindgen(value) else .utf8;
        var buffer = try bun.api.node.StringOrBuffer.fromBindgen(args.data, encoding);
        defer buffer.deinit();

        this.sendData(stream, buffer.slice(), args.close orelse false, if (callback) |*owned| owned.take() else null);
        callback = null;
        return true;
    }

    fn getNextStreamID(this: *H2FrameParser) u32 {
        var stream_id: u32 = this.lastStreamID;
        if (this.isServer) {
            if (stream_id % 2 == 0) {
                stream_id += 2;
            } else {
                stream_id += 1;
            }
        } else {
            if (stream_id % 2 == 0) {
                stream_id += 1;
            } else if (stream_id == 0) {
                stream_id = 1;
            } else {
                stream_id += 2;
            }
        }
        return stream_id;
    }

    pub fn setNextStreamID(this: *H2FrameParser, _: anytype, args: anytype) bun.JSError!void {
        this.lastStreamID = args.stream_id;
        // to set the next stream id we need to decrement because we only keep the last stream id
        if (this.isServer) {
            if (this.lastStreamID % 2 == 0) {
                this.lastStreamID -|= 2;
            } else {
                this.lastStreamID -= 1;
            }
        } else {
            if (this.lastStreamID % 2 == 0) {
                this.lastStreamID -|= 1;
            } else if (this.lastStreamID == 1) {
                this.lastStreamID = 0;
            } else {
                this.lastStreamID -= 2;
            }
        }
    }

    pub fn hasNativeRead(this: *H2FrameParser, _: anytype, _: anytype) bun.JSError!bool {
        return this.native_socket == .tcp or this.native_socket == .tls;
    }

    pub fn getNextStream(this: *H2FrameParser, _: anytype, _: anytype) bun.JSError!i32 {
        const id = this.getNextStreamID();
        if (id > MAX_STREAM_ID) return -1;
        _ = this.handleReceivedStreamID(id) orelse return -1;
        return @intCast(id);
    }

    pub fn getStreamContext(
        this: *H2FrameParser,
        context: anytype,
        args: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!bindgen.Return(H2FrameParserSchema.member("getStreamContext")) {
        const stream = try this.requireStream(context, args.stream_id);
        return stream.jsContext.toResult(context) orelse
            bindgen.Return(H2FrameParserSchema.member("getStreamContext")).initUndefined(context);
    }

    pub fn setStreamContext(this: *H2FrameParser, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
        const stream = try this.requireStream(context, args.stream_id);
        try stream.setContext(args.context);
    }

    pub fn forEachStream(this: *H2FrameParser, context: anytype, args: anytype) bun.JSError!void {
        var it = StreamResumableIterator.init(this);
        while (it.next()) |stream| {
            const value = stream.jsContext.operand(context) orelse continue;
            try args.callback.call(.{
                .bindingThis = if (args.this_value) |receiver| receiver.operand(context) else null,
                .stream_context = value,
            });
        }
    }

    pub fn emitAbortToAllStreams(this: *H2FrameParser, _: anytype, _: anytype) bun.JSError!void {
        var it = StreamResumableIterator.init(this);
        while (it.next()) |stream| {

            // this is the oposite logic of emitErrorToallStreams, in this case we wanna to cancel this streams
            if (this.isServer) {
                if (stream.id % 2 == 0) continue;
            } else if (stream.id % 2 != 0) continue;
            if (stream.state != .CLOSED) {
                const old_state = stream.state;
                stream.state = .CLOSED;
                stream.rstCode = @backingInt(ErrorCode.CANCEL);
                const identifier = stream.getIdentifier();
                stream.freeResources(this, false);
                this.dispatchAborted(identifier, null, @backingInt(old_state));
            }
        }
    }

    pub fn emitErrorToAllStreams(this: *H2FrameParser, _: anytype, args: anytype) bun.JSError!void {
        var it = StreamResumableIterator.init(this);
        while (it.next()) |stream| {
            if (stream.state != .CLOSED) {
                stream.state = .CLOSED;
                stream.rstCode = args.code;
                const identifier = stream.getIdentifier();
                stream.freeResources(this, false);
                this.dispatchStreamError(identifier, args.code);
            }
        }
    }

    pub fn flushFromJS(this: *H2FrameParser, _: anytype, _: anytype) bun.JSError!usize {
        return this.flush();
    }

    fn requestHeaderEncodingFailure(this: *H2FrameParser, stream_id: u32, stream_context: anytype, err: anyerror) bun.JSError!i32 {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const stream = this.handleReceivedStreamID(stream_id) orelse return -1;
        if (stream_context) |value| try stream.setContext(value);
        stream.state = .CLOSED;
        stream.rstCode = @backingInt(ErrorCode.COMPRESSION_ERROR);
        this.dispatchStreamError(stream.getIdentifier(), stream.rstCode);
        return @intCast(stream_id);
    }

    pub fn request(this: *H2FrameParser, context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!i32 {
        log("request", .{});
        var preparation = std.heap.ArenaAllocator.init(bun.default_allocator);
        defer preparation.deinit();
        const prepared_headers = try this.prepareHeaders(context, args.headers, args.sensitive_headers, false, preparation.allocator());
        // Use shared buffer when possible, fall back to heap for large headers
        var buf_fallback: std.heap.BufferFirstAllocator = .init(&shared_request_buffer, bun.default_allocator);
        const alloc = buf_fallback.allocator();
        // Use ArrayList with initial capacity of shared buffer size, doubling when needed
        var encoded_headers = std.ArrayList(u8).empty;
        // IMPORTANT: defer cleanup immediately after init to prevent memory leaks on early returns
        defer encoded_headers.deinit(alloc);
        // Pre-allocate to the shared buffer size.
        encoded_headers.ensureTotalCapacity(alloc, shared_request_buffer.len) catch return error.OutOfMemory;
        const stream_id = args.stream_id orelse this.getNextStreamID();
        if (stream_id > MAX_STREAM_ID) return -1;
        var encoder_block = this.beginHeaderBlock(&encoded_headers, alloc) catch |err| {
            return this.requestHeaderEncodingFailure(stream_id, args.stream_context, err);
        };
        defer encoder_block.deinit();

        for (prepared_headers) |header| {
            _ = encoder_block.encodeIntoList(&encoded_headers, alloc, header.name, header.value, header.never_index) catch |err| {
                return this.requestHeaderEncodingFailure(stream_id, args.stream_context, err);
            };
        }
        const encoded_data = encoded_headers.items;
        const encoded_size = encoded_data.len;

        const stream = this.handleReceivedStreamID(stream_id) orelse return -1;
        if (args.stream_context) |value| try stream.setContext(value);
        var flags: u8 = @backingInt(HeadersFrameFlags.END_HEADERS);
        var exclusive: bool = false;
        var has_priority: bool = false;
        var weight: i32 = 0;
        var parent: i32 = 0;
        var waitForTrailers: bool = false;
        var end_stream: bool = false;
        if (args.options) |options| {
            if (options.padding_strategy == .number) {
                const padding_strategy = options.padding_strategy.number;
                stream.paddingStrategy = if (padding_strategy == 1) .aligned else if (padding_strategy == 2) .max else .none;
            }
            waitForTrailers = options.wait_for_trailers orelse false;
            stream.waitForTrailers = waitForTrailers;
            end_stream = options.end_stream orelse false;
            if (end_stream and (!waitForTrailers or this.isServer)) flags |= @backingInt(HeadersFrameFlags.END_STREAM);

            if (options.exclusive orelse false) {
                exclusive = true;
                stream.exclusive = true;
                has_priority = true;
            }

            if (options.parent) |value| {
                has_priority = true;
                if (value == 0 or value > MAX_STREAM_ID) {
                    stream.state = .CLOSED;
                    stream.rstCode = @backingInt(ErrorCode.INTERNAL_ERROR);
                    this.dispatchStreamError(stream.getIdentifier(), stream.rstCode);
                    return @intCast(stream_id);
                }
                parent = @intCast(value);
                stream.streamDependency = value;
            }

            if (options.weight) |value| {
                has_priority = true;
                if (value == 0 or value > std.math.maxInt(u8)) {
                    stream.state = .CLOSED;
                    stream.rstCode = @backingInt(ErrorCode.INTERNAL_ERROR);
                    this.dispatchStreamError(stream.getIdentifier(), stream.rstCode);
                    return @intCast(stream_id);
                }
                weight = @intCast(value);
                stream.weight = @intCast(value);
            }

            if (options.signal) |signal_view| {
                const signal = signal_view.get();
                if (signal.aborted()) {
                    stream.state = .IDLE;
                    var reason = try signal.abortReasonRoot(this.handlers.globalObject);
                    defer reason.deinit();
                    var abort_error = try jsc.WebCore.AbortSignal.wrapAbortErrorRoot(this.handlers.globalObject, &reason);
                    defer abort_error.deinit();
                    this.abortStreamRoot(stream, &abort_error);
                    return @intCast(stream_id);
                }
                try stream.attachSignal(this, signal);
            }
        }

        // too much memory being use
        if (this.getSessionMemoryUsage() > this.maxSessionMemory) {
            stream.state = .CLOSED;
            stream.rstCode = @backingInt(ErrorCode.ENHANCE_YOUR_CALM);
            this.rejectedStreams += 1;
            this.dispatchStreamError(stream.getIdentifier(), stream.rstCode);
            if (this.rejectedStreams >= this.maxRejectedStreams) {
                var chunk = try this.binaryPayload("ENHANCE_YOUR_CALM");
                defer releaseBinaryPayload(&chunk);
                this.dispatchError(context, &.{
                    .{ .code = @backingInt(ErrorCode.ENHANCE_YOUR_CALM) },
                    .{ .code = this.lastStreamID },
                    .{ .binary = chunk.operand() },
                });
            }
            return @intCast(stream_id);
        }
        var length: usize = encoded_size;
        if (has_priority) {
            length += 5;
            flags |= @backingInt(HeadersFrameFlags.PRIORITY);
        }

        log("request encoded_size {}", .{encoded_size});

        // Check if headers block exceeds maxSendHeaderBlockLength
        if (this.maxSendHeaderBlockLength != 0 and encoded_size > this.maxSendHeaderBlockLength) {
            stream.state = .CLOSED;
            stream.rstCode = @backingInt(ErrorCode.REFUSED_STREAM);

            this.dispatchFrameError(
                stream.getIdentifier(),
                @backingInt(FrameType.HTTP_FRAME_HEADERS),
                @backingInt(ErrorCode.FRAME_SIZE_ERROR),
            );

            this.dispatchStreamError(stream.getIdentifier(), stream.rstCode);
            return @intCast(stream_id);
        }

        // RFC 7540 Section 4.2: SETTINGS_MAX_FRAME_SIZE determines max frame payload (default 16384)
        const actual_max_frame_size = (this.remoteSettings orelse this.localSettings).maxFrameSize;

        // RFC 7540 Section 6.2: HEADERS frame can include optional PRIORITY (5 bytes)
        const priority_overhead: usize = if (has_priority) StreamPriority.byteSize else 0;

        // Compute available payload budget for HEADERS frame (before padding is applied)
        const available_payload = actual_max_frame_size - priority_overhead;

        // RFC 7540 Section 6.10: CONTINUATION frames carry ONLY header block fragments.
        // Unlike HEADERS frames, CONTINUATION frames CANNOT have padding or priority fields.
        // When we need CONTINUATION frames, disable padding to keep the logic simple.
        // Pass available_payload as maxLen so getPadding can apply padding when headers fit in one frame.
        const padding: u8 = if (encoded_size > available_payload) 0 else stream.getPadding(encoded_size, available_payload);
        const padding_overhead: usize = if (padding != 0) @as(usize, @intCast(padding)) + 1 else 0;

        // Max payload for HEADERS frame (accounting for priority and padding overhead)
        const headers_frame_max_payload = available_payload - padding_overhead;

        encoder_block.commit();
        const writer = this.toWriter();

        // Check if we need CONTINUATION frames
        if (encoded_size <= headers_frame_max_payload) {
            // Single HEADERS frame - fits in one frame
            const payload_size = encoded_size + priority_overhead + padding_overhead;
            log("padding: {d} size: {d} max_size: {d} payload_size: {d}", .{ padding, encoded_size, encoded_data.len, payload_size });

            if (padding != 0) {
                flags |= @backingInt(HeadersFrameFlags.PADDED);
            }

            var frame: FrameHeader = .{
                .type = @backingInt(FrameType.HTTP_FRAME_HEADERS),
                .flags = flags,
                .streamIdentifier = @intCast(stream.id),
                .length = @intCast(payload_size),
            };
            _ = frame.write(@TypeOf(writer), writer);

            // Write priority data if present
            if (has_priority) {
                var stream_identifier: UInt31WithReserved = .{
                    .reserved = exclusive,
                    .uint31 = @intCast(parent),
                };
                var priority_data: StreamPriority = .{
                    .streamIdentifier = stream_identifier.toUInt32(),
                    .weight = @intCast(weight),
                };
                _ = priority_data.write(@TypeOf(writer), writer);
            }

            // Handle padding
            if (padding != 0) {
                // Need extra capacity for padding length byte and padding bytes
                encoded_headers.ensureTotalCapacity(alloc, encoded_size + padding_overhead) catch return error.OutOfMemory;
                const buffer = encoded_headers.allocatedSlice();
                bun.memmove(buffer[1..][0..encoded_size], buffer[0..encoded_size]);
                buffer[0] = padding;
                _ = writer.write(buffer[0 .. encoded_size + padding_overhead]) catch 0;
            } else {
                _ = writer.write(encoded_data) catch 0;
            }
        } else {
            // RFC 7540 Section 6.2 & 6.10: Header blocks exceeding MAX_FRAME_SIZE must be split
            // into HEADERS frame followed by one or more CONTINUATION frames.
            // - HEADERS frame without END_HEADERS flag indicates more frames follow
            // - CONTINUATION frames carry remaining header block fragments
            // - Last frame (HEADERS or CONTINUATION) must have END_HEADERS flag set
            // - All frames must have the same stream identifier
            // - No other frames can be interleaved on this stream until END_HEADERS
            log("Using CONTINUATION frames: encoded_size={d} max_frame_payload={d}", .{ encoded_size, actual_max_frame_size });

            // RFC 7540 Section 6.2: First chunk goes in HEADERS frame (without END_HEADERS flag)
            // HEADERS frame can carry PRIORITY but CONTINUATION frames cannot.
            const first_chunk_size = actual_max_frame_size - priority_overhead;
            const headers_flags = flags & ~@as(u8, @backingInt(HeadersFrameFlags.END_HEADERS));

            var headers_frame: FrameHeader = .{
                .type = @backingInt(FrameType.HTTP_FRAME_HEADERS),
                .flags = headers_flags | (if (has_priority) @backingInt(HeadersFrameFlags.PRIORITY) else 0),
                .streamIdentifier = @intCast(stream.id),
                .length = @intCast(first_chunk_size + priority_overhead),
            };
            _ = headers_frame.write(@TypeOf(writer), writer);

            // Write priority data if present (only in HEADERS frame, not CONTINUATION)
            if (has_priority) {
                var stream_identifier: UInt31WithReserved = .{
                    .reserved = exclusive,
                    .uint31 = @intCast(parent),
                };
                var priority_data: StreamPriority = .{
                    .streamIdentifier = stream_identifier.toUInt32(),
                    .weight = @intCast(weight),
                };
                _ = priority_data.write(@TypeOf(writer), writer);
            }

            // Write first chunk of header block fragment
            _ = writer.write(encoded_data[0..first_chunk_size]) catch 0;

            // RFC 7540 Section 6.10: CONTINUATION frames carry remaining header block fragments.
            // CONTINUATION frame format: just frame header + header block fragment (no padding, no priority)
            var offset: usize = first_chunk_size;
            while (offset < encoded_size) {
                const remaining = encoded_size - offset;
                const chunk_size = @min(remaining, actual_max_frame_size);
                const is_last = (offset + chunk_size >= encoded_size);

                // RFC 7540 Section 6.10: END_HEADERS flag must be set on the last frame
                var cont_frame: FrameHeader = .{
                    .type = @backingInt(FrameType.HTTP_FRAME_CONTINUATION),
                    .flags = if (is_last) @backingInt(HeadersFrameFlags.END_HEADERS) else 0,
                    .streamIdentifier = @intCast(stream.id),
                    .length = @intCast(chunk_size),
                };
                _ = cont_frame.write(@TypeOf(writer), writer);
                _ = writer.write(encoded_data[offset..][0..chunk_size]) catch 0;

                offset += chunk_size;
            }
        }

        if (end_stream) {
            stream.endAfterHeaders = true;
            stream.state = .HALF_CLOSED_LOCAL;

            if (waitForTrailers) {
                this.dispatchWantTrailers(stream.getIdentifier());
                return @intCast(stream_id);
            }
        } else {
            stream.waitForTrailers = waitForTrailers;
        }

        return @intCast(stream_id);
    }

    pub fn read(this: *H2FrameParser, _: anytype, args: anytype) bun.JSError!void {
        defer this.incrementWindowSizeIfNeeded();
        var bytes = args.data.unsafePtr("the generated entry frame owns the input lease through parsing and re-entrant callbacks; readBytes copies any incomplete frame before read returns");
        while (bytes.len > 0) {
            const result = try this.readBytes(bytes);
            bytes = bytes[result..];
        }
    }

    pub fn onNativeRead(this: *H2FrameParser, data: []const u8) bun.JSError!void {
        log("onNativeRead", .{});
        this.ref();
        defer this.deref();
        defer this.incrementWindowSizeIfNeeded();
        var bytes = data;
        while (bytes.len > 0) {
            const result = try this.readBytes(bytes);
            bytes = bytes[result..];
        }
    }

    pub fn onNativeWritable(this: *H2FrameParser) void {
        _ = this.flush();
    }

    pub fn onNativeClose(this: *H2FrameParser) void {
        log("onNativeClose", .{});
        this.detachNativeSocket();
    }

    fn attachTLSSocket(this: *H2FrameParser, socket: *TLSSocket) void {
        log("TLSSocket attached", .{});
        defer _ = this.flush();
        if (socket.attachNativeCallback(.{ .h2 = this })) {
            this.native_socket = .{ .tls = socket };
        } else {
            socket.ref();
            this.native_socket = .{ .tls_writeonly = socket };
        }
        this.has_nonnative_backpressure = false;
    }

    fn attachTCPSocket(this: *H2FrameParser, socket: *TCPSocket) void {
        log("TCPSocket attached", .{});
        defer _ = this.flush();
        if (socket.attachNativeCallback(.{ .h2 = this })) {
            this.native_socket = .{ .tcp = socket };
        } else {
            socket.ref();
            this.native_socket = .{ .tcp_writeonly = socket };
        }
        this.has_nonnative_backpressure = false;
    }

    fn attachSocket(this: *H2FrameParser, socket: anytype) void {
        switch (socket) {
            .tls => |value| this.attachTLSSocket(value.get(TLSSocket.JSBinding).socket.get()),
            .tcp => |value| this.attachTCPSocket(value.get(TCPSocket.JSBinding).socket.get()),
        }
    }

    pub fn setNativeSocketFromJS(this: *H2FrameParser, _: anytype, args: anytype) bun.JSError!void {
        this.detachNativeSocket();
        this.attachSocket(args.socket);
    }

    pub fn detachNativeSocket(this: *H2FrameParser) void {
        const native_socket = this.native_socket;
        this.native_socket = .{ .none = {} };

        switch (native_socket) {
            inline .tcp, .tls => |socket| {
                socket.detachNativeCallback();
            },
            inline .tcp_writeonly, .tls_writeonly => |socket| {
                socket.deref();
            },
            .none => {},
        }
    }

    pub fn construct(context: anytype, args: anytype) bun.bindgen.CallError(@TypeOf(context))!*H2FrameParser {
        const globalObject = context.viewToken().globalObject();
        const options = args.options;
        const handlers = try Handlers.fromBindgen(globalObject, options.context, options.handlers);

        var this = brk: {
            if (ENABLE_ALLOCATOR_POOL) {
                if (H2FrameParser.pool == null) {
                    H2FrameParser.pool = bun.handleOom(bun.default_allocator.create(H2FrameParser.H2FrameParserHiveAllocator));
                    H2FrameParser.pool.?.* = H2FrameParser.H2FrameParserHiveAllocator.init(bun.default_allocator);
                }
                const self = bun.handleOom(H2FrameParser.pool.?.tryGet());

                self.* = H2FrameParser{
                    .ref_count = .init(),
                    .handlers = handlers,
                    .globalThis = globalObject,
                    .allocator = bun.default_allocator,
                    .readBuffer = .initEmpty(bun.default_allocator),
                    .streams = bun.U32HashMap(*Stream).init(bun.default_allocator),
                };
                break :brk self;
            } else {
                break :brk bun.new(H2FrameParser, .{
                    .ref_count = .init(),
                    .handlers = handlers,
                    .globalThis = globalObject,
                    .allocator = bun.default_allocator,
                    .readBuffer = .initEmpty(bun.default_allocator),
                    .streams = bun.U32HashMap(*Stream).init(bun.default_allocator),
                });
            }
        };
        errdefer this.deinit();

        if (options.native) |socket| this.attachSocket(socket);
        if (options.settings) |settings_options| {
            log("settings received in the constructor", .{});
            try this.applySettings(context, settings_options);
            if (settings_options.max_outstanding_pings) |value| this.maxOutstandingPings = value;
            if (settings_options.max_session_memory) |value| this.maxSessionMemory = @max(1, @as(u32, @truncate(value)));
            if (settings_options.max_header_list_pairs) |value| this.maxHeaderListPairs = @max(4, @as(u32, @truncate(value)));
            if (settings_options.max_session_rejected_streams) |value| this.maxRejectedStreams = @truncate(value);
            if (settings_options.max_outstanding_settings) |value| this.maxOutstandingSettings = @max(1, value);
            if (settings_options.max_send_header_block_length) |value| this.maxSendHeaderBlockLength = value;
            if (settings_options.padding_strategy) |value| {
                this.paddingStrategy = switch (value) {
                    1 => .aligned,
                    2 => .max,
                    else => .none,
                };
            }
        }
        const is_server = if (options.type) |value| value == 0 else false;

        this.isServer = is_server;
        this.hpack = Hpack.init(H2Frame.default_header_table_size, H2Frame.default_header_table_size);
        return this;
    }

    fn start(this: *H2FrameParser) bun.OOM!void {
        if (this.isServer) {
            _ = try this.setSettings(this.localSettings);
        } else {
            // consider that we need to queue until the first flush
            this.has_nonnative_backpressure = true;
            try this.sendPrefaceAndSettings();
        }
    }

    pub fn detachFromJS(this: *H2FrameParser, _: anytype, _: anytype) bun.JSError!void {
        var it = StreamResumableIterator.init(this);
        while (it.next()) |stream| {
            stream.freeResources(this, false);
        }
        this.detach();
        this.handlers.deinit();
        this.strong_this.downgrade();
    }

    /// be careful when calling detach be sure that the socket is closed and the parser not accesible anymore
    /// this function can be called multiple times, it will erase stream info
    pub fn detach(this: *H2FrameParser) void {
        this.uncork();
        this.unregisterAutoFlush();
        this.detachNativeSocket();

        this.readBuffer.deinit();
        this.header_block.clearAndFree(this.allocator);
        this.pending_headers = null;
        this.writeBuffer.clearAndFree(this.allocator);
        this.writeBufferOffset = 0;
        this.pendingSettings.clearAndFree(this.allocator);

        if (this.hpack) |*hpack| {
            hpack.deinit();
            this.hpack = null;
        }
    }

    fn deinit(this: *H2FrameParser) void {
        log("deinit", .{});

        defer {
            if (ENABLE_ALLOCATOR_POOL) {
                H2FrameParser.pool.?.put(this);
            } else {
                bun.destroy(this);
            }
        }
        this.detach();
        this.handlers.deinit();
        this.strong_this.deinit();
        var it = this.streams.valueIterator();
        while (it.next()) |item| {
            const stream = item.*;
            stream.freeResources(this, true);
            bun.destroy(stream);
        }
        var streams = this.streams;
        defer streams.deinit();
        this.streams = bun.U32HashMap(*Stream).init(bun.default_allocator);
    }

    pub fn finalize(this: *H2FrameParser) void {
        log("finalize", .{});
        this.strong_this.deinit();
        this.deref();
    }
};

const Hpack = @import("../../../http/Hpack.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

const bun = @import("bun");
const bindgen = bun.bindgen;
const MutableString = bun.MutableString;
const Output = bun.Output;
const strings = bun.strings;

const TCPSocket = bun.api.socket.TCPSocket;
const TLSSocket = bun.api.socket.TLSSocket;

const jsc = bun.jsc;
const AutoFlusher = jsc.WebCore.AutoFlusher;
const AutoFlusherEngine = jsc.WebCore.AutoFlusherEngine;
const BinaryType = dictionaryFieldType(H2HandlersSchema, "binary_type").Native;

const NodeHTTP2Bindings = bun.bindgen.Module("NodeHTTP2");
const AssertSettingsSchema = NodeHTTP2Bindings.function("assertSettings");
const AssertSettingsBinding = bun.bindgen.Fn(AssertSettingsSchema, jsAssertSettings);

const H2FrameParserBindings = bindgen.Module("H2FrameParser");
const H2FrameParserSchema = H2FrameParserBindings.class("H2FrameParser");
const H2FrameParserConstructorSchema = H2FrameParserSchema.constructor();
const H2ConstructorOptionsSchema = H2FrameParserConstructorSchema.args[0].ArgumentType;
const H2HandlersSchema = dictionaryFieldType(H2ConstructorOptionsSchema, "handlers");
const H2WriteStreamSchema = H2FrameParserSchema.member("writeStream");
const H2WriteCallbackType = H2WriteStreamSchema.args[4].ArgumentType;
const H2FrameParserClass = bindgen.Class(H2FrameParserSchema, H2FrameParser.JSBinding);

comptime {
    _ = AssertSettingsBinding;
    _ = H2FrameParserClass;
}
