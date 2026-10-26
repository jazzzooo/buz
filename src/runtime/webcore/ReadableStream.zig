const ReadableStream = @This();

const LockedGetter = bindgen.Module("WebCoreStreams").class("ReadableStream").memberKind("locked", .getter);

fn getLocked(context: bindgen.CallContext(LockedGetter), args: bindgen.Args(LockedGetter)) bindgen.CallError(LockedGetter)!bool {
    return context.engineIn("readable_streams", "readableStreamIsLocked").call(.{ .stream = args.bindingThis.operand(context) });
}

comptime {
    _ = bindgen.Fn(LockedGetter, getLocked);
}

pub const Strong = struct {
    owned: ?Owned = null,
    ptr: Source = .{ .Invalid = {} },

    pub fn has(this: *const Strong) bool {
        return this.owned != null;
    }

    pub fn isEmpty(this: *const Strong) bool {
        return this.owned == null;
    }

    pub fn isDisturbed(this: *const Strong, global: *jsc.JSGlobalObject) bool {
        const owned = if (this.owned) |*value| value else return false;
        var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
        engine_scope.init(global);
        defer engine_scope.deinit();
        return engine_scope.engine(ReadableStreamIsDisturbedSchema).call(.{ .stream = owned.operand(&engine_scope) });
    }

    pub fn isLocked(this: *const Strong, global: *jsc.JSGlobalObject) bool {
        const owned = if (this.owned) |*value| value else return false;
        var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
        engine_scope.init(global);
        defer engine_scope.deinit();
        return engine_scope.engine(ReadableStreamIsLockedSchema).call(.{ .stream = owned.operand(&engine_scope) });
    }

    pub fn sizeHint(this: *const Strong) ?Blob.SizeType {
        return switch (this.ptr) {
            .Bytes => |bytes| bytes.get().context.size_hint,
            else => null,
        };
    }

    pub fn sourceTag(this: *const Strong) Tag {
        return std.meta.activeTag(this.ptr);
    }

    pub fn refreshSource(this: *Strong) bun.JSError!void {
        const owned = if (this.owned) |*value| value else {
            this.ptr.deinit();
            return;
        };
        const source = try describeOwned(owned);
        var previous = this.ptr;
        this.ptr = source;
        previous.deinit();
    }

    pub fn byteStream(this: *const Strong) ?*webcore.ByteStream {
        return switch (this.ptr) {
            .Bytes => |bytes| &bytes.get().context,
            else => null,
        };
    }

    pub fn blobLoader(this: *const Strong) ?*webcore.ByteBlobLoader.Loader {
        return switch (this.ptr) {
            .Blob => |blob| &blob.get().context,
            else => null,
        };
    }

    pub fn fileReader(this: *const Strong) ?*webcore.FileReader {
        return switch (this.ptr) {
            .File => |file| &file.get().context.core,
            else => null,
        };
    }

    pub fn toAnyBlob(this: *Strong, global: *jsc.JSGlobalObject) bun.OOM!?Blob.Any {
        const owned = if (this.owned) |*value| value else return null;
        var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
        engine_scope.init(global);
        defer engine_scope.deinit();
        if (!engine_scope.engine(ReadableStreamCanConsumeNativeSchema).call(.{ .stream = owned.operand(&engine_scope) })) return null;

        const blob: Blob.Any = switch (this.ptr) {
            .Blob => |source| (try webcore.ByteBlobLoader.toAnyBlob(&source.get().context)) orelse return null,
            .File => |source| file: {
                const reader = &source.get().context.core;
                if (reader.lazy != .blob) return null;
                const store = reader.lazy.blob.get();
                store.ref();
                var file_blob = try Blob.initWithStore(store);
                file_blob.offset = @intCast(reader.start_offset orelse 0);
                file_blob.size = @intCast(reader.max_size orelse Blob.max_size);
                bun.assert(!reader.started);
                break :file .{ .Blob = file_blob };
            },
            .Bytes => |source| source.get().context.toAnyBlob() orelse return null,
            else => return null,
        };

        this.forceDetach(global);
        this.done(global);
        return blob;
    }

    pub fn initOwned(owned: Owned) bun.JSError!Strong {
        var result: Strong = .{ .owned = owned };
        errdefer result.owned.?.deinit();
        result.ptr = try describeOwned(&result.owned.?);
        return result;
    }

    pub fn take(this: *Strong) Strong {
        const result = this.*;
        this.* = .{};
        return result;
    }

    pub fn cloneOwned(this: *const Strong) ?Owned {
        if (this.owned) |*owned| return owned.clone();
        return null;
    }

    pub fn clone(this: *const Strong) Strong {
        return .{
            .owned = this.cloneOwned(),
            .ptr = this.ptr.clone(),
        };
    }

    pub fn toResult(this: *const Strong, context: anytype) ?Result {
        const owned = if (this.owned) |*value| value else return null;
        return owned.toResult(context);
    }

    pub fn format(
        this: *const Strong,
        global: *jsc.JSGlobalObject,
        options: jsc.ConsoleObject.FormatOptions,
    ) bun.JSError!bindgen.DOMString {
        const owned = if (this.owned) |*value| value else return bindgen.DOMString.fromUTF8("undefined");
        return jsc.ConsoleObject.formatOwnedBranded(global, owned, options);
    }

    pub fn consumePromise(
        this: *const Strong,
        comptime operation_name: []const u8,
        content_type: ?*const bindgen.DOMString,
    ) bun.JSError!bindgen.OwnedBrandedValue(ReadableStreamBindings.engineShim(operation_name).ReturnType) {
        const owned = if (this.owned) |*value| value else @panic("cannot consume an empty readable stream");
        var scope: bindgen.FocusedEngineScope = undefined;
        owned.initScope(&scope);
        defer scope.deinit();
        const operation = scope.engineIn("readable_streams", operation_name);
        var result = if (comptime std.mem.eql(u8, operation_name, "readableStreamConsumeFormData"))
            try operation.call(.{
                .stream = owned.operand(&scope),
                .content_type = if (content_type) |value| value.operand() else null,
            })
        else result: {
            if (content_type != null) @panic("content type is only valid for form-data consumption");
            break :result try operation.call(.{ .stream = owned.operand(&scope) });
        };
        defer result.deinit();
        return result.toOwned();
    }

    pub fn deinit(this: *Strong) void {
        var value = this.take();
        value.ptr.deinit();
        if (value.owned) |*owned| owned.deinit();
    }

    pub fn cancelInStoredRealm(this: *const Strong) void {
        const global = this.storedGlobal() orelse return;
        this.cancel(global);
    }

    pub fn abortInStoredRealm(this: *const Strong) void {
        const global = this.storedGlobal() orelse return;
        this.abort(global);
    }

    pub fn doneInStoredRealm(this: *const Strong) void {
        _ = this.storedGlobal() orelse return;
        var source = this.ptr.clone();
        defer source.deinit();
        doneSource(source);
    }

    pub fn done(this: *const Strong, global: *JSGlobalObject) void {
        if (this.owned == null) return;
        if (this.storedGlobal().? != global) @panic("readable stream used in a different realm");
        var source = this.ptr.clone();
        defer source.deinit();
        doneSource(source);
    }

    pub fn cancel(this: *const Strong, global: *JSGlobalObject) void {
        var snapshot = this.clone();
        defer snapshot.deinit();
        const owned = if (snapshot.owned) |*value| value else return;
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(global);
        defer scope.deinit();
        if (scope.engine(ReadableStreamCancelSchema).call(.{ .stream = owned.operand(&scope) })) |promise| {
            scope.engine(PromiseSetHandledSchema).call(.{ .promise = promise.operand(&scope).asPromise() });
        } else |err| {
            global.reportActiveExceptionAsUnhandled(err);
        }
        doneSource(snapshot.ptr);
    }

    pub fn cancelWithReasonRoot(this: *const Strong, global: *JSGlobalObject, reason: *const bindgen.Root) void {
        var snapshot = this.clone();
        defer snapshot.deinit();
        const owned = if (snapshot.owned) |*value| value else return;
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(global);
        defer scope.deinit();
        if (scope.engine(ReadableStreamCancelWithReasonSchema).call(.{
            .stream = owned.operand(&scope),
            .reason = reason.operand(&scope).asAny(),
        })) |promise| {
            scope.engine(PromiseSetHandledSchema).call(.{ .promise = promise.operand(&scope).asPromise() });
        } else |err| global.reportActiveExceptionAsUnhandled(err);
        doneSource(snapshot.ptr);
    }

    pub fn abort(this: *const Strong, global: *JSGlobalObject) void {
        this.cancel(global);
    }

    pub fn forceDetach(this: *const Strong, global: *JSGlobalObject) void {
        const owned = if (this.owned) |*value| value else return;
        var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
        engine_scope.init(global);
        defer engine_scope.deinit();
        engine_scope.engine(ReadableStreamDetachSchema).call(.{ .stream = owned.operand(&engine_scope) });
    }

    pub fn retainStreamError(this: *const Strong, err: *const streams.Result.StreamError) bun.JSError!bindgen.Root {
        const global = this.storedGlobal() orelse @panic("empty stream handle has no realm");
        return err.toRoot(global);
    }

    pub fn storedGlobal(this: *const Strong) ?*JSGlobalObject {
        if (this.owned) |*owned| return @ptrCast(@alignCast(owned.storedRealm()));
        return null;
    }

    pub fn tee(this: *Strong, global: *JSGlobalObject) bun.JSError!?Strong {
        const owned = if (this.owned) |*value| value else return null;
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(global);
        defer scope.deinit();
        var pair = try scope.engine(ReadableStreamTeeSchema).call(.{ .stream = owned.operand(&scope) });
        defer bindgen.deinitReturn(ReadableStreamTeeSchema, &pair);
        var first = try Strong.initOwned(try pair.first.toOwned());
        errdefer first.deinit();
        const second = try Strong.initOwned(try pair.second.toOwned());
        var previous = this.take();
        this.* = first.take();
        previous.deinit();
        return second;
    }
};

