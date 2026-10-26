pub fn writableStream(
    credentials: *S3.S3Credentials,
    path: []const u8,
    global: *jsc.JSGlobalObject,
    options: S3.MultiPartUploadOptions,
    content_type: ?[]const u8,
    content_disposition: ?[]const u8,
    content_encoding: ?[]const u8,
    proxy: ?[]const u8,
    storage_class: ?S3.StorageClass,
    request_payer: bool,
) bun.JSError!jsc.WebCore.NetworkSink.JSSink.Ref {
    const response_stream = create: {
        const sink = try jsc.WebCore.NetworkSink.create();
        errdefer sink.finalize();
        sink.task = try S3.MultiPartUpload.create(credentials, path, S3Scheduler.initCurrent(), .{
            .options = options,
            .callback = jsc.WebCore.NetworkSink.complete,
            .callback_context = .init(sink),
            .on_writable = jsc.WebCore.NetworkSink.onWritable,
            .proxy = proxy,
            .content_type = content_type,
            .content_disposition = content_disposition,
            .content_encoding = content_encoding,
            .storage_class = storage_class,
            .request_payer = request_payer,
        });
        sink.highWaterMark = @intCast(options.partSize);
        break :create sink;
    };
    const task = response_stream.task.?;
    const value = try jsc.WebCore.NetworkSink.JSSink.createRef(global, response_stream);
    response_stream.ref();
    task.activate();
    return value;
}

pub const S3UploadStreamWrapper = struct {
    const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;
    pub const ResumableSink = @import("../ResumableSinkEngine.zig").ResumableS3UploadSink;
    const log = bun.Output.scoped(.S3UploadStream, .visible);

    ref_count: RefCount,
    sink: ?*ResumableSink,
    task: *S3.MultiPartUpload,
    callback: ?*const fn (S3.S3UploadStreamResult, bun.bindgen.NativeCallbackContext(.vm)) void,
    callback_context: bun.bindgen.NativeCallbackContext(.vm),
    path: []const u8,
    global: *jsc.JSGlobalObject,
    stream_ended: bool = false,

    fn finishCallback(self: *@This(), result: S3.S3UploadStreamResult) void {
        const callback = self.callback orelse return;
        self.callback = null;
        callback(result, self.callback_context);
    }

    fn detachSink(self: *@This()) void {
        log("detachSink {}", .{self.sink != null});
        if (self.sink) |sink| {
            self.sink = null;
            sink.deref();
        }
    }

    pub fn onWritable(task: *S3.MultiPartUpload, capture: S3.MultiPartUpload.CallbackContext, _: u64) void {
        const self = capture.get(*@This());
        log("onWritable {} {}", .{ self.sink != null, task.ended });
        if (task.ended) return;
        if (self.sink) |sink| sink.drain();
    }

    pub fn writeRequestData(self: *@This(), data: []const u8) bun.OOM!jsc.WebCore.ResumableSinkBackpressure {
        log("writeRequestData {}", .{data.len});
        return self.task.writeBytes(data, false);
    }

    pub fn writeEndRequest(self: *@This(), failed: bool, reason: ?*const bun.bindgen.Root) void {
        log("writeEndRequest {}", .{failed});
        bun.assert(!self.stream_ended);
        self.stream_ended = true;
        self.detachSink();
        defer self.deref();
        if (failed) {
            if (reason) |explicit_reason| self.finishCallback(.{ .stream_error = explicit_reason });
            if (self.task.state != .finished) {
                self.task.fail(.{
                    .code = "UnknownError",
                    .message = "ReadableStream ended with an error",
                });
            }
        } else {
            _ = self.task.writeBytes("", true) catch {
                self.task.failOutOfMemory();
                return;
            };
        }
    }

    pub fn resolve(result: S3.S3UploadResult, opaque_self: S3.MultiPartUpload.CallbackContext) void {
        const self = opaque_self.get(*@This());
        log("resolve {any}", .{result});
        defer self.deref();
        switch (result) {
            .success => self.finishCallback(.success),
            .out_of_memory => {
                self.finishCallback(.out_of_memory);
                if (self.sink) |sink| {
                    self.sink = null;
                    sink.cancelOnError(error.OutOfMemory);
                    sink.deref();
                }
            },
            .failure => |err| {
                self.finishCallback(.{ .failure = .{ .error_value = err, .path = self.path } });
                if (self.sink) |sink| {
                    self.sink = null;
                    var rooted_error = ErrorEngine.retainServiceError(&err, self.global, self.path) catch |creation_error| {
                        sink.cancelOnError(creation_error);
                        sink.deref();
                        return;
                    };
                    defer rooted_error.deinit();
                    sink.cancel(&rooted_error);
                    sink.deref();
                }
            },
        }
    }

    fn deinit(self: *@This()) void {
        log("deinit {}", .{self.sink != null});
        self.detachSink();
        self.task.deref();
        bun.destroy(self);
    }
};

