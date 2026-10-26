//! The JS `Blob` class can be backed by different forms (in Blob.Store), which
//! represent different sources of Blob. For example, `Bun.file()` returns Blob
//! objects that reference the filesystem (Blob.Store.File). This is how
//! operations like writing `Store.File` to another `Store.File` knows to use a
//! basic file copy instead of a naive read write loop.

const Blob = @This();

pub const Store = @import("./blob/Store.zig");
pub const SharedBytes = @import("./blob/SharedBytes.zig");
const PathOrFileDescriptor = @import("../node/PathLike.zig").PathOrFileDescriptor;
const PathOrBlobEngine = @import("../node/PathOrBlobEngine.zig");
const NodeFSBindings = @import("../node_jsc/NodeFSBindingEngine.zig").Bindings;
const StoreEngine = @import("./blob/StoreEngine.zig");
pub const read_file = @import("./blob/read_file.zig");
pub const write_file = @import("./blob/WriteFileEngine.zig");
pub const copy_file = @import("./blob/copy_file.zig");
const CopyFileEngine = @import("./blob/CopyFileEngine.zig");

pub fn retainBytes(blob: *const Blob) SharedBytes {
    return .{
        .store = if (blob.store) |store| store.clone() else null,
        .offset = blob.offset,
        .size = blob.size,
    };
}

pub fn new(blob: *Blob) bun.OOM!*Blob {
    const result = try bun.default_allocator.create(Blob);
    result.* = blob.take();
    result.ref_count = .init(1);
    return result;
}

/// Borrows the logical blob for the class-reference call frame.
pub fn fromClassRef(view: bun.bindgen.ClassRefView(BlobSchema)) *Blob {
    return view.get(BlobJSBinding).native();
}

reported_estimated_size: usize = 0,

size: SizeType = 0,
offset: SizeType = 0,
store: ?bun.bindgen.RefNative(Store, .any) = null,
content_type: bun.bindgen.OwnedBytes = .empty(),
content_type_was_set: bool = false,

/// JavaScriptCore strings are either latin1 or UTF-16
/// When UTF-16, they're nearly always due to non-ascii characters
charset: strings.AsciiStatus = .unknown,

/// Was it created via file constructor?
is_jsdom_file: bool = false,

/// Reference count, for use with `bun.ptr.ExternalShared`. If the reference count is 0, that means
/// this blob is *not* heap-allocated, and will not be freed in `deinit`.
ref_count: bun.ptr.RawRefCount(u32, .single_threaded) = .init(0),

last_modified: f64 = 0.0,
/// Blob name will lazy initialize when getName is called, but
/// we must be able to set the name, and we need to keep the value alive
/// https://github.com/oven-sh/bun/issues/10178
name: ?bun.bindgen.ThreadSafeDOMString = null,

pub const Ref = bun.ptr.ExternalShared(Blob);

pub fn storePtr(this: *const Blob) ?*Store {
    return if (this.store) |store| store.get() else null;
}

pub const SizeType = BlobSize.SizeType;
pub const max_size = BlobSize.max_size;

/// 1: Initial
/// 2: Added byte for whether it's a dom file, length and bytes for `stored_name`,
///    and f64 for `last_modified`. Removed reserved bytes, it's handled by version
///    number.
/// 3: Added File name serialization for File objects (when is_jsdom_file is true)
/// 4: Added the byte-window size and serialize byte-backed slices without their parent bytes.
const serialization_version: u8 = 4;

pub fn hasContentTypeFromUser(this: *const Blob) bool {
    const store = this.storePtr() orelse return this.content_type_was_set;
    return this.content_type_was_set or store.data == .file or store.data == .s3;
}

pub fn contentTypeOrMimeType(this: *const Blob) ?[]const u8 {
    if (!this.content_type.isEmpty()) {
        return this.content_type.slice();
    }
    if (this.storePtr()) |store| {
        switch (store.data) {
            .file => |file| {
                return file.mime_type.value;
            },
            .s3 => |s3| {
                return s3.mime_type.value;
            },
            else => return null,
        }
    }
    return null;
}

pub fn isBunFile(this: *const Blob) bool {
    const store = this.storePtr() orelse return false;

    return store.data == .file;
}

pub const BlobReadMetadata = struct {
    content_type: bun.bindgen.OwnedBytes = .empty(),
    form_data_encoding: ?bun.FormData.OwnedEncoding = null,

    pub fn deinit(this: *BlobReadMetadata) void {
        this.content_type.deinit();
        if (this.form_data_encoding) |*encoding| encoding.deinit();
        this.* = .{};
    }

    pub fn take(this: *BlobReadMetadata) BlobReadMetadata {
        const result = this.*;
        this.* = .{};
        return result;
    }
};

pub const BlobReadPayload = union(enum) {
    bytes: struct {
        value: bun.bindgen.OwnedBytes,
        metadata: BlobReadMetadata,
    },
    blob: bun.bindgen.RefNative(Blob, .vm),
    abort_reason: jsc.CommonAbortReason,
    s3_error: S3.completions.OwnedS3Error,
    consumed: void,

    fn deinit(this: *BlobReadPayload) void {
        switch (this.*) {
            .bytes => |*result| {
                result.value.deinit();
                result.metadata.deinit();
            },
            .blob => |*blob| blob.deinit(),
            .abort_reason => {},
            .s3_error => |*err| err.deinit(),
            .consumed => {},
        }
        this.* = .{ .consumed = {} };
    }

    fn takeBytes(this: *BlobReadPayload) bun.bindgen.OwnedBytes {
        const bytes = this.bytes.value;
        this.bytes.value = .empty();
        return bytes;
    }

    fn takeBlob(this: *BlobReadPayload) *Blob {
        const blob = this.blob.take();
        this.* = .{ .consumed = {} };
        return blob;
    }
};

fn isReadableStreamBufferSchema(comptime FunctionSchema: type) bool {
    if (!@hasDecl(FunctionSchema, "owner_class_name")) return false;
    if (!std.mem.eql(u8, FunctionSchema.module_name, "ReadableStreamSource")) return false;
    const is_buffered_source = std.mem.eql(u8, FunctionSchema.owner_class_name, "BlobInternalReadableStreamSource") or
        std.mem.eql(u8, FunctionSchema.owner_class_name, "BytesInternalReadableStreamSource");
    if (!is_buffered_source) return false;
    inline for (.{ "arrayBuffer", "blob", "bytes", "json", "text" }) |name| {
        if (std.mem.eql(u8, FunctionSchema.js_name, name)) return true;
    }
    return false;
}

fn isBlobReadFormDataSchema(comptime FunctionSchema: type) bool {
    return bun.bindgen.Return(FunctionSchema) == bun.bindgen.ClassRef(FormDataSchema);
}

fn isBlobReadJSONSchema(comptime FunctionSchema: type) bool {
    return bun.bindgen.Return(FunctionSchema) == bun.bindgen.AnyResult;
}

fn isBlobReadTextSchema(comptime FunctionSchema: type) bool {
    return bun.bindgen.Return(FunctionSchema) == bun.bindgen.DOMString;
}

fn blobTextFromBytes(bytes: []const u8) error{ OutOfMemory, StringTooLong }!bun.bindgen.DOMString {
    const bom, const contents = strings.BOM.detectAndSplit(bytes);
    if (contents.len == 0) return .empty();

    const allocated_utf16 = if (bom == .utf16_le) null else try strings.toUTF16Alloc(bun.default_allocator, contents, false, false);
    defer if (allocated_utf16) |units| bun.default_allocator.free(units);
    const text: bun.TextView = if (bom == .utf16_le)
        .{ .utf16 = bun.reinterpretSlice(u16, contents) }
    else if (allocated_utf16) |units|
        .{ .utf16 = units }
    else
        .{ .latin1 = contents };
    if (text.len() > bun.String.max_length()) return error.StringTooLong;
    return bun.bindgen.DOMString.fromTextView(text);
}

pub const BlobReadCompletionOps = struct {
    pub fn materialize(
        comptime FunctionSchema: type,
        context: bun.bindgen.MaterializationContext(FunctionSchema),
        payload: *BlobReadPayload,
    ) bun.bindgen.MaterializationError(FunctionSchema)!bun.bindgen.Return(FunctionSchema) {
        switch (payload.*) {
            .abort_reason => |reason| {
                if (comptime !isReadableStreamBufferSchema(FunctionSchema) and !jsc.WebCore.Body.isConsumptionCompletion(FunctionSchema)) {
                    @panic("Blob read completion received an abort reason for an incompatible schema");
                }
                const operation = context.engineIn("abort_signals", "commonAbortReasonToJS");
                var error_value = try operation.call(.{
                    .value = reason.toBinding(@FieldType(@TypeOf(operation).Args, "value")),
                });
                defer error_value.deinit();
                var error_root = try error_value.toRoot();
                return context.reject(&error_root, .{ .attach_async_stack = true });
            },
            .s3_error => |*err| {
                return context.fail(.s3, err.takeFailure());
            },
            .bytes => {},
            .blob => {
                if (comptime bun.bindgen.Return(FunctionSchema) != bun.bindgen.ClassRef(BlobSchema)) {
                    @panic("Blob read completion received a Blob for a non-Blob result");
                }
                const blob = payload.takeBlob();
                const binding = try BlobJSBinding.create(blob);
                return BlobClass.adoptResult(binding, context);
            },
            .consumed => @panic("Blob read completion payload was consumed twice"),
        }

        if (comptime bun.bindgen.Return(FunctionSchema) == bun.bindgen.OwnedBytes) {
            if (comptime FunctionSchema.ReturnType.buffer_result_representation == .uint8_array) {
                if (payload.bytes.value.slice().len > bun.JavaScriptLimits.syntheticAllocationLimit())
                    return context.fail(.bytes_too_large, {});
            }
            return payload.takeBytes();
        }

        if (comptime isBlobReadTextSchema(FunctionSchema) or isBlobReadJSONSchema(FunctionSchema)) {
            var text = blobTextFromBytes(payload.bytes.value.slice()) catch |err| switch (err) {
                error.StringTooLong => return context.fail(.string_too_long, {}),
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (comptime isBlobReadTextSchema(FunctionSchema)) return text;
            defer text.deinit();
            return context.engineIn("js_strings", "parseJSONFromString").call(.{ .value = text.operand() });
        }

        if (comptime isBlobReadFormDataSchema(FunctionSchema)) {
            const encoding = if (payload.bytes.metadata.form_data_encoding) |*owned|
                owned.view()
            else
                bun.FormData.Encoding.get(payload.bytes.metadata.content_type.slice()) orelse
                    return context.fail(.invalid_form_data_encoding, {});
            return FormDataEngine.toClassRef(context, payload.bytes.value.slice(), encoding) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.JSError => return error.JSError,
                error.JSTerminated => return error.JSTerminated,
                else => {
                    const message_bytes = try std.fmt.allocPrint(bun.default_allocator, if (FunctionSchema == BlobFormDataSchema)
                        "FormData encoding failed: {s}"
                    else
                        "FormData parse error {s}", .{@errorName(err)});
                    defer bun.default_allocator.free(message_bytes);
                    return context.fail(.form_data_parse_failed, try bun.bindgen.ThreadSafeDOMString.fromUTF8(message_bytes));
                },
            };
        }

        if (comptime bun.bindgen.Return(FunctionSchema) == bun.bindgen.ClassRef(BlobSchema)) {
            @panic("Blob read completion received bytes for a Blob result");
        }

        @compileError("unknown Blob read completion schema");
    }

    pub fn destroyPayload(payload: *BlobReadPayload) void {
        payload.deinit();
        bun.destroy(payload);
    }

};

const BlobReadCompletions = bun.bindgen.MaterializedCompletionSet(.{
    BlobArrayBufferSchema,
    BlobBytesSchema,
    BlobFormDataSchema,
    BlobJSONSchema,
    BlobTextSchema,
}, BlobReadPayload, BlobReadCompletionOps);

fn blobReadMetadata(comptime FunctionSchema: type, this: *const Blob) bun.OOM!BlobReadMetadata {
    if (comptime !isBlobReadFormDataSchema(FunctionSchema)) return .{};
    return .{ .content_type = try bun.bindgen.OwnedBytes.fromSlice(this.content_type.slice()) };
}

pub fn startBlobRead(
    this: *Blob,
    global: *JSGlobalObject,
    completion: anytype,
    metadata: BlobReadMetadata,
) void {
    const Completion = @TypeOf(completion);
    const PayloadOwner = bun.bindgen.OwnedNativeWithDestructor(BlobReadPayload, BlobReadCompletionOps.destroyPayload, .vm);
    var owned_completion = completion;
    var owned_metadata = metadata;
    const payload = bun.default_allocator.create(BlobReadPayload) catch {
        owned_metadata.deinit();
        owned_completion.outOfMemory();
        return;
    };
    payload.* = .{ .bytes = .{ .value = .empty(), .metadata = owned_metadata.take() } };
    var payload_owner = PayloadOwner.init(payload);
    defer payload_owner.deinit();

    if (this.needsToReadFile()) {
        const Handler = struct {
            completion: Completion,
            payload: PayloadOwner,

            pub fn run(handler: *@This(), result: read_file.ReadFileResultType) void {
                defer {
                    handler.payload.deinit();
                    bun.destroy(handler);
                }
                switch (result) {
                    .result => |read| {
                        handler.payload.get().bytes.value = .fromDefaultAllocatedSlice(read.buf);
                        handler.completion.complete(handler.payload.take());
                    },
                    .err => |err| handler.completion.fail(.system, err),
                    .out_of_memory => handler.completion.outOfMemory(),
                    .cancelled => handler.completion.release(),
                }
            }
        };
        const handler = bun.default_allocator.create(Handler) catch {
            owned_completion.outOfMemory();
            return;
        };
        handler.* = .{ .completion = owned_completion, .payload = .init(payload_owner.take()) };
        this.doReadFileInternal(*Handler, handler, Handler.run, global) catch {
            handler.payload.deinit();
            handler.completion.outOfMemory();
            bun.destroy(handler);
        };
        return;
    }

    if (this.isS3()) {
        const Task = struct {
            blob: Blob,
            completion: Completion,
            payload: PayloadOwner,
            global: *JSGlobalObject,
            poll_ref: bun.Async.KeepAlive = .{},

            fn deinit(task: *@This()) void {
                task.payload.deinit();
                task.blob.deinit();
                task.poll_ref.unref(task.global.bunVM());
                bun.destroy(task);
            }

            fn onComplete(result: S3.S3DownloadResult, opaque_task: S3.CallbackContext) void {
                const task = opaque_task.get(*@This());
                defer task.deinit();
                switch (result) {
                    .out_of_memory => task.completion.outOfMemory(),
                    .success => |response| {
                        var body = response.body;
                        const bytes = body.list.toOwnedSlice(body.allocator) catch {
                            body.deinit();
                            task.completion.outOfMemory();
                            return;
                        };
                        body.deinit();
                        task.payload.get().bytes.value = .fromDefaultAllocatedSlice(bytes);
                        task.completion.complete(task.payload.take());
                    },
                    inline .not_found, .failure => |err| {
                        const path = task.blob.storePtr().?.getPath();
                        const owned_error = S3.completions.OwnedS3Error.init(err, path) catch {
                            task.completion.outOfMemory();
                            return;
                        };
                        task.payload.get().deinit();
                        task.payload.get().* = .{ .s3_error = owned_error };
                        task.completion.complete(task.payload.take());
                    },
                }
            }
        };
        var copy = this.dupe() catch {
            owned_completion.outOfMemory();
            return;
        };
        const task = bun.default_allocator.create(Task) catch {
            copy.deinit();
            owned_completion.outOfMemory();
            return;
        };
        task.* = .{
            .blob = copy,
            .completion = owned_completion,
            .payload = .init(payload_owner.take()),
            .global = global,
        };
        task.poll_ref.ref(global.bunVM());
        const env = global.bunVM().transpiler.env;
        const s3_store = &task.blob.storePtr().?.data.s3;
        const proxy = if (env.getHttpProxy(true, null, null)) |value| value.href else null;
        if (task.blob.offset > 0 or task.blob.size != Blob.max_size) {
            const len: ?usize = if (task.blob.size != Blob.max_size) @intCast(task.blob.size) else null;
            S3.downloadSlice(
                s3_store.getCredentials(),
                s3_store.path(),
                @intCast(task.blob.offset),
                len,
                Task.onComplete,
                .init(task),
                proxy,
                s3_store.request_payer,
            );
        } else {
            S3.download(
                s3_store.getCredentials(),
                s3_store.path(),
                Task.onComplete,
                .init(task),
                proxy,
                s3_store.request_payer,
            );
        }
        return;
    }

    const bytes = bun.bindgen.OwnedBytes.fromSlice(this.sharedView()) catch {
        owned_completion.outOfMemory();
        return;
    };
    payload_owner.get().bytes.value = bytes;
    owned_completion.complete(payload_owner.take());
}

fn completeBlobReadFromContext(
    comptime FunctionSchema: type,
    this: *Blob,
    global: *JSGlobalObject,
    context: bun.bindgen.CallContext(FunctionSchema),
) bun.OOM!void {
    var metadata = try blobReadMetadata(FunctionSchema, this);
    errdefer metadata.deinit();
    var view = context.completion();
    const completion = BlobReadCompletions.take(FunctionSchema, &view);
    startBlobRead(this, global, completion, metadata.take());
}

pub fn NewInternalReadFileHandler(comptime Context: type, comptime Function: anytype) type {
    return struct {
        pub fn run(handler: *anyopaque, bytes: read_file.ReadFileResultType) void {
            Function(bun.cast(Context, handler), bytes);
        }
    };
}

/// Transfers default-allocator bytes or a portable error to the callback on the VM thread.
pub fn readBytesToHandler(this: *Blob, comptime Handler: type, ctx: *Handler, global: *JSGlobalObject) bun.OOM!void {
    if (this.needsToReadFile()) {
        const Adapter = struct {
            fn run(c: *Handler, r: read_file.ReadFileResultType) void {
                Handler.onReadBytes(c, switch (r) {
                    .result => |b| .{ .ok = b.buf },
                    .err => |e| .{ .err = e },
                    .out_of_memory => .out_of_memory,
                    .cancelled => .cancelled,
                });
            }
        };
        return this.doReadFileInternal(*Handler, ctx, Adapter.run, global);
    }
    if (this.isS3()) {
        const Task = struct {
            ctx: *Handler,
            blob: Blob, // dupe for store ref + offset/size
            poll: bun.Async.KeepAlive = .{},
            vm: *jsc.VirtualMachine,

            fn done(t: *@This(), r: ReadBytesResult) void {
                t.poll.unref(t.vm);
                t.blob.deinit();
                const c = t.ctx;
                bun.destroy(t);
                Handler.onReadBytes(c, r);
            }
            fn cb(result: S3.S3DownloadResult, opaque_self: S3.CallbackContext) void {
                const t = opaque_self.get(*@This());
                switch (result) {
                    .out_of_memory => t.done(.out_of_memory),
                    .success => |response| {
                        var body = response.body;
                        defer body.deinit();
                        const bytes = body.list.toOwnedSlice(body.allocator) catch return t.done(.out_of_memory);
                        t.done(.{ .ok = bytes });
                    },
                    inline .not_found, .failure => |e| {
                        const payload = bun.bindgen.SystemError.init(.{
                            .errno = 0,
                            .code = e.code,
                            .message = e.message,
                            .path = t.blob.storePtr().?.getPath() orelse "",
                            .syscall = "fetch",
                        }) catch return t.done(.out_of_memory);
                        t.done(.{ .err = payload });
                    },
                }
            }
        };
        const t = try bun.default_allocator.create(Task);
        errdefer bun.destroy(t);
        t.* = .{ .ctx = ctx, .blob = try this.dupe(), .vm = global.bunVM() };
        t.poll.ref(t.vm);
        const env = t.vm.transpiler.env;
        const cred = t.blob.storePtr().?.data.s3.getCredentials();
        const path = t.blob.storePtr().?.data.s3.path();
        const proxy = if (env.getHttpProxy(true, null, null)) |p| p.href else null;
        const payer = t.blob.storePtr().?.data.s3.request_payer;
        if (this.offset > 0 or this.size != Blob.max_size) {
            const len: ?usize = if (this.size != Blob.max_size) @intCast(this.size) else null;
            S3.downloadSlice(cred, path, @intCast(this.offset), len, Task.cb, .init(t), proxy, payer);
        } else {
            S3.download(cred, path, Task.cb, .init(t), proxy, payer);
        }
        return;
    }
    // In-memory or detached.
    const view = this.sharedView();
    const owned = try bun.default_allocator.dupe(u8, view);
    Handler.onReadBytes(ctx, .{ .ok = owned });
}