fn doneSource(source_value: Source) void {
    switch (source_value) {
        inline .Blob, .File, .Bytes => |source| source.get().cancel(),
        else => {},
    }
}

pub const Tag = enum(i32) {
    Invalid = -1,

    /// ReadableStreamDefaultController or ReadableByteStreamController
    JavaScript = 0,

    /// ReadableByteStreamController
    /// but with a BlobLoader
    /// we can skip the BlobLoader and just use the underlying Blob
    Blob = 1,

    /// ReadableByteStreamController
    /// but with a FileLoader
    /// we can skip the FileLoader and just use the underlying File
    File = 2,

    /// This is a direct readable stream
    /// That means we can turn it into whatever we want
    Direct = 3,

    Bytes = 4,
};

pub const Source = union(Tag) {
    Invalid: void,
    /// ReadableStreamDefaultController or ReadableByteStreamController
    JavaScript: void,
    /// ReadableByteStreamController
    /// but with a BlobLoader
    /// we can skip the BlobLoader and just use the underlying Blob
    Blob: bindgen.RefNative(webcore.ByteBlobLoader.Source, .vm),

    /// ReadableByteStreamController
    /// but with a FileLoader
    /// we can skip the FileLoader and just use the underlying File
    File: bindgen.RefNative(webcore.FileReaderEngine.Source, .vm),

    /// This is a direct readable stream
    /// That means we can turn it into whatever we want
    Direct: void,

    Bytes: bindgen.RefNative(webcore.ByteStream.Source, .vm),

    fn clone(this: Source) Source {
        return switch (this) {
            inline .Blob, .File, .Bytes => |source, tag| @unionInit(Source, @tagName(tag), source.clone()),
            .Invalid, .JavaScript, .Direct => this,
        };
    }

    fn deinit(this: *Source) void {
        var value = this.*;
        this.* = .{ .Invalid = {} };
        switch (value) {
            inline .Blob, .File, .Bytes => |*source| source.deinit(),
            .Invalid, .JavaScript, .Direct => {},
        }
    }
};

