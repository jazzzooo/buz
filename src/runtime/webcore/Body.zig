//! https://developer.mozilla.org/en-US/docs/Web/API/Body

const Body = @This();

pub const Consumption = enum {
    text,
    json,
    array_buffer,
    bytes,
    form_data,
    blob,
};

const RequestBindingModule = bun.bindgen.Module("Request");
const ResponseBindingModule = bun.bindgen.Module("Response");
const BodyBindingModule = bun.bindgen.Module("Body");

fn BodyCompletions(comptime member_name: []const u8) type {
    return bun.bindgen.MaterializedCompletionSet(.{
        RequestBindingModule.class("Request").memberKind(member_name, .method),
        ResponseBindingModule.class("Response").memberKind(member_name, .method),
    }, Blob.BlobReadPayload, Blob.BlobReadCompletionOps);
}

const BodyTextCompletions = BodyCompletions("text");
const BodyJSONCompletions = BodyCompletions("json");
const BodyArrayBufferCompletions = BodyCompletions("arrayBuffer");
const BodyBytesCompletions = BodyCompletions("bytes");
const BodyFormDataCompletions = BodyCompletions("formData");
const BodyBlobCompletionSchema = BodyBindingModule.function("blobCompletion");
const BodyBlobPromiseSchema = bun.bindgen.Module("readable_streams").engineShim("readableStreamConsumeBlob").ReturnType;
pub const BodyBlobPromiseResult = bun.bindgen.BrandedValueResult(BodyBlobPromiseSchema);
pub const BodyBlobPromise = bun.bindgen.StrongPromise(BodyBlobPromiseResult);
const BodyBlobCompletions = bun.bindgen.MaterializedCompletionSet(.{
    RequestBindingModule.class("Request").memberKind("blob", .method),
    ResponseBindingModule.class("Response").memberKind("blob", .method),
    BodyBlobCompletionSchema,
}, Blob.BlobReadPayload, Blob.BlobReadCompletionOps);

pub fn isConsumptionCompletion(comptime FunctionSchema: type) bool {
    if (FunctionSchema == BodyBlobCompletionSchema) return true;
    inline for (.{ RequestBindingModule.class("Request"), ResponseBindingModule.class("Response") }) |Class| {
        inline for (.{ "text", "json", "arrayBuffer", "bytes", "formData", "blob" }) |name| {
            if (FunctionSchema == Class.memberKind(name, .method)) return true;
        }
    }
    return false;
}

value: Value, // = Value.empty,

pub fn len(this: *Body) Blob.SizeType {
    return this.value.size();
}

pub fn slice(this: *const Body) []const u8 {
    return this.value.slice();
}

pub fn use(this: *Body) bun.OOM!Blob {
    return this.value.use();
}

pub fn clone(this: *Body, globalThis: *JSGlobalObject) bun.JSError!Body {
    return Body{
        .value = try this.value.clone(globalThis),
    };
}

pub fn cloneWithReadableStream(this: *Body, globalThis: *JSGlobalObject, readable: ?*const jsc.WebCore.ReadableStream.Strong) bun.JSError!Body {
    return Body{
        .value = try this.value.cloneWithReadableStream(globalThis, readable),
    };
}

pub fn deinit(this: *Body, _: std.mem.Allocator) void {
    this.value.deinit();
}