pub const ReadBytesResult = union(enum) {
    /// `bun.default_allocator`-owned by the callback.
    ok: []u8,
    err: bun.bindgen.SystemError,
    out_of_memory,
    cancelled,

    pub fn deinit(this: *ReadBytesResult) void {
        switch (this.*) {
            .ok => |bytes| bun.default_allocator.free(bytes),
            .err => |*err| err.deinit(),
            .out_of_memory, .cancelled => {},
        }
    }
};

/// `Bun.file("…").image(opts?)` ≡ `new Bun.Image(this, opts?)`. Lives here so
/// the proto entry covers Blob/BunFile/S3File in one place; the actual
/// construction is `Image.fromBlobResult` so Blob.zig doesn't grow image
/// knowledge.
fn doImageWithOptions(context: anytype, blob: *const Blob, options: Image.ConstructorOptions) bun.JSError!bun.bindgen.Return(BlobImageSchema) {
    return Image.fromBlobResult(context, blob, options);
}

pub fn doReadFileInternal(this: *Blob, comptime Handler: type, ctx: Handler, comptime Function: anytype, global: *JSGlobalObject) bun.OOM!void {
    if (Environment.isWindows) {
        const ReadFileHandler = NewInternalReadFileHandler(Handler, Function);
        return ReadFileEngine.startUV(global.bunVM().eventLoop(), this.storePtr().?, this.offset, this.size, ReadFileHandler, ctx);
    }
    const file_read = try read_file.ReadFile.createWithCtx(
        this.storePtr().?,
        ctx,
        NewInternalReadFileHandler(Handler, Function).run,
        this.offset,
        this.size,
    );
    errdefer file_read.deinitUnscheduled();
    const read_file_task = try ReadFileEngine.Task.createOnJSThread(global, file_read);
    read_file_task.schedule();
}

const FormDataContext = struct {
    buffer: std.array_list.Managed(u8),
    boundary: []const u8,
    globalThis: *jsc.JSGlobalObject,

    pub fn onEntry(this: *FormDataContext, name: bun.TextView, entry: jsc.DOMFormData.FormDataEntry) bun.JSError!void {
        var globalThis = this.globalThis;
        const allocator = this.buffer.allocator;
        const buffer = &this.buffer;
        const boundary = this.boundary;

        try buffer.appendSlice("--");
        try buffer.appendSlice(boundary);
        try buffer.appendSlice("\r\nContent-Disposition: form-data; name=\"");
        const name_slice = try name.toSlice(allocator);
        defer name_slice.deinit();
        try buffer.appendSlice(name_slice.slice());

        switch (entry) {
            .string => |value| {
                try buffer.appendSlice("\"\r\n\r\n");
                const value_slice = try value.toSlice(allocator);
                defer value_slice.deinit();
                try buffer.appendSlice(value_slice.slice());
            },
            .file => |value| {
                try buffer.appendSlice("\"; filename=\"");
                const filename_slice = try value.filename.toSlice(allocator);
                defer filename_slice.deinit();
                try buffer.appendSlice(filename_slice.slice());
                try buffer.appendSlice("\"\r\n");

                const blob = value.blob;
                const content_type = if (!blob.content_type.isEmpty()) blob.content_type.slice() else "application/octet-stream";
                try buffer.appendSlice("Content-Type: ");
                try buffer.appendSlice(content_type);
                try buffer.appendSlice("\r\n\r\n");

                if (blob.storePtr()) |store| {
                    if (blob.size == Blob.max_size) {
                        blob.resolveSize();
                    }
                    switch (store.data) {
                        .s3 => {
                            // TODO: s3
                            // we need to make this async and use download/downloadSlice
                        },
                        .file => |file| {

                            // TODO: make this async + lazy
                            const res = bun.api.node.fs.NodeFS.readFile(
                                globalThis.bunVM().nodeFS(),
                                .{
                                    .encoding = .buffer,
                                    .path = file.pathlike,
                                    .offset = blob.offset,
                                    .max_size = blob.size,
                                },
                                .sync,
                            );

                            switch (res) {
                                .err => |err| return bun.api.SystemErrorBindings.throwSysError(err, globalThis),
                                .result => |result| {
                                    var owned_result = result;
                                    defer owned_result.deinit();
                                    try buffer.appendSlice(owned_result.slice());
                                },
                            }
                        },
                        .bytes => {
                            try buffer.appendSlice(blob.sharedView());
                        },
                    }
                }
            },
        }

        try buffer.appendSlice("\r\n");
    }
};

pub fn getContentType(
    this: *Blob,
) ?bun.String.Slice {
    if (!this.content_type.isEmpty())
        return bun.String.Slice.fromUTF8NeverFree(this.content_type.slice());

    return null;
}

fn _onStructuredCloneSerialize(
    this: *Blob,
    writer: bun.bindgen.StructuredCloneWriter,
) bun.OOM!void {
    this.resolveSize();
    const store = this.storePtr();
    const bytes = if (store) |value|
        if (value.data == .bytes) this.sharedView() else null
    else
        null;

    const offset = if (bytes != null or store == null) 0 else this.offset;
    const size = if (bytes) |value| value.len else if (store == null) 0 else this.size;
    try writer.writeInt(u8, serialization_version, .little);
    try writer.writeInt(u64, @intCast(offset), .little);
    try writer.writeInt(u64, @intCast(size), .little);

    const content_type_length = std.math.cast(u32, this.content_type.length()) orelse return error.OutOfMemory;
    try writer.writeInt(u32, content_type_length, .little);
    try writer.writeAll(this.content_type.slice());
    try writer.writeInt(u8, @intFromBool(this.content_type_was_set), .little);

    const store_tag: Store.SerializeTag = if (store) |value|
        if (value.data == .bytes) .bytes else .file
    else
        .empty;

    try writer.writeInt(u8, @backingInt(store_tag), .little);

    if (store) |value| {
        if (bytes) |view|
            try value.serializeByteView(view, bun.bindgen.StructuredCloneWriter, writer)
        else
            try value.serialize(bun.bindgen.StructuredCloneWriter, writer);
    }

    try writer.writeInt(u8, @intFromBool(this.is_jsdom_file), .little);
    try writer.writeInt(u64, @bitCast(this.last_modified), .little);

    // Serialize File name if this is a File object
    if (this.is_jsdom_file) {
        if (try this.getNameString()) |name_string| {
            const name_slice = try name_string.toUTF8(bun.default_allocator);
            defer name_slice.deinit();
            const name_length = std.math.cast(u32, name_slice.slice().len) orelse return error.OutOfMemory;
            try writer.writeInt(u32, name_length, .little);
            try writer.writeAll(name_slice.slice());
        } else {
            // No name available, write empty string
            try writer.writeInt(u32, 0, .little);
        }
    }
}

fn readSlice(
    reader: *std.Io.Reader,
    len: usize,
    allocator: std.mem.Allocator,
) ![]u8 {
    const slice = try allocator.alloc(u8, len);
    errdefer allocator.free(slice);
    reader.readSliceAll(slice) catch |err| switch (err) {
        error.EndOfStream => return error.TooSmall,
        error.ReadFailed => return error.ReadFailed,
    };
    return slice;
}

fn _onStructuredCloneDeserialize(
    globalThis: *jsc.JSGlobalObject,
    reader: *std.Io.Reader,
) !*Blob {
    const allocator = bun.default_allocator;

    const version = try reader.takeInt(u8, .little);
    if (version == 0 or version > serialization_version) return error.InvalidData;

    const offset = try reader.takeInt(u64, .little);
    const serialized_size = if (version >= 4) try reader.takeInt(u64, .little) else null;

    const content_type_len = try reader.takeInt(u32, .little);

    var content_type = try bun.bindgen.OwnedBytes.initUninitialized(content_type_len);
    errdefer content_type.deinit();
    reader.readSliceAll(content_type.mutableSlice()) catch |err| switch (err) {
        error.EndOfStream => return error.TooSmall,
        error.ReadFailed => return error.ReadFailed,
    };

    const content_type_was_set: bool = try reader.takeInt(u8, .little) != 0;

    const store_tag = try reader.takeEnum(Store.SerializeTag, .little);

    const blob: *Blob = switch (store_tag) {
        .bytes => bytes: {
            const bytes_len = try reader.takeInt(u32, .little);
            const bytes = try readSlice(reader, bytes_len, allocator);

            var blob = try Blob.init(bytes, allocator);
            // `blob` now owns `bytes` (via its Store when non-empty). If any
            // of the remaining reads fail before we heap-promote it, release
            // the store so the payload bytes don't leak.
            errdefer blob.deinit();

            versions: {
                if (version == 1) break :versions;

                const name_len = try reader.takeInt(u32, .little);
                const name = try readSlice(reader, name_len, allocator);

                var name_consumed = false;
                if (blob.storePtr()) |store| switch (store.data) {
                    .bytes => |*bytes_store| {
                        bytes_store.stored_name = .fromOwnedSlice(allocator, name);
                        name_consumed = true;
                    },
                    else => {},
                };
                if (!name_consumed) allocator.free(name);

                if (version == 2) break :versions;
            }

            break :bytes try Blob.new(&blob);
        },
        .file => file: {
            const pathlike_tag = try reader.takeEnum(bun.api.node.PathOrFileDescriptor.SerializeTag, .little);

            switch (pathlike_tag) {
                .fd => {
                    const fd: bun.FD = @bitCast(try reader.takeInt(Store.SerializedFileDescriptor, .little));
                    if (fd.number() < 0) return error.InvalidData;

                    var path_or_fd = bun.api.node.PathOrFileDescriptor{
                        .fd = fd,
                    };
                    var blob = try Blob.findOrCreateFileFromPath(
                        &path_or_fd,
                        globalThis,
                        true,
                    );
                    defer blob.deinit();
                    break :file try Blob.new(&blob);
                },
                .path => {
                    const path_len = try reader.takeInt(u32, .little);

                    const path = try readSlice(reader, path_len, default_allocator);
                    if (std.mem.indexOfScalar(u8, path, 0) != null) {
                        allocator.free(path);
                        return error.InvalidData;
                    }
                    var dest = bun.api.node.PathOrFileDescriptor{
                        .path = .{
                            .encoded_slice = bun.String.Slice.init(allocator, path),
                        },
                    };
                    defer dest.deinit();
                    var blob = try Blob.findOrCreateFileFromPath(
                        &dest,
                        globalThis,
                        true,
                    );
                    defer blob.deinit();
                    break :file try Blob.new(&blob);
                },
            }
        },
        .empty => empty: {
            var blob = Blob.initEmpty();
            break :empty try Blob.new(&blob);
        },
    };
    // `blob` is heap-allocated past this point; on any remaining error
    // (truncated trailer fields) tear down both the heap object and its store.
    errdefer blob.deinit();

    versions: {
        if (version == 1) break :versions;

        blob.is_jsdom_file = try reader.takeInt(u8, .little) != 0;
        blob.last_modified = @bitCast(try reader.takeInt(u64, .little));

        if (version == 2) break :versions;

        // Version 3 and later: Read File name if this is a File object
        if (blob.is_jsdom_file) {
            const name_len = try reader.takeInt(u32, .little);
            const name_bytes = try readSlice(reader, name_len, allocator);
            defer allocator.free(name_bytes);
            blob.name = try bun.bindgen.ThreadSafeDOMString.fromUTF8(name_bytes);
        }

        if (version >= 3) break :versions;
    }

    if (blob.is_jsdom_file and blob.name == null) {
        blob.name = try bun.bindgen.ThreadSafeDOMString.fromUTF8("");
    }

    bun.assertf(blob.isHeapAllocated(), "expected blob to be heap-allocated", .{});

    // `offset` comes from untrusted bytes. Clamp it so a crafted payload cannot
    // make sharedView() slice past the end of the backing store (OOB heap read
    // in ReleaseFast). For bytes stores this also keeps `size` within bounds;
    // file/s3 stores report `max_size` here and are bounded by the filesystem
    // read path instead.
    blob.offset = @intCast(@min(offset, @as(u64, Blob.max_size)));
    const requested_size: ?SizeType = if (serialized_size) |size|
        @intCast(@min(size, @as(u64, Blob.max_size)))
    else
        null;
    if (blob.storePtr()) |store| {
        const store_size = store.size();
        if (store_size != Blob.max_size) {
            blob.offset = @min(blob.offset, store_size);
            const available = store_size - blob.offset;
            blob.size = @min(requested_size orelse available, available);
        } else if (requested_size) |size| {
            blob.size = size;
        }
    } else {
        blob.offset = 0;
        blob.size = 0;
    }

    if (!content_type.isEmpty()) {
        blob.content_type.deinit();
        blob.content_type = content_type.take();
        blob.content_type_was_set = content_type_was_set;
    }

    return blob;
}

pub fn fromURLSearchParams(
    allocator: std.mem.Allocator,
    search_params: *jsc.URLSearchParams,
) bun.OOM!Blob {
    var serialized = try search_params.toString();
    defer serialized.deinit();
    const bytes = try serialized.toOwnedSlice(allocator);
    var store = try Blob.Store.init(bytes, allocator);
    store.mime_type = MimeType.Compact.from(.@"application/x-www-form-urlencoded").toMimeType();

    var blob = try Blob.initWithStore(store);
    errdefer blob.deinit();
    try blob.setContentType(store.mime_type.value, .explicit);
    return blob;
}

pub fn fromDOMFormData(
    globalThis: *jsc.JSGlobalObject,
    allocator: std.mem.Allocator,
    form_data: *jsc.DOMFormData,
) bun.JSError!Blob {
    var hex_buf: [70]u8 = undefined;
    const boundary = brk: {
        var random = globalThis.bunVM().rareData().nextUUID().bytes;
        break :brk std.fmt.bufPrint(&hex_buf, "----WebKitFormBoundary{x}", .{&random}) catch unreachable;
    };

    var context = FormDataContext{
        .buffer = .init(allocator),
        .boundary = boundary,
        .globalThis = globalThis,
    };
    defer context.buffer.deinit();

    try form_data.forEach(FormDataContext, &context, FormDataContext.onEntry);
    try context.buffer.appendSlice("--");
    try context.buffer.appendSlice(boundary);
    try context.buffer.appendSlice("--\r\n");

    const content_type = try std.fmt.allocPrint(bun.default_allocator, "multipart/form-data; boundary={s}", .{boundary});
    errdefer bun.default_allocator.free(content_type);
    var blob = try Blob.init(try context.buffer.toOwnedSlice(), allocator);
    blob.setContentTypeOwned(content_type, .explicit);

    return blob;
}

pub fn contentType(this: *const Blob) string {
    return this.content_type.slice();
}

pub const ContentTypeOrigin = enum { inferred, explicit };

pub fn setContentType(this: *Blob, value: []const u8, origin: ContentTypeOrigin) bun.OOM!void {
    const owned = try bun.bindgen.OwnedBytes.fromSlice(value);
    this.content_type.deinit();
    this.content_type = owned;
    this.content_type_was_set = origin == .explicit;
}

pub fn setContentTypeOwned(this: *Blob, value: []u8, origin: ContentTypeOrigin) void {
    this.content_type.deinit();
    this.content_type = .fromDefaultAllocatedSlice(value);
    this.content_type_was_set = origin == .explicit;
}

fn clearContentType(this: *Blob, origin: ContentTypeOrigin) void {
    this.content_type.deinit();
    this.content_type_was_set = origin == .explicit;
}

fn setASCIIContentType(this: *Blob, globalThis: *jsc.JSGlobalObject, value: []const u8) bun.OOM!void {
    bun.debugAssert(strings.isAllASCII(value));
    this.clearContentType(.explicit);
    if (value.len == 0) return;
    if (globalThis.bunVM().mimeType(value)) |mime| {
        return this.setContentType(mime.value, .explicit);
    }
    const storage = try bun.default_allocator.alloc(u8, value.len);
    _ = strings.copyLowercase(value, storage);
    this.setContentTypeOwned(storage, .explicit);
}

pub fn isDetached(this: *const Blob) bool {
    return this.store == null;
}

fn setAsFileForBindings(this: *Blob, filename: bun.bindgen.DOMStringView) bun.OOM!void {
    if (filename.length() > 0) {
        var owned = filename.toOwned();
        defer owned.deinit();
        const name = try owned.toThreadSafe();
        if (this.name) |*old| old.deinit();
        this.name = name;
    }
    if (!this.is_jsdom_file) this.last_modified = @floatFromInt(bun.timespec.realNow().ms());
    this.is_jsdom_file = true;
}

fn cloneForBindings(this: *Blob) bun.OOM!*Blob {
    var copy = try this.dupe();
    defer copy.deinit();
    return new(&copy);
}

fn bindBlobCloneAsFile(args: bun.bindgen.Args(BlobCloneAsFileSchema)) bun.OOM!bun.bindgen.Return(BlobCloneAsFileSchema) {
    const clone = try cloneForBindings(@ptrCast(@alignCast(args.blob)));
    errdefer clone.deref();
    try setAsFileForBindings(clone, args.filename);
    return bun.bindgen.Return(BlobCloneAsFileSchema).initNative(clone);
}

fn bindBlobFileName(args: bun.bindgen.Args(BlobFileNameSchema)) bun.OOM!bun.bindgen.Return(BlobFileNameSchema) {
    const blob: *Blob = @ptrCast(@alignCast(args.blob));
    if (blob.name) |name| {
        var owned = name.clone();
        return bun.bindgen.DOMString.fromBunString(owned.takeBunString());
    }
    return bun.bindgen.DOMString.fromUTF8(blob.getFileName() orelse "");
}

pub fn writeFormatForSize(is_jdom_file: bool, size: usize, writer: anytype, comptime enable_ansi_colors: bool) !void {
    if (is_jdom_file) {
        try writer.writeAll(comptime Output.prettyFmt("<r>File<r>", enable_ansi_colors));
    } else {
        try writer.writeAll(comptime Output.prettyFmt("<r>Blob<r>", enable_ansi_colors));
    }
    try writer.print(
        comptime Output.prettyFmt(" (<yellow>{f}<r>)", enable_ansi_colors),
        .{
            bun.fmt.size(size, .{}),
        },
    );
}

pub fn writeFormat(this: *Blob, comptime Formatter: type, formatter: *Formatter, writer: anytype, comptime enable_ansi_colors: bool) !void {
    const Writer = @TypeOf(writer);

    if (this.isDetached()) {
        // A blob with no store and size > 0 was genuinely detached (e.g. after
        // transferring its contents). An empty `new Blob([])` or `new File([])`
        // also has no store but is a valid zero-byte blob — render it like a
        // normal zero-sized blob instead of calling it "detached".
        if (this.size > 0) {
            if (this.is_jsdom_file) {
                try writer.writeAll(comptime Output.prettyFmt("<d>[<r>File<r> detached<d>]<r>", enable_ansi_colors));
            } else {
                try writer.writeAll(comptime Output.prettyFmt("<d>[<r>Blob<r> detached<d>]<r>", enable_ansi_colors));
            }
            return;
        }

        try writeFormatForSize(this.is_jsdom_file, 0, writer, enable_ansi_colors);
    } else {
        const store = this.storePtr().?;
        switch (store.data) {
            .s3 => |*s3| {
                try S3File.writeFormat(s3, Formatter, formatter, writer, enable_ansi_colors, this.content_type.slice(), this.offset);
            },
            .file => |file| {
                try writer.writeAll(comptime Output.prettyFmt("<r>FileRef<r>", enable_ansi_colors));
                switch (file.pathlike) {
                    .path => |path| {
                        try writer.print(
                            comptime Output.prettyFmt(" (<green>\"{s}\"<r>)<r>", enable_ansi_colors),
                            .{
                                path.slice(),
                            },
                        );
                    },
                    .fd => |fd| {
                        if (Environment.isWindows) {
                            switch (fd.decodeWindows()) {
                                .uv => |uv_file| try writer.print(
                                    comptime Output.prettyFmt(" (<r>fd<d>:<r> <yellow>{d}<r>)<r>", enable_ansi_colors),
                                    .{uv_file},
                                ),
                                .windows => |handle| {
                                    if (Environment.isDebug) {
                                        @panic("this shouldn't be reachable.");
                                    }
                                    try writer.print(
                                        comptime Output.prettyFmt(" (<r>fd<d>:<r> <yellow>0x{x}<r>)<r>", enable_ansi_colors),
                                        .{@intFromPtr(handle)},
                                    );
                                },
                            }
                        } else {
                            try writer.print(
                                comptime Output.prettyFmt(" (<r>fd<d>:<r> <yellow>{d}<r>)<r>", enable_ansi_colors),
                                .{fd.native()},
                            );
                        }
                    },
                }
            },
            .bytes => {
                try writeFormatForSize(this.is_jsdom_file, this.size, writer, enable_ansi_colors);
            },
        }
    }

    const name: ?*const bun.bindgen.ThreadSafeDOMString = if (this.is_jsdom_file)
        try this.getNameString()
    else if (this.name) |*value|
        value
    else
        null;
    const show_name = name != null and (this.is_jsdom_file or
        (!name.?.isEmpty() and this.storePtr() != null and this.storePtr().?.data == .bytes));
    if (!this.isS3() and (!this.content_type.isEmpty() or this.offset > 0 or show_name or this.last_modified != 0.0)) {
        try writer.writeAll(" {\n");
        {
            formatter.indent += 1;
            defer formatter.indent -= 1;

            if (show_name) {
                try formatter.writeIndent(Writer, writer);

                try writer.print(
                    comptime Output.prettyFmt("name<d>:<r> <green>\"{f}\"<r>", enable_ansi_colors),
                    .{
                        name.?.*,
                    },
                );

                if (!this.content_type.isEmpty() or this.offset > 0 or this.last_modified != 0) {
                    try formatter.printComma(Writer, writer, enable_ansi_colors);
                }

                try writer.writeAll("\n");
            }

            if (!this.content_type.isEmpty()) {
                try formatter.writeIndent(Writer, writer);
                try writer.print(
                    comptime Output.prettyFmt("type<d>:<r> <green>\"{s}\"<r>", enable_ansi_colors),
                    .{
                        this.content_type.slice(),
                    },
                );

                if (this.offset > 0 or this.last_modified != 0) {
                    try formatter.printComma(Writer, writer, enable_ansi_colors);
                }

                try writer.writeAll("\n");
            }

            if (this.offset > 0) {
                try formatter.writeIndent(Writer, writer);

                try writer.print(
                    comptime Output.prettyFmt("offset<d>:<r> <yellow>{d}<r>\n", enable_ansi_colors),
                    .{
                        this.offset,
                    },
                );

                if (this.last_modified != 0) {
                    try formatter.printComma(Writer, writer, enable_ansi_colors);
                }

                try writer.writeAll("\n");
            }

            if (this.last_modified != 0) {
                try formatter.writeIndent(Writer, writer);

                try writer.print(
                    comptime Output.prettyFmt("lastModified<d>:<r> <yellow>{d}<r>\n", enable_ansi_colors),
                    .{
                        this.last_modified,
                    },
                );
            }
        }

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll("}");
    }
}