pub const Owned = bindgen.OwnedBrandedValue(ReadableStreamEmptyShim.ReturnType);
pub const Result = Owned.Result;

fn describeOwned(owned: *const Owned) bun.JSError!Source {
    var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
    owned.initScope(&engine_scope);
    defer engine_scope.deinit();
    var description = try engine_scope.engine(ReadableStreamDescribeSchema).call(.{ .stream = owned.operand(&engine_scope) });
    return takeDescriptionSource(&description);
}

fn takeDescriptionSource(description: anytype) Source {
    if (description.source) |*source| {
        const result: Source = switch (source.*) {
            .blob => |*ref| .{
                .Blob = ref.get(webcore.ByteBlobLoader.Source.JSBinding).source.clone(),
            },
            .file => |*ref| .{
                .File = ref.get(webcore.FileReaderEngine.Source.JSBinding).source.clone(),
            },
            .bytes => |*ref| .{
                .Bytes = ref.get(webcore.ByteStream.Source.JSBinding).source.clone(),
            },
        };
        description.source = null;
        return result;
    }

    return switch (description.tag) {
        .JavaScript => .{ .JavaScript = {} },
        .Direct => .{ .Direct = {} },
        .Blob, .File, .Bytes => @panic("native readable stream description omitted its source"),
    };
}

fn fromNative(
    comptime ClassSchema: type,
    globalThis: *JSGlobalObject,
    native: *const bindgen.ClassRef(ClassSchema),
) bun.JSError!Owned {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(globalThis);
    defer scope.deinit();
    const NativeSource = bindgen.EngineArgumentType(ReadableStreamCreateNativeSchema, "native");
    const source: NativeSource = if (ClassSchema == BlobSourceSchema)
        .{ .blob = native.operand(&scope) }
    else if (ClassSchema == BytesSourceSchema)
        .{ .bytes = native.operand(&scope) }
    else if (ClassSchema == FileSourceSchema)
        .{ .file = native.operand(&scope) }
    else
        @compileError("unsupported native readable stream source class");
    const result = try scope.engine(ReadableStreamCreateNativeSchema).call(.{ .native = source });
    return result.toOwned();
}

pub fn fromOwnedSliceResultFromBinding(
    context: anytype,
    bytes: []u8,
    recommended_chunk_size: Blob.SizeType,
) bun.bindgen.CallError(@TypeOf(context))!Result {
    const global = context.viewToken().globalObject();
    comptime requireSubprocessReadableContext(@TypeOf(context));
    var owned = try fromOwnedSliceOwned(global, bytes, recommended_chunk_size);
    defer owned.deinit();
    return owned.toResult(context);
}

pub fn fromOwnedSliceOwned(globalThis: *JSGlobalObject, bytes: []u8, recommended_chunk_size: Blob.SizeType) bun.JSError!Owned {
    var blob = try Blob.init(bytes, bun.default_allocator);
    defer blob.deinit();
    return fromBlobCopyRefOwned(globalThis, &blob, recommended_chunk_size);
}

pub fn fromBlobCopyRefOwned(globalThis: *JSGlobalObject, blob: *const Blob, recommended_chunk_size: Blob.SizeType) bun.JSError!Owned {
    const store = blob.storePtr() orelse {
        return emptyOwned(globalThis);
    };
    switch (store.data) {
        .bytes => {
            const reader = try webcore.ByteBlobLoader.Source.create(globalThis, .{});
            defer reader.deref();
            try reader.context.setup(blob, recommended_chunk_size);
            return reader.toReadableStreamOwned(globalThis);
        },
        .file => {
            const reader = try webcore.FileReaderEngine.create(globalThis, .{
                .event_loop = globalThis.bunVM().runtimeLoopHandle(),
                .start_offset = blob.offset,
                .max_size = if (blob.size != Blob.max_size) blob.size else null,

                .lazy = .{
                    .blob = .init(store),
                },
            });
            defer reader.deref();
            return reader.toReadableStreamOwned(globalThis);
        },
        .s3 => |*s3| {
            const credentials = s3.getCredentials();
            const path = s3.path();
            const proxy = globalThis.bunVM().transpiler.env.getHttpProxy(true, null, null);
            const proxy_url = if (proxy) |p| p.href else null;

            return S3StreamEngine.readableStream(credentials, path, blob.offset, if (blob.size != Blob.max_size) blob.size else null, proxy_url, s3.request_payer, globalThis);
        },
    }
}