pub const PendingValue = struct {
    pub const Source = struct {
        on_start_buffering: ?*const fn (*Source) void,
        on_start_streaming: ?*const fn (*Source) jsc.WebCore.DrainResult,
        on_readable_stream_available: ?*const fn (*Source, *jsc.JSGlobalObject, *const jsc.WebCore.ReadableStream.Strong) void,
        on_stream_cancelled: ?*const fn (*Source) void,
        retain_owner: *const fn (*Source) void,
        release_owner: *const fn (*Source) void,
        attached: bool = false,

        fn Options(comptime Owner: type) type {
            return struct {
                on_start_buffering: ?*const fn (*Owner) void = null,
                on_start_streaming: ?*const fn (*Owner) jsc.WebCore.DrainResult = null,
                on_readable_stream_available: ?*const fn (*Owner, *jsc.JSGlobalObject, *const jsc.WebCore.ReadableStream.Strong) void = null,
                on_stream_cancelled: ?*const fn (*Owner) void = null,
                retain_owner: *const fn (*Owner) void,
                release_owner: *const fn (*Owner) void,
            };
        }

        pub fn init(
            comptime Owner: type,
            comptime field_name: []const u8,
            comptime callbacks: Options(Owner),
        ) Source {
            const Adapter = struct {
                fn owner(source: *Source) *Owner {
                    return @fieldParentPtr(field_name, source);
                }

                fn onStartBuffering(source: *Source) void {
                    callbacks.on_start_buffering.?(owner(source));
                }

                fn onStartStreaming(source: *Source) jsc.WebCore.DrainResult {
                    return callbacks.on_start_streaming.?(owner(source));
                }

                fn onReadableStreamAvailable(
                    source: *Source,
                    global: *jsc.JSGlobalObject,
                    readable: *const jsc.WebCore.ReadableStream.Strong,
                ) void {
                    callbacks.on_readable_stream_available.?(owner(source), global, readable);
                }

                fn onStreamCancelled(source: *Source) void {
                    callbacks.on_stream_cancelled.?(owner(source));
                }

                fn retainOwner(source: *Source) void {
                    callbacks.retain_owner(owner(source));
                }

                fn releaseOwner(source: *Source) void {
                    callbacks.release_owner(owner(source));
                }
            };

            return .{
                .on_start_buffering = if (callbacks.on_start_buffering != null) Adapter.onStartBuffering else null,
                .on_start_streaming = if (callbacks.on_start_streaming != null) Adapter.onStartStreaming else null,
                .on_readable_stream_available = if (callbacks.on_readable_stream_available != null) Adapter.onReadableStreamAvailable else null,
                .on_stream_cancelled = if (callbacks.on_stream_cancelled != null) Adapter.onStreamCancelled else null,
                .retain_owner = Adapter.retainOwner,
                .release_owner = Adapter.releaseOwner,
            };
        }

        fn attach(source: *Source) void {
            if (source.attached) @panic("body source is already attached");
            source.attached = true;
            source.retain_owner(source);
        }

        fn detach(source: *Source) void {
            if (!source.attached) @panic("body source was already detached");
            source.attached = false;
        }

        fn drop(source: *Source) void {
            source.detach();
            source.release_owner(source);
        }

        fn cancelFromStream(context: bun.bindgen.NativeCallbackContext(.vm)) void {
            const source = context.get(*Source);
            source.retain_owner(source);
            defer source.release_owner(source);
            source.on_stream_cancelled.?(source);
        }
    };

    pub const Receiver = struct {
        on_receive: *const fn (*Receiver, *Value) void,
        on_drop: ?*const fn (*Receiver) void,
        pending: ?*PendingValue = null,

        fn Options(comptime Owner: type) type {
            return struct {
                on_receive: *const fn (*Owner, *Value) void,
                on_drop: ?*const fn (*Owner) void = null,
            };
        }

        pub fn init(
            comptime Owner: type,
            comptime field_name: []const u8,
            comptime callbacks: Options(Owner),
        ) Receiver {
            const Adapter = struct {
                fn owner(receiver: *Receiver) *Owner {
                    return @fieldParentPtr(field_name, receiver);
                }

                fn onReceive(receiver: *Receiver, value: *Value) void {
                    callbacks.on_receive(owner(receiver), value);
                }

                fn onDrop(receiver: *Receiver) void {
                    callbacks.on_drop.?(owner(receiver));
                }
            };

            return .{
                .on_receive = Adapter.onReceive,
                .on_drop = if (callbacks.on_drop != null) Adapter.onDrop else null,
            };
        }

        pub fn detach(receiver: *Receiver) void {
            const pending = receiver.pending orelse return;
            receiver.pending = null;
            if (pending.receiver) |handle| {
                if (handle.get() != receiver) @panic("body receiver attachment is inconsistent");
                pending.receiver = null;
            }
        }

        pub fn drop(receiver: *Receiver) void {
            if (receiver.pending == null) return;
            receiver.detach();
            if (receiver.on_drop) |callback| callback(receiver);
        }
    };

    readable: jsc.WebCore.ReadableStream.Strong = .{},
    // Production retains its owner independently of the single consuming receiver or completion.
    source: ?bindgen.BorrowedNative(Source, .vm) = null,
    receiver: ?bindgen.BorrowedNative(Receiver, .vm) = null,

    global: bindgen.BorrowedNative(JSGlobalObject, .vm),

    size_hint: Blob.SizeType = 0,
    started_buffering: bool = false,
    started_streaming: bool = false,

    is_deinitialized: bool = false,
    action: Action = Action{ .none = {} },

    pub fn hasStartedConsumption(this: *const PendingValue) bool {
        return this.action != .none;
    }

    /// For Http Client requests
    /// when Content-Length is provided this represents the whole size of the request
    /// If chunked encoded this will represent the total received size (ignoring the chunk headers)
    /// If the size is unknown will be 0
    fn sizeHint(this: *const PendingValue) Blob.SizeType {
        return this.readable.sizeHint() orelse this.size_hint;
    }

    fn startBuffering(this: *PendingValue) void {
        if (this.started_buffering) return;
        this.started_buffering = true;
        const source = if (this.source) |handle| handle.get() else return;
        if (source.on_start_buffering) |callback| {
            source.retain_owner(source);
            defer source.release_owner(source);
            callback(source);
        }
    }

    fn startStreaming(this: *PendingValue) jsc.WebCore.DrainResult {
        if (this.started_streaming) return .{ .estimated_size = 0 };
        this.started_streaming = true;
        const source = if (this.source) |handle| handle.get() else return .{ .estimated_size = 0 };
        const callback = source.on_start_streaming orelse return .{ .estimated_size = 0 };
        source.retain_owner(source);
        defer source.release_owner(source);
        const result = callback(source);
        if (!source.attached) @panic("body source detached while starting its stream");
        return result;
    }

    fn setStreamCancellation(this: *PendingValue, reader: anytype) void {
        const source = if (this.source) |handle| handle.get() else return;
        if (source.on_stream_cancelled != null) {
            reader.cancel_handler = Source.cancelFromStream;
            reader.cancel_ctx = .init(source);
        }
    }

    fn clearStreamCancellation(this: *PendingValue, readable: *const jsc.WebCore.ReadableStream.Strong) void {
        const source = if (this.source) |handle| handle.get() else return;
        const reader = (readable.byteStream() orelse return).parent();
        if (reader.cancel_ctx != null and reader.cancel_ctx.?.eql(.init(source))) {
            reader.cancel_handler = null;
            reader.cancel_ctx = null;
        }
    }

    fn notifyReadableStreamAvailable(this: *PendingValue, global: *jsc.JSGlobalObject) void {
        const source = if (this.source) |handle| handle.get() else return;
        if (source.on_readable_stream_available) |callback| {
            source.retain_owner(source);
            defer source.release_owner(source);
            callback(source, global, &this.readable);
            if (!source.attached) @panic("body source detached while receiving its readable stream");
        }
    }

    pub fn setReceiver(this: *PendingValue, receiver: *Receiver) void {
        if (this.action != .none or this.receiver != null or receiver.pending != null) {
            @panic("body receiver is already attached");
        }
        this.action = .{ .consumed = {} };
        receiver.pending = this;
        this.receiver = bindgen.BorrowedNative(Receiver, .vm).init(receiver);
        this.startBuffering();
    }

    pub fn setSource(this: *PendingValue, source: *Source) void {
        if (this.source != null or this.receiver != null) {
            @panic("body source cannot replace an existing source or receiver");
        }
        source.attach();
        this.source = bindgen.BorrowedNative(Source, .vm).init(source);
    }

    pub fn hasReceiver(this: *const PendingValue) bool {
        return this.receiver != null;
    }

    fn deliverToReceiver(this: *PendingValue, value: *Value) bool {
        const receiver = if (this.receiver) |handle| handle.get() else return false;
        const callback = receiver.on_receive;
        this.receiver = null;
        receiver.pending = null;
        callback(receiver, value);
        return true;
    }

    fn takeSource(this: *PendingValue) ?*Source {
        const source = if (this.source) |handle| handle.get() else return null;
        this.source = null;
        return source;
    }

    fn dropSource(this: *PendingValue) void {
        const source = this.takeSource() orelse return;
        source.drop();
    }

    pub fn isDisturbed(
        this: *const PendingValue,
        globalObject: *jsc.JSGlobalObject,
        comptime T: type,
        context: anytype,
        receiver: anytype,
    ) bun.JSError!bool {
        if (this.action != .none) return true;

        if (try T.BodySlot.view(receiver)) |body_value| {
            return context.engineIn("readable_streams", "readableStreamIsDisturbed").call(.{
                .stream = body_value.operand(context),
            });
        }

        return this.readable.isDisturbed(globalObject);
    }

    pub fn isDisturbed2(this: *const PendingValue, globalObject: *jsc.JSGlobalObject) bool {
        if (this.action != .none) return true;

        return this.readable.isDisturbed(globalObject);
    }

    fn adoptReadableStreamPromise(
        completion: anytype,
        stream: *const jsc.WebCore.ReadableStream.Strong,
        comptime operation_name: []const u8,
        content_type: ?*const bun.bindgen.DOMString,
    ) bun.JSError!void {
        var promise = try stream.consumePromise(operation_name, content_type);
        defer promise.deinit();
        completion.adoptPromise(&promise);
    }

    pub fn setCompletion(
        value: *PendingValue,
        comptime action_tag: std.meta.Tag(Action),
        action_payload: @FieldType(Action, @tagName(action_tag)),
        owned_readable: ?*const jsc.WebCore.ReadableStream.Strong,
    ) bun.JSError!void {
        var action = @unionInit(Action, @tagName(action_tag), action_payload);
        var action_live = true;
        defer if (action_live) action.deinit();
        const readable = owned_readable orelse if (value.readable.has()) &value.readable else null;
        if (readable) |stream| {
            value.action = .{ .consumed = {} };
            switch (comptime action_tag) {
                .getText => try adoptReadableStreamPromise(&action.getText, stream, "readableStreamConsumeText", null),
                .getJSON => try adoptReadableStreamPromise(&action.getJSON, stream, "readableStreamConsumeJSON", null),
                .getArrayBuffer => try adoptReadableStreamPromise(&action.getArrayBuffer, stream, "readableStreamConsumeArrayBuffer", null),
                .getBytes => try adoptReadableStreamPromise(&action.getBytes, stream, "readableStreamConsumeBytes", null),
                .getBlob => try adoptReadableStreamPromise(&action.getBlob, stream, "readableStreamConsumeBlob", null),
                .getFormData => {
                    var boundary: ?bun.bindgen.DOMString = switch (action.getFormData.encoding.view()) {
                        .Multipart => |multipart| try bun.bindgen.DOMString.fromUTF8(multipart),
                        .URLEncoded => null,
                    };
                    defer if (boundary) |*boundary_string| boundary_string.deinit();
                    try adoptReadableStreamPromise(
                        &action.getFormData.completion,
                        stream,
                        "readableStreamConsumeFormData",
                        if (boundary) |*boundary_string| boundary_string else null,
                    );
                    action.getFormData.encoding.deinit();
                },
                .none, .consumed => unreachable,
            }
            action_live = false;
            value.readable.deinit();
            return;
        }

        if (value.action != .none) @panic("body already has a pending consumption completion");
        value.action = action;
        action_live = false;
        value.startBuffering();
    }

    fn deinitStorage(this: *PendingValue) void {
        if (this.is_deinitialized) return;
        this.is_deinitialized = true;
        var readable = this.detachReadable();
        var action = this.action;
        this.action = .{ .consumed = {} };
        const receiver = if (this.receiver) |handle| handle.get() else null;
        this.receiver = null;
        if (receiver) |attached| attached.pending = null;
        const source = this.takeSource();
        if (source) |attached| attached.detach();

        readable.deinit();
        action.deinit();
        if (receiver) |attached| if (attached.on_drop) |callback| callback(attached);
        if (source) |attached| attached.release_owner(attached);
    }

    pub fn detachReadable(this: *PendingValue) jsc.WebCore.ReadableStream.Strong {
        this.clearStreamCancellation(&this.readable);
        return this.readable.take();
    }

    pub const Action = union(enum) {
        none: void,
        consumed: void,
        getText: BodyTextCompletions.Owned,
        getJSON: BodyJSONCompletions.Owned,
        getArrayBuffer: BodyArrayBufferCompletions.Owned,
        getBytes: BodyBytesCompletions.Owned,
        getBlob: BodyBlobCompletions.Owned,
        getFormData: struct {
            completion: BodyFormDataCompletions.Owned,
            encoding: bun.FormData.OwnedEncoding,
        },

        fn deinit(this: *Action) void {
            switch (this.*) {
                .getText => |*completion| completion.release(),
                .getJSON => |*completion| completion.release(),
                .getArrayBuffer => |*completion| completion.release(),
                .getBytes => |*completion| completion.release(),
                .getBlob => |*completion| completion.release(),
                .getFormData => |*pending| {
                    pending.completion.release();
                    pending.encoding.deinit();
                },
                .none, .consumed => {},
            }
            this.* = .{ .none = {} };
        }
    };
};