pub fn uploadStream(
    credentials: *S3.S3Credentials,
    path: []const u8,
    readable_stream: *const jsc.WebCore.ReadableStream.Strong,
    global: *jsc.JSGlobalObject,
    options: S3.MultiPartUploadOptions,
    acl: ?S3.ACL,
    storage_class: ?S3.StorageClass,
    content_type: ?[]const u8,
    content_disposition: ?[]const u8,
    content_encoding: ?[]const u8,
    proxy: ?[]const u8,
    request_payer: bool,
    callback: *const fn (S3.S3UploadStreamResult, bun.bindgen.NativeCallbackContext(.vm)) void,
    callback_context: bun.bindgen.NativeCallbackContext(.vm),
) bun.JSError!void {
    if (readable_stream.isDisturbed(global)) {
        var reason = try retainMessageError(global, "ReadableStream is already disturbed");
        defer reason.deinit();
        callback(.{ .stream_error = &reason }, callback_context);
        return;
    }

    switch (readable_stream.sourceTag()) {
        .Invalid => {
            var reason = try retainMessageError(global, "ReadableStream is invalid");
            defer reason.deinit();
            callback(.{ .stream_error = &reason }, callback_context);
            return;
        },
        .File => if (try takeFileReaderError(readable_stream.fileReader().?, global)) |pending_error| {
            var reason = pending_error;
            defer reason.deinit();
            callback(.{ .stream_error = &reason }, callback_context);
            return;
        },
        .Bytes => if (try takePendingStreamError(readable_stream.byteStream().?, global)) |pending_error| {
            var reason = pending_error;
            defer reason.deinit();
            callback(.{ .stream_error = &reason }, callback_context);
            return;
        },
        else => {},
    }

    const context = try bun.default_allocator.create(S3UploadStreamWrapper);
    const task = S3.MultiPartUpload.create(credentials, path, S3Scheduler.initCurrent(), .{
        .callback = S3UploadStreamWrapper.resolve,
        .callback_context = .init(context),
        .on_writable = S3UploadStreamWrapper.onWritable,
        .proxy = proxy,
        .content_type = content_type,
        .content_disposition = content_disposition,
        .content_encoding = content_encoding,
        .wait_for_stream = true,
        .options = options,
        .acl = acl,
        .storage_class = storage_class,
        .request_payer = request_payer,
    }) catch |err| {
        bun.default_allocator.destroy(context);
        return err;
    };
    context.* = .{
        .ref_count = .init(),
        .sink = null,
        .callback = callback,
        .callback_context = callback_context,
        .path = task.path,
        .task = task,
        .global = global,
    };
    // Stream attachment can synchronously consume both completion references.
    defer context.deref();
    context.ref();
    context.ref();
    task.activate();
    context.sink = S3UploadStreamWrapper.ResumableSink.init(global, readable_stream, context) catch |err| {
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(global);
        defer scope.deinit();
        var thrown = scope.takeThrownValue(err) catch |termination| {
            context.finishCallback(.terminated);
            if (!context.stream_ended) context.writeEndRequest(true, null);
            bun.bindgen.voidFromJSError(termination, global);
            return;
        };
        defer thrown.deinit();
        var reason = thrown.toRoot() catch |failure| {
            const callback_pending = context.callback != null;
            context.callback = null;
            if (!context.stream_ended) context.writeEndRequest(true, null);
            if (callback_pending) return failure;
            global.reportActiveExceptionAsUnhandled(failure);
            return;
        };
        defer reason.deinit();
        if (!context.stream_ended) context.writeEndRequest(true, &reason);
        return;
    };
    task.continueStream() catch task.failOutOfMemory();
}

fn retainMessageError(global: *jsc.JSGlobalObject, message: []const u8) bun.JSError!bun.bindgen.Root {
    var text = try bun.bindgen.DOMString.fromUTF8(message);
    defer text.deinit();
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    var value = try scope.engineIn("errors", "createError").call(.{ .message = text.operand() });
    defer value.deinit();
    return value.toRoot();
}

fn takePendingStreamError(stream: anytype, global: *jsc.JSGlobalObject) bun.JSError!?bun.bindgen.Root {
    if (stream.pending.result != .err) return null;
    const reason = try stream.pending.result.err.toRoot(global);
    stream.pending.deinit();
    return reason;
}