pub fn fromPipeOwned(
    globalThis: *JSGlobalObject,
    _: anytype,
    buffered_reader: anytype,
) bun.JSError!Owned {
    const source = try webcore.FileReaderEngine.create(globalThis, .{
        .event_loop = globalThis.bunVM().runtimeLoopHandle(),
    });
    defer source.deref();
    const readable = try source.toReadableStreamOwned(globalThis);
    source.context.core.reader.from(buffered_reader, &source.context.core);
    return readable;
}

pub fn fromPipeResultFromBinding(
    context: anytype,
    parent: anytype,
    buffered_reader: anytype,
) bun.bindgen.CallError(@TypeOf(context))!Result {
    const global = context.viewToken().globalObject();
    comptime requireSubprocessReadableContext(@TypeOf(context));
    var owned = try fromPipeOwned(global, parent, buffered_reader);
    defer owned.deinit();
    return owned.toResult(context);
}

pub fn emptyOwned(globalThis: *JSGlobalObject) bun.JSError!Owned {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(globalThis);
    defer scope.deinit();
    const result = try scope.engine(ReadableStreamEmptyShim).call(.{});
    return result.toOwned();
}

pub fn emptyResultFromBinding(
    context: anytype,
    canceled: bool,
) bun.bindgen.CallError(@TypeOf(context))!Result {
    const global = context.viewToken().globalObject();
    comptime requireSubprocessReadableContext(@TypeOf(context));
    var owned = try emptyOwned(global);
    defer owned.deinit();
    if (canceled) {
        var stream = try Strong.initOwned(owned.clone());
        defer stream.deinit();
        stream.cancel(global);
    }
    return owned.toResult(context);
}

fn requireSubprocessReadableContext(comptime Context: type) void {
    const implementation = bindgen.ContextImplementationName(Context);
    const Schema = if (std.mem.eql(u8, implementation, "bindGetReadable"))
        SubprocessClassSchema.memberKind("readable", .getter)
    else if (std.mem.eql(u8, implementation, "bindGetStderr"))
        SubprocessClassSchema.memberKind("stderr", .getter)
    else if (std.mem.eql(u8, implementation, "bindGetStdout"))
        SubprocessClassSchema.memberKind("stdout", .getter)
    else
        @compileError("subprocess readable-stream construction requires an exact subprocess output getter context");
    bindgen.requireFunctionContext(Context, Schema);
    if (bindgen.Args(Context) != bindgen.Args(Schema) or
        bindgen.Return(Context) != bindgen.Return(Schema))
    {
        @compileError("subprocess readable-stream construction requires its exact getter arguments and result");
    }
}

pub fn usedOwned(globalThis: *JSGlobalObject) bun.JSError!Owned {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(globalThis);
    defer scope.deinit();
    const result = try scope.engine(ReadableStreamUsedShim).call(.{});
    return result.toOwned();
}

const BufferedSourceCompletions = bindgen.MaterializedCompletionSet(.{
    BlobSourceSchema.memberKind("arrayBuffer", .method),
    BlobSourceSchema.memberKind("blob", .method),
    BlobSourceSchema.memberKind("bytes", .method),
    BlobSourceSchema.memberKind("json", .method),
    BlobSourceSchema.memberKind("text", .method),
    BytesSourceSchema.memberKind("arrayBuffer", .method),
    BytesSourceSchema.memberKind("blob", .method),
    BytesSourceSchema.memberKind("bytes", .method),
    BytesSourceSchema.memberKind("json", .method),
    BytesSourceSchema.memberKind("text", .method),
}, Blob.BlobReadPayload, Blob.BlobReadCompletionOps);