fn writeFileWithEmptySourceToDestination(ctx: *jsc.JSGlobalObject, destination_blob: *Blob, options: WriteFileOptions, acceptor: *WriteAcceptor) bun.JSError!void {
    const destination_store = destination_blob.storePtr().?;

    switch (destination_store.data) {
        .file => {
            var source = try Blob.initWithStore(try Store.init(&.{}, bun.default_allocator));
            defer source.deinit();
            return writeFileWithSourceDestination(ctx, &source, destination_blob, options, acceptor);
        },
        .s3 => |*s3| {

            // create empty file
            var s3_options = try WriteS3Options.init(s3, options, ctx);
            defer s3_options.deinit();
            const aws_options = s3_options.get();

            const Wrapper = struct {
                acceptor: WriteAcceptor,
                store: *Store,

                pub fn resolve(result: S3.S3UploadResult, opaque_this: S3.CallbackContext) void {
                    const this = opaque_this.get(*@This());
                    defer this.deinit();
                    switch (result) {
                        .success => this.acceptor.complete(.{ .written = 0 }),
                        .out_of_memory => this.acceptor.outOfMemory(),
                        .failure => |err| {
                            this.acceptor.completeS3Error(err, this.store.getPath() orelse "");
                        },
                    }
                }

                fn deinit(this: *@This()) void {
                    this.acceptor.deinit();
                    this.store.deref();
                    bun.destroy(this);
                }
            };

            const proxy = ctx.bunVM().transpiler.env.getHttpProxy(true, null, null);
            const proxy_url = if (proxy) |p| p.href else null;
            const wrapper = try bun.default_allocator.create(Wrapper);
            destination_store.ref();
            wrapper.* = .{
                .acceptor = acceptor.take(),
                .store = destination_store,
            };
            S3.upload(
                &aws_options.credentials,
                s3.path(),
                "",
                destination_blob.contentTypeOrMimeType(),
                aws_options.content_disposition,
                aws_options.content_encoding,
                aws_options.acl,
                proxy_url,
                aws_options.storage_class,
                aws_options.request_payer,
                Wrapper.resolve,
                .init(wrapper),
            );
            return;
        },
        .bytes => @panic("in-memory Blob passed as a validated write destination"),
    }
}

pub fn writeFileWithSourceDestination(ctx: *jsc.JSGlobalObject, source_blob: *Blob, destination_blob: *Blob, options: WriteFileOptions, acceptor: *WriteAcceptor) bun.JSError!void {
    const destination_store = destination_blob.storePtr() orelse Output.panic("Destination blob is detached", .{});
    const destination_type = std.meta.activeTag(destination_store.data);

    if (destination_type == .bytes) @panic("in-memory Blob passed as a validated write destination");

    const source_store = source_blob.storePtr() orelse return writeFileWithEmptySourceToDestination(ctx, destination_blob, options, acceptor);
    const source_type = std.meta.activeTag(source_store.data);

    if (destination_type == .file and source_type == .bytes) {
        const destination_range: write_file.StoreRange = .{
            .store = destination_store,
            .offset = destination_blob.offset,
            .size = destination_blob.size,
        };
        const source_range: write_file.StoreRange = .{
            .store = source_store,
            .offset = source_blob.offset,
            .size = source_blob.size,
        };
        const handler = try bun.default_allocator.create(write_file.WriteFileAcceptorHandler);
        handler.* = .{
            .acceptor = acceptor.take(),
        };

        if (comptime Environment.isWindows) {
            write_file.startUV(
                ctx.bunVM().eventLoop(),
                destination_range,
                source_range,
                handler,
                options.mkdirp_if_not_exists orelse true,
                options.mode,
            ) catch |err| {
                acceptor.* = handler.acceptor.take();
                bun.destroy(handler);
                return err;
            };
            return;
        }

        const file_copier = write_file.WriteFile.create(
            destination_range,
            source_range,
            *write_file.WriteFileAcceptorHandler,
            handler,
            write_file.WriteFileAcceptorHandler.run,
            options.mkdirp_if_not_exists orelse true,
            options.mode,
        ) catch |err| {
            acceptor.* = handler.acceptor.take();
            bun.destroy(handler);
            return err;
        };
        const task = write_file.WriteFileTask.createOnJSThread(ctx, file_copier) catch |err| {
            file_copier.deinitUnscheduled();
            acceptor.* = handler.acceptor.take();
            bun.destroy(handler);
            return err;
        };
        task.schedule();
        return;
    }
    // If this is file <> file, we can just copy the file
    else if (destination_type == .file and source_type == .file) {
        const handler = try bun.default_allocator.create(write_file.WriteFileAcceptorHandler);
        handler.* = .{
            .acceptor = acceptor.take(),
        };
        errdefer {
            acceptor.* = handler.acceptor.take();
            bun.destroy(handler);
        }
        const completion = copy_file.CopyFileCompletion.init(
            write_file.WriteFileAcceptorHandler,
            handler,
            &write_file.WriteFileAcceptorHandler.runCopy,
        );
        try CopyFileEngine.start(
            ctx,
            .{ .store = destination_store, .offset = destination_blob.offset, .size = destination_blob.size },
            .{ .store = source_store, .offset = source_blob.offset, .size = source_blob.size },
            completion,
            options.mkdirp_if_not_exists orelse true,
            options.mode,
        );
        return;
    } else if (destination_type == .file and source_type == .s3) {
        const s3 = &source_store.data.s3;
        var strong = try jsc.WebCore.ReadableStream.Strong.initOwned(try jsc.WebCore.ReadableStream.fromBlobCopyRefOwned(
            ctx,
            source_blob,
            @truncate(s3.options.partSize),
        ));
        defer strong.deinit();
        return destination_blob.pipeReadableStreamToFile(ctx, &strong, acceptor);
    } else if (destination_type == .s3) {
        const s3 = &destination_store.data.s3;
        var s3_options = try WriteS3Options.init(s3, options, ctx);
        defer s3_options.deinit();
        const aws_options = s3_options.get();
        const proxy = ctx.bunVM().transpiler.env.getHttpProxy(true, null, null);
        const proxy_url = if (proxy) |p| p.href else null;
        switch (source_store.data) {
            .bytes => |bytes| {
                if (bytes.len > S3.MultiPartUploadOptions.MAX_SINGLE_UPLOAD_SIZE) {
                    var strong = try jsc.WebCore.ReadableStream.Strong.initOwned(try jsc.WebCore.ReadableStream.fromBlobCopyRefOwned(
                        ctx,
                        source_blob,
                        @truncate(s3.options.partSize),
                    ));
                    defer strong.deinit();
                    const has_overrides = options.hasS3Overrides();
                    const stream_credentials = if (has_overrides) try aws_options.credentials.dupe() else s3.getCredentials();
                    defer if (has_overrides) stream_credentials.deref();
                    return uploadStreamToWriteAcceptor(
                        stream_credentials,
                        s3.path(),
                        &strong,
                        ctx,
                        aws_options.options,
                        aws_options.acl,
                        aws_options.storage_class,
                        destination_blob.contentTypeOrMimeType(),
                        aws_options.content_disposition,
                        aws_options.content_encoding,
                        proxy_url,
                        aws_options.request_payer,
                        acceptor,
                    );
                } else {
                    const Wrapper = struct {
                        store: *Store,
                        acceptor: WriteAcceptor,

                        pub fn resolve(result: S3.S3UploadResult, opaque_self: S3.CallbackContext) void {
                            const this = opaque_self.get(*@This());
                            defer this.deinit();
                            switch (result) {
                                .success => this.acceptor.complete(.{ .written = this.store.data.bytes.len }),
                                .out_of_memory => this.acceptor.outOfMemory(),
                                .failure => |err| {
                                    this.acceptor.completeS3Error(err, this.store.getPath() orelse "");
                                },
                            }
                        }

                        fn deinit(this: *@This()) void {
                            this.acceptor.deinit();
                            this.store.deref();
                            bun.destroy(this);
                        }
                    };
                    const wrapper = try bun.default_allocator.create(Wrapper);
                    source_store.ref();
                    wrapper.* = .{
                        .store = source_store,
                        .acceptor = acceptor.take(),
                    };

                    S3.upload(
                        &aws_options.credentials,
                        s3.path(),
                        bytes.slice(),
                        destination_blob.contentTypeOrMimeType(),
                        aws_options.content_disposition,
                        aws_options.content_encoding,
                        aws_options.acl,
                        proxy_url,
                        aws_options.storage_class,
                        aws_options.request_payer,
                        Wrapper.resolve,
                        .init(wrapper),
                    );
                    return;
                }
            },
            .file, .s3 => {
                var strong = try jsc.WebCore.ReadableStream.Strong.initOwned(try jsc.WebCore.ReadableStream.fromBlobCopyRefOwned(
                    ctx,
                    source_blob,
                    @truncate(s3.options.partSize),
                ));
                defer strong.deinit();
                const has_overrides = options.hasS3Overrides();
                const stream_credentials = if (has_overrides) try aws_options.credentials.dupe() else s3.getCredentials();
                defer if (has_overrides) stream_credentials.deref();
                return uploadStreamToWriteAcceptor(
                    stream_credentials,
                    s3.path(),
                    &strong,
                    ctx,
                    aws_options.options,
                    aws_options.acl,
                    aws_options.storage_class,
                    destination_blob.contentTypeOrMimeType(),
                    aws_options.content_disposition,
                    aws_options.content_encoding,
                    proxy_url,
                    aws_options.request_payer,
                    acceptor,
                );
            },
        }
    }

    unreachable;
}

const WriteFileOptions = struct {
    mkdirp_if_not_exists: ?bool = null,
    binding_options: BindingWriteOptions = null,
    resolved_s3_options: ?*const S3.S3CredentialsWithOptions = null,
    mode: ?bun.Mode = null,

    fn hasS3Overrides(this: WriteFileOptions) bool {
        return this.binding_options != null or this.resolved_s3_options != null;
    }
};

const WriteS3Options = union(enum) {
    borrowed: *const S3.S3CredentialsWithOptions,
    owned: S3.S3CredentialsWithOptions,

    fn init(s3: *const Store.S3, options: WriteFileOptions, globalThis: *jsc.JSGlobalObject) bun.JSError!WriteS3Options {
        if (options.resolved_s3_options) |resolved| return .{ .borrowed = resolved };
        if (options.binding_options != null) return .{ .owned = try StoreEngine.getCredentialsWithBindingOptions(s3, options.binding_options, globalThis) };
        return .{ .owned = StoreEngine.getCredentialsWithDefaults(s3, globalThis) };
    }

    fn get(this: *const WriteS3Options) *const S3.S3CredentialsWithOptions {
        return switch (this.*) {
            .borrowed => |resolved| resolved,
            .owned => |*resolved| resolved,
        };
    }

    fn deinit(this: *WriteS3Options) void {
        switch (this.*) {
            .borrowed => {},
            .owned => |*resolved| resolved.deinit(),
        }
    }
};

fn uploadStreamToWriteAcceptor(
    credentials: *S3.S3Credentials,
    path: []const u8,
    readable_stream: *const jsc.WebCore.ReadableStream.Strong,
    globalThis: *jsc.JSGlobalObject,
    options: S3.MultiPartUploadOptions,
    acl: ?S3.ACL,
    storage_class: ?S3.StorageClass,
    content_type: ?[]const u8,
    content_disposition: ?[]const u8,
    content_encoding: ?[]const u8,
    proxy: ?[]const u8,
    request_payer: bool,
    acceptor: *WriteAcceptor,
) bun.JSError!void {
    const Wrapper = struct {
        acceptor: WriteAcceptor,

        fn resolve(result: S3.S3UploadStreamResult, opaque_context: bun.bindgen.NativeCallbackContext(.vm)) void {
            const this = opaque_context.get(*@This());
            var owned_acceptor = this.acceptor.take();
            bun.destroy(this);
            switch (result) {
                .success => owned_acceptor.complete(.{ .written = 0 }),
                .out_of_memory => owned_acceptor.outOfMemory(),
                .terminated => owned_acceptor.deinit(),
                .failure => |failure| owned_acceptor.completeS3Error(failure.error_value, failure.path),
                .stream_error => |reason| {
                    var root = reason.clone();
                    owned_acceptor.reject(&root);
                },
            }
        }
    };

    const wrapper = try bun.default_allocator.create(Wrapper);
    wrapper.* = .{ .acceptor = acceptor.take() };
    S3StreamEngine.uploadStream(
        credentials,
        path,
        readable_stream,
        globalThis,
        options,
        acl,
        storage_class,
        content_type,
        content_disposition,
        content_encoding,
        proxy,
        request_payer,
        Wrapper.resolve,
        .init(wrapper),
    ) catch |err| {
        acceptor.* = wrapper.acceptor.take();
        bun.destroy(wrapper);
        return err;
    };
}

const WriteFileSource = union(enum) {
    response: *Response,
    request: *Request,
    archive: *Archive,
    build_artifact: *jsc.API.BuildArtifact,
    blob: *Blob,
    buffer: []const u8,
    string: *const bun.bindgen.DOMString,
};

pub fn writeFileWithBindingData(
    globalThis: *jsc.JSGlobalObject,
    path_or_blob: *PathOrBlob,
    data: anytype,
    options: WriteFileOptions,
    acceptor: *WriteAcceptor,
) bun.JSError!void {
    const input = data orelse {
        return globalThis.throwInvalidArguments("Bun.write(pathOrFdOrBlob, blob) expects a Blob-y thing to write", .{});
    };
    return switch (input) {
        .response => |value| writeFileInternal(globalThis, path_or_blob, .{ .response = value.get(Response) }, options, acceptor),
        .request => |value| writeFileInternal(globalThis, path_or_blob, .{ .request = value.get(Request) }, options, acceptor),
        .archive => |value| writeFileInternal(globalThis, path_or_blob, .{ .archive = value.get(Archive) }, options, acceptor),
        .build_artifact => |value| writeFileInternal(globalThis, path_or_blob, .{ .build_artifact = value.get(jsc.API.BuildArtifact) }, options, acceptor),
        .buffer => |value| writeFileInternal(globalThis, path_or_blob, .{ .buffer = value.unsafePtr("the generated entry frame owns the input lease until writeFileInternal writes the bytes synchronously or copies them into the asynchronous task's Blob") }, options, acceptor),
        .blob => |value| writeFileInternal(globalThis, path_or_blob, .{ .blob = value.get() }, options, acceptor),
        .string => |value| string: {
            var source = value.toOwned();
            defer source.deinit();
            break :string writeFileInternal(globalThis, path_or_blob, .{ .string = &source }, options, acceptor);
        },
    };
}

pub fn writeFileWithBytes(
    globalThis: *jsc.JSGlobalObject,
    path_or_blob: *PathOrBlob,
    bytes: []const u8,
    options: WriteFileOptions,
    acceptor: *WriteAcceptor,
) bun.JSError!void {
    return writeFileInternal(globalThis, path_or_blob, .{ .buffer = bytes }, options, acceptor);
}

const PreparedBodySource = union(enum) {
    blob: Blob,
    pending,
};

fn prepareBodySource(
    globalThis: *jsc.JSGlobalObject,
    owner: anytype,
    destination_blob: *Blob,
    options: WriteFileOptions,
    acceptor: *WriteAcceptor,
) bun.JSError!PreparedBodySource {
    const body_value = owner.getBodyValue();
    if (body_value.* == .Used or (body_value.* == .Locked and body_value.Locked.hasStartedConsumption())) {
        return prepareBodyPromise(globalThis, owner, destination_blob, options, acceptor);
    }
    return switch (body_value.*) {
        .WTFStringImpl,
        .InternalBlob,
        .Empty,
        .Blob,
        .Null,
        => .{ .blob = try body_value.use() },
        .Used => unreachable,
        .Error => |*error_reference| {
            destination_blob.detach();
            const body_error = error_reference.dupe();
            acceptor.completeError(body_error);
            return .pending;
        },
        .Locked => {
            if (destination_blob.isS3()) {
                const s3 = &destination_blob.storePtr().?.data.s3;
                var s3_options = try WriteS3Options.init(s3, options, globalThis);
                defer s3_options.deinit();
                const aws_options = s3_options.get();
                if (try body_value.toReadableStream(globalThis)) |owned| {
                    var returned = owned;
                    returned.deinit();
                }

                var readable = (try owner.getBodyReadableStream(globalThis)) orelse body_value.Locked.readable.clone();
                defer readable.deinit();
                if (readable.has()) {
                    if (readable.isDisturbed(globalThis)) {
                        destination_blob.detach();
                        return globalThis.throwInvalidArguments("ReadableStream has already been used", .{});
                    }
                    const proxy = globalThis.bunVM().transpiler.env.getHttpProxy(true, null, null);
                    const proxy_url = if (proxy) |value| value.href else null;
                    const has_overrides = options.hasS3Overrides();
                    const stream_credentials = if (has_overrides) try aws_options.credentials.dupe() else s3.getCredentials();
                    defer if (has_overrides) stream_credentials.deref();
                    try uploadStreamToWriteAcceptor(
                        stream_credentials,
                        s3.path(),
                        &readable,
                        globalThis,
                        aws_options.options,
                        aws_options.acl,
                        aws_options.storage_class,
                        destination_blob.contentTypeOrMimeType(),
                        aws_options.content_disposition,
                        aws_options.content_encoding,
                        proxy_url,
                        aws_options.request_payer,
                        acceptor,
                    );
                    return .pending;
                }
                destination_blob.detach();
                return globalThis.throwInvalidArguments("ReadableStream has already been used", .{});
            }
            return prepareBodyPromise(globalThis, owner, destination_blob, options, acceptor);
        },
    };
}

fn prepareBodyPromise(
    globalThis: *jsc.JSGlobalObject,
    owner: anytype,
    destination_blob: *Blob,
    options: WriteFileOptions,
    acceptor: *WriteAcceptor,
) bun.JSError!PreparedBodySource {
    const task = try bun.default_allocator.create(WriteBodyTask);
    task.* = .{
        .globalThis = globalThis,
        .file_blob = destination_blob.take(),
        .acceptor = .{},
        .mkdirp_if_not_exists = options.mkdirp_if_not_exists orelse true,
        .mode = options.mode,
    };
    var owner_live = true;
    defer if (owner_live) task.releasePromiseReactionRef();
    var body_promise = try owner.getBlobWithoutWrapper(globalThis);
    defer body_promise.deinit();
    var promise = body_promise.toOwned();
    defer promise.deinit();
    owner_live = false;
    var reaction_scope: bun.bindgen.FocusedEngineScope = undefined;
    reaction_scope.init(globalThis);
    defer reaction_scope.deinit();
    try WriteBodyTask.PromiseReaction.attach(
        &reaction_scope,
        promise.operand(&reaction_scope).asPromise(),
        task,
        OnWriteBodyBinding,
        OnWriteBodyErrorBinding,
    );
    task.acceptor = acceptor.take();
    return .pending;
}