/// This is a duplex stream!
pub const Value = union(Tag) {
    const log = Output.scoped(.BodyValue, .visible);

    const pool_size = if (bun.heap_breakdown.enabled) 0 else 256;
    pub const HiveRef = bun.HiveRef(jsc.WebCore.Body.Value, pool_size);
    pub const HiveAllocator = bun.HiveArray(HiveRef, pool_size).Fallback;

    Blob: Blob,

    /// This is the String type from WebKit
    /// It is reference counted, so we must always deref it (which this does automatically)
    /// Be careful where it can directly be used.
    ///
    /// If it is a latin1 string with only ascii, we can use it directly.
    /// Otherwise, we must convert it to utf8.
    ///
    /// Unless we are sending it directly to JavaScript, for example:
    ///
    ///   var str = "hello world 🤭"
    ///   var response = new Response(str);
    ///   /* Body.Value stays WTFStringImpl */
    ///   var body = await response.text();
    ///
    /// In this case, even though there's an emoji, we can use the StringImpl directly.
    /// BUT, if we were instead using it in the HTTP server, this cannot be used directly.
    ///
    /// When the server calls .toBlobIfPossible(), we will automatically
    /// convert this Value to an InternalBlob
    ///
    /// Example code:
    ///
    ///     Bun.serve({
    ///         fetch(req) {
    ///              /* Body.Value becomes InternalBlob */
    ///              return new Response("hello world 🤭");
    ///         }
    ///     })
    ///
    /// This works for .json(), too.
    WTFStringImpl: Blob.WTFStringImplRef,
    /// Single-use Blob
    /// Avoids a heap allocation.
    InternalBlob: InternalBlob,
    /// Single-use Blob that stores the bytes in the Value itself.
    // InlineBlob: InlineBlob,
    Locked: PendingValue,
    Used,
    Empty,
    Error: ValueError,
    Null,

    // We may not have all the data yet
    // So we can't know for sure if it's empty or not
    // We CAN know that it is definitely empty.
    pub fn isDefinitelyEmpty(this: *const Value) bool {
        return switch (this.*) {
            .Null => true,
            .Used, .Empty => true,
            .InternalBlob => this.InternalBlob.sliceConst().len == 0,
            .Blob => this.Blob.size == 0,
            .WTFStringImpl => this.WTFStringImpl.get().length() == 0,
            .Error, .Locked => false,
        };
    }

    pub fn wasString(this: *const Value) bool {
        return switch (this.*) {
            .InternalBlob => |*blob| blob.was_string,
            .WTFStringImpl => true,
            else => false,
        };
    }

    pub const ValueError = @import("./BodyErrorEngine.zig").ValueError;

    pub fn markUsed(this: *Value) void {
        var previous = this.*;
        this.* = .{ .Used = {} };
        previous.deinit();
    }

    fn finishLockedReplacement(this: *Value, replacement: Value) void {
        var previous = this.*;
        this.* = replacement;
        previous.Locked.deinitStorage();
    }

    fn replaceLockedWithAnyBlob(this: *Value) bun.OOM!bool {
        const locked = &this.Locked;
        if (locked.action != .none) return false;
        if (locked.hasReceiver()) @panic("cannot consume a body while another native receiver is attached");
        const blob = (try locked.readable.toAnyBlob(locked.global.get())) orelse return false;
        this.finishLockedReplacement(switch (blob) {
            .Blob => .{ .Blob = blob.Blob },
            .InternalBlob => .{ .InternalBlob = blob.InternalBlob },
            .WTFStringImpl => .{ .WTFStringImpl = blob.WTFStringImpl },
        });
        return true;
    }

    fn takeLockedAnyBlobAllowPromise(this: *Value) bun.OOM!?AnyBlob {
        const locked = &this.Locked;
        if (locked.hasReceiver()) @panic("cannot consume a body while another native receiver is attached");
        const blob = (try locked.readable.toAnyBlob(locked.global.get())) orelse return null;
        this.finishLockedReplacement(.{ .Used = {} });
        return blob;
    }

    pub fn toBlobIfPossible(this: *Value) bun.OOM!void {
        if (this.* == .WTFStringImpl) {
            if (try this.WTFStringImpl.get().toUTF8IfNeeded(bun.default_allocator)) |bytes| {
                var str = this.WTFStringImpl;
                defer str.deinit();
                this.* = .{
                    .InternalBlob = InternalBlob{
                        .bytes = .fromOwnedSlice(bun.default_allocator, @constCast(bytes.slice())),
                        .was_string = true,
                    },
                };
            }
        }

        if (this.* != .Locked)
            return;

        _ = try this.replaceLockedWithAnyBlob();
    }

    pub fn size(this: *Value) Blob.SizeType {
        return switch (this.*) {
            .Blob => this.Blob.sizeIfKnown() orelse Blob.max_size,
            .InternalBlob => @as(Blob.SizeType, @truncate(this.InternalBlob.sliceConst().len)),
            .WTFStringImpl => @as(Blob.SizeType, @truncate(this.WTFStringImpl.get().utf8ByteLength())),
            .Locked => this.Locked.sizeHint(),
            // .InlineBlob => @truncate(Blob.SizeType, this.InlineBlob.sliceConst().len),
            else => 0,
        };
    }

    pub fn fastSize(this: *const Value) Blob.SizeType {
        return switch (this.*) {
            .InternalBlob => @as(Blob.SizeType, @truncate(this.InternalBlob.sliceConst().len)),
            .WTFStringImpl => @as(Blob.SizeType, @truncate(this.WTFStringImpl.get().byteSlice().len)),
            .Locked => this.Locked.sizeHint(),
            // .InlineBlob => @truncate(Blob.SizeType, this.InlineBlob.sliceConst().len),
            else => 0,
        };
    }

    pub fn memoryCost(this: *const Value) usize {
        return switch (this.*) {
            .InternalBlob => this.InternalBlob.bytes.length(),
            .WTFStringImpl => this.WTFStringImpl.get().memoryCost(),
            .Locked => this.Locked.sizeHint(),
            // .InlineBlob => this.InlineBlob.sliceConst().len,
            else => 0,
        };
    }

    pub fn estimatedSize(this: *const Value) usize {
        return switch (this.*) {
            .InternalBlob => this.InternalBlob.sliceConst().len,
            .WTFStringImpl => this.WTFStringImpl.get().byteSlice().len,
            .Locked => this.Locked.sizeHint(),
            // .InlineBlob => this.InlineBlob.sliceConst().len,
            else => 0,
        };
    }

    pub const Tag = enum {
        Blob,
        WTFStringImpl,
        InternalBlob,
        // InlineBlob,
        Locked,
        Used,
        Empty,
        Error,
        Null,
    };

    // pub const empty = Value{ .Empty = {} };

    pub fn toReadableStream(this: *Value, globalThis: *JSGlobalObject) bun.JSError!?jsc.WebCore.ReadableStream.Owned {
        switch (this.*) {
            .Used => {
                return try jsc.WebCore.ReadableStream.usedOwned(globalThis);
            },
            .Empty => {
                return try jsc.WebCore.ReadableStream.emptyOwned(globalThis);
            },
            .Null => {
                return null;
            },
            .InternalBlob, .Blob, .WTFStringImpl => {
                var blob = try this.use();
                defer blob.deinit();
                errdefer this.* = .{ .Blob = blob.take() };
                blob.resolveSize();
                const stream = try jsc.WebCore.ReadableStream.fromBlobCopyRefOwned(globalThis, &blob, blob.size);
                this.* = .{
                    .Locked = .{
                        .readable = try jsc.WebCore.ReadableStream.Strong.initOwned(stream),
                        .global = .init(globalThis),
                    },
                };
                return this.Locked.readable.cloneOwned().?;
            },
            .Locked => {
                var locked = &this.Locked;
                if (locked.readable.cloneOwned()) |readable| return readable;
                if (locked.action != .none) {
                    return try jsc.WebCore.ReadableStream.usedOwned(globalThis);
                }
                var readable = try this.startNativeReadableStream(globalThis);
                defer readable.deinit();
                return readable.cloneOwned().?;
            },
            .Error => {
                return try jsc.WebCore.ReadableStream.emptyOwned(globalThis);
            },
        }
    }

    fn startNativeReadableStream(this: *Value, global: *JSGlobalObject) bun.JSError!jsc.WebCore.ReadableStream.Strong {
        const locked = &this.Locked;
        bun.assert(!locked.readable.has() and locked.action == .none);
        const reader = try jsc.WebCore.ByteStream.Source.create(global, .{});
        defer reader.deref();
        const readable = try jsc.WebCore.ReadableStream.Strong.initOwned(try reader.toReadableStreamOwned(global));

        // Native stream startup is deferred, so allocation can finish before the producer relinquishes its bytes.
        switch (locked.startStreaming()) {
            .empty, .aborted => {
                reader.context.has_received_last_chunk = true;
                this.finishLockedReplacement(.{ .Null = {} });
                return readable;
            },
            .estimated_size => |size_hint| {
                reader.context.highWaterMark = @truncate(size_hint);
                reader.context.size_hint = @truncate(size_hint);
            },
            .owned => |drained| {
                reader.context.buffer = drained.list;
                reader.context.size_hint = @truncate(drained.size_hint);
            },
        }
        locked.setStreamCancellation(reader);
        locked.readable = readable.clone();
        locked.notifyReadableStreamAvailable(global);
        return readable;
    }

    /// Builds a body from a generated `bodyInitInput` union.
    pub fn fromGeneratedBodyInit(globalThis: *JSGlobalObject, context: anytype, generated: anytype) bun.JSError!Value {
        switch (generated.*) {
            .nulled => return .{ .Null = {} },
            .flag => |flag| {
                // Booleans become a plain blob with no content type, not a
                // string body.
                const text: []const u8 = if (flag) "true" else "false";
                return .{
                    .InternalBlob = .{
                        .bytes = .fromOwnedSlice(bun.default_allocator, try bun.default_allocator.dupe(u8, text)),
                        .was_string = false,
                    },
                };
            },
            .text => |*view| {
                if (view.length() == 0) {
                    return .{ .Empty = {} };
                }
                var owned = view.toOwned();
                const str = owned.takeBunString();
                assert(str.tag == .WTFStringImpl);
                return .{ .WTFStringImpl = .adopt(str.value.WTFStringImpl) };
            },
            .bytes => |*view| {
                const bytes = view.unsafePtr("the generated entry frame owns the converted byte lease until the body copies its contents");
                if (bytes.len == 0) {
                    return .{ .Empty = {} };
                }
                return .{
                    .InternalBlob = .{
                        .bytes = .fromOwnedSlice(bun.default_allocator, try bun.default_allocator.dupe(u8, bytes)),
                        .was_string = false,
                    },
                };
            },
            .form_data => |*view| {
                return .{ .Blob = try Blob.fromDOMFormData(globalThis, bun.default_allocator, view.get()) };
            },
            .url_search_params => |*view| {
                return .{ .Blob = try Blob.fromURLSearchParams(bun.default_allocator, view.get()) };
            },
            .blob => |*view| {
                // We must preserve "type" so that DOMFormData and the "type" field are preserved.
                return .{ .Blob = try view.get().dupe() };
            },
            .image => |*handle| {
                // Body init is synchronous, so encode now and wrap as a Blob
                // with the right MIME type. The off-thread path is still
                // available via `await image.blob()`.
                const image = handle.get(bun.api.Image.JSBinding).image.get();
                var snapshot: ?bun.bindgen.OwnedBytes = if (image.source == .buffer)
                    try context.engineIn("Image", "copyInput").call(.{ .image = handle.operand(context) })
                else
                    null;
                defer if (snapshot) |*bytes| bytes.deinit();
                const out = switch (try image.encodeForBody(if (snapshot) |*bytes| bytes.slice() else null)) {
                    .encoded => |out| out,
                    .unsupported_source => return globalThis.throw(
                        "Image: fd/S3-backed Bun.file as a Response body — pass `await file.bytes()` or a path string",
                        .{},
                    ),
                    .pipeline_error => |message| return globalThis.throw("{s}", .{message}),
                    .io_error => |err| return bun.api.SystemErrorBindings.throwSysError(err, globalThis),
                };
                // Blob.Store frees via an Allocator, so dupe out of the
                // codec's allocator here. The hot path (`.bytes()`) hands the
                // codec buffer to JS without this copy.
                defer out.bytes.deinit();
                const owned = try bun.default_allocator.dupe(u8, out.bytes.bytes);
                var blob = try Blob.init(owned, bun.default_allocator);
                errdefer blob.deinit();
                try blob.setContentType(out.mime, .explicit);
                return .{ .Blob = blob };
            },
            .stream => |*stream| {
                var owned = try stream.toOwned();
                defer owned.deinit();
                return fromReadableStreamOwned(globalThis, &owned);
            },
            .artifact => |*handle| {
                // We must preserve "type" so that DOMFormData and the "type" field are preserved.
                return .{ .Blob = try handle.get(jsc.API.BuildArtifact).blob.dupe() };
            },
            .parts => |*list| {
                return .{ .Blob = try Blob.blobFromBindgenParts(list, .body_move) };
            },
            .other => |value| {
                if (try context.engineIn("readable_streams", "readableStreamCoerce").call(.{ .value = value.operand(context).asEngine() })) |stream| {
                    var result = stream;
                    defer result.deinit();
                    var owned = try result.toOwned();
                    defer owned.deinit();
                    return fromReadableStreamOwned(globalThis, &owned);
                }
                var text = try context.engineIn("js_strings", "stringFromJS").call(.{ .value = value.operand(context).asEngine() });
                defer text.deinit();
                // Coerced values become a plain blob with no content type,
                // unlike real string bodies.
                if (text.isEmpty()) {
                    return .{ .Empty = {} };
                }
                const copied = try text.toOwnedSlice(bun.default_allocator);
                return .{
                    .InternalBlob = .{
                        .bytes = .fromOwnedSlice(bun.default_allocator, copied),
                        .was_string = false,
                    },
                };
            },
        }
    }

    fn fromReadableStreamOwned(globalThis: *JSGlobalObject, stream: *const jsc.WebCore.ReadableStream.Owned) bun.JSError!Value {
        var readable = try jsc.WebCore.ReadableStream.Strong.initOwned(stream.clone());
        errdefer readable.deinit();
        if (readable.isDisturbed(globalThis) or readable.isLocked(globalThis)) {
            return globalThis.throwTypeError("ReadableStream has already been used", .{});
        }
        return .{
            .Locked = .{
                .readable = readable.take(),
                .global = .init(globalThis),
            },
        };
    }

    fn startBodyRead(
        completion: anytype,
        value: *Value,
        global: *JSGlobalObject,
        metadata: Blob.BlobReadMetadata,
    ) void {
        var completing = completion;
        var blob = value.use() catch {
            var owned_metadata = metadata;
            owned_metadata.deinit();
            completing.outOfMemory();
            return;
        };
        defer blob.deinit();
        Blob.startBlobRead(&blob, global, completing, metadata);
    }

    fn applyBodyBlobContentType(blob: *Blob, headers: ?*FetchHeaders) bun.OOM!void {
        if (blob.content_type.isEmpty()) {
            if (headers) |fetch_headers| {
                if (try fetch_headers.fastGet(.ContentType)) |owned_content_type| {
                    var content_type = owned_content_type;
                    defer content_type.deinit();
                    var content_slice = try content_type.toUTF8(bun.default_allocator);
                    defer content_slice.deinit();
                    const mime_type = MimeType.init(content_slice.slice());
                    try blob.setContentType(mime_type.value, .explicit);
                }
            }
            if (!blob.content_type_was_set and blob.storePtr() != null) {
                try blob.setContentType(MimeType.text.value, .explicit);
                blob.storePtr().?.mime_type = MimeType.text;
            }
        }
    }

    fn completeBodyBlob(
        completion: anytype,
        value: *Value,
        headers: ?*FetchHeaders,
    ) void {
        var completing = completion;
        var body_blob = value.use() catch {
            completing.outOfMemory();
            return;
        };
        defer body_blob.deinit();
        applyBodyBlobContentType(&body_blob, headers) catch {
            completing.outOfMemory();
            return;
        };
        const payload = bun.default_allocator.create(Blob.BlobReadPayload) catch {
            completing.outOfMemory();
            return;
        };
        const blob = Blob.new(&body_blob) catch {
            bun.destroy(payload);
            completing.outOfMemory();
            return;
        };
        payload.* = .{ .blob = .adopt(blob) };
        completing.complete(payload);
    }

    pub fn resolve(
        to_resolve: *Value,
        new: *Value,
        global: *JSGlobalObject,
        headers: ?*FetchHeaders,
    ) bun.JSTerminated!void {
        log("resolve", .{});
        if (to_resolve.* == .Locked) {
            var previous = to_resolve.*;
            to_resolve.* = .{ .Used = {} };
            defer previous.deinit();
            const locked = &previous.Locked;
            if (locked.receiver) |handle| handle.get().pending = locked;
            var readable = locked.detachReadable();
            defer readable.deinit();
            readable.done(global);

            if (locked.deliverToReceiver(new)) return;

            if (locked.action != .none and locked.action != .consumed) {
                var action = locked.action;
                locked.action = .{ .consumed = {} };
                switch (action) {
                    .none, .consumed => unreachable,
                    inline else => |*payload, tag| {
                        const completion = if (comptime tag == .getFormData) &payload.completion else payload;
                        var delivery = completion.readyDeliveryScope(global);
                        defer delivery.deinit();
                        switch (comptime tag) {
                            .getBlob => completeBodyBlob(completion.*, new, headers),
                            .getFormData => startBodyRead(completion.*, new, global, .{
                                .form_data_encoding = payload.encoding.take(),
                            }),
                            else => startBodyRead(completion.*, new, global, .{}),
                        }
                    },
                }
            }
        }
    }

    pub fn finishStreaming(this: *Value, source: *PendingValue.Source, readable: *const jsc.WebCore.ReadableStream.Strong) void {
        if (!source.attached) return;
        if (this.* != .Locked) @panic("stream producer lost its pending body");
        const locked = &this.Locked;
        const attached = locked.source orelse @panic("stream producer lost its source attachment");
        if (attached.get() != source) @panic("stream producer does not own this body");
        if (locked.hasReceiver() or (locked.action != .none and locked.action != .consumed)) {
            @panic("stream producer has a buffered body consumer");
        }
        locked.clearStreamCancellation(readable);
        locked.dropSource();
    }

    pub fn slice(this: *const Value) []const u8 {
        return switch (this.*) {
            .Blob => this.Blob.sharedView(),
            .InternalBlob => this.InternalBlob.sliceConst(),
            .WTFStringImpl => if (this.WTFStringImpl.get().canUseAsUTF8()) this.WTFStringImpl.get().latin1Slice() else "",
            // .InlineBlob => this.InlineBlob.sliceConst(),
            else => "",
        };
    }

    pub fn use(this: *Value) bun.OOM!Blob {
        try this.toBlobIfPossible();

        switch (this.*) {
            .Empty => {
                this.* = .{ .Used = {} };
                return Blob.initEmpty();
            },
            .Blob => {
                const new_blob = this.Blob.take();
                assert(!new_blob.isHeapAllocated()); // owned by Body
                this.* = .{ .Used = {} };
                return new_blob;
            },
            .InternalBlob => {
                const new_blob = try Blob.initByteList(&this.InternalBlob.bytes);

                this.* = .{ .Used = {} };
                return new_blob;
            },
            .WTFStringImpl => {
                var new_blob: Blob = undefined;
                var wtf_ref = this.WTFStringImpl;
                const wtf = wtf_ref.get();
                if (try wtf.toUTF8IfNeeded(bun.default_allocator)) |allocated_slice| {
                    new_blob = try Blob.init(
                        @constCast(allocated_slice.slice()),
                        bun.default_allocator,
                    );
                } else {
                    new_blob = try Blob.init(
                        try bun.default_allocator.dupe(u8, wtf.latin1Slice()),
                        bun.default_allocator,
                    );
                }

                wtf_ref.deinit();
                this.* = .{ .Used = {} };
                return new_blob;
            },
            // .InlineBlob => {
            //     const cloned = this.InlineBlob.bytes;
            //     // keep same behavior as InternalBlob but clone the data
            //     const new_blob = Blob.create(
            //         cloned[0..this.InlineBlob.len],
            //         bun.default_allocator,
            //         false,
            //     );

            //     this.* = .{ .Used = {} };
            //     return new_blob;
            // },
            else => {
                return Blob.initEmpty();
            },
        }
    }

    pub fn tryUseAsAnyBlob(this: *Value) bun.OOM!?AnyBlob {
        if (this.* == .Locked) return this.takeLockedAnyBlobAllowPromise();

        const any_blob: AnyBlob = switch (this.*) {
            .Blob => .{ .Blob = this.Blob },
            .InternalBlob => .{ .InternalBlob = this.InternalBlob },
            .WTFStringImpl => |str| if (str.get().canUseAsUTF8()) .{ .WTFStringImpl = str } else return null,
            else => return null,
        };

        this.* = .{ .Used = {} };
        return any_blob;
    }

    pub fn useAsAnyBlob(this: *Value) bun.OOM!AnyBlob {
        if (this.* == .Locked) {
            if (try this.takeLockedAnyBlobAllowPromise()) |blob| return blob;
            this.finishLockedReplacement(.{ .Used = {} });
            return .{ .Blob = Blob.initEmpty() };
        }

        const any_blob: AnyBlob = switch (this.*) {
            .Blob => .{ .Blob = this.Blob },
            .InternalBlob => .{ .InternalBlob = this.InternalBlob },
            .WTFStringImpl => |str| brk: {
                if (try str.get().toUTF8IfNeeded(bun.default_allocator)) |utf8| {
                    var str_ref = str;
                    defer str_ref.deinit();
                    break :brk .{
                        .InternalBlob = InternalBlob{
                            .bytes = .fromOwnedSlice(bun.default_allocator, @constCast(utf8.slice())),
                            .was_string = true,
                        },
                    };
                } else {
                    break :brk .{
                        .WTFStringImpl = str,
                    };
                }
            },
            // .InlineBlob => .{ .InlineBlob = this.InlineBlob },
            else => .{ .Blob = Blob.initEmpty() },
        };

        this.* = if (this.* == .Null)
            .{ .Null = {} }
        else
            .{ .Used = {} };
        return any_blob;
    }

    pub fn useAsAnyBlobAllowNonUTF8String(this: *Value) bun.OOM!AnyBlob {
        if (this.* == .Locked) {
            if (try this.takeLockedAnyBlobAllowPromise()) |blob| return blob;
            this.finishLockedReplacement(.{ .Used = {} });
            return .{ .Blob = Blob.initEmpty() };
        }

        const any_blob: AnyBlob = switch (this.*) {
            .Blob => .{ .Blob = this.Blob },
            .InternalBlob => .{ .InternalBlob = this.InternalBlob },
            .WTFStringImpl => .{ .WTFStringImpl = this.WTFStringImpl },
            // .InlineBlob => .{ .InlineBlob = this.InlineBlob },
            else => .{ .Blob = Blob.initEmpty() },
        };

        this.* = if (this.* == .Null)
            .{ .Null = {} }
        else
            .{ .Used = {} };
        return any_blob;
    }

    fn completeBodyError(
        completion: anytype,
        body_error: *ValueError,
    ) void {
        defer body_error.deinit();
        switch (body_error.*) {
            .OutOfMemory => completion.outOfMemory(),
            .SystemError => |*system_error| {
                const payload = system_error.get().borrow().clone() catch {
                    completion.outOfMemory();
                    return;
                };
                completion.fail(.system, payload);
            },
            .Message => |*message| {
                const payload = bun.bindgen.ThreadSafeDOMString.fromBunString(message.take()) catch {
                    completion.outOfMemory();
                    return;
                };
                completion.fail(.body_error, payload);
            },
            .TypeError => |*message| {
                const payload = bun.bindgen.ThreadSafeDOMString.fromBunString(message.take()) catch {
                    completion.outOfMemory();
                    return;
                };
                completion.fail(.body_type_error, payload);
            },
            .AbortReason => |reason| {
                const payload = bun.default_allocator.create(Blob.BlobReadPayload) catch {
                    completion.outOfMemory();
                    return;
                };
                payload.* = .{ .abort_reason = reason };
                completion.complete(payload);
            },
            .JSValue => |*value| {
                var root = value.takeRoot() orelse @panic("body error was already consumed");
                completion.reject(&root, .{ .attach_async_stack = true });
            },
        }
    }

    fn completeActionError(
        action: *PendingValue.Action,
        body_error: *ValueError,
    ) void {
        switch (action.*) {
            .getText => |*completion| completeBodyError(completion, body_error),
            .getJSON => |*completion| completeBodyError(completion, body_error),
            .getArrayBuffer => |*completion| completeBodyError(completion, body_error),
            .getBytes => |*completion| completeBodyError(completion, body_error),
            .getBlob => |*completion| completeBodyError(completion, body_error),
            .getFormData => |*pending| {
                pending.encoding.deinit();
                completeBodyError(&pending.completion, body_error);
            },
            .none, .consumed => unreachable,
        }
    }

    pub fn toErrorInstance(this: *Value, err: ValueError, global: *JSGlobalObject) bun.JSError!void {
        return this.toErrorInstanceWithReadable(err, global, null);
    }

    pub fn toErrorInstanceWithReadable(
        this: *Value,
        err: ValueError,
        global: *JSGlobalObject,
        readable: ?*const jsc.WebCore.ReadableStream.Strong,
    ) bun.JSError!void {
        if (this.* == .Locked) {
            var locked = this.Locked;
            if (locked.receiver) |handle| handle.get().pending = &locked;
            var delivered_error: Value = .{ .Error = err.dupe() };
            defer delivered_error.deinit();
            this.* = .{ .Error = err };
            defer locked.deinitStorage();

            var strong_readable = if (readable) |stream| stream.clone() else locked.detachReadable();
            defer strong_readable.deinit();
            locked.clearStreamCancellation(&strong_readable);
            var previous_readable = locked.detachReadable();
            previous_readable.deinit();

            if (locked.action != .none and locked.action != .consumed) {
                var action = locked.action;
                locked.action = .{ .consumed = {} };
                var completion_error = delivered_error.Error.dupe();
                completeActionError(&action, &completion_error);
            }

            if (strong_readable.has()) {
                if (strong_readable.byteStream()) |bytes| {
                    try bytes.onData(
                        .{ .err = try delivered_error.Error.toStreamError(global) },
                        bun.default_allocator,
                    );
                } else {
                    strong_readable.abort(global);
                }
            }

            _ = locked.deliverToReceiver(&delivered_error);
            return;
        }
        var previous = this.*;
        this.* = .{ .Error = err };
        previous.deinit();
    }

    pub fn toError(this: *Value, err: anyerror, global: *JSGlobalObject) bun.JSError!void {
        if (err == error.OutOfMemory) return this.toErrorInstance(.OutOfMemory, global);
        const message = bun.String.createFormat("Error reading file {s}", .{@errorName(err)}) catch
            return this.toErrorInstance(.OutOfMemory, global);
        return this.toErrorInstance(.{ .Message = .adopt(message) }, global);
    }

    pub fn deinit(this: *Value) void {
        var value = this.*;
        this.* = .{ .Null = {} };
        switch (value) {
            .Locked => |*locked| locked.deinitStorage(),
            .InternalBlob => |*blob| blob.clearAndFree(),
            .Blob => |*blob| blob.deinit(),
            .WTFStringImpl => |*text| text.deinit(),
            .Error => |*err| err.deinit(),
            .Null, .Empty, .Used => {},
        }
    }

    pub fn tee(this: *Value, globalThis: *jsc.JSGlobalObject, owned_readable: ?*const jsc.WebCore.ReadableStream.Strong) bun.JSError!Value {
        var locked = &this.Locked;
        if (owned_readable) |readable| {
            if (readable.isDisturbed(globalThis)) {
                return Value{ .Used = {} };
            }

            var first = readable.clone();
            errdefer first.deinit();
            if (try first.tee(globalThis)) |second| {
                this.Locked.readable.deinit();
                this.Locked.readable = first.take();
                return Value{
                    .Locked = .{
                        .readable = second,
                        .global = .init(globalThis),
                    },
                };
            }
            first.deinit();
        }
        if (locked.readable.isDisturbed(globalThis)) {
            return Value{ .Used = {} };
        }

        if (try locked.readable.tee(globalThis)) |readable| {
            return Value{
                .Locked = .{
                    .readable = readable,
                    .global = .init(globalThis),
                },
            };
        }

        if (locked.action != .none or locked.readable.has()) {
            return Value{ .Used = {} };
        }

        var readable = try this.startNativeReadableStream(globalThis);
        defer readable.deinit();
        if (this.* == .Null) {
            return Value{ .Null = {} };
        }
        const teed = (try locked.readable.tee(globalThis)) orelse return Value{ .Used = {} };

        return Value{
            .Locked = .{
                .readable = teed,
                .global = .init(globalThis),
            },
        };
    }

    pub fn clone(this: *Value, globalThis: *jsc.JSGlobalObject) bun.JSError!Value {
        return this.cloneWithReadableStream(globalThis, null);
    }

    pub fn cloneWithReadableStream(this: *Value, globalThis: *jsc.JSGlobalObject, readable: ?*const jsc.WebCore.ReadableStream.Strong) bun.JSError!Value {
        if (this.* == .Locked) {
            return this.tee(globalThis, readable);
        }

        try this.toBlobIfPossible();

        if (this.* == .InternalBlob) {
            const blob = try Blob.initByteList(&this.InternalBlob.bytes);
            this.* = .{
                .Blob = blob,
            };
        }

        if (this.* == .Blob) {
            return Value{ .Blob = try this.Blob.dupe() };
        }

        if (this.* == .WTFStringImpl) {
            return Value{ .WTFStringImpl = this.WTFStringImpl.clone() };
        }

        if (this.* == .Null) {
            return Value{ .Null = {} };
        }

        return Value{ .Empty = {} };
    }
};