pub const BufferAction = union(enum) {
    text: PendingBufferAction,
    array_buffer: PendingBufferAction,
    blob: PendingBufferAction,
    bytes: PendingBufferAction,
    json: PendingBufferAction,
    consumed: void,

    const PendingBufferAction = struct {
        completion: BufferedSourceCompletions.Owned,
        global: *JSGlobalObject,
    };

    pub const Kind = enum {
        text,
        array_buffer,
        blob,
        bytes,
        json,
    };

    fn init(comptime kind: Kind, global: *JSGlobalObject, context: anytype, view: anytype) BufferAction {
        const completion = BufferedSourceCompletions.takeForContext(context, view);
        return switch (kind) {
            .text => .{ .text = .{ .completion = completion, .global = global } },
            .array_buffer => .{ .array_buffer = .{ .completion = completion, .global = global } },
            .blob => .{ .blob = .{ .completion = completion, .global = global } },
            .bytes => .{ .bytes = .{ .completion = completion, .global = global } },
            .json => .{ .json = .{ .completion = completion, .global = global } },
        };
    }

    pub fn take(this: *BufferAction) BufferAction {
        if (this.* == .consumed) @panic("buffer completion was consumed twice");
        const result = this.*;
        this.* = .{ .consumed = {} };
        return result;
    }

    fn takeCompletion(this: *BufferAction) BufferedSourceCompletions.Owned {
        return switch (this.take()) {
            inline .text, .array_buffer, .blob, .bytes, .json => |pending| pending.completion,
            .consumed => unreachable,
        };
    }

    pub fn outOfMemory(this: *BufferAction) void {
        var completion = this.takeCompletion();
        completion.outOfMemory();
    }

    pub fn fulfill(this: *BufferAction, value: *Blob.Any) void {
        switch (this.take()) {
            .blob => |pending| {
                var completion = pending.completion;
                var blob = value.intoBlob() catch {
                    value.detach();
                    completion.outOfMemory();
                    return;
                };
                defer blob.deinit();
                const payload = bun.default_allocator.create(Blob.BlobReadPayload) catch {
                    completion.outOfMemory();
                    return;
                };
                const owned = Blob.new(&blob) catch {
                    bun.destroy(payload);
                    completion.outOfMemory();
                    return;
                };
                payload.* = .{ .blob = .adopt(owned) };
                completion.complete(payload);
            },
            inline .text, .array_buffer, .bytes, .json => |pending| {
                value.startRead(pending.global, pending.completion, .{});
            },
            .consumed => unreachable,
        }
    }

    pub fn reject(this: *BufferAction, stream_error: *streams.Result.StreamError) void {
        var completion = this.takeCompletion();
        switch (stream_error.*) {
            .OutOfMemory => completion.outOfMemory(),
            .Error => completion.fail(.system, stream_error.takeSystem()),
            .AbortReason => |reason| {
                const payload = bun.default_allocator.create(Blob.BlobReadPayload) catch {
                    completion.outOfMemory();
                    return;
                };
                payload.* = .{ .abort_reason = reason };
                completion.complete(payload);
            },
            .JSValue => |*value| {
                var root = value.takeRoot() orelse @panic("stored stream error has no JS value");
                completion.reject(&root, .{ .attach_async_stack = true });
            },
            .consumed => @panic("consumed stream error cannot reject a read"),
        }
    }

    pub fn failBodyAlreadyUsed(this: *BufferAction) void {
        var completion = this.takeCompletion();
        completion.fail(.body_already_used, {});
    }

    pub fn failAlreadyBuffering(this: *BufferAction) void {
        var completion = this.takeCompletion();
        completion.fail(.already_buffering, {});
    }

    pub fn deinit(this: *BufferAction) void {
        if (this.* == .consumed) return;
        var completion = this.takeCompletion();
        completion.release();
    }
};