/// ## Errors
/// - If `path_or_blob` is a detached blob
/// ## Panics
/// - If `path_or_blob` is a `Blob` backed by a byte store
fn writeFileInternal(globalThis: *jsc.JSGlobalObject, path_or_blob_: *PathOrBlob, data: WriteFileSource, options: WriteFileOptions, acceptor: *WriteAcceptor) bun.JSError!void {
    var path_or_blob = path_or_blob_.*;
    const destination_view: ?*Blob = if (path_or_blob == .blob) path_or_blob.blob.get() else null;
    if (destination_view) |destination| {
        const blob_store = destination.storePtr() orelse {
            return globalThis.throwInvalidArguments("Blob is detached", .{});
        };
        bun.assertWithLocation(blob_store.data != .bytes, @src());
        // TODO only reset last_modified on success paths instead of
        // resetting last_modified at the beginning for better performance.
        if (blob_store.data == .file) {
            // reset last_modified to force getLastModified() to reload after writing.
            blob_store.data.file.last_modified = Store.uninitialized_timestamp;
        }
    }

    const input_store: ?*Store = if (destination_view) |destination| destination.storePtr() else null;
    if (input_store) |st| st.ref();
    defer if (input_store) |st| st.deref();

    if (options.mkdirp_if_not_exists) |mkdir| {
        if (mkdir and
            path_or_blob == .blob and
            destination_view.?.storePtr() != null and
            destination_view.?.storePtr().?.data == .file and
            destination_view.?.storePtr().?.data.file.pathlike == .fd)
        {
            return globalThis.throwInvalidArguments("Cannot create a directory for a file descriptor", .{});
        }
    }

    // If you're doing Bun.write(), try to go fast by writing short input on the main thread.
    // This is a heuristic, but it's a good one.
    //
    // except if you're on Windows. Windows I/O is slower. Let's not even try.
    if (comptime !Environment.isWindows) {
        if (path_or_blob == .path or
            // If they try to set an offset, its a little more complicated so let's avoid that
            (destination_view.?.offset == 0 and !destination_view.?.isS3() and
                // Is this a file that is known to be a pipe? Let's avoid blocking the main thread on it.
                !(destination_view.?.storePtr() != null and
                    destination_view.?.storePtr().?.data == .file and
                    destination_view.?.storePtr().?.data.file.mode != 0 and
                    bun.isRegularFile(destination_view.?.storePtr().?.data.file.mode))))
        {
            switch (data) {
                .string => |text| {
                    if (text.length() < 256 * 1024) {
                        var utf8 = try text.toUTF8(bun.default_allocator);
                        defer utf8.deinit();
                        const pathlike: bun.api.node.PathOrFileDescriptor = if (path_or_blob == .path)
                            path_or_blob.path
                        else
                            destination_view.?.storePtr().?.data.file.pathlike;
                        const result = if (pathlike == .path)
                            try writeBytesToFileFast(globalThis, pathlike, utf8.slice(), true)
                        else
                            try writeBytesToFileFast(globalThis, pathlike, utf8.slice(), false);
                        if (result) |written| {
                            return acceptor.complete(.{ .written = written });
                        }
                    }
                },
                .buffer => |bytes| {
                    if (bytes.len < 256 * 1024) {
                        const pathlike: bun.api.node.PathOrFileDescriptor = if (path_or_blob == .path)
                            path_or_blob.path
                        else
                            destination_view.?.storePtr().?.data.file.pathlike;
                        const result = if (pathlike == .path)
                            try writeBytesToFileFast(globalThis, pathlike, bytes, true)
                        else
                            try writeBytesToFileFast(globalThis, pathlike, bytes, false);
                        if (result) |written| {
                            return acceptor.complete(.{ .written = written });
                        }
                    }
                },
                else => {},
            }
        }
    }

    // if path_or_blob is a path, convert it into a file blob
    var destination_blob: Blob = if (path_or_blob == .path) brk: {
        const new_blob = try Blob.findOrCreateFileFromPath(&path_or_blob_.path, globalThis, true);
        if (new_blob.storePtr() == null) {
            return globalThis.throwInvalidArguments("Writing to an empty blob is not implemented yet", .{});
        }
        break :brk new_blob;
    } else try destination_view.?.dupe();
    defer destination_blob.deinit();

    if (bun.Environment.allow_assert and path_or_blob == .blob) {
        // sanity check. Should never happen because
        // 1. destination blobs passed via path_or_blob are null checked at the very start
        // 2. newly created blobs from paths get null checked immediately after creation.
        bun.unsafeAssert(destination_view.?.storePtr() != null);
    }

    // TODO: implement a writeev() fast path
    var source_blob: Blob = source: switch (data) {
        .response => |response| switch (try prepareBodySource(globalThis, response, &destination_blob, options, acceptor)) {
            .blob => |blob| break :source blob,
            .pending => return,
        },
        .request => |request| switch (try prepareBodySource(globalThis, request, &destination_blob, options, acceptor)) {
            .blob => |blob| break :source blob,
            .pending => return,
        },
        .archive => |archive| {
            const store = archive.store.get();
            store.ref();
            break :source try Blob.initWithStore(store);
        },
        .build_artifact => |artifact| break :source try artifact.blob.dupe(),
        .blob => |blob| break :source try blob.dupe(),
        .buffer => |bytes| break :source try Blob.create(bytes, bun.default_allocator, false),
        .string => |string_value| {
            var utf8 = try string_value.toUTF8(bun.default_allocator);
            defer utf8.deinit();
            break :source try Blob.create(utf8.slice(), bun.default_allocator, true);
        },
    };
    defer source_blob.deinit();

    return writeFileWithSourceDestination(globalThis, &source_blob, &destination_blob, options, acceptor);
}

fn validateWritableBlob(context: anytype, blob: *Blob) bun.bindgen.CallError(@TypeOf(context))!void {
    const store = blob.storePtr() orelse {
        return context.fail(.write_detached_blob, {});
    };
    if (store.data == .bytes) {
        return context.fail(.write_readonly_blob, {});
    }
}

/// `Bun.write(destination, input, options?)`
pub fn writeFile(
    context: bun.bindgen.CallContext(WriteFileFunctionSchema),
    args: bun.bindgen.Args(WriteFileFunctionSchema),
) bun.bindgen.CallError(WriteFileFunctionSchema)!void {
    const globalThis = context.viewToken().globalObject();
    var path_or_blob = try PathOrBlobEngine.fromBindgen(args.destination);
    defer path_or_blob.deinit();
    // "Blob" must actually be a BunFile, not a webcore blob.
    if (path_or_blob == .blob) {
        try validateWritableBlob(context, path_or_blob.blob.get());
    }

    if (args.input == null) {
        return context.fail(.write_missing_data, {});
    }

    var mkdirp_if_not_exists: ?bool = null;
    var mode: ?bun.Mode = null;
    if (args.options) |input| switch (input) {
        .nulled, .undefined => {},
        .invalid => return globalThis.throwInvalidArgumentType("write", "options", "object"),
        .options => |options| {
            mkdirp_if_not_exists = options.create_path;
            if (options.mode) |value| {
                if (value > 0o777) return globalThis.throwRangeError(value, .{ .field_name = "mode", .min = 0, .max = 0o777 });
                mode = @intCast(value);
            }
        },
    };
    var completion = context.completion();
    var acceptor = write_file.WriteAcceptor.fromCompletion(write_file.WriteCompletions.takeForContext(context, &completion)) orelse return;
    defer acceptor.deinit();
    try writeFileWithBindingData(globalThis, &path_or_blob, args.input, .{
        .mkdirp_if_not_exists = mkdirp_if_not_exists,
        .binding_options = args.options,
        .mode = mode,
    }, &acceptor);
    acceptor.assertConsumed();
}

const write_permissions = 0o664;

fn writeBytesToFileFast(
    globalThis: *jsc.JSGlobalObject,
    pathlike: bun.api.node.PathOrFileDescriptor,
    bytes: []const u8,
    comptime needs_open: bool,
) bun.JSError!?u64 {
    const fd: bun.FD = if (comptime !needs_open) pathlike.fd else brk: {
        var file_path: bun.PathBuffer = undefined;
        switch (bun.sys.open(
            pathlike.path.sliceZ(&file_path),
            if (!Environment.isWindows)
                // we deliberately don't use O_TRUNC here
                // it's a perf optimization
                bun.O.WRONLY | bun.O.CREAT | bun.O.NONBLOCK
            else
                bun.O.WRONLY | bun.O.CREAT,
            write_permissions,
        )) {
            .result => |result| {
                break :brk result;
            },
            .err => |err| {
                if (!Environment.isWindows) {
                    if (err.getErrno() == .NOENT) {
                        return null;
                    }
                }

                return bun.api.SystemErrorBindings.throwSysError(err.withPath(pathlike.path.slice()), globalThis);
            },
        }
    };

    // TODO: on windows this is always synchronous

    const truncate = needs_open or bytes.len == 0;
    var written: usize = 0;
    defer if (needs_open) fd.close();

    var remain = bytes;
    const end = remain.ptr + remain.len;

    while (remain.ptr != end) {
        const result = bun.sys.write(fd, remain);
        switch (result) {
            .result => |res| {
                written += res;
                remain = remain[res..];
                if (res == 0) break;
            },
            .err => |err| {
                if (!Environment.isWindows) {
                    if (err.getErrno() == .AGAIN) {
                        return null;
                    }
                }
                if (comptime !needs_open) {
                    return bun.api.SystemErrorBindings.throwSysError(err, globalThis);
                }
                return bun.api.SystemErrorBindings.throwSysError(err.withPath(pathlike.path.slice()), globalThis);
            },
        }
    }

    if (truncate) {
        if (Environment.isWindows) {
            _ = std.os.windows.kernel32.SetEndOfFile(fd.cast());
        } else {
            _ = bun.sys.ftruncate(fd, @as(i64, @intCast(written)));
        }
    }

    return written;
}
fn emptyConstructorBlob() Blob {
    return Blob.initEmpty();
}

fn blobFromBindgenPartsInput(
    context: anytype,
    parts_input: anytype,
) bun.bindgen.CallError(@TypeOf(context))!Blob {
    return switch (parts_input.*) {
        .nulled => emptyConstructorBlob(),
        .flag, .invalid => context.fail(.blob_parts_not_array, {}),
        .list => |*list| try blobFromBindgenParts(list, .constructor),
        .bytes => |*buffer| try Blob.create(
            buffer.unsafePtr("the generated entry frame owns the converted byte lease until Blob.create copies its contents"),
            bun.default_allocator,
            false,
        ),
    };
}

pub const PartsMode = enum {
    constructor,
    /// `new Response([blob])` moves the single blob's store instead of
    /// duplicating it.
    body_move,
};

fn PartValuePtr(comptime ItemPtr: type) type {
    const Item = @typeInfo(ItemPtr).pointer.child;
    return if (@hasField(Item, "value")) *@FieldType(Item, "value") else ItemPtr;
}

/// Owned sequence entries wrap the union in a `value` field; borrowed views
/// yield it directly.
fn partValue(item: anytype) PartValuePtr(@TypeOf(item)) {
    const Item = @typeInfo(@TypeOf(item)).pointer.child;
    return if (comptime @hasField(Item, "value")) &item.value else item;
}

fn emptyPartsBlob(comptime mode: PartsMode) Blob {
    return switch (mode) {
        .constructor => emptyConstructorBlob(),
        .body_move => Blob{},
    };
}

pub fn blobFromBindgenParts(
    parts: anytype,
    comptime mode: PartsMode,
) bun.JSError!Blob {
    const allocator = bun.default_allocator;
    const length = parts.len();
    if (length == 0) return emptyPartsBlob(mode);

    const Parts = @typeInfo(@TypeOf(parts)).pointer.child;
    const parts_are_borrowed = @hasDecl(Parts, "at");
    const Item = if (parts_are_borrowed)
        @TypeOf(parts.at(0).?)
    else
        @TypeOf(parts.pop().?);
    const retained = try allocator.alloc(Item, length);
    if (comptime parts_are_borrowed) {
        for (retained, 0..) |*slot, index| slot.* = parts.at(index).?;
    } else {
        var retained_index = length;
        while (parts.pop()) |item| {
            retained_index -= 1;
            retained[retained_index] = item;
        }
        bun.debugAssert(retained_index == 0);
    }
    defer {
        if (comptime !parts_are_borrowed) {
            for (retained) |*item| item.deinit();
        }
        allocator.free(retained);
    }

    if (length == 1) switch (partValue(&retained[0]).*) {
        .blob => |*blob_ref| {
            const blob = blob_ref.get();
            switch (mode) {
                .constructor => return blob.dupe(),
                .body_move => {
                    var moved = blob.*;
                    moved.setNotHeapAllocated();
                    moved.name = if (blob.name) |*name| name.clone() else null;
                    moved.content_type = try blob.content_type.clone();
                    blob.transfer();
                    return moved;
                },
            }
        },
        .artifact => |*artifact_ref| return artifact_ref.get(jsc.API.BuildArtifact).blob.dupe(),
        else => {},
    };

    var bytes = std.array_list.Managed(u8).init(allocator);
    errdefer bytes.deinit();
    for (retained) |*item| {
        switch (partValue(item).*) {
            .flag => |flag| try bytes.appendSlice(if (flag) "true" else "false"),
            .nulled, .skipped => {},
            .blob => |*blob_ref| try bytes.appendSlice(blob_ref.get().sharedView()),
            .artifact => |*artifact_ref| try bytes.appendSlice(artifact_ref.get(jsc.API.BuildArtifact).blob.sharedView()),
            .buffer => |*buffer| {
                const Buffer = @TypeOf(buffer.*);
                if (comptime @hasDecl(Buffer, "slice")) {
                    try bytes.appendSlice(buffer.slice());
                } else {
                    try bytes.appendSlice(buffer.unsafePtr("the retained part or generated entry frame owns the buffer until appendSlice copies it"));
                }
            },
            .string, .coerced => |*string_value| {
                const utf8 = try string_value.toUTF8(allocator);
                defer utf8.deinit();
                try bytes.appendSlice(utf8.slice());
            },
        }
    }

    if (bytes.items.len == 0) {
        bytes.deinit();
        return emptyPartsBlob(mode);
    }
    const owned = try bytes.toOwnedSlice();
    return Blob.initWithAllASCII(owned, allocator, strings.isAllASCII(owned));
}

fn applyConstructorContentType(
    blob: *Blob,
    globalThis: *jsc.JSGlobalObject,
    content_type: anytype,
) bun.OOM!void {
    // An absent type leaves the parts-derived content type (a single blob
    // part donates its type) untouched.
    const value = content_type orelse return;
    blob.clearContentType(.explicit);

    const utf8 = try value.toUTF8(bun.default_allocator);
    defer utf8.deinit();
    const bytes = utf8.slice();
    if (bytes.len == 0 or !strings.isAllASCII(bytes)) return;

    try blob.setASCIIContentType(globalThis, bytes);
}

fn applyConstructorFileName(blob: *Blob, name: anytype) bun.OOM!void {
    var owned = name.toOwned();
    defer owned.deinit();
    const replacement = try owned.toThreadSafe();
    if (blob.name) |*previous| previous.deinit();
    blob.name = replacement;
}

fn calculateEstimatedByteSize(this: *Blob) void {
    // in-memory size. not the size on disk.
    var size: usize = @sizeOf(Blob);

    if (this.storePtr()) |store| {
        size += @sizeOf(Blob.Store);
        switch (store.data) {
            .bytes => {
                size += store.data.bytes.stored_name.capacity();
                size += if (this.size != Blob.max_size)
                    this.size
                else
                    store.data.bytes.len;
            },
            .file => size += store.data.file.pathlike.estimatedSize(),
            .s3 => size += store.data.s3.estimatedSize(),
        }
    }

    this.reported_estimated_size = size +
        this.content_type.length() +
        (if (this.name) |*name| name.byteLength() else 0);
}

pub fn estimatedSize(this: *Blob) usize {
    return this.reported_estimated_size;
}

pub fn constructBunFile(
    context: bun.bindgen.CallContext(ConstructBunFileSchema),
    bind_args: bun.bindgen.Args(ConstructBunFileSchema),
) bun.bindgen.CallError(ConstructBunFileSchema)!bun.bindgen.Return(ConstructBunFileSchema) {
    const globalObject = context.viewToken().globalObject();
    var path = try PathOrFileDescriptor.fromBinding(bind_args.path);
    defer path.deinit();

    if (path == .path) {
        if (strings.hasPrefixComptime(path.path.slice(), "s3://")) {
            const blob = try S3File.constructInternalWithBindingOptions(context, &path.path, bind_args.options);
            return blob.toBindingRef(context);
        }
    }

    var blob = try Blob.findOrCreateFileFromPath(&path, globalObject, false);
    errdefer blob.deinit();

    if (bind_args.options) |input| switch (input) {
        .nulled, .undefined, .invalid => {},
        .options => |*options| {
            try applyConstructorContentType(&blob, globalObject, options.content_type);
            if (options.last_modified) |last_modified| blob.last_modified = last_modified;
        },
    };

    return (try Blob.new(&blob)).toBindingRef(context);
}

pub fn findOrCreateFileFromPath(path_or_fd: *bun.api.node.PathOrFileDescriptor, globalThis: *JSGlobalObject, comptime check_s3: bool) bun.OOM!Blob {
    var vm = globalThis.bunVM();
    const allocator = bun.default_allocator;
    if (check_s3) {
        if (path_or_fd.* == .path) {
            if (strings.startsWith(path_or_fd.path.slice(), "s3://")) {
                const credentials = globalThis.bunVM().transpiler.env.getS3Credentials();
                const copy = path_or_fd.*;
                path_or_fd.* = .{ .path = .{ .string = bun.PathString.empty } };
                return Blob.initWithStore(try Blob.Store.initS3(copy.path, null, credentials, allocator));
            }
        }
    }

    const path: bun.api.node.PathOrFileDescriptor = brk: {
        switch (path_or_fd.*) {
            .path => {
                var slice = path_or_fd.path.slice();

                if (Environment.isWindows and bun.strings.eqlComptime(slice, "/dev/null")) {
                    const null_path = try allocator.dupe(u8, "\\\\.\\NUL");
                    path_or_fd.deinit();
                    path_or_fd.* = .{
                        .path = .{
                            // this memory is freed with this allocator in `Blob.Store.deinit`
                            .string = bun.PathString.init(null_path),
                        },
                    };
                    slice = path_or_fd.path.slice();
                }

                if (vm.standalone_module_graph) |graph| {
                    if (graph.find(slice)) |file| {
                        defer {
                            if (path_or_fd.path != .string) {
                                path_or_fd.deinit();
                                path_or_fd.* = .{ .path = .{ .string = bun.PathString.empty } };
                            }
                        }

                        return jsc.API.StandaloneGraphEngine.fileBlob(file);
                    }
                }

                try path_or_fd.toThreadSafe();
                const copy = path_or_fd.*;
                path_or_fd.* = .{ .path = .{ .string = bun.PathString.empty } };
                break :brk copy;
            },
            .fd => {
                if (path_or_fd.fd.stdioTag()) |tag| {
                    const store = try vm.rareData().stdio(tag);
                    store.ref();
                    return Blob.initWithStore(store);
                }
                break :brk path_or_fd.*;
            },
        }
    };

    return Blob.initWithStore(try Blob.Store.initFile(path, null, allocator));
}

pub fn getStreamWithChunkSize(
    this: *Blob,
    globalThis: *jsc.JSGlobalObject,
    recommended_chunk_size_value: ?i64,
) bun.JSError!jsc.WebCore.ReadableStream.Owned {
    const recommended_chunk_size: SizeType = if (recommended_chunk_size_value) |value|
        @intCast(std.math.clamp(value, 0, @as(i64, std.math.maxInt(SizeType))))
    else
        0;
    return jsc.WebCore.ReadableStream.fromBlobCopyRefOwned(
        globalThis,
        this,
        recommended_chunk_size,
    );
}

pub fn shouldCacheStream(this: *const Blob) bool {
    if (this.storePtr()) |store| {
        switch (store.data) {
            .file => |f| switch (f.pathlike) {
                .fd => return true,
                else => {},
            },
            else => {},
        }
    }

    return false;
}

fn getExistsSync(this: *Blob) bool {
    if (this.size == Blob.max_size) {
        this.resolveSize();
    }

    // If there's no store that means it's empty and we just return true
    // it will not error to return an empty Blob
    const store = this.storePtr() orelse return true;

    if (store.data == .bytes) {
        // Bytes will never error
        return true;
    }

    // We say regular files and pipes exist.
    // This is mostly meant for "Can we use this in new Response(file)?"
    return bun.isRegularFile(store.data.file.mode) or bun.sys.S.ISFIFO(@intCast(store.data.file.mode));
}

pub fn isS3(this: *const Blob) bool {
    if (this.storePtr()) |store| {
        return store.data == .s3;
    }
    return false;
}