fn takeFileReaderError(stream: *jsc.WebCore.FileReader, global: *jsc.JSGlobalObject) bun.JSError!?bun.bindgen.Root {
    const err = stream.takeTerminalError() orelse return null;
    var payload = try bun.bindgen.SystemError.fromSysError(err);
    defer payload.deinit();
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    var value = try payload.toErrorInstance(&scope);
    defer value.deinit();
    return try value.toRoot();
}

pub fn readableStream(
    credentials: *S3.S3Credentials,
    path: []const u8,
    offset: usize,
    size: ?usize,
    proxy_url: ?[]const u8,
    request_payer: bool,
    global: *jsc.JSGlobalObject,
) bun.JSError!jsc.WebCore.ReadableStream.Owned {
    const reader = try jsc.WebCore.ByteStream.Source.create(global, .{});
    defer reader.deref();

    var readable = try reader.toReadableStreamOwned(global);
    errdefer readable.deinit();
    var stream = try jsc.WebCore.ReadableStream.Strong.initOwned(readable.clone());
    defer stream.deinit();

    const S3DownloadStreamWrapper = struct {
        readable_stream_ref: jsc.WebCore.ReadableStream.Strong,
        path: []const u8,
        global: *jsc.JSGlobalObject,

        fn retainServiceFailure(self: *const @This(), service_error: *const ErrorEngine.S3Error) bun.JSError!bun.bindgen.Root {
            return ErrorEngine.retainServiceError(service_error, self.global, self.path) catch |creation_error| {
                if (creation_error == error.OutOfMemory) return error.OutOfMemory;
                var scope: bun.bindgen.FocusedEngineScope = undefined;
                scope.init(self.global);
                defer scope.deinit();
                var thrown = try scope.takeThrownValue(creation_error);
                defer thrown.deinit();
                return thrown.toRoot();
            };
        }

        pub fn callback(chunk: bun.MutableString, has_more: bool, request_err: ?S3.RequestFailure, opaque_self: S3.CallbackContext) void {
            const self = opaque_self.get(*@This());
            defer if (!has_more) self.deinit();

            if (self.readable_stream_ref.byteStream()) |byte_stream| {
                if (request_err) |err| {
                    byte_stream.onData(
                        .{ .err = switch (err) {
                            .out_of_memory => .OutOfMemory,
                            .service => |service_error| service: {
                                var error_root = self.retainServiceFailure(&service_error) catch |creation_error| {
                                    if (creation_error == error.OutOfMemory) break :service .OutOfMemory;
                                    bun.bindgen.voidFromJSError(creation_error, self.global);
                                    return;
                                };
                                break :service .{ .JSValue = error_root.takeOptional() };
                            },
                        } },
                        bun.default_allocator,
                    ) catch |delivery_err| bun.bindgen.voidFromJSError(delivery_err, self.global);
                    return;
                }
                if (has_more) {
                    byte_stream.onData(
                        .{ .temporary = chunk.list.items },
                        bun.default_allocator,
                    ) catch |delivery_err| bun.bindgen.voidFromJSError(delivery_err, self.global);
                    return;
                }
                byte_stream.onData(
                    .{ .temporary_and_done = chunk.list.items },
                    bun.default_allocator,
                ) catch |delivery_err| bun.bindgen.voidFromJSError(delivery_err, self.global);
            }
        }

        fn clearStreamCancelHandler(self: *@This()) void {
            if (self.readable_stream_ref.byteStream()) |byte_stream| {
                const source = byte_stream.parent();
                source.cancel_handler = null;
                source.cancel_ctx = null;
            }
        }

        pub fn deinit(self: *@This()) void {
            self.clearStreamCancelHandler();
            self.readable_stream_ref.deinit();
            bun.default_allocator.free(self.path);
            bun.destroy(self);
        }

        fn onStreamCancelled(context: bun.bindgen.NativeCallbackContext(.vm)) void {
            const self = context.get(*@This());
            self.readable_stream_ref.deinit();
        }
    };

    const owned_path = try bun.default_allocator.dupe(u8, path);
    errdefer bun.default_allocator.free(owned_path);
    const wrapper = try bun.default_allocator.create(S3DownloadStreamWrapper);
    wrapper.* = .{
        .readable_stream_ref = stream.take(),
        .path = owned_path,
        .global = global,
    };
    reader.cancel_handler = S3DownloadStreamWrapper.onStreamCancelled;
    reader.cancel_ctx = .init(wrapper);

    S3.downloadStream(
        credentials,
        path,
        offset,
        size,
        proxy_url,
        request_payer,
        S3DownloadStreamWrapper.callback,
        .init(wrapper),
    );
    return readable;
}

const bun = @import("bun");
const jsc = bun.jsc;
const S3 = @import("./client.zig");
const ErrorEngine = @import("./ErrorEngine.zig");
const S3Scheduler = @import("./S3SchedulerEngine.zig").S3Scheduler;