pub fn NewSource(
    comptime Context: type,
    comptime name_: []const u8,
    comptime onStart: anytype,
    comptime onPull: anytype,
    comptime onCancel: fn (this: *Context) void,
    comptime deinit_fn: fn (this: *Context) void,
    comptime setRefUnrefFn: ?fn (this: *Context, enable: bool) void,
    comptime drainInternalBuffer: fn (this: *Context) bun.OOM!bindgen.OwnedBytes,
    comptime memoryCostFn: ?fn (this: *const Context) usize,
    comptime toBufferedValue: ?fn (this: *Context, action: *BufferAction) void,
) type {
    return struct {
        context: Context,
        cancelled: bool = false,
        ref_count: u32 = 1,
        pending_err: ?Syscall.Error = null,
        cancel_handler: ?*const fn (bindgen.NativeCallbackContext(.vm)) void = null,
        cancel_ctx: ?bindgen.NativeCallbackContext(.vm) = null,
        globalThis: *JSGlobalObject = undefined,
        wrapper: bindgen.ClassWrapperHandle(ClassSchema, .weak) = .empty,
        is_closed: bool = false,

        const This = @This();
        const ReadableStreamSourceType = @This();

        /// Consumes the initialized context, including on allocation failure.
        pub fn create(globalThis: *JSGlobalObject, context: Context) bun.OOM!*This {
            const source = bun.default_allocator.create(This) catch |err| {
                var owned_context = context;
                deinit_fn(&owned_context);
                return err;
            };
            source.* = .{ .context = context, .globalThis = globalThis };
            return source;
        }

        pub fn ref(this: *This) void {
            this.incrementCount();
        }

        pub fn deref(this: *This) void {
            _ = this.decrementCount();
        }

        pub fn setRef(this: *This, value: bool) void {
            if (setRefUnrefFn) |setRefUnref| {
                setRefUnref(&this.context, value);
            }
        }

        pub fn start(this: *This) streams.ReadableStart {
            return onStart(&this.context);
        }

        pub fn onPullFromJS(this: *This, buf: []u8) streams.Result {
            return onPull(&this.context, buf);
        }

        pub fn onStartFromJS(this: *This) streams.ReadableStart {
            return onStart(&this.context);
        }

        pub fn cancel(this: *This) void {
            if (this.cancelled) {
                return;
            }

            this.ref();
            defer this.deref();
            this.cancelled = true;
            this.is_closed = true;
            onCancel(&this.context);
            if (this.cancel_handler) |handler| {
                this.cancel_handler = null;
                handler(bun.take(&this.cancel_ctx).?);
            }
        }

        pub fn onClose(this: *This) void {
            if (this.cancelled or this.is_closed) {
                return;
            }

            this.ref();
            defer this.deref();
            this.is_closed = true;
            JSBinding.onClose(this);
        }

        pub fn incrementCount(this: *This) void {
            this.ref_count += 1;
        }

        pub fn decrementCount(this: *This) u32 {
            if (comptime Environment.isDebug) {
                if (this.ref_count == 0) {
                    @panic("Attempted to decrement ref count below zero");
                }
            }

            this.ref_count -= 1;
            if (this.ref_count == 0) {
                this.cancelled = true;
                this.cancel_handler = null;
                this.wrapper.deinit();
                deinit_fn(&this.context);
                bun.destroy(this);
                return 0;
            }

            return this.ref_count;
        }

        pub fn getError(this: *This) ?Syscall.Error {
            if (this.pending_err) |err| {
                this.pending_err = null;
                return err;
            }

            return null;
        }

        pub fn toReadableStreamOwned(this: *ReadableStreamSourceType, globalThis: *JSGlobalObject) bun.JSError!Owned {
            if (try this.wrapper.toOwned()) |native| {
                var native_ref = native;
                defer native_ref.deinit();
                return ReadableStream.fromNative(ClassSchema, globalThis, &native_ref);
            }

            this.wrapper.deinit();
            const binding = try bun.default_allocator.create(JSBinding);
            binding.* = .{ .source = .init(this) };
            var native_ref = try Binding.adoptNativeRef(binding, globalThis);
            defer native_ref.deinit();
            this.wrapper = try Binding.WeakWrapper.initRef(&native_ref);
            return ReadableStream.fromNative(ClassSchema, globalThis, &native_ref);
        }

        pub fn memoryCost(this: *const ReadableStreamSourceType) usize {
            if (memoryCostFn) |function| {
                return function(&this.context) + @sizeOf(@This());
            }
            return @sizeOf(@This());
        }

        pub const JSBinding = struct {
            bindgen_state: bindgen.ClassState = .{},
            source: bindgen.RefNative(This, .vm),

            const ResultAction = enum { pull_native, start };

            pub const destroy = deinit;

            fn deinit(this: *JSBinding) void {
                this.source.deinit();
                bun.destroy(this);
            }

            fn resultFromBinding(
                this: *JSBinding,
                comptime operation: ResultAction,
                context: anytype,
                args: anytype,
            ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
                return switch (operation) {
                    .pull_native => this.pullFromBinding(context, args),
                    .start => this.startFromBinding(context),
                };
            }

            fn completionFromBinding(
                this: *JSBinding,
                comptime operation: BufferAction.Kind,
                context: anytype,
                _: anytype,
            ) bun.bindgen.CallError(@TypeOf(context))!void {
                const globalThis = context.viewToken().globalObject();
                var view = context.completion();
                var action = BufferAction.init(operation, globalThis, context, &view);
                defer action.deinit();
                if (comptime toBufferedValue) |to_buffered_value| {
                    to_buffered_value(&this.source.get().context, &action);
                    return;
                }
                @compileError("buffered readable-stream methods require a buffering implementation");
            }

            fn pullFromBinding(
                this: *JSBinding,
                context: anytype,
                args: anytype,
            ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
                const view = args.view orelse return .{
                    .value = .{ .undefined = false },
                    .done = false,
                };
                var owned_view = try view.toOwned();
                const result = this.source.get().onPullFromJS(
                    owned_view.unsafeMutPtr("the pending readable result owns the mutable lease until pull settlement"),
                );
                if (result == .pending) {
                    result.pending.retainPullView(owned_view.take());
                } else {
                    owned_view.release();
                }
                return processResult(
                    context,
                    result,
                );
            }

            fn startFromBinding(
                this: *JSBinding,
                context: anytype,
            ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
                const globalThis = context.viewToken().globalObject();
                const source = this.source.get();
                source.globalThis = globalThis;
                var start_result = source.onStartFromJS();
                defer start_result.deinit();
                return switch (start_result) {
                    .empty => .{ .chunk_size = 0 },
                    .ready => .{ .chunk_size = 16384 },
                    .chunk_size => |size| .{ .chunk_size = size },
                    .err => |err| failure: {
                        start_result = .empty;
                        break :failure context.fail(.system, err);
                    },
                    .out_of_memory => error.OutOfMemory,
                    .owned_and_done => |*list| .{
                        .bytes = .fromDefaultAllocatedSlice(try list.toOwnedSlice(bun.default_allocator)),
                    },
                };
            }

            pub fn memoryUsage(this: *const JSBinding, _: bindgen.MemoryUsageContext(.vm)) usize {
                return @sizeOf(JSBinding) + this.source.get().memoryCost();
            }

            pub fn bindPullNative(
                this: *JSBinding,
                context: bindgen.CallContext(PullNativeSchema),
                args: bindgen.Args(PullNativeSchema),
            ) bun.JSError!bindgen.Return(PullNativeSchema) {
                return this.resultFromBinding(.pull_native, context, args);
            }

            pub fn bindStart(
                this: *JSBinding,
                context: bindgen.CallContext(StartSchema),
                args: bindgen.Args(StartSchema),
            ) bindgen.CallError(StartSchema)!bindgen.Return(StartSchema) {
                return this.resultFromBinding(.start, context, args);
            }

            pub fn bindIsClosed(
                this: *JSBinding,
                _: bindgen.CallContext(IsClosedSchema),
                _: bindgen.Args(IsClosedSchema),
            ) bun.JSError!bool {
                return this.source.get().is_closed;
            }

            fn processResult(
                context: anytype,
                result: streams.Result,
            ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
                var result_ = result;
                defer result_.deinit();
                return switch (result_) {
                    .err => .{
                        .value = .{ .pending = try result_.rejectedPullPromiseResult(context) },
                        .done = false,
                    },
                    .pending => |pending| .{
                        .value = .{ .pending = try pending.promiseResult(context) },
                        .done = false,
                    },
                    else => try result_.toDirectPullResult(),
                };
            }

            pub fn bindCancel(
                this: *JSBinding,
                _: bindgen.CallContext(CancelSchema),
                _: bindgen.Args(CancelSchema),
            ) bun.JSError!void {
                this.source.get().cancel();
            }

            pub fn bindSetOnClose(
                _: *JSBinding,
                _: bindgen.CallContext(OnCloseSetterSchema),
                args: bindgen.Args(OnCloseSetterSchema),
            ) bun.JSError!void {
                if (args.value) |callback| {
                    OnCloseCallbackSlot.setView(args.bindingThis, callback);
                } else {
                    OnCloseCallbackSlot.clearView(args.bindingThis);
                }
            }

            pub fn bindSetOnDrain(
                _: *JSBinding,
                context: bindgen.CallContext(OnDrainSetterSchema),
                args: bindgen.Args(OnDrainSetterSchema),
            ) bun.JSError!void {
                const callback = args.value orelse {
                    OnDrainCallbackSlot.clearView(args.bindingThis);
                    return;
                };
                _ = context;
                OnDrainCallbackSlot.setView(args.bindingThis, callback);
            }

            pub fn bindGetOnClose(
                _: *JSBinding,
                _: bindgen.CallContext(OnCloseGetterSchema),
                args: bindgen.Args(OnCloseGetterSchema),
            ) bun.JSError!bindgen.Return(OnCloseGetterSchema) {
                return OnCloseCallbackSlot.ownedCallbackFromView(args.bindingThis);
            }

            pub fn bindGetOnDrain(
                _: *JSBinding,
                _: bindgen.CallContext(OnDrainGetterSchema),
                _: bindgen.Args(OnDrainGetterSchema),
            ) bun.JSError!bindgen.Return(OnDrainGetterSchema) {
                return null;
            }

            pub fn bindUpdateRef(
                this: *JSBinding,
                _: bindgen.CallContext(UpdateRefSchema),
                args: bindgen.Args(UpdateRefSchema),
            ) bun.JSError!void {
                this.source.get().setRef(args.enabled orelse false);
            }

            const CloseNotification = struct {
                task: jsc.NativeMicrotask = undefined,
                callback: bindgen.Callback(CloseCallbackType),

                pub fn run(notification: *@This()) bun.JSError!void {
                    var invocation: @TypeOf(notification.callback).Invocation = undefined;
                    notification.callback.beginInvocation(&invocation);
                    defer invocation.deinit();
                    try invocation.call(.{});
                }

                pub fn deinit(notification: *@This()) void {
                    notification.callback.deinit();
                }

                pub fn destroy(notification: *@This()) void {
                    notification.task.destroy();
                }
            };

            fn onClose(source: *ReadableStreamSourceType) void {
                const global = source.globalThis;
                var wrapper = (source.wrapper.toOwned() catch |err| return global.reportActiveExceptionAsUnhandled(err)) orelse return;
                defer wrapper.deinit();
                var callback = (OnCloseCallbackSlot.takeOwnedCallback(&wrapper) catch |err| return global.reportActiveExceptionAsUnhandled(err)) orelse return;
                defer callback.deinit();
                var notification: bindgen.OwnedNative(CloseNotification, .vm) = .init(jsc.NativeMicrotask.create(CloseNotification, .{
                    .callback = callback.take(),
                }) catch |err| return global.reportActiveExceptionAsUnhandled(err));
                global.queueMicrotaskTask(&notification.take().task) catch |err|
                    global.reportActiveExceptionAsUnhandled(err);
            }

            pub fn bindDrain(
                this: *JSBinding,
                _: bindgen.CallContext(DrainSchema),
                _: bindgen.Args(DrainSchema),
            ) bun.JSError!?bindgen.OwnedBytes {
                var bytes = try drainInternalBuffer(&this.source.get().context);
                if (bytes.slice().len == 0) {
                    bytes.deinit();
                    return null;
                }
                return bytes;
            }

            pub fn bindText(
                this: *JSBinding,
                context: bindgen.CallContext(TextSchema),
                args: bindgen.Args(TextSchema),
            ) bindgen.CallError(TextSchema)!void {
                return this.completionFromBinding(.text, context, args);
            }

            pub fn bindArrayBuffer(
                this: *JSBinding,
                context: bindgen.CallContext(ArrayBufferSchema),
                args: bindgen.Args(ArrayBufferSchema),
            ) bindgen.CallError(ArrayBufferSchema)!void {
                return this.completionFromBinding(.array_buffer, context, args);
            }

            pub fn bindBlob(
                this: *JSBinding,
                context: bindgen.CallContext(BlobSchema),
                args: bindgen.Args(BlobSchema),
            ) bindgen.CallError(BlobSchema)!void {
                return this.completionFromBinding(.blob, context, args);
            }

            pub fn bindBytes(
                this: *JSBinding,
                context: bindgen.CallContext(BytesSchema),
                args: bindgen.Args(BytesSchema),
            ) bindgen.CallError(BytesSchema)!void {
                return this.completionFromBinding(.bytes, context, args);
            }

            pub fn bindJSON(
                this: *JSBinding,
                context: bindgen.CallContext(JSONSchema),
                args: bindgen.Args(JSONSchema),
            ) bindgen.CallError(JSONSchema)!void {
                return this.completionFromBinding(.json, context, args);
            }

            pub fn bindSetRawMode(
                this: *JSBinding,
                context: bindgen.CallContext(SetRawModeSchema),
                args: bindgen.Args(SetRawModeSchema),
            ) bun.JSError!bindgen.Return(SetRawModeSchema) {
                if (@hasDecl(Context, "setRawMode")) {
                    return switch (this.source.get().context.setRawMode(args.enabled)) {
                        .result => null,
                        .err => |err| error_value: {
                            if (err.getErrno() == .NOMEM) return error.OutOfMemory;
                            var system_error = try bindgen.SystemError.fromSysError(err);
                            defer system_error.deinit();
                            break :error_value try system_error.toErrorInstance(context);
                        },
                    };
                }

                @compileError("setRawMode is not implemented on " ++ @typeName(Context));
            }

            pub fn bindSetFlowing(
                this: *JSBinding,
                _: bindgen.CallContext(SetFlowingSchema),
                args: bindgen.Args(SetFlowingSchema),
            ) bun.JSError!void {
                if (@hasDecl(Context, "setFlowing")) {
                    this.source.get().context.setFlowing(args.enabled);
                }
            }
        };

        const ClassSchema = ReadableStreamSourceBindings.class(name_ ++ "InternalReadableStreamSource");
        pub const Binding = bindgen.Class(ClassSchema, JSBinding);
        const OnCloseCallbackSlot = Binding.CachedSlot("onCloseCallback");
        const OnDrainCallbackSlot = Binding.CachedSlot("onDrainCallback");
        const PullNativeSchema = ClassSchema.memberKind("pullNative", .method);
        const StartSchema = ClassSchema.memberKind("start", .method);
        const IsClosedSchema = ClassSchema.memberKind("isClosed", .getter);
        const CancelSchema = ClassSchema.memberKind("cancel", .method);
        const OnCloseGetterSchema = ClassSchema.memberKind("onClose", .getter);
        const OnCloseSetterSchema = ClassSchema.memberKind("onClose", .setter);
        const OnDrainGetterSchema = ClassSchema.memberKind("onDrain", .getter);
        const OnDrainSetterSchema = ClassSchema.memberKind("onDrain", .setter);
        const CloseCallbackType = OnCloseSetterSchema.args[0].ArgumentType.child;
        const UpdateRefSchema = ClassSchema.memberKind("updateRef", .method);
        const DrainSchema = ClassSchema.memberKind("drain", .method);
        const TextSchema = ClassSchema.memberKind("text", .method);
        const ArrayBufferSchema = ClassSchema.memberKind("arrayBuffer", .method);
        const BlobSchema = ClassSchema.memberKind("blob", .method);
        const BytesSchema = ClassSchema.memberKind("bytes", .method);
        const JSONSchema = ClassSchema.memberKind("json", .method);
        const SetRawModeSchema = ClassSchema.memberKind("setRawMode", .method);
        const SetFlowingSchema = ClassSchema.memberKind("setFlowing", .method);

        comptime {
            _ = Binding;
        }
    };
}