fn doWrite(
    this: *Blob,
    globalThis: *jsc.JSGlobalObject,
    context: anytype,
    data: anytype,
    options: anytype,
    acceptor: *WriteAcceptor,
) bun.bindgen.CallError(@TypeOf(context))!void {
    try validateWritableBlob(context, this);
    var mkdirp_if_not_exists: ?bool = null;
    if (options) |input| switch (input) {
        .nulled, .undefined => {},
        .invalid => return globalThis.throwInvalidArgumentType("write", "options", "object"),
        .options => |resolved| {
            mkdirp_if_not_exists = resolved.create_path;
            if (resolved.content_type) |content_type| {
                const content_type_str = try content_type.toUTF8(bun.default_allocator);
                defer content_type_str.deinit();
                const slice = content_type_str.slice();
                if (strings.isAllASCII(slice)) {
                    try this.setASCIIContentType(globalThis, slice);
                }
            }
        },
    };
    var blob_internal: PathOrBlob = .{ .blob = .init(this) };
    try writeFileWithBindingData(globalThis, &blob_internal, data, .{
        .mkdirp_if_not_exists = mkdirp_if_not_exists,
        .binding_options = options,
    }, acceptor);
}

fn doUnlink(
    comptime FunctionSchema: type,
    this: *Blob,
    globalThis: *jsc.JSGlobalObject,
    context: anytype,
    options: anytype,
) bun.bindgen.CallError(@TypeOf(context))!void {
    try validateWritableBlob(context, this);

    const store = this.storePtr().?;
    switch (store.data) {
        .s3 => |*s3| {
            var resolved = try StoreEngine.getCredentialsWithBindingOptions(s3, options, globalThis);
            defer resolved.deinit();
            var acceptor = bun.S3.S3VoidAcceptor.takeForContext(context);
            StoreEngine.unlinkResolved(s3, store, globalThis, &resolved, &acceptor) catch |err| {
                acceptor.release();
                return err;
            };
        },
        .file => |*file| switch (file.pathlike) {
            .fd => return context.fail(.unlink_file_descriptor, {}),
            .path => |path_like| {
                const Task = NodeFSBindings.Async.materializedUnlink(FunctionSchema);
                var args: bun.api.node.fs.Arguments.Unlink = .{
                    .path = .{
                        .encoded_slice = switch (path_like) {
                            .encoded_slice => |slice| try slice.toOwned(bun.default_allocator),
                            else => try bun.TextView.toSliceClone(.{ .utf8 = path_like.slice() }, bun.default_allocator),
                        },
                    },
                };
                errdefer args.deinit();
                var completion_view = context.completion();
                const completion = try Task.Completion.take(&completion_view, {});
                const vm = globalThis.bunVM();
                Task.schedule(args, .{
                    .background_tasks = &vm.background_tasks,
                    .io = null,
                }, completion);
            },
        },
        else => unreachable,
    }
}

fn completeExists(
    this: *Blob,
    globalThis: *jsc.JSGlobalObject,
    context: anytype,
) bun.bindgen.CallError(@TypeOf(context))!void {
    if (this.isS3()) {
        var acceptor = bun.S3.S3ExistsAcceptor.takeForContext(context);
        S3File.stat(.exists, globalThis, this, &acceptor) catch {
            acceptor.outOfMemory();
        };
        return;
    }
    var acceptor = bun.S3.S3ExistsAcceptor.takeForContext(context);
    acceptor.resolve(this.getExistsSync());
}

pub const FileStreamWrapper = struct {
    const PromiseReaction = bun.bindgen.PromiseReaction(
        OnResolveRequestStreamSchema.args[1].ArgumentType,
        @This(),
    );

    acceptor: WriteAcceptor,
    readable_stream_ref: jsc.WebCore.ReadableStream.Strong,
    sink: *jsc.WebCore.FileSink,

    pub fn deinit(this: *@This()) void {
        this.acceptor.deinit();
        this.readable_stream_ref.deinit();
        this.sink.deref();
        bun.destroy(this);
    }

    pub fn releasePromiseReactionRef(this: *@This()) void {
        this.deinit();
    }
};

const WriteBodyTask = struct {
    const PromiseReaction = bun.bindgen.PromiseReaction(OnWriteBodySchema.args[1].ArgumentType, @This());

    globalThis: *JSGlobalObject,
    file_blob: Blob,
    acceptor: WriteAcceptor,
    mkdirp_if_not_exists: bool,
    mode: ?bun.Mode,

    pub fn releasePromiseReactionRef(this: *@This()) void {
        this.acceptor.deinit();
        this.file_blob.deinit();
        bun.destroy(this);
    }
};

fn bindOnWriteBody(
    context: bun.bindgen.CallContext(OnWriteBodySchema),
    args: bun.bindgen.Args(OnWriteBodySchema),
) bun.JSError!bun.bindgen.Return(OnWriteBodySchema) {
    const task = WriteBodyTask.PromiseReaction.take(args.context) orelse return;
    defer task.releasePromiseReactionRef();
    writeFileWithSourceDestination(
        task.globalThis,
        args.blob.get(BlobJSBinding).native(),
        &task.file_blob,
        .{ .mkdirp_if_not_exists = task.mkdirp_if_not_exists, .mode = task.mode },
        &task.acceptor,
    ) catch |err| switch (err) {
        error.OutOfMemory => return task.acceptor.outOfMemory(),
        error.JSTerminated => return error.JSTerminated,
        error.JSError => {
            var thrown = try context.takeThrownValue(err);
            defer thrown.deinit();
            var root = try thrown.toRoot();
            defer root.deinit();
            return task.acceptor.reject(&root);
        },
    };
    task.acceptor.assertConsumed();
}

fn bindOnWriteBodyError(
    _: bun.bindgen.CallContext(OnWriteBodyErrorSchema),
    args: bun.bindgen.Args(OnWriteBodyErrorSchema),
) bun.JSError!bun.bindgen.Return(OnWriteBodyErrorSchema) {
    const task = WriteBodyTask.PromiseReaction.take(args.context) orelse return;
    defer task.releasePromiseReactionRef();
    var error_value = try args.errorValue.toRoot();
    defer error_value.deinit();
    task.acceptor.reject(&error_value);
}

const FileStreamReaction = enum { resolve, reject };

fn bindOnResolveRequestStream(
    context: bun.bindgen.CallContext(OnResolveRequestStreamSchema),
    args: bun.bindgen.Args(OnResolveRequestStreamSchema),
) bun.JSError!bun.bindgen.Return(OnResolveRequestStreamSchema) {
    return fileStreamReactionFromBinding(.resolve, context, args);
}

fn bindOnRejectRequestStream(
    context: bun.bindgen.CallContext(OnRejectRequestStreamSchema),
    args: bun.bindgen.Args(OnRejectRequestStreamSchema),
) bun.JSError!bun.bindgen.Return(OnRejectRequestStreamSchema) {
    return fileStreamReactionFromBinding(.reject, context, args);
}

pub fn fileStreamReactionFromBinding(
    comptime reaction: FileStreamReaction,
    context: anytype,
    args: anytype,
) bun.JSError!bun.bindgen.Return(@TypeOf(context)) {
    const globalThis = context.viewToken().globalObject();
    const this = FileStreamWrapper.PromiseReaction.take(args.context) orelse return;
    defer this.deinit();
    var strong = this.readable_stream_ref;
    defer strong.deinit();
    this.readable_stream_ref = .{};

    switch (reaction) {
        .resolve => {
            strong.done(globalThis);
            this.acceptor.complete(.{ .written = 0 });
        },
        .reject => {
            var error_value = try args.errorValue.toRoot();
            defer error_value.deinit();
            this.acceptor.reject(&error_value);

            strong.cancel(globalThis);
        },
    }
}

fn pipeReadableStreamToFile(this: *Blob, globalThis: *jsc.JSGlobalObject, readable_stream: *const jsc.WebCore.ReadableStream.Strong, acceptor: *WriteAcceptor) bun.JSError!void {
    const store = this.storePtr() orelse unreachable;
    bun.assertWithLocation(store.data == .file, @src());

    const file_sink = brk_sink: {
        if (Environment.isWindows) {
            const pathlike = store.data.file.pathlike;
            const fd: bun.FD = if (pathlike == .fd) pathlike.fd else brk: {
                var file_path: bun.PathBuffer = undefined;
                const path = pathlike.path.sliceZ(&file_path);
                switch (bun.sys.open(
                    path,
                    bun.O.WRONLY | bun.O.CREAT | bun.O.NONBLOCK,
                    write_permissions,
                )) {
                    .result => |result| {
                        break :brk switch (result.makeLibUVOwnedForSyscall(.open, .close_on_fail)) {
                            .result => |fd| fd,
                            .err => |err| return acceptor.completeSysError(err.withPath(path)),
                        };
                    },
                    .err => |err| {
                        return acceptor.completeSysError(err.withPath(path));
                    },
                }
                unreachable;
            };
            var owns_opened_fd = pathlike == .path;
            defer {
                if (owns_opened_fd) _ = fd.closeAllowingStandardIo(null);
            }

            const is_stdout_or_stderr = brk: {
                if (pathlike != .fd) {
                    break :brk false;
                }

                if (globalThis.bunVM().rare_data) |rare| {
                    if (store == rare.stdout_store) {
                        break :brk true;
                    }

                    if (store == rare.stderr_store) {
                        break :brk true;
                    }
                }

                break :brk if (fd.stdioTag()) |tag| switch (tag) {
                    .std_out, .std_err => true,
                    else => false,
                } else false;
            };
            const sink = try jsc.WebCore.FileSink.create(globalThis.bunVM().eventLoop());
            sink.writer.owns_fd = pathlike != .fd;

            if (is_stdout_or_stderr) {
                switch (sink.writer.startSync(fd)) {
                    .err => |err| {
                        sink.deref();
                        return acceptor.completeSysError(err);
                    },
                    else => {},
                }
            } else {
                switch (sink.writer.start(fd, .{})) {
                    .err => |err| {
                        sink.deref();
                        return acceptor.completeSysError(err);
                    },
                    else => {},
                }
            }
            owns_opened_fd = false;

            break :brk_sink sink;
        }

        const sink = try jsc.WebCore.FileSink.create(globalThis.bunVM().eventLoop());
        errdefer sink.deref();

        const input_path: jsc.WebCore.PathOrFileDescriptor = brk: {
            if (store.data.file.pathlike == .fd) {
                break :brk .{ .fd = store.data.file.pathlike.fd };
            } else {
                break :brk .{
                    .path = try bun.String.Slice.initDupe(
                        bun.default_allocator,
                        store.data.file.pathlike.path.slice(),
                    ),
                };
            }
        };
        defer input_path.deinit();

        const stream_start: jsc.WebCore.streams.Start = .{
            .FileSink = .{
                .input_path = input_path,
            },
        };

        switch (sink.start(stream_start)) {
            .err => |err| {
                sink.deref();
                return acceptor.completeSysError(err);
            },
            else => {},
        }
        break :brk_sink sink;
    };
    var owns_sink = true;
    defer if (owns_sink) file_sink.deref();
    var signal = &file_sink.signal;

    signal.clear();
    bun.assert(signal.isDead());

    var owned_stream = readable_stream.cloneOwned() orelse @panic("cannot pipe an empty readable stream");
    defer owned_stream.deinit();
    var assignment_result = try jsc.WebCore.FileSink.JSSink.assignToStream(
        globalThis,
        &owned_stream,
        file_sink,
    ) orelse {
        return acceptor.complete(.{ .written = 0 });
    };
    defer assignment_result.deinit();

    {
        try globalThis.bunVM().drainMicrotasks();

        var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
        engine_scope.init(globalThis);
        defer engine_scope.deinit();
        switch (engine_scope.engine(PromiseStatusSchema).call(.{ .promise = assignment_result.operand(&engine_scope) })) {
            .pending => {
                const wrapper = try bun.default_allocator.create(FileStreamWrapper);
                wrapper.* = .{
                    .acceptor = .{},
                    .readable_stream_ref = readable_stream.clone(),
                    .sink = file_sink,
                };
                owns_sink = false;

                var reaction_scope: bun.bindgen.FocusedEngineScope = undefined;
                reaction_scope.init(globalThis);
                defer reaction_scope.deinit();
                try FileStreamWrapper.PromiseReaction.attach(
                    &reaction_scope,
                    assignment_result.operand(&reaction_scope).asPromise(),
                    wrapper,
                    OnResolveRequestStreamBinding,
                    OnRejectRequestStreamBinding,
                );
                wrapper.acceptor = acceptor.take();
                return;
            },
            .fulfilled => {
                readable_stream.done(globalThis);
                return acceptor.complete(.{ .written = 0 });
            },
            .rejected => {
                readable_stream.cancel(globalThis);
                var scope: bun.bindgen.FocusedEngineScope = undefined;
                scope.init(globalThis);
                defer scope.deinit();
                const reason = (try scope.engine(PromiseResultSchema).call(.{
                    .promise = assignment_result.operand(&scope).asPromise(),
                })) orelse @panic("rejected stream assignment omitted its reason");
                const any_reason = reason.asAny(&scope);
                var reason_root = try any_reason.toRoot();
                defer reason_root.deinit();
                return acceptor.reject(&reason_root);
            },
        }
    }
}