pub fn Mixin(comptime Type: type) type {
    return struct {
        pub fn getText(this: *Type, context: anytype, receiver: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
            return consumeFromBinding(.text, this, context, receiver);
        }

        pub fn getBody(this: *Type, globalThis: *jsc.JSGlobalObject) bun.JSError!?jsc.WebCore.ReadableStream.Owned {
            var body: *Body.Value = this.getBodyValue();

            if (body.* == .Used) {
                return try jsc.WebCore.ReadableStream.usedOwned(globalThis);
            }
            if (@hasDecl(Type, "getBodyReadableStream")) {
                if (body.* == .Locked) {
                    if (try this.getBodyReadableStream(globalThis)) |readable| {
                        var owned_readable = readable;
                        defer owned_readable.deinit();
                        return owned_readable.cloneOwned().?;
                    }
                }
            }
            return body.toReadableStream(globalThis);
        }

        pub fn getBodyUsed(this: *Type, globalObject: *jsc.JSGlobalObject) bun.JSError!bool {
            return switch (this.getBodyValue().*) {
                .Used => true,
                .Locked => |*pending| brk: {
                    if (pending.action != .none) {
                        break :brk true;
                    }
                    if (@hasDecl(Type, "getBodyReadableStream")) {
                        if (try this.getBodyReadableStream(globalObject)) |readable| {
                            var owned_readable = readable;
                            defer owned_readable.deinit();
                            break :brk owned_readable.isDisturbed(globalObject);
                        }
                    }

                    break :brk pending.readable.isDisturbed(globalObject);
                },
                else => false,
            };
        }

        fn CompletionSet(comptime consumption: Consumption) type {
            return switch (consumption) {
                .text => BodyTextCompletions,
                .json => BodyJSONCompletions,
                .array_buffer => BodyArrayBufferCompletions,
                .bytes => BodyBytesCompletions,
                .form_data => BodyFormDataCompletions,
                .blob => BodyBlobCompletions,
            };
        }

        fn failBodyAlreadyUsed(completion: anytype) void {
            completion.fail(.body_already_used, {});
        }

        fn attachLockedCompletion(
            comptime consumption: Consumption,
            this: *Type,
            pending: *PendingValue,
            completion: CompletionSet(consumption).Owned,
            readable: ?*const jsc.WebCore.ReadableStream.Strong,
        ) bun.JSError!void {
            const Completion = CompletionSet(consumption).Owned;
            var retained: ?Completion = completion;
            defer if (retained) |*owned| owned.release();

            if (comptime consumption == .form_data) {
                var encoding = (try this.getFormDataEncoding()) orelse {
                    retained.?.fail(.invalid_form_data_encoding, {});
                    retained = null;
                    return;
                };
                const owned = retained.?;
                retained = null;
                return pending.setCompletion(.getFormData, .{
                    .completion = owned,
                    .encoding = encoding.take(),
                }, readable);
            }

            const owned = retained.?;
            retained = null;
            return switch (comptime consumption) {
                .text => pending.setCompletion(.getText, owned, readable),
                .json => pending.setCompletion(.getJSON, owned, readable),
                .array_buffer => pending.setCompletion(.getArrayBuffer, owned, readable),
                .bytes => pending.setCompletion(.getBytes, owned, readable),
                .blob => pending.setCompletion(.getBlob, owned, readable),
                .form_data => unreachable,
            };
        }

        fn completeImmediateConsumption(
            comptime consumption: Consumption,
            this: *Type,
            value: *Value,
            global: *JSGlobalObject,
            completion: CompletionSet(consumption).Owned,
        ) bun.JSError!void {
            const Completion = CompletionSet(consumption).Owned;
            var retained: ?Completion = completion;
            defer if (retained) |*owned| owned.release();

            if (value.* == .Error) {
                var body_error = value.Error.dupe();
                const owned = retained.?;
                retained = null;
                var completing = owned;
                Value.completeBodyError(&completing, &body_error);
                return;
            }

            if (comptime consumption == .form_data) {
                var encoding = (try this.getFormDataEncoding()) orelse {
                    retained.?.fail(.invalid_form_data_encoding, {});
                    retained = null;
                    return;
                };
                const owned = retained.?;
                retained = null;
                Value.startBodyRead(owned, value, global, .{
                    .form_data_encoding = encoding.take(),
                });
                return;
            }

            const owned = retained.?;
            retained = null;
            if (comptime consumption == .blob) {
                Value.completeBodyBlob(owned, value, this.getFetchHeaders());
            } else {
                Value.startBodyRead(owned, value, global, .{});
            }
        }

        fn consumeWithCompletion(
            comptime consumption: Consumption,
            this: *Type,
            global: *JSGlobalObject,
            context: anytype,
            receiver: anytype,
            comptime has_receiver: bool,
            completion: CompletionSet(consumption).Owned,
        ) bun.JSError!void {
            const Completion = CompletionSet(consumption).Owned;
            var retained: ?Completion = completion;
            defer if (retained) |*owned| owned.release();
            var value = this.getBodyValue();

            if (value.* == .Used) {
                failBodyAlreadyUsed(&retained.?);
                retained = null;
                return;
            }

            if (value.* == .Locked) {
                if (@hasDecl(Type, "getBodyReadableStream")) {
                    if (try this.getBodyReadableStream(global)) |readable| {
                        var owned_readable = readable;
                        defer owned_readable.deinit();
                        if (value.Locked.action != .none or owned_readable.isDisturbed(global) or owned_readable.isLocked(global)) {
                            failBodyAlreadyUsed(&retained.?);
                            retained = null;
                            return;
                        }
                        if (comptime consumption != .text) try value.toBlobIfPossible();
                        if (value.* == .Locked) {
                            const owned = retained.?;
                            retained = null;
                            return attachLockedCompletion(
                                consumption,
                                this,
                                &value.Locked,
                                owned,
                                &owned_readable,
                            );
                        }
                    }
                }

                if (value.* == .Locked) {
                    const disturbed = if (comptime has_receiver)
                        try value.Locked.isDisturbed(global, Type, context, receiver)
                    else
                        value.Locked.readable.isDisturbed(global);
                    if (value.Locked.action != .none or disturbed or value.Locked.readable.isLocked(global)) {
                        failBodyAlreadyUsed(&retained.?);
                        retained = null;
                        return;
                    }
                    if (comptime consumption != .text) try value.toBlobIfPossible();
                    if (value.* == .Locked) {
                        const owned = retained.?;
                        retained = null;
                        return attachLockedCompletion(consumption, this, &value.Locked, owned, null);
                    }
                }
            }

            const owned = retained.?;
            retained = null;
            return completeImmediateConsumption(consumption, this, value, global, owned);
        }

        pub fn getJSON(this: *Type, context: anytype, receiver: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
            return consumeFromBinding(.json, this, context, receiver);
        }

        pub fn getArrayBuffer(this: *Type, context: anytype, receiver: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
            return consumeFromBinding(.array_buffer, this, context, receiver);
        }

        pub fn getBytes(this: *Type, context: anytype, receiver: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
            return consumeFromBinding(.bytes, this, context, receiver);
        }

        pub fn getFormData(this: *Type, context: anytype, receiver: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
            return consumeFromBinding(.form_data, this, context, receiver);
        }

        pub fn getBlob(this: *Type, context: anytype, receiver: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
            return consumeFromBinding(.blob, this, context, receiver);
        }

        pub fn consumeFromBinding(
            comptime consumption: Consumption,
            this: *Type,
            context: anytype,
            receiver: anytype,
        ) bun.bindgen.CallError(@TypeOf(context))!void {
            const globalObject = context.viewToken().globalObject();
            const Completions = CompletionSet(consumption);
            var view = context.completion();
            const completion = Completions.takeForContext(context, &view);
            return consumeWithCompletion(consumption, this, globalObject, context, receiver, true, completion);
        }

        pub fn getBlobWithoutWrapper(this: *Type, globalObject: *jsc.JSGlobalObject) bun.JSError!BodyBlobPromise {
            const created = try BodyBlobCompletions.createTypedInRealm(
                BodyBlobCompletionSchema,
                BodyBlobPromiseResult,
                globalObject,
            );
            var promise = created.promise;
            errdefer promise.deinit();
            try consumeWithCompletion(.blob, this, globalObject, {}, {}, false, created.completion);
            return promise;
        }
    };
}

const string = []const u8;

const std = @import("std");
const bun = @import("bun");
const Output = bun.Output;
const bindgen = bun.bindgen;
const assert = bun.assert;
const default_allocator = bun.default_allocator;
const strings = bun.strings;
const FetchHeaders = bun.webcore.FetchHeaders;
const MimeType = bun.http.MimeType;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const SystemError = bun.sys.SystemError;
const VirtualMachine = jsc.VirtualMachine;

const Response = jsc.WebCore.Response;
const streams = jsc.WebCore.streams;

const Blob = jsc.WebCore.Blob;
const AnyBlob = Blob.Any;
const InternalBlob = Blob.Internal;