const bun = @import("bun");
const std = @import("std");
const bindgen = bun.bindgen;
const ReadableStreamBindings = bun.bindgen.Module("readable_streams");
const ReadableStreamSourceBindings = bun.bindgen.Module("ReadableStreamSource");
const ReadableStreamTeeSchema = ReadableStreamBindings.engineShim("readableStreamTee");
const ReadableStreamCancelSchema = ReadableStreamBindings.engineShim("readableStreamCancel");
const ReadableStreamCancelWithReasonSchema = ReadableStreamBindings.engineShim("readableStreamCancelWithReason");
const PromiseSetHandledSchema = bindgen.Module("promises").engineShim("promiseSetHandled");
const ReadableStreamDetachSchema = ReadableStreamBindings.engineShim("readableStreamDetach");
const ReadableStreamCanConsumeNativeSchema = ReadableStreamBindings.engineShim("readableStreamCanConsumeNative");
const ReadableStreamIsDisturbedSchema = ReadableStreamBindings.engineShim("readableStreamIsDisturbed");
const ReadableStreamIsLockedSchema = ReadableStreamBindings.engineShim("readableStreamIsLocked");
const ReadableStreamDescribeSchema = ReadableStreamBindings.engineShim("readableStreamDescribe");
const ReadableStreamCreateNativeSchema = ReadableStreamBindings.engineShim("readableStreamCreateNative");
const BlobSourceSchema = ReadableStreamSourceBindings.class("BlobInternalReadableStreamSource");
const BytesSourceSchema = ReadableStreamSourceBindings.class("BytesInternalReadableStreamSource");
const FileSourceSchema = ReadableStreamSourceBindings.class("FileInternalReadableStreamSource");
const SubprocessClassSchema = bindgen.Module("Subprocess").class("Subprocess");
const ReadableStreamEmptyShim = ReadableStreamBindings.engineShim("readableStreamEmpty");
const ReadableStreamUsedShim = ReadableStreamBindings.engineShim("readableStreamUsed");
const Environment = bun.Environment;
const Syscall = bun.sys;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const S3StreamEngine = @import("./s3/ClientStreamEngine.zig");

const webcore = bun.webcore;
const Blob = webcore.Blob;
const streams = webcore.streams;