fn getWriter(
    this: *Blob,
    globalThis: *jsc.JSGlobalObject,
    context: anytype,
    options: anytype,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(BlobWriterSchema) {
    if (options) |input| switch (input) {
        .options => {},
        .nulled, .undefined => {},
        .invalid => return context.fail(.write_options_not_object, {}),
    };

    try validateWritableBlob(context, this);

    const store = this.storePtr().?;
    if (this.isS3()) {
        const s3 = &store.data.s3;
        const path = s3.path();
        const proxy = globalThis.bunVM().transpiler.env.getHttpProxy(true, null, null);
        const proxy_url = if (proxy) |p| p.href else null;
        if (options) |input| switch (input) {
            .nulled, .undefined, .invalid => {},
            .options => |resolved| {
                if (resolved.content_type) |content_type| {
                    var content_type_str = try content_type.toUTF8(bun.default_allocator);
                    defer content_type_str.deinit();
                    const slice = content_type_str.slice();
                    if (strings.isAllASCII(slice)) {
                        try this.setASCIIContentType(globalThis, slice);
                    }
                }
                const content_disposition_str: ?bun.String.Slice = if (resolved.content_disposition) |content_disposition|
                    if (content_disposition.length() > 0) try content_disposition.toUTF8(bun.default_allocator) else null
                else
                    null;
                defer if (content_disposition_str) |cd| cd.deinit();
                const content_encoding_str: ?bun.String.Slice = if (resolved.content_encoding) |content_encoding|
                    if (content_encoding.length() > 0) try content_encoding.toUTF8(bun.default_allocator) else null
                else
                    null;
                defer if (content_encoding_str) |ce| ce.deinit();
                var credentials_with_options = try StoreEngine.getCredentialsWithBindingOptions(s3, options, globalThis);
                defer credentials_with_options.deinit();
                const owned_credentials = try credentials_with_options.credentials.dupe();
                defer owned_credentials.deref();
                const value = try S3StreamEngine.writableStream(
                    owned_credentials,
                    path,
                    globalThis,
                    credentials_with_options.options,
                    this.contentTypeOrMimeType(),
                    if (content_disposition_str) |cd| cd.slice() else null,
                    if (content_encoding_str) |ce| ce.slice() else null,
                    proxy_url,
                    credentials_with_options.storage_class,
                    credentials_with_options.request_payer,
                );
                return .{ .network = value };
            },
        };
        const value = try S3StreamEngine.writableStream(
            s3.getCredentials(),
            path,
            globalThis,
            .{},
            this.contentTypeOrMimeType(),
            null,
            null,
            proxy_url,
            null,
            s3.request_payer,
        );
        return .{ .network = value };
    }

    if (Environment.isWindows) {
        const pathlike = store.data.file.pathlike;
        const vm = globalThis.bunVM();
        const fd: bun.FD = if (pathlike == .fd) pathlike.fd else brk: {
            var file_path: bun.PathBuffer = undefined;
            switch (bun.sys.open(
                pathlike.path.sliceZ(&file_path),
                bun.O.WRONLY | bun.O.CREAT | bun.O.NONBLOCK,
                write_permissions,
            )) {
                .result => |result| {
                    break :brk switch (result.makeLibUVOwnedForSyscall(.open, .close_on_fail)) {
                        .result => |fd| fd,
                        .err => |err| return context.fail(.system, try bun.bindgen.SystemError.fromSysError(err.withPath(pathlike.path.slice()))),
                    };
                },
                .err => |err| {
                    return context.fail(.system, try bun.bindgen.SystemError.fromSysError(err.withPath(pathlike.path.slice())));
                },
            }
            @compileError("unreachable");
        };
        var owns_opened_fd = pathlike == .path;
        defer {
            if (owns_opened_fd) _ = fd.closeAllowingStandardIo(null);
        }

        const is_stdout_or_stderr = brk: {
            if (pathlike != .fd) {
                break :brk false;
            }

            if (vm.rare_data) |rare| {
                if (store == rare.stdout_store) {
                    break :brk true;
                }

                if (store == rare.stderr_store) {
                    break :brk true;
                }
            }

            break :brk if (fd.stdioTag()) |tag| switch (tag) {
                .std_out, .std_err => true,
                else => false,
            } else false;
        };
        const sink = try jsc.WebCore.FileSink.create(globalThis.bunVM().eventLoop());
        sink.writer.owns_fd = pathlike != .fd;

        if (is_stdout_or_stderr) {
            switch (sink.writer.startSync(fd)) {
                .err => |err| {
                    sink.deref();
                    return context.fail(.system, try bun.bindgen.SystemError.fromSysError(err));
                },
                else => {},
            }
        } else {
            switch (sink.writer.start(fd, .{})) {
                .err => |err| {
                    sink.deref();
                    return context.fail(.system, try bun.bindgen.SystemError.fromSysError(err));
                },
                else => {},
            }
        }
        owns_opened_fd = false;

        return .{ .file = try jsc.WebCore.FileSink.JSSink.createRef(globalThis, sink) };
    }

    const sink = try jsc.WebCore.FileSink.create(globalThis.bunVM().eventLoop());
    var owns_sink = true;
    defer if (owns_sink) sink.deref();

    const input_path: jsc.WebCore.PathOrFileDescriptor = brk: {
        if (store.data.file.pathlike == .fd) {
            break :brk .{ .fd = store.data.file.pathlike.fd };
        } else {
            break :brk .{
                .path = try bun.String.Slice.initDupe(
                    bun.default_allocator,
                    store.data.file.pathlike.path.slice(),
                ),
            };
        }
    };
    defer input_path.deinit();

    var stream_start: bun.webcore.streams.Start = .{
        .FileSink = .{
            .input_path = input_path,
        },
    };

    if (options) |input| switch (input) {
        .nulled, .undefined, .invalid => {},
        .options => |resolved| {
            stream_start.FileSink.chunk_size = jsc.WebCore.streams.Start.bindingHighWaterMark(resolved) orelse 0;
        },
    };

    switch (sink.start(stream_start)) {
        .err => |err| {
            return context.fail(.system, try bun.bindgen.SystemError.fromSysError(err));
        },
        else => {},
    }

    owns_sink = false;
    return .{ .file = try jsc.WebCore.FileSink.JSSink.createRef(globalThis, sink) };
}

pub fn getSliceFrom(this: *Blob, relativeStart: i64, relativeEnd: i64, content_type: *bun.bindgen.OwnedBytes, content_type_was_set: bool) bun.OOM!*Blob {
    const offset = this.offset +| @as(SizeType, @intCast(relativeStart));
    const len = @as(SizeType, @intCast(@max(relativeEnd -| relativeStart, 0)));

    var blob: Blob = .{
        .store = if (this.store) |store| store.clone() else null,
        .charset = this.charset,
        .offset = offset,
        .size = len,
        .content_type = content_type.take(),
        .content_type_was_set = content_type_was_set,
    };
    defer blob.deinit();
    return Blob.new(&blob);
}

/// https://w3c.github.io/FileAPI/#slice-method-algo
/// The slice() method returns a new Blob object with bytes ranging from the
/// optional start parameter up to but not including the optional end
/// parameter, and with a type attribute that is the value of the optional
/// contentType parameter. It must act as follows:
pub fn getSliceWithArguments(
    this: *Blob,
    start_argument: anytype,
    end_argument: anytype,
    content_type_argument: anytype,
) bun.OOM!*Blob {
    const allocator = bun.default_allocator;

    var start_value: ?i64 = null;
    var end_value: ?i64 = null;
    var content_type_value: ?bun.bindgen.DOMStringView = null;
    var content_type_from_position = false;

    if (start_argument) |value| switch (value) {
        .number => |number| start_value = number,
        .content_type => |content_type| {
            content_type_value = content_type;
            content_type_from_position = true;
        },
        .ignored => {},
    };

    if (!content_type_from_position) {
        if (end_argument) |value| switch (value) {
            .number => |number| end_value = number,
            .content_type => |content_type| {
                content_type_value = content_type;
                content_type_from_position = true;
            },
            .ignored => {},
        };
    }

    if (!content_type_from_position) {
        if (content_type_argument) |value| switch (value) {
            .string => |content_type| content_type_value = content_type,
            .ignored => {},
        };
    }

    // If the optional start parameter is not used as a parameter when making this call, let relativeStart be 0.
    var relativeStart: i64 = 0;

    // If the optional end parameter is not used as a parameter when making this call, let relativeEnd be size.
    var relativeEnd: i64 = @as(i64, @intCast(this.size));

    if (start_value) |start| {
        if (start < 0) {
            // If the optional start parameter is negative, let relativeStart be start + size.
            relativeStart = @as(i64, @intCast(@max(start +% @as(i64, @intCast(this.size)), 0)));
        } else {
            // Otherwise, let relativeStart be start.
            relativeStart = @min(@as(i64, @intCast(start)), @as(i64, @intCast(this.size)));
        }
    }

    if (end_value) |end| {
        // If end is negative, let relativeEnd be max((size + end), 0).
        if (end < 0) {
            relativeEnd = @as(i64, @intCast(@max(end +% @as(i64, @intCast(this.size)), 0)));
        } else {
            // Otherwise, let relativeEnd be min(end, size).
            relativeEnd = @min(@as(i64, @intCast(end)), @as(i64, @intCast(this.size)));
        }
    }

    var content_type: bun.bindgen.OwnedBytes = .empty();
    var content_type_was_set = false;
    if (content_type_value) |content_type_view| {
        inner: {
            const slicer = try content_type_view.toUTF8(allocator);
            defer slicer.deinit();
            const slice = slicer.slice();
            if (!strings.isAllASCII(slice)) {
                break :inner;
            }

            content_type_was_set = slice.len > 0;
            const content_type_buf = try allocator.alloc(u8, slice.len);
            _ = strings.copyLowercase(slice, content_type_buf);
            content_type = .fromDefaultAllocatedSlice(content_type_buf);
        }
    }

    return this.getSliceFrom(relativeStart, relativeEnd, &content_type, content_type_was_set);
}

pub fn getMimeType(this: *const Blob) ?bun.http.MimeType {
    if (this.storePtr()) |store| {
        return store.mime_type;
    }

    return null;
}

pub fn getMimeTypeOrContentType(this: *const Blob) ?bun.http.MimeType {
    if (this.content_type_was_set) {
        return bun.http.MimeType.init(this.content_type.slice());
    }

    if (this.storePtr()) |store| {
        return store.mime_type;
    }

    return null;
}

pub fn getType(
    this: *Blob,
) bun.OOM!bun.bindgen.DOMString {
    if (!this.content_type.isEmpty()) {
        return bun.bindgen.DOMString.fromUTF8(this.content_type.slice());
    }

    if (this.storePtr()) |store| {
        return bun.bindgen.DOMString.fromUTF8(store.mime_type.value);
    }

    return bun.bindgen.DOMString.fromUTF8("");
}

pub fn getNameString(this: *Blob) bun.OOM!?*const bun.bindgen.ThreadSafeDOMString {
    if (this.name) |*name| return name;

    if (this.getFileName()) |path| {
        this.name = try bun.bindgen.ThreadSafeDOMString.fromUTF8(path);
        return &this.name.?;
    }

    return null;
}

fn getNameValue(
    this: *Blob,
) bun.OOM!?bun.bindgen.DOMString {
    const name = (try this.getNameString()) orelse return null;
    var owned = name.clone();
    return try bun.bindgen.DOMString.fromBunString(owned.takeBunString());
}

fn setNameString(
    this: *Blob,
    value: bun.bindgen.DOMStringView,
) bun.OOM!void {
    var owned = value.toOwned();
    defer owned.deinit();
    const replacement = try owned.toThreadSafe();
    if (this.name) |*old_name| old_name.deinit();
    this.name = replacement;
}

pub fn getFileName(
    this: *const Blob,
) ?[]const u8 {
    if (this.storePtr()) |store| {
        if (store.data == .file) {
            if (store.data.file.pathlike == .path) {
                return store.data.file.pathlike.path.slice();
            }

            // we shouldn't return Number here.
        } else if (store.data == .bytes) {
            return store.data.bytes.fileName();
        } else if (store.data == .s3) {
            return store.data.s3.path();
        }
    }

    return null;
}

pub fn getLoader(blob: *const Blob, jsc_vm: *VirtualMachine) ?bun.options.Loader {
    if (blob.getFileName()) |filename| {
        const current_path = bun.fs.Path.init(filename);
        return current_path.loader(&jsc_vm.transpiler.options.loaders) orelse .tsx;
    } else if (blob.getMimeTypeOrContentType()) |mime_type| {
        return .fromMimeType(mime_type);
    } else {
        // Be maximally permissive.
        return .tsx;
    }
}

pub fn getLastModified(
    this: *Blob,
) f64 {
    if (this.is_jsdom_file) return this.last_modified;
    if (this.storePtr()) |store| {
        if (store.data == .file) {
            // last_modified can be already set during read.
            if (store.data.file.last_modified == Store.uninitialized_timestamp and !this.isS3()) {
                resolveFileStat(store);
            }
            return @floatFromInt(store.data.file.last_modified);
        }
    }

    return @floatFromInt(Store.uninitialized_timestamp);
}

pub fn sizeIfKnown(this: *Blob) ?SizeType {
    if (this.size == Blob.max_size) {
        this.resolveSize();
    }

    // If the file doesn't exist or is not seekable
    // signal that the size is unknown.
    if (this.storePtr()) |store| {
        if (store.data == .file and !(store.data.file.seekable orelse false)) {
            return null;
        }
    }

    if (this.size == Blob.max_size)
        return null;

    return this.size;
}

fn bindGetSizeForBindings(args: bun.bindgen.Args(BlobGetSizeForBindingsSchema)) bun.bindgen.Return(BlobGetSizeForBindingsSchema) {
    const blob: *Blob = @ptrCast(@alignCast(args.blob));
    return if (blob.sizeIfKnown()) |size| size else null;
}

fn releaseBlobSharedData(_: ?*anyopaque, context: ?*anyopaque) callconv(.c) void {
    const blob: *Blob = @ptrCast(@alignCast(context orelse @panic("Blob byte owner is missing its source")));
    blob.deref();
}

fn bindBlobSharedData(args: bun.bindgen.Args(BlobSharedDataSchema)) bun.OOM!bun.bindgen.Return(BlobSharedDataSchema) {
    const blob: *Blob = @ptrCast(@alignCast(args.blob));
    const data = blob.sharedView();
    blob.ref();
    const owner = try bun.bindgen.adoptExternalBytesOwner(
        if (data.len == 0) null else @ptrCast(@constCast(data.ptr)),
        data.len,
        blob,
        releaseBlobSharedData,
    );
    return bun.bindgen.Return(BlobSharedDataSchema).initNative(owner);
}

fn bindBlobNeedsToReadFile(args: bun.bindgen.Args(BlobNeedsToReadFileSchema)) bun.bindgen.Return(BlobNeedsToReadFileSchema) {
    const blob: *Blob = @ptrCast(@alignCast(args.blob));
    return blob.needsToReadFile();
}

fn createFromBytesForBindings(bytes: []const u8) bun.OOM!*Blob {
    if (bytes.len == 0) {
        var blob = initEmpty();
        return new(&blob);
    }

    const owned_bytes = try bun.default_allocator.dupe(u8, bytes);
    const store = try Store.init(owned_bytes, bun.default_allocator);
    var blob = try initWithStore(store);
    defer blob.deinit();
    return new(&blob);
}

fn bindBlobCreateFromBytes(_: bun.bindgen.CallContext(BlobCreateFromBytesSchema), args: bun.bindgen.Args(BlobCreateFromBytesSchema)) bun.JSError!bun.bindgen.Return(BlobCreateFromBytesSchema) {
    const bytes = args.bytes.unsafePtr("the C++ caller owns the source bytes until synchronous Blob construction copies them");
    return bun.bindgen.Return(BlobCreateFromBytesSchema).initNative(try createFromBytesForBindings(bytes));
}

fn setContentTypeForBindings(blob: *Blob, mime: bun.bindgen.DOMStringView) bun.OOM!void {
    if (mime.length() == 0) return;

    var utf8 = try mime.toUTF8(bun.default_allocator);
    blob.setContentTypeOwned(@constCast(try utf8.intoOwnedSlice(bun.default_allocator)), .explicit);
}

fn bindBlobCreateFromBytesWithType(_: bun.bindgen.CallContext(BlobCreateFromBytesWithTypeSchema), args: bun.bindgen.Args(BlobCreateFromBytesWithTypeSchema)) bun.JSError!bun.bindgen.Return(BlobCreateFromBytesWithTypeSchema) {
    const bytes = args.bytes.unsafePtr("the C++ caller owns the source bytes until synchronous Blob construction copies them");
    const blob = try createFromBytesForBindings(bytes);
    errdefer blob.deref();
    try setContentTypeForBindings(blob, args.mime);
    return bun.bindgen.Return(BlobCreateFromBytesWithTypeSchema).initNative(blob);
}

fn adoptOwnedBytesWithTypeForBindings(resource: *bun.bindgen.OwnedByteResource, mime: bun.bindgen.DOMStringView) bun.OOM!*Blob {
    if (resource.length() == 0) {
        resource.deinit();
        var blob = initEmpty();
        defer blob.deinit();
        try setContentTypeForBindings(&blob, mime);
        return new(&blob);
    }
    const store = try Store.initByteResource(resource);
    var blob = try initWithStore(store);
    defer blob.deinit();
    try setContentTypeForBindings(&blob, mime);
    return new(&blob);
}

fn bindBlobAdoptOwnedBytesWithType(_: bun.bindgen.CallContext(BlobAdoptOwnedBytesWithTypeSchema), args: *bun.bindgen.Args(BlobAdoptOwnedBytesWithTypeSchema)) bun.JSError!bun.bindgen.Return(BlobAdoptOwnedBytesWithTypeSchema) {
    var resource = args.owner.takeByteResource();
    defer resource.deinit();
    return bun.bindgen.Return(BlobAdoptOwnedBytesWithTypeSchema).initNative(
        try adoptOwnedBytesWithTypeForBindings(&resource, args.mime),
    );
}

fn getStatSource(this: *const Blob) bun.bindgen.Return(BlobStatSourceSchema) {
    const store = this.storePtr() orelse return .none;
    return switch (store.data) {
        .file => .file,
        .s3 => .s3,
        else => .none,
    };
}

fn completeFileStat(
    this: *Blob,
    globalThis: *jsc.JSGlobalObject,
    context: bun.bindgen.CallContext(BlobStatFileSchema),
) bun.bindgen.CallError(BlobStatFileSchema)!void {
    const store = this.storePtr() orelse @panic("Blob stat source changed before file stat");
    const vm = globalThis.bunVM();
    const runtime: NodeFSBindings.AsyncRuntime = .{
        .background_tasks = &vm.background_tasks,
        .io = null,
    };
    switch (store.data) {
        .file => |*file| switch (file.pathlike) {
            .path => |path_like| {
                const Task = NodeFSBindings.Async.materializedStat(BlobStatFileSchema);
                var args: bun.api.node.fs.Arguments.Stat = .{
                    .path = .{
                        .encoded_slice = switch (path_like) {
                            .encoded_slice => |slice| try slice.toOwned(bun.default_allocator),
                            else => try bun.TextView.toSliceClone(.{ .utf8 = path_like.slice() }, bun.default_allocator),
                        },
                    },
                };
                errdefer args.deinit();
                var completion_view = context.completion();
                const completion = try Task.Completion.take(&completion_view, {});
                Task.schedule(args, runtime, completion);
            },
            .fd => |fd| {
                const Task = NodeFSBindings.Async.materializedFstat(BlobStatFileSchema);
                var completion_view = context.completion();
                const completion = try Task.Completion.take(&completion_view, {});
                Task.schedule(.{ .fd = fd }, runtime, completion);
            },
        },
        else => @panic("Blob stat source changed before file stat"),
    }
}

fn completeS3Stat(
    this: *Blob,
    globalThis: *jsc.JSGlobalObject,
    context: bun.bindgen.CallContext(BlobStatS3Schema),
) bun.bindgen.CallError(BlobStatS3Schema)!void {
    if (!this.isS3()) @panic("Blob stat source changed before S3 stat");
    var acceptor = bun.S3.S3StatAcceptor.takeForContext(context);
    S3File.stat(.stat, globalThis, this, &acceptor) catch {
        acceptor.outOfMemory();
    };
}
pub fn getSize(this: *Blob) f64 {
    if (this.size == Blob.max_size) {
        if (this.isS3()) {
            return std.math.nan(f64);
        }
        this.resolveSize();
        if (this.size == Blob.max_size and this.storePtr() != null) {
            return std.math.inf(f64);
        } else if (this.size == 0 and this.storePtr() != null) {
            const store = this.storePtr().?;
            if (store.data == .file and
                (store.data.file.seekable orelse true) == false and
                store.data.file.max_size == Blob.max_size)
            {
                return std.math.inf(f64);
            }
        }
    }

    return @floatFromInt(this.size);
}

pub fn resolveSize(this: *Blob) void {
    if (this.storePtr()) |store| {
        if (store.data == .bytes) {
            const offset = this.offset;
            const store_size = store.size();
            if (store_size != Blob.max_size) {
                this.offset = @min(store_size, offset);
                const available = store_size - this.offset;
                this.size = if (this.size == Blob.max_size) available else @min(this.size, available);
            }

            return;
        } else if (store.data == .file) {
            if (store.data.file.seekable == null) {
                resolveFileStat(store);
            }

            if (store.data.file.seekable != null and store.data.file.max_size != Blob.max_size) {
                const store_size = store.data.file.max_size;
                const offset = this.offset;

                this.offset = @min(store_size, offset);
                const available = store_size - this.offset;
                this.size = if (this.size == Blob.max_size) available else @min(this.size, available);
                return;
            }

            // For non-seekable files (pipes, FIFOs), the size is genuinely
            // unknown — leave it as max_size so that stream readers don't
            // treat it as an empty file.
            if (store.data.file.seekable != null and store.data.file.seekable.? == false) {
                return;
            }
        } else if (store.data == .s3) {
            return;
        }

        // A failed stat does not invalidate a previously resolved byte window.
        if (this.size == Blob.max_size) this.size = 0;
    } else {
        this.size = 0;
    }
}

/// resolve file stat like size, last_modified
fn resolveFileStat(store: *Store) void {
    if (store.data.file.pathlike == .path) {
        var buffer: bun.PathBuffer = undefined;
        switch (bun.sys.stat(store.data.file.pathlike.path.sliceZ(&buffer))) {
            .result => |stat| {
                store.data.file.max_size = if (bun.isRegularFile(stat.mode) or stat.size > 0)
                    @truncate(@as(u64, @intCast(@max(stat.size, 0))))
                else
                    Blob.max_size;
                store.data.file.mode = @intCast(stat.mode);
                store.data.file.seekable = bun.isRegularFile(stat.mode);
                store.data.file.last_modified = jsc.toJSTime(stat.mtime().sec, stat.mtime().nsec);
            },
            // the file may not exist yet. Thats's okay.
            else => {},
        }
    } else if (store.data.file.pathlike == .fd) {
        switch (bun.sys.fstat(store.data.file.pathlike.fd)) {
            .result => |stat| {
                store.data.file.max_size = if (bun.isRegularFile(stat.mode) or stat.size > 0)
                    @as(SizeType, @truncate(@as(u64, @intCast(@max(stat.size, 0)))))
                else
                    Blob.max_size;
                store.data.file.mode = @intCast(stat.mode);
                store.data.file.seekable = bun.isRegularFile(stat.mode);
                store.data.file.last_modified = jsc.toJSTime(stat.mtime().sec, stat.mtime().nsec);
            },
            // the file may not exist yet. Thats's okay.
            else => {},
        }
    }
}

pub fn finalize(this: *Blob) void {
    bun.assertf(
        this.isHeapAllocated(),
        "`finalize` may only be called on a heap-allocated Blob",
        .{},
    );
    var shared = Blob.Ref.adopt(this);
    shared.deinit();
}

pub fn initWithAllASCII(bytes: []u8, allocator: std.mem.Allocator, is_all_ascii: bool) bun.OOM!Blob {
    var blob = try init(bytes, allocator);
    if (blob.storePtr()) |store| store.is_all_ascii = is_all_ascii;
    blob.charset = .fromBool(is_all_ascii);
    return blob;
}

/// Consumes `bytes`, including on failure; they must come from `allocator`.
pub fn init(bytes: []u8, allocator: std.mem.Allocator) bun.OOM!Blob {
    if (bytes.len == 0) {
        allocator.free(bytes);
        return initEmpty();
    }
    return initWithStore(try Store.init(bytes, allocator));
}

pub fn initByteList(bytes: *bun.bindgen.OwnedByteList) bun.OOM!Blob {
    if (bytes.length() == 0) {
        bytes.deinit();
        return initEmpty();
    }
    const store = try Store.initByteList(bytes);
    return .{ .size = store.size(), .store = .adopt(store) };
}

pub fn createWithBytesAndAllocator(
    bytes: []u8,
    allocator: std.mem.Allocator,
    was_string: bool,
) bun.OOM!Blob {
    var blob = try init(bytes, allocator);
    errdefer blob.deinit();
    if (was_string) try blob.setContentType(MimeType.text.value, .inferred);
    return blob;
}

pub fn create(
    bytes_: []const u8,
    allocator_: std.mem.Allocator,
    was_string: bool,
) bun.OOM!Blob {
    if (comptime Environment.isLinux) {
        if (bun.linux.MemFdAllocator.shouldUse(bytes_)) {
            switch (bun.linux.MemFdAllocator.create(bytes_)) {
                .err => {},
                .result => |result| {
                    var bytes = result;
                    const store = bun.default_allocator.create(Store) catch |err| {
                        bytes.deinit();
                        return err;
                    };
                    store.* = .{
                        .data = .{ .bytes = bytes },
                        .allocator = bun.default_allocator,
                    };
                    var blob = try initWithStore(store);
                    errdefer blob.deinit();
                    if (was_string and blob.content_type.isEmpty()) {
                        try blob.setContentType(MimeType.text.value, .inferred);
                    }

                    return blob;
                },
            }
        }
    }

    return createWithBytesAndAllocator(try allocator_.dupe(u8, bytes_), allocator_, was_string);
}

/// Consumes one reference to `store`, including on failure.
pub fn initWithStore(store: *Blob.Store) bun.OOM!Blob {
    var blob = Blob{
        .size = store.size(),
        .store = .adopt(store),
    };
    errdefer blob.deinit();
    if (store.data == .file) try blob.setContentType(store.data.file.mime_type.value, .inferred);
    return blob;
}

pub fn initEmpty() Blob {
    return Blob{
        .size = 0,
        .store = null,
    };
}

// Transferring doesn't change the reference count
// It is a move
inline fn transfer(this: *Blob) void {
    if (this.store) |*store| _ = store.take();
    this.store = null;
}

pub fn detach(this: *Blob) void {
    if (this.store) |*store| store.deinit();
    this.store = null;
}

pub fn take(this: *Blob) Blob {
    const value = this.*;
    this.* = .{};
    return value;
}

pub fn dupe(this: *const Blob) bun.OOM!Blob {
    var duped = this.*;
    duped.content_type = try this.content_type.clone();
    duped.store = if (this.store) |store| store.clone() else null;
    duped.setNotHeapAllocated();
    duped.name = if (duped.name) |*name| name.clone() else null;
    return duped;
}

const BlobMemberOperation = enum {
    array_buffer,
    bytes,
    delete,
    form_data,
    json,
    stat_file,
    stat_s3,
    stat_source,
    stream,
    text,
    unlink,
    writer,
};

pub const BlobJSBinding = struct {
    bindgen_state: bun.bindgen.ClassState = .{},
    blob: bun.bindgen.RefNative(Blob, .vm),
    name_override: enum { none, nulled, undefined } = .none,

    fn init(blob: *Blob) BlobJSBinding {
        blob.calculateEstimatedByteSize();
        return .{ .blob = .adopt(blob) };
    }

    fn create(blob: *Blob) bun.OOM!*BlobJSBinding {
        errdefer blob.deref();
        const binding = try bun.default_allocator.create(BlobJSBinding);
        binding.* = BlobJSBinding.init(blob);
        return binding;
    }

    fn release(this: *BlobJSBinding) void {
        this.blob.deinit();
    }

    pub fn native(this: *const BlobJSBinding) *Blob {
        return this.blob.get();
    }

    pub fn inspectCustom(_: *BlobJSBinding, context: bun.bindgen.CallContext(BlobInspectSchema), args: bun.bindgen.Args(BlobInspectSchema)) bun.JSError!bun.bindgen.DOMString {
        return @import("./BlobInspection.zig").inspect(context, args);
    }

    pub fn construct(
        context: bun.bindgen.CallContext(BlobConstructorSchema),
        args: bun.bindgen.Args(BlobConstructorSchema),
    ) bun.bindgen.CallError(BlobConstructorSchema)!*BlobJSBinding {
        const global = context.viewToken().globalObject();
        var blob = if (args.parts) |*parts|
            try blobFromBindgenPartsInput(context, parts)
        else
            emptyConstructorBlob();
        errdefer blob.deinit();

        if (args.options) |*options| {
            try applyConstructorContentType(
                &blob,
                global,
                if (options.content_type) |*content_type| content_type else null,
            );
        }
        blob.is_jsdom_file = false;
        return BlobJSBinding.create(try Blob.new(&blob));
    }

    pub fn memberFromBinding(
        this: *BlobJSBinding,
        comptime operation: BlobMemberOperation,
        context: anytype,
        args: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!BlobMemberBindingResult(operation, @TypeOf(context)) {
        const global = context.viewToken().globalObject();
        return switch (operation) {
            .array_buffer => completeBlobReadFromContext(BlobArrayBufferSchema, this.native(), global, context),
            .bytes => completeBlobReadFromContext(BlobBytesSchema, this.native(), global, context),
            .delete => doUnlink(BlobDeleteSchema, this.native(), global, context, args.options),
            .form_data => completeBlobReadFromContext(BlobFormDataSchema, this.native(), global, context),
            .json => completeBlobReadFromContext(BlobJSONSchema, this.native(), global, context),
            .stat_file => completeFileStat(this.native(), global, context),
            .stat_s3 => completeS3Stat(this.native(), global, context),
            .stat_source => this.native().getStatSource(),
            .stream => stream: {
                var readable = try this.native().getStreamWithChunkSize(global, args.chunkSize);
                defer readable.deinit();
                break :stream .{
                    .stream = readable.toResult(context),
                    .cache = this.native().shouldCacheStream(),
                };
            },
            .text => completeBlobReadFromContext(BlobTextSchema, this.native(), global, context),
            .unlink => doUnlink(BlobUnlinkSchema, this.native(), global, context, args.options),
            .writer => this.native().getWriter(global, context, args.options),
        };
    }

    pub fn destroy(this: *BlobJSBinding) void {
        this.release();
        bun.destroy(this);
    }

    pub fn memoryUsage(this: *const BlobJSBinding, _: bun.bindgen.MemoryUsageContext(.any)) usize {
        return this.native().estimatedSize();
    }

    pub fn structuredCloneSerialize(
        this: *const BlobJSBinding,
        _: bun.bindgen.StructuredCloneContext(BlobSchema),
        writer: bun.bindgen.StructuredCloneWriter,
    ) bun.JSError!void {
        try _onStructuredCloneSerialize(this.native(), writer);
    }

    pub fn structuredCloneDeserialize(
        context: bun.bindgen.StructuredCloneContext(BlobSchema),
        reader: *bun.bindgen.StructuredCloneReader,
    ) bun.bindgen.StructuredCloneError!*BlobJSBinding {
        return structuredCloneDeserializeFromBinding(context, reader);
    }

    pub fn structuredCloneDeserializeFromBinding(
        context: anytype,
        reader: *bun.bindgen.StructuredCloneReader,
    ) bun.bindgen.StructuredCloneError!*BlobJSBinding {
        const global = context.viewToken().globalObject();
        var std_reader = std.Io.Reader.fixed(reader.ptr[0..reader.remaining()]);
        const blob = _onStructuredCloneDeserialize(global, &std_reader) catch |err| switch (err) {
            error.OutOfMemory => return global.throwOutOfMemory(),
            else => return error.InvalidData,
        };
        reader.ptr += std_reader.seek;
        return BlobJSBinding.create(blob);
    }

    pub fn bindGetArrayBuffer(
        this: *BlobJSBinding,
        context: bun.bindgen.CallContext(BlobArrayBufferSchema),
        _: bun.bindgen.Args(BlobArrayBufferSchema),
    ) bun.bindgen.CallError(BlobArrayBufferSchema)!void {
        return this.memberFromBinding(.array_buffer, context, .{});
    }

    pub fn bindGetBytes(
        this: *BlobJSBinding,
        context: bun.bindgen.CallContext(BlobBytesSchema),
        _: bun.bindgen.Args(BlobBytesSchema),
    ) bun.bindgen.CallError(BlobBytesSchema)!void {
        return this.memberFromBinding(.bytes, context, .{});
    }

    pub fn bindDelete(
        this: *BlobJSBinding,
        context: bun.bindgen.CallContext(BlobDeleteSchema),
        args: bun.bindgen.Args(BlobDeleteSchema),
    ) bun.bindgen.CallError(BlobDeleteSchema)!void {
        return this.memberFromBinding(.delete, context, args);
    }

    pub fn bindUnlink(
        this: *BlobJSBinding,
        context: bun.bindgen.CallContext(BlobUnlinkSchema),
        args: bun.bindgen.Args(BlobUnlinkSchema),
    ) bun.bindgen.CallError(BlobUnlinkSchema)!void {
        return this.memberFromBinding(.unlink, context, args);
    }

    pub fn bindGetExists(
        this: *BlobJSBinding,
        context: bun.bindgen.CallContext(BlobExistsSchema),
        _: bun.bindgen.Args(BlobExistsSchema),
    ) bun.bindgen.CallError(BlobExistsSchema)!void {
        return this.native().completeExists(context.viewToken().globalObject(), context);
    }

    pub fn bindGetFormData(
        this: *BlobJSBinding,
        context: bun.bindgen.CallContext(BlobFormDataSchema),
        _: bun.bindgen.Args(BlobFormDataSchema),
    ) bun.bindgen.CallError(BlobFormDataSchema)!void {
        return this.memberFromBinding(.form_data, context, .{});
    }

    pub fn bindDoImage(
        this: *BlobJSBinding,
        context: bun.bindgen.CallContext(BlobImageSchema),
        args: bun.bindgen.Args(BlobImageSchema),
    ) bun.JSError!bun.bindgen.Return(BlobImageSchema) {
        const options = if (args.options) |options_arg|
            Image.ConstructorOptions.fromBindgen(options_arg)
        else
            Image.ConstructorOptions{};
        return doImageWithOptions(context, this.native(), options);
    }

    pub fn bindGetJSON(
        this: *BlobJSBinding,
        context: bun.bindgen.CallContext(BlobJSONSchema),
        _: bun.bindgen.Args(BlobJSONSchema),
    ) bun.bindgen.CallError(BlobJSONSchema)!void {
        return this.memberFromBinding(.json, context, .{});
    }

    pub fn bindGetLastModified(
        this: *BlobJSBinding,
        _: bun.bindgen.CallContext(BlobLastModifiedSchema),
        _: bun.bindgen.Args(BlobLastModifiedSchema),
    ) bun.JSError!f64 {
        return this.native().getLastModified();
    }

    pub fn bindGetName(
        this: *BlobJSBinding,
        _: bun.bindgen.CallContext(BlobNameGetterSchema),
        _: bun.bindgen.Args(BlobNameGetterSchema),
    ) bun.JSError!bun.bindgen.Return(BlobNameGetterSchema) {
        return this.getName();
    }

    pub fn bindSetName(
        this: *BlobJSBinding,
        _: bun.bindgen.CallContext(BlobNameSetterSchema),
        args: bun.bindgen.Args(BlobNameSetterSchema),
    ) bun.bindgen.CallError(BlobNameSetterSchema)!void {
        return this.setName(args.value);
    }

    fn getName(this: *BlobJSBinding) bun.OOM!bun.bindgen.Return(BlobNameGetterSchema) {
        return switch (this.name_override) {
            .none => if (try this.native().getNameValue()) |name| .{ .string = name } else .{ .undefined = true },
            .nulled => .{ .nulled = true },
            .undefined => .{ .undefined = true },
        };
    }

    fn setName(this: *BlobJSBinding, value: @FieldType(bun.bindgen.Args(BlobNameSetterSchema), "value")) bun.OOM!void {
        switch (value) {
            .string => |name| {
                try this.native().setNameString(name);
                this.name_override = .none;
            },
            .nulled, .undefined => {
                const blob = this.native();
                // File serialization retains its filename even when the wrapper exposes a nullish name.
                if (!blob.is_jsdom_file) {
                    if (blob.name) |*name| name.deinit();
                    blob.name = null;
                }
                this.name_override = if (value == .nulled) .nulled else .undefined;
            },
            .invalid => {},
        }
    }

    pub fn bindGetSize(
        this: *BlobJSBinding,
        _: bun.bindgen.CallContext(BlobSizeSchema),
        _: bun.bindgen.Args(BlobSizeSchema),
    ) bun.JSError!f64 {
        return this.native().getSize();
    }

    pub fn bindGetSlice(
        this: *BlobJSBinding,
        context: bun.bindgen.CallContext(BlobSliceSchema),
        args: bun.bindgen.Args(BlobSliceSchema),
    ) bun.JSError!bun.bindgen.Return(BlobSliceSchema) {
        const blob = try this.native().getSliceWithArguments(args.start, args.end, args.contentType);
        return blob.toBindingRef(context);
    }

    pub fn bindGetStatSource(
        this: *BlobJSBinding,
        context: bun.bindgen.CallContext(BlobStatSourceSchema),
        _: bun.bindgen.Args(BlobStatSourceSchema),
    ) bun.bindgen.CallError(BlobStatSourceSchema)!bun.bindgen.Return(BlobStatSourceSchema) {
        return this.memberFromBinding(.stat_source, context, .{});
    }

    pub fn bindGetStatFile(
        this: *BlobJSBinding,
        context: bun.bindgen.CallContext(BlobStatFileSchema),
        _: bun.bindgen.Args(BlobStatFileSchema),
    ) bun.bindgen.CallError(BlobStatFileSchema)!void {
        return this.memberFromBinding(.stat_file, context, .{});
    }

    pub fn bindGetStatS3(
        this: *BlobJSBinding,
        context: bun.bindgen.CallContext(BlobStatS3Schema),
        _: bun.bindgen.Args(BlobStatS3Schema),
    ) bun.bindgen.CallError(BlobStatS3Schema)!void {
        return this.memberFromBinding(.stat_s3, context, .{});
    }

    pub fn bindGetStreamNative(
        this: *BlobJSBinding,
        context: bun.bindgen.CallContext(BlobStreamNativeSchema),
        args: bun.bindgen.Args(BlobStreamNativeSchema),
    ) bun.JSError!bun.bindgen.Return(BlobStreamNativeSchema) {
        return this.memberFromBinding(.stream, context, args);
    }

    pub fn bindGetText(
        this: *BlobJSBinding,
        context: bun.bindgen.CallContext(BlobTextSchema),
        _: bun.bindgen.Args(BlobTextSchema),
    ) bun.bindgen.CallError(BlobTextSchema)!void {
        return this.memberFromBinding(.text, context, .{});
    }

    pub fn bindGetType(
        this: *BlobJSBinding,
        _: bun.bindgen.CallContext(BlobTypeSchema),
        _: bun.bindgen.Args(BlobTypeSchema),
    ) bun.JSError!bun.bindgen.DOMString {
        return this.native().getType();
    }

    pub fn bindDoWrite(
        this: *BlobJSBinding,
        context: bun.bindgen.CallContext(BlobWriteSchema),
        args: bun.bindgen.Args(BlobWriteSchema),
    ) bun.bindgen.CallError(BlobWriteSchema)!void {
        var completion = context.completion();
        var acceptor = write_file.WriteAcceptor.fromCompletion(write_file.WriteCompletions.takeForContext(context, &completion)) orelse return;
        defer acceptor.deinit();
        try this.native().doWrite(context.viewToken().globalObject(), context, args.data, args.options, &acceptor);
        acceptor.assertConsumed();
    }

    pub fn bindGetWriter(
        this: *BlobJSBinding,
        context: bun.bindgen.CallContext(BlobWriterSchema),
        args: bun.bindgen.Args(BlobWriterSchema),
    ) bun.bindgen.CallError(BlobWriterSchema)!bun.bindgen.Return(BlobWriterSchema) {
        return this.memberFromBinding(.writer, context, args);
    }
};

fn BlobMemberBindingResult(comptime operation: BlobMemberOperation, comptime Context: type) type {
    return switch (operation) {
        .array_buffer, .bytes, .delete, .form_data, .json, .stat_file, .stat_s3, .text, .unlink => void,
        else => bun.bindgen.Return(Context),
    };
}

pub const FileJSBinding = struct {
    pub const Parent = BlobJSBinding;

    bindgen_state: bun.bindgen.ClassState = .{},
    parent: BlobJSBinding,

    fn create(blob: *Blob) bun.OOM!*FileJSBinding {
        errdefer blob.deref();
        const binding = try bun.default_allocator.create(FileJSBinding);
        binding.* = .{ .parent = BlobJSBinding.init(blob) };
        return binding;
    }

    pub fn construct(
        context: bun.bindgen.CallContext(FileConstructorSchema),
        args: bun.bindgen.Args(FileConstructorSchema),
    ) bun.bindgen.CallError(FileConstructorSchema)!*FileJSBinding {
        const global = context.viewToken().globalObject();
        const parts_arg = args.parts orelse return context.fail(.missing_arguments, {});
        const name = args.name orelse return context.fail(.missing_arguments, {});

        const converted_parts = parts: {
            if (args.options != null) break :parts try parts_arg.convert(context);
            const forced = try parts_arg.convertLast(context);
            try context.lease(forced.proof);
            break :parts forced.converted;
        };
        const converted_options = if (args.options) |options_arg| options: {
            const forced = try options_arg.convertLast(context);
            try context.lease(forced.proof);
            break :options forced.converted;
        } else null;
        var blob = try blobFromBindgenPartsInput(context, &converted_parts.value);
        errdefer blob.deinit();
        try applyConstructorFileName(&blob, name);

        if (converted_options) |*converted| {
            try applyConstructorContentType(
                &blob,
                global,
                if (converted.value.content_type) |*content_type| content_type else null,
            );
            blob.last_modified = if (converted.value.last_modified) |last_modified|
                @floatFromInt(last_modified)
            else
                @floatFromInt(bun.timespec.realNow().ms());
        } else {
            blob.last_modified = @floatFromInt(bun.timespec.realNow().ms());
        }

        blob.is_jsdom_file = true;
        const binding = try bun.default_allocator.create(FileJSBinding);
        errdefer bun.destroy(binding);
        binding.* = .{ .parent = BlobJSBinding.init(try Blob.new(&blob)) };
        return binding;
    }

    pub fn asBlob(this: *FileJSBinding) *BlobJSBinding {
        return &this.parent;
    }

    pub fn bindGetName(this: *FileJSBinding, _: bun.bindgen.CallContext(FileNameGetterSchema), _: bun.bindgen.Args(FileNameGetterSchema)) bun.JSError!bun.bindgen.Return(FileNameGetterSchema) {
        return this.parent.getName();
    }

    pub fn bindSetName(this: *FileJSBinding, _: bun.bindgen.CallContext(FileNameSetterSchema), args: bun.bindgen.Args(FileNameSetterSchema)) bun.JSError!void {
        return this.parent.setName(args.value);
    }

    pub fn bindHasInstance(
        _: bun.bindgen.CallContext(FileHasInstanceSchema),
        args: bun.bindgen.Args(FileHasInstanceSchema),
    ) bun.JSError!bool {
        const blob = ((args.value orelse return false) orelse return false).get(BlobJSBinding);
        return blob.native().is_jsdom_file;
    }

    pub fn destroy(this: *FileJSBinding) void {
        this.parent.release();
        bun.destroy(this);
    }
};

pub const S3FileJSBinding = struct {
    pub const Parent = BlobJSBinding;

    bindgen_state: bun.bindgen.ClassState = .{},
    parent: BlobJSBinding,

    fn create(blob: *Blob) bun.OOM!*S3FileJSBinding {
        errdefer blob.deref();
        const binding = try bun.default_allocator.create(S3FileJSBinding);
        binding.* = .{ .parent = BlobJSBinding.init(blob) };
        return binding;
    }

    pub fn asBlob(this: *S3FileJSBinding) *BlobJSBinding {
        return &this.parent;
    }

    pub fn destroy(this: *S3FileJSBinding) void {
        this.parent.release();
        bun.destroy(this);
    }

    pub fn bindPresign(
        this: *S3FileJSBinding,
        context: bun.bindgen.CallContext(S3FilePresignMemberSchema),
        args: bun.bindgen.Args(S3FilePresignMemberSchema),
    ) bun.bindgen.CallError(S3FilePresignMemberSchema)!bun.bindgen.DOMString {
        return @import("./S3ClientEngine.zig").presignFile(this.parent.native(), context, args.options);
    }

    pub fn bindStat(
        this: *S3FileJSBinding,
        context: bun.bindgen.CallContext(S3FileStatMemberSchema),
        _: bun.bindgen.Args(S3FileStatMemberSchema),
    ) bun.bindgen.CallError(S3FileStatMemberSchema)!void {
        return this.statFromBinding(context);
    }

    pub fn statFromBinding(
        this: *S3FileJSBinding,
        context: bun.bindgen.CallContext(S3FileStatMemberSchema),
    ) bun.JSError!void {
        const global = context.viewToken().globalObject();
        var acceptor = bun.S3.S3StatAcceptor.takeForContext(context);
        S3File.stat(.stat, global, this.parent.native(), &acceptor) catch {
            acceptor.outOfMemory();
        };
    }

    pub fn bindBucket(
        this: *S3FileJSBinding,
        _: bun.bindgen.CallContext(S3FileBucketMemberSchema),
        _: bun.bindgen.Args(S3FileBucketMemberSchema),
    ) bun.JSError!?bun.bindgen.DOMString {
        return S3File.getBucket(this.parent.native());
    }
};

fn adoptBindingResult(
    this: *Blob,
    context: bun.bindgen.CallContext(BlobAdoptSchema),
) bun.JSError!bun.bindgen.Return(BlobAdoptSchema) {
    if (this.is_jsdom_file) {
        const binding = try FileJSBinding.create(this);
        return .{ .file = try FileClass.adoptResult(binding, context) };
    }
    if (this.isS3()) {
        const binding = try S3FileJSBinding.create(this);
        return .{ .s3_file = try S3FileClass.adoptResult(binding, context) };
    }
    const binding = try BlobJSBinding.create(this);
    return .{ .blob = try BlobClass.adoptResult(binding, context) };
}

pub fn toBindingRef(this: *Blob, context: anytype) bun.JSError!bun.bindgen.ClassRef(BlobSchema) {
    if (this.is_jsdom_file) return FileClass.adoptResultAs(BlobSchema, try FileJSBinding.create(this), context);
    if (this.isS3()) return S3FileClass.adoptResultAs(BlobSchema, try S3FileJSBinding.create(this), context);
    const binding = try BlobJSBinding.create(this);
    return BlobClass.adoptResult(binding, context);
}

pub fn deinit(this: *Blob) void {
    this.detach();
    if (this.name) |*name| name.deinit();
    this.name = null;

    this.content_type.deinit();

    if (this.isHeapAllocated()) {
        bun.destroy(this);
    }
}

pub fn sharedView(this: *const Blob) []const u8 {
    if (this.size == 0 or this.storePtr() == null) return "";
    var slice_ = this.storePtr().?.sharedView();
    if (slice_.len == 0) return "";
    // Defensive: `offset` may originate from untrusted structured-clone data.
    // Never index past the store's actual length regardless of caller state.
    slice_ = slice_[@min(@as(usize, this.offset), slice_.len)..];

    return slice_[0..@min(slice_.len, @as(usize, this.size))];
}

pub fn needsToReadFile(this: *const Blob) bool {
    return this.storePtr() != null and this.storePtr().?.data == .file;
}

pub const WTFStringImplRef = bun.bindgen.RefNative(bun.WTF._StringImplStruct, .any);

pub const Any = union(enum) {
    Blob: Blob,
    InternalBlob: Internal,
    WTFStringImpl: WTFStringImplRef,

    pub fn fromOwnedSlice(allocator: std.mem.Allocator, bytes: []u8) Any {
        return .{ .InternalBlob = .{ .bytes = .fromOwnedSlice(allocator, bytes) } };
    }

    pub fn fromArrayList(list: std.array_list.Managed(u8)) Any {
        return .{ .InternalBlob = .{ .bytes = .fromManaged(list) } };
    }

    pub fn take(this: *Any) Any {
        const value = this.*;
        this.* = .{ .Blob = .{} };
        return value;
    }

    /// Assumed that AnyBlob itself is covered by the caller.
    pub fn memoryCost(this: *const Any) usize {
        return switch (this.*) {
            .Blob => |*blob| if (blob.storePtr()) |blob_store| blob_store.memoryCost() else 0,
            .WTFStringImpl => |str| if (str.get().refCount() == 1) str.get().memoryCost() else 0,
            .InternalBlob => |*internal_blob| internal_blob.memoryCost(),
        };
    }

    pub fn hasOneRef(this: *const Any) bool {
        if (this.store()) |s| {
            return s.hasOneRef();
        }

        return false;
    }

    pub fn getFileName(this: *const Any) ?[]const u8 {
        return switch (this.*) {
            .Blob => this.Blob.getFileName(),
            .WTFStringImpl => null,
            .InternalBlob => null,
        };
    }

    pub inline fn fastSize(this: *const Any) Blob.SizeType {
        return switch (this.*) {
            .Blob => this.Blob.size,
            .WTFStringImpl => @truncate(this.WTFStringImpl.get().byteLength()),
            .InternalBlob => @truncate(this.slice().len),
        };
    }

    pub inline fn size(this: *const Any) Blob.SizeType {
        return switch (this.*) {
            .Blob => this.Blob.size,
            .WTFStringImpl => @truncate(this.WTFStringImpl.get().utf8ByteLength()),
            else => @truncate(this.slice().len),
        };
    }

    pub fn hasContentTypeFromUser(this: Any) bool {
        return switch (this) {
            .Blob => this.Blob.hasContentTypeFromUser(),
            .WTFStringImpl => false,
            .InternalBlob => false,
        };
    }

    pub fn intoBlob(this: *Any) bun.OOM!Blob {
        return switch (this.*) {
            .Blob => this.Blob.take(),
            .WTFStringImpl => brk: {
                if (this.WTFStringImpl.get().length() == 0) {
                    this.WTFStringImpl.deinit();
                    this.* = .{ .Blob = .{} };
                    break :brk Blob.initEmpty();
                }
                const blob = try Blob.create(this.slice(), bun.default_allocator, true);
                this.WTFStringImpl.deinit();
                this.* = .{ .Blob = .{} };
                break :brk blob;
            },
            .InternalBlob => brk: {
                const blob = try Blob.initByteList(&this.InternalBlob.bytes);
                this.* = .{ .Blob = .{} };
                break :brk blob;
            },
        };
    }

    pub fn startRead(
        this: *Any,
        global: *JSGlobalObject,
        completion: anytype,
        metadata: BlobReadMetadata,
    ) void {
        if (this.* != .InternalBlob) {
            var blob = this.intoBlob() catch {
                this.detach();
                var owned_metadata = metadata;
                owned_metadata.deinit();
                var owned_completion = completion;
                owned_completion.outOfMemory();
                return;
            };
            defer blob.deinit();
            startBlobRead(&blob, global, completion, metadata);
            return;
        }

        var internal = this.InternalBlob;
        this.* = .{ .Blob = .{} };
        defer internal.deinit();
        var owned_metadata = metadata;
        var owned_completion = completion;
        const payload = bun.default_allocator.create(BlobReadPayload) catch {
            owned_metadata.deinit();
            owned_completion.outOfMemory();
            return;
        };
        const bytes = internal.bytes.tryToDefaultOwnedSlice() catch {
            bun.destroy(payload);
            owned_metadata.deinit();
            owned_completion.outOfMemory();
            return;
        };
        payload.* = .{ .bytes = .{
            .value = .fromDefaultAllocatedSlice(bytes),
            .metadata = owned_metadata.take(),
        } };
        owned_completion.complete(payload);
    }

    pub fn isDetached(this: *const Any) bool {
        return switch (this.*) {
            .Blob => |blob| blob.isDetached(),
            .InternalBlob => this.InternalBlob.bytes.length() == 0,
            .WTFStringImpl => this.WTFStringImpl.get().length() == 0,
        };
    }

    pub fn store(this: *const @This()) ?*Blob.Store {
        if (this.* == .Blob) {
            return this.Blob.storePtr();
        }

        return null;
    }

    pub fn contentType(self: *const @This()) []const u8 {
        return switch (self.*) {
            .Blob => self.Blob.content_type.slice(),
            .WTFStringImpl => MimeType.text.value,
            .InternalBlob => self.InternalBlob.contentType(),
        };
    }

    pub fn wasString(self: *const @This()) bool {
        return switch (self.*) {
            .Blob => self.Blob.charset == .all_ascii,
            .WTFStringImpl => true,
            .InternalBlob => self.InternalBlob.was_string,
        };
    }

    pub inline fn slice(self: *const @This()) []const u8 {
        return switch (self.*) {
            .Blob => self.Blob.sharedView(),
            .WTFStringImpl => self.WTFStringImpl.get().utf8Slice(),
            .InternalBlob => self.InternalBlob.sliceConst(),
        };
    }

    pub fn needsToReadFile(self: *const @This()) bool {
        return switch (self.*) {
            .Blob => self.Blob.needsToReadFile(),
            .WTFStringImpl, .InternalBlob => false,
        };
    }

    pub fn isS3(self: *const @This()) bool {
        return switch (self.*) {
            .Blob => self.Blob.isS3(),
            .WTFStringImpl, .InternalBlob => false,
        };
    }

    pub fn detach(self: *@This()) void {
        return switch (self.*) {
            .Blob => {
                self.Blob.deinit();
                self.* = .{
                    .Blob = .{},
                };
            },
            .InternalBlob => {
                self.InternalBlob.bytes.deinit();
                self.* = .{ .Blob = .{} };
            },
            .WTFStringImpl => {
                self.WTFStringImpl.deinit();
                self.* = .{ .Blob = .{} };
            },
        };
    }
};

/// A single-use Blob backed by an allocation of memory.
pub const Internal = struct {
    bytes: bun.bindgen.OwnedByteList,
    was_string: bool = false,

    pub fn memoryCost(this: *const @This()) usize {
        return this.bytes.capacity();
    }

    pub inline fn sliceConst(this: *const @This()) []const u8 {
        return this.bytes.slice();
    }

    pub fn deinit(this: *@This()) void {
        this.bytes.deinit();
    }

    pub inline fn slice(this: @This()) []u8 {
        return @constCast(this.bytes.slice());
    }

    pub fn clearAndFree(this: *@This()) void {
        this.bytes.deinit();
    }

    pub fn contentType(self: *const @This()) []const u8 {
        if (self.was_string) {
            return MimeType.text.value;
        }

        return MimeType.other.value;
    }
};

/// A blob which stores all the data in the same space as a real Blob
/// This is an optimization for small Response and Request bodies
/// It means that we can avoid an additional heap allocation for a small response
pub const Inline = extern struct {
    const real_blob_size = @sizeOf(Blob);
    pub const IntSize = u8;
    pub const available_bytes = real_blob_size - @sizeOf(IntSize) - 1 - 1;
    bytes: [available_bytes]u8 align(1) = undefined,
    len: IntSize align(1) = 0,
    was_string: bool align(1) = false,

    pub fn concat(first: []const u8, second: []const u8) Inline {
        const total = first.len + second.len;
        assert(total <= available_bytes);

        var inline_blob: jsc.WebCore.InlineBlob = .{};
        var bytes_slice = inline_blob.bytes[0..total];

        if (first.len > 0)
            @memcpy(bytes_slice[0..first.len], first);

        if (second.len > 0)
            @memcpy(bytes_slice[first.len..][0..second.len], second);

        inline_blob.len = @as(@TypeOf(inline_blob.len), @truncate(total));
        return inline_blob;
    }

    fn internalInit(data: []const u8, was_string: bool) Inline {
        assert(data.len <= available_bytes);

        var blob = Inline{
            .len = @as(IntSize, @intCast(data.len)),
            .was_string = was_string,
        };

        if (data.len > 0)
            @memcpy(blob.bytes[0..data.len], data);
        return blob;
    }

    pub fn init(data: []const u8) Inline {
        return internalInit(data, false);
    }

    pub fn contentType(self: *const @This()) []const u8 {
        if (self.was_string) {
            return MimeType.text.value;
        }

        return MimeType.other.value;
    }

    pub fn deinit(_: *@This()) void {}

    pub inline fn slice(this: *@This()) []u8 {
        return this.bytes[0..this.len];
    }

    pub inline fn sliceConst(this: *const @This()) []const u8 {
        return this.bytes[0..this.len];
    }

    pub fn toOwnedSlice(this: *@This()) []u8 {
        return this.slice();
    }

    pub fn clearAndFree(_: *@This()) void {}
};

pub fn isAllASCII(self: *const Blob) ?bool {
    return switch (self.charset) {
        .unknown => null,
        .all_ascii => true,
        .non_ascii => false,
    };
}

/// Takes ownership of `self` by value. Invalidates `self`.
pub fn takeOwnership(self: *Blob) Blob {
    var result = self.*;
    self.* = undefined;
    result.setNotHeapAllocated();
    return result;
}

pub fn isHeapAllocated(self: *const Blob) bool {
    return self.ref_count.raw_value != 0;
}

fn setNotHeapAllocated(self: *Blob) void {
    self.ref_count = .init(0);
}

pub const external_shared_descriptor = struct {
    pub const ref = refForExternal;
    pub const deref = derefForExternal;
};

pub fn ref(this: *Blob) void {
    refForExternal(this);
}

pub fn deref(this: *Blob) void {
    derefForExternal(this);
}

fn refForExternal(self: *Blob) void {
    bun.assertf(self.isHeapAllocated(), "cannot ref: this Blob is not heap-allocated", .{});
    self.ref_count.increment();
}

fn derefForExternal(self: *Blob) void {
    bun.assertf(self.isHeapAllocated(), "cannot deref: this Blob is not heap-allocated", .{});
    if (self.ref_count.decrement() == .should_destroy) {
        self.ref_count.increment(); // deinit has its own isHeapAllocated() guard around bun.destroy(this), so this is needed to ensure that returns true.
        self.deinit();
    }
}

fn bindBlobClone(args: bun.bindgen.Args(BlobCloneSchema)) bun.OOM!bun.bindgen.Return(BlobCloneSchema) {
    const blob: *Blob = @ptrCast(@alignCast(args.blob));
    return bun.bindgen.Return(BlobCloneSchema).initNative(try cloneForBindings(blob));
}

fn bindBlobAdopt(
    context: bun.bindgen.CallContext(BlobAdoptSchema),
    args: *bun.bindgen.Args(BlobAdoptSchema),
) bun.JSError!bun.bindgen.Return(BlobAdoptSchema) {
    return adoptBindingResult(args.blob.takeNative(), context);
}

fn bindBlobRetainFromBinding(args: bun.bindgen.Args(BlobRetainFromBindingSchema)) bun.bindgen.Return(BlobRetainFromBindingSchema) {
    const blob = args.binding.native();
    refForExternal(blob);
    return bun.bindgen.Return(BlobRetainFromBindingSchema).initNative(blob);
}

fn bindBlobEstimatedSize(args: bun.bindgen.Args(BlobEstimatedSizeSchema)) bun.bindgen.Return(BlobEstimatedSizeSchema) {
    const blob: *Blob = @ptrCast(@alignCast(args.blob));
    blob.calculateEstimatedByteSize();
    return blob.estimatedSize();
}

fn bindBlobRef(args: bun.bindgen.Args(BlobRefSchema)) bun.bindgen.Return(BlobRefSchema) {
    refForExternal(@ptrCast(@alignCast(args.blob)));
}

fn bindBlobDeref(args: bun.bindgen.Args(BlobDerefSchema)) bun.bindgen.Return(BlobDerefSchema) {
    derefForExternal(@ptrCast(@alignCast(args.blob)));
}

const WriteAcceptor = write_file.WriteAcceptor;

const string = []const u8;

const Archive = @import("../api/Archive.zig");
const Environment = @import("../../bun_core/env.zig");
const Image = @import("../image/Image.zig");
const FormDataEngine = @import("./FormDataEngine.zig");
const BlobSize = @import("./BlobSize.zig");
const S3File = @import("./S3FileEngine.zig");
const std = @import("std");

const bun = @import("bun");
const ReadFileEngine = @import("./blob/ReadFileEngine.zig");
const JSError = bun.JSError;
const Output = bun.Output;
const S3 = bun.S3;
const S3StreamEngine = @import("./s3/ClientStreamEngine.zig");
const assert = bun.assert;
const default_allocator = bun.default_allocator;
const strings = bun.strings;
const streams = bun.webcore.streams;

const http = bun.http;
const MimeType = http.MimeType;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const VirtualMachine = jsc.VirtualMachine;
const PathOrBlob = bun.api.node.PathOrBlob;

const BunObjectBindingModule = bun.bindgen.Module("BunObject");
const ConstructBunFileSchema = BunObjectBindingModule.function("file");
const ConstructBunFileBinding = bun.bindgen.Fn(ConstructBunFileSchema, constructBunFile);
const WriteFileFunctionSchema = BunObjectBindingModule.function("write");
const BindingWriteOptions = @FieldType(bun.bindgen.Args(WriteFileFunctionSchema), "options");
const WriteFileFunctionBinding = bun.bindgen.Fn(WriteFileFunctionSchema, writeFile);
const BlobBindingModule = bun.bindgen.Module("Blob");
const FormDataSchema = bun.bindgen.Module("WebCoreFormData").class("FormData");
const BlobSchema = BlobBindingModule.class("Blob");
const FileSchema = BlobBindingModule.class("File");
const FileNameGetterSchema = FileSchema.memberKind("name", .getter);
const FileNameSetterSchema = FileSchema.memberKind("name", .setter);
const S3FileSchema = BlobBindingModule.class("S3File");
pub const BlobClass = bun.bindgen.Class(BlobSchema, BlobJSBinding);
pub const FileClass = bun.bindgen.Class(FileSchema, FileJSBinding);
pub const S3FileClass = bun.bindgen.Class(S3FileSchema, S3FileJSBinding);
const BlobConstructorSchema = BlobSchema.constructor();
const BlobInspectSchema = BlobSchema.member("inspectCustom");
const BlobArrayBufferSchema = BlobSchema.member("arrayBuffer");
const BlobBytesSchema = BlobSchema.member("bytes");
const BlobDeleteSchema = BlobSchema.member("delete");
const BlobExistsSchema = BlobSchema.member("exists");
const BlobFormDataSchema = BlobSchema.member("formData");
const BlobImageSchema = BlobSchema.member("image");
const BlobJSONSchema = BlobSchema.member("json");
const BlobLastModifiedSchema = BlobSchema.memberKind("lastModified", .getter);
const BlobNameGetterSchema = BlobSchema.memberKind("name", .getter);
const BlobNameSetterSchema = BlobSchema.memberKind("name", .setter);
const BlobSizeSchema = BlobSchema.memberKind("size", .getter);
const BlobSliceSchema = BlobSchema.member("slice");
const BlobStatFileSchema = BlobSchema.member("statFileNative");
const BlobStatS3Schema = BlobSchema.member("statS3Native");
const BlobStatSourceSchema = BlobSchema.member("statSourceNative");
const BlobStreamNativeSchema = BlobSchema.member("streamNative");
const BlobTextSchema = BlobSchema.member("text");
const BlobTypeSchema = BlobSchema.memberKind("type", .getter);
const BlobUnlinkSchema = BlobSchema.member("unlink");
const BlobWriteSchema = BlobSchema.member("write");
const BlobWriterSchema = BlobSchema.member("writer");
const FileConstructorSchema = FileSchema.constructor();
const FileHasInstanceSchema = FileSchema.member("hasInstance");
const S3FilePresignMemberSchema = S3FileSchema.member("presign");
const S3FileStatMemberSchema = S3FileSchema.member("stat");
const S3FileBucketMemberSchema = S3FileSchema.memberKind("bucket", .getter);

const PromiseBindings = bun.bindgen.Module("promises");
const PromiseStatusSchema = PromiseBindings.engineShim("promiseStatus");
const PromiseResultSchema = PromiseBindings.engineShim("promiseResult");
const BlobGetSizeForBindingsSchema = BlobBindingModule.nativeExport("blobGetSizeForBindings");
const BlobCloneSchema = BlobBindingModule.nativeExport("blobClone");
const BlobAdoptSchema = BlobBindingModule.nativeExport("blobAdopt");
const BlobRetainFromBindingSchema = BlobBindingModule.nativeExport("blobRetainFromBinding");
const BlobEstimatedSizeSchema = BlobBindingModule.nativeExport("blobEstimatedSize");
const BlobRefSchema = BlobBindingModule.nativeExport("blobRef");
const BlobDerefSchema = BlobBindingModule.nativeExport("blobDeref");
const BlobCloneAsFileSchema = BlobBindingModule.nativeExport("blobCloneAsFile");
const BlobFileNameSchema = BlobBindingModule.nativeExport("blobFileName");
const BlobSharedDataSchema = BlobBindingModule.nativeExport("blobSharedData");
const BlobNeedsToReadFileSchema = BlobBindingModule.nativeExport("blobNeedsToReadFile");
const BlobCreateFromBytesSchema = BlobBindingModule.nativeExport("blobCreateFromBytes");
const BlobCreateFromBytesWithTypeSchema = BlobBindingModule.nativeExport("blobCreateFromBytesWithType");
const BlobAdoptOwnedBytesWithTypeSchema = BlobBindingModule.nativeExport("blobAdoptOwnedBytesWithType");
const BlobGetSizeForBindingsBinding = bun.bindgen.Fn(BlobGetSizeForBindingsSchema, bindGetSizeForBindings);
const BlobCloneBinding = bun.bindgen.Fn(BlobCloneSchema, bindBlobClone);
const BlobAdoptBinding = bun.bindgen.Fn(BlobAdoptSchema, bindBlobAdopt);
const BlobRetainFromBindingBinding = bun.bindgen.Fn(BlobRetainFromBindingSchema, bindBlobRetainFromBinding);
const BlobEstimatedSizeBinding = bun.bindgen.Fn(BlobEstimatedSizeSchema, bindBlobEstimatedSize);
const BlobRefBinding = bun.bindgen.Fn(BlobRefSchema, bindBlobRef);
const BlobDerefBinding = bun.bindgen.Fn(BlobDerefSchema, bindBlobDeref);
const BlobCloneAsFileBinding = bun.bindgen.Fn(BlobCloneAsFileSchema, bindBlobCloneAsFile);
const BlobFileNameBinding = bun.bindgen.Fn(BlobFileNameSchema, bindBlobFileName);
const BlobSharedDataBinding = bun.bindgen.Fn(BlobSharedDataSchema, bindBlobSharedData);
const BlobNeedsToReadFileBinding = bun.bindgen.Fn(BlobNeedsToReadFileSchema, bindBlobNeedsToReadFile);
const BlobCreateFromBytesBinding = bun.bindgen.Fn(BlobCreateFromBytesSchema, bindBlobCreateFromBytes);
const BlobCreateFromBytesWithTypeBinding = bun.bindgen.Fn(BlobCreateFromBytesWithTypeSchema, bindBlobCreateFromBytesWithType);
const BlobAdoptOwnedBytesWithTypeBinding = bun.bindgen.Fn(BlobAdoptOwnedBytesWithTypeSchema, bindBlobAdoptOwnedBytesWithType);
const FileSinkCallbackBindings = bun.bindgen.Module("FileSink");
const OnResolveRequestStreamSchema = FileSinkCallbackBindings.function("onResolveRequestStream");
const OnRejectRequestStreamSchema = FileSinkCallbackBindings.function("onRejectRequestStream");
const OnResolveRequestStreamBinding = bun.bindgen.Fn(OnResolveRequestStreamSchema, bindOnResolveRequestStream);
const OnRejectRequestStreamBinding = bun.bindgen.Fn(OnRejectRequestStreamSchema, bindOnRejectRequestStream);
const OnWriteBodySchema = bun.bindgen.Module("BlobWrite").function("onBody");
const OnWriteBodyErrorSchema = bun.bindgen.Module("BlobWrite").function("onBodyError");
const OnWriteBodyBinding = bun.bindgen.Fn(OnWriteBodySchema, bindOnWriteBody);
const OnWriteBodyErrorBinding = bun.bindgen.Fn(OnWriteBodyErrorSchema, bindOnWriteBodyError);

comptime {
    _ = ConstructBunFileBinding;
    _ = WriteFileFunctionBinding;
    _ = BlobClass;
    _ = FileClass;
    _ = S3FileClass;
    _ = BlobGetSizeForBindingsBinding;
    _ = BlobCloneBinding;
    _ = BlobAdoptBinding;
    _ = BlobRetainFromBindingBinding;
    _ = BlobEstimatedSizeBinding;
    _ = BlobRefBinding;
    _ = BlobDerefBinding;
    _ = BlobCloneAsFileBinding;
    _ = BlobFileNameBinding;
    _ = BlobSharedDataBinding;
    _ = BlobNeedsToReadFileBinding;
    _ = BlobCreateFromBytesBinding;
    _ = BlobCreateFromBytesWithTypeBinding;
    _ = BlobAdoptOwnedBytesWithTypeBinding;
    _ = OnResolveRequestStreamBinding;
    _ = OnRejectRequestStreamBinding;
    _ = OnWriteBodyBinding;
    _ = OnWriteBodyErrorBinding;
}

const Request = jsc.WebCore.Request;
const Response = jsc.WebCore.Response;
