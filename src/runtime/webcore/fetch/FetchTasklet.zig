pub const FetchTasklet = struct {
    pub const ResumableSink = jsc.WebCore.ResumableFetchSink;

    const log = Output.scoped(.FetchTasklet, .visible);
    const ResponseSchema = bun.bindgen.Module("Response").class("Response");
    const ResponseHandle = bun.bindgen.ClassWeakHandle(
        ResponseSchema,
        @This(),
    );

    /// Settled outcome of a fetch, materialized on delivery.
    pub const FetchPayload = union(enum) {
        response: Response.Ref,
        native_response: ?*Response,
        js_error: bun.bindgen.Root.Optional,

        pub fn deinit(this: *FetchPayload) void {
            switch (this.*) {
                .response => |*response| response.deinit(),
                .native_response => |response| if (response) |native| native.unref(),
                .js_error => |*error_value| error_value.deinit(),
            }
            this.* = .{ .js_error = .empty };
        }
    };

    const FetchCompletionOps = struct {
        pub fn materialize(
            comptime FunctionSchema: type,
            context: bun.bindgen.MaterializationContext(FunctionSchema),
            payload: *FetchPayload,
        ) bun.bindgen.MaterializationError(FunctionSchema)!bun.bindgen.Return(FunctionSchema) {
            switch (payload.*) {
                .response => |*response| return response.take(),
                .native_response => |*owned| {
                    const response = owned.* orelse @panic("fetch response was already consumed");
                    owned.* = null;
                    response.calculateEstimatedByteSize();
                    return Response.Binding.adoptResult(response, context);
                },
                .js_error => |*strong| {
                    var error_root = strong.takeRoot() orelse @panic("fetch rejection was already consumed");
                    return context.reject(&error_root, .{ .attach_async_stack = true });
                },
            }
        }

        pub fn destroyPayload(payload: *FetchPayload) void {
            payload.deinit();
            bun.destroy(payload);
        }

    };

    pub const FetchCompletions = bun.bindgen.MaterializedCompletionSet(.{
        bun.bindgen.Module("BunObject").function("fetch"),
        bun.bindgen.Module("NodeHTTP").function("client"),
    }, FetchPayload, FetchCompletionOps);

    pub fn completeFetch(owned: *FetchCompletions.Owned, payload: FetchPayload) void {
        const result = bun.default_allocator.create(FetchPayload) catch {
            var value = payload;
            value.deinit();
            owned.outOfMemory();
            return;
        };
        result.* = payload;
        owned.complete(result);
    }

    sink: ?*ResumableSink = null,
    http_task: *FetchHTTPTask,
    result: http.HTTPClientResult = .{},
    metadata: ?http.HTTPResponseMetadata = null,
    javascript_vm: *VirtualMachine = undefined,
    global_this: *JSGlobalObject = undefined,
    request_body: HTTPRequestBody = undefined,
    /// buffer used to stream response to JS
    scheduled_response_buffer: MutableString = undefined,
    /// response weak ref we need this to track the response JS lifetime
    response: ResponseHandle = .empty,
    /// native response ref if we still need it when JS is discarted
    native_response: ?*Response = null,
    ignore_data: bool = false,
    /// stream strong ref if any is available
    readable_stream_ref: jsc.WebCore.ReadableStream.Strong = .{},
    body_source: Body.PendingValue.Source = .init(FetchTasklet, "body_source", .{
        .on_start_streaming = onStartStreamingHTTPResponseBody,
        .on_readable_stream_available = onReadableStreamAvailable,
        .on_stream_cancelled = onStreamCancelled,
        .retain_owner = ref,
        .release_owner = deref,
    }),
    completion: ?FetchCompletions.Owned,
    poll_ref: Async.KeepAlive = .{},
    /// For Http Client requests
    /// when Content-Length is provided this represents the whole size of the request
    /// If chunked encoded this will represent the total received size (ignoring the chunk headers)
    /// If is not chunked encoded and Content-Length is not provided this will be unknown
    body_size: http.HTTPClientResult.BodySize = .unknown,

    signal: ?*jsc.WebCore.AbortSignal = null,
    abort_listener: jsc.WebCore.AbortSignal.Listener = undefined,

    // must be stored because AbortSignal stores reason weakly
    abort_reason: bun.bindgen.Root.Optional = .empty,

    // custom checkServerIdentity
    check_server_identity: ?FetchCheckServerIdentityCallback = null,
    reject_unauthorized: bool = true,
    upgraded_connection: bool = false,
    request_has_content_length: bool = false,
    is_waiting_body: bool = false,
    is_waiting_abort: bool = false,
    is_waiting_request_stream_start: bool = false,

    detached: bool = false,
    finished: bool = false,
    cleared: bool = false,
    ref_count: RefCount = .init(),

    const RefCount = bun.ptr.RefCount(FetchTasklet, "ref_count", deinit, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;

    pub const HTTPRequestBody = union(enum) {
        AnyBlob: AnyBlob,
        Sendfile: http.SendFile,
        ReadableStream: jsc.WebCore.ReadableStream.Strong,

        pub const Empty: HTTPRequestBody = .{ .AnyBlob = .{ .Blob = .{} } };

        pub fn store(this: *HTTPRequestBody) ?*Blob.Store {
            return switch (this.*) {
                .AnyBlob => this.AnyBlob.store(),
                else => null,
            };
        }

        pub fn slice(this: *const HTTPRequestBody) []const u8 {
            return switch (this.*) {
                .AnyBlob => this.AnyBlob.slice(),
                else => "",
            };
        }

        pub fn take(this: *HTTPRequestBody) HTTPRequestBody {
            const value = this.*;
            this.* = HTTPRequestBody.Empty;
            return value;
        }

        pub fn detach(this: *HTTPRequestBody) void {
            var owned = this.take();
            switch (owned) {
                .AnyBlob => owned.AnyBlob.detach(),
                .ReadableStream => |*stream| {
                    stream.deinit();
                },
                .Sendfile => {
                    if (@max(owned.Sendfile.offset, owned.Sendfile.remain) > 0)
                        owned.Sendfile.fd.close();
                },
            }
        }

        pub fn fromGeneratedBodyInit(globalThis: *JSGlobalObject, context: anytype, generated: anytype) bun.JSError!HTTPRequestBody {
            const body_value = try Body.Value.fromGeneratedBodyInit(globalThis, context, generated);
            return fromBodyValue(globalThis, body_value);
        }

        fn fromBodyValue(globalThis: *JSGlobalObject, initial_body_value: Body.Value) bun.JSError!HTTPRequestBody {
            var body_value = initial_body_value;
            errdefer body_value.deinit();
            if (body_value == .Used or (body_value == .Locked and (body_value.Locked.action != .none or body_value.Locked.isDisturbed2(globalThis)))) {
                return globalThis.throwNodeError(.ERR_BODY_ALREADY_USED, "body already used", .{});
            }
            if (body_value == .Locked) {
                if (body_value.Locked.readable.has()) {
                    // just grab the ref
                    return FetchTasklet.HTTPRequestBody{ .ReadableStream = body_value.Locked.readable };
                }
                if (try body_value.toReadableStream(globalThis)) |readable| {
                    var owned_readable = readable;
                    owned_readable.deinit();
                }
                if (body_value == .Locked and body_value.Locked.readable.has()) {
                    return FetchTasklet.HTTPRequestBody{ .ReadableStream = body_value.Locked.readable };
                }
            }
            return FetchTasklet.HTTPRequestBody{ .AnyBlob = try body_value.useAsAnyBlob() };
        }

        pub fn needsToReadFile(this: *HTTPRequestBody) bool {
            return switch (this.*) {
                .AnyBlob => |blob| blob.needsToReadFile(),
                else => false,
            };
        }

        pub fn isS3(this: *const HTTPRequestBody) bool {
            return switch (this.*) {
                .AnyBlob => |*blob| blob.isS3(),
                else => false,
            };
        }

        pub fn hasContentTypeFromUser(this: *HTTPRequestBody) bool {
            return switch (this.*) {
                .AnyBlob => |blob| blob.hasContentTypeFromUser(),
                else => false,
            };
        }

        pub fn getAnyBlob(this: *HTTPRequestBody) ?*AnyBlob {
            return switch (this.*) {
                .AnyBlob => &this.AnyBlob,
                else => null,
            };
        }

        pub fn hasBody(this: *HTTPRequestBody) bool {
            return switch (this.*) {
                .AnyBlob => |blob| blob.size() > 0,
                .ReadableStream => |*stream| stream.has(),
                .Sendfile => true,
            };
        }
    };

    fn clearSink(this: *FetchTasklet) void {
        if (this.sink) |sink| {
            this.sink = null;
            sink.abandon();
            sink.deref();
        }
    }

    fn clearData(this: *FetchTasklet) void {
        if (this.cleared) return;
        this.cleared = true;
        log("clearData ", .{});
        const allocator = bun.default_allocator;

        if (this.result.certificate_info) |*certificate| {
            certificate.deinit(bun.default_allocator);
            this.result.certificate_info = null;
        }

        if (this.metadata != null) {
            this.metadata.?.deinit(allocator);
            this.metadata = null;
        }

        this.response.deinit();
        if (this.native_response) |response| {
            this.native_response = null;

            response.unref();
        }

        this.clearStreamCancelHandler();
        this.readable_stream_ref.deinit();

        this.scheduled_response_buffer.deinit();
        this.request_body.detach();

        this.abort_reason.deinit();
        if (this.check_server_identity) |*identity_callback| identity_callback.deinit();
        this.check_server_identity = null;
        if (this.completion) |*owned| {
            owned.release();
            this.completion = null;
        }
        this.clearAbortSignal();
        this.clearSink();
    }

    fn deinit(this: *FetchTasklet) void {
        log("deinit", .{});
        this.clearData();
        this.http_task.deref();
        bun.destroy(this);
    }

    fn deliver(raw: bun.bindgen.NativeCallbackContext(.vm)) void {
        const this = raw.get(*FetchTasklet);
        this.ref();
        defer this.deref();
        this.onProgressUpdate() catch |err| this.global_this.reportActiveExceptionAsUnhandled(err);
    }

    fn detach(raw: bun.bindgen.NativeCallbackContext(.vm)) void {
        const this = raw.get(*FetchTasklet);
        defer this.deref();
        this.detached = true;
        this.http_task.close();
        if (!this.finished) this.http_task.abort();
        this.poll_ref.unref(this.javascript_vm);
        this.clearData();
    }

    const CurrentResponse = union(enum) {
        native: *Response,
        wrapper: bun.bindgen.ClassRef(ResponseSchema),

        fn get(this: *const CurrentResponse) *Response {
            return switch (this.*) {
                .native => |response| response,
                .wrapper => |*reference| reference.get(Response),
            };
        }

        fn deinit(this: *CurrentResponse) void {
            switch (this.*) {
                .native => |response| response.unref(),
                .wrapper => |*handle| handle.deinit(),
            }
        }
    };

    fn getCurrentResponse(this: *FetchTasklet) bun.JSError!?CurrentResponse {
        // we need a body to resolve the promise when buffering
        if (this.native_response) |response| {
            return .{ .native = response.ref() };
        }

        if (try this.response.toOwned()) |response| return .{ .wrapper = response };

        return null;
    }

    pub fn startRequestStream(this: *FetchTasklet) void {
        this.is_waiting_request_stream_start = false;
        bun.assert(this.request_body == .ReadableStream);
        var stream = this.request_body.ReadableStream.clone();
        defer stream.deinit();
        if (stream.has()) {
            if (this.signal) |signal| {
                if (signal.aborted()) {
                    stream.abort(this.global_this);
                    return;
                }
            }

            const globalThis = this.global_this;
            this.ref(); // lets only unref when sink is done
            // +1 because the task refs the sink
            const sink = ResumableSink.init(globalThis, &stream, this) catch |err| {
                if (this.detached) {
                    this.writeEndRequest(true, null);
                    return;
                }
                var reason = this.retainFailure(err) catch |failure| {
                    this.writeEndRequest(true, null);
                    globalThis.reportActiveExceptionAsUnhandled(failure);
                    return;
                };
                defer reason.deinit();
                this.writeEndRequest(true, &reason);
                return;
            };
            if (this.detached) {
                sink.abandon();
                sink.deref();
                return;
            }
            this.sink = sink;
        }
    }

    pub fn onBodyReceived(this: *FetchTasklet) bun.JSError!void {
        const success = this.result.isSuccess();
        const globalThis = this.global_this;
        // reset the buffer if we are streaming or if we are not waiting for bufferig anymore
        var buffer_reset = true;
        log("onBodyReceived success={} has_more={}", .{ success, this.result.has_more });
        defer {
            if (buffer_reset) {
                this.scheduled_response_buffer.reset();
            }
        }

        if (!success) {
            var err = try this.onReject();
            defer err.deinit();
            this.clearStreamCancelHandler();
            var readable = this.readable_stream_ref.take();
            defer readable.deinit();

            if (try this.getCurrentResponse()) |current_response_value| {
                var current_response = current_response_value;
                defer current_response.deinit();
                try current_response.get().getBodyValue().toErrorInstanceWithReadable(
                    err.dupe(),
                    globalThis,
                    if (readable.has()) &readable else null,
                );
            } else if (readable.byteStream()) |byte_stream| {
                try byte_stream.onData(
                    .{ .err = try err.toStreamError(globalThis) },
                    bun.default_allocator,
                );
            }
            if (this.sink) |sink| {
                var rooted_error = try err.toRoot(globalThis);
                defer rooted_error.deinit();
                sink.cancel(&rooted_error);
            }
            return;
        }

        var retained_stream = this.readable_stream_ref.clone();
        defer retained_stream.deinit();
        if (retained_stream.byteStream()) |byte_stream| {
            log("onBodyReceived readable_stream_ref", .{});
            byte_stream.size_hint = this.getSizeHint();
            var buffer = this.takeResponseBuffer();
            defer buffer.deinit();
            const chunk = buffer.list.items;

            if (this.result.has_more) {
                try byte_stream.onData(
                    .{
                        .temporary = chunk,
                    },
                    bun.default_allocator,
                );
            } else {
                this.clearStreamCancelHandler();
                var prev = this.readable_stream_ref.take();
                defer prev.deinit();
                buffer_reset = false;
                if (try this.getCurrentResponse()) |current_response_value| {
                    var response = current_response_value;
                    defer response.deinit();
                    response.get().getBodyValue().finishStreaming(&this.body_source, &prev);
                }

                try byte_stream.onData(
                    .{
                        .temporary_and_done = chunk,
                    },
                    bun.default_allocator,
                );
            }
            return;
        }

        if (try this.getCurrentResponse()) |current_response_value| {
            var current_response = current_response_value;
            defer current_response.deinit();
            const response = current_response.get();
            log("onBodyReceived Current Response", .{});
            const sizeHint = this.getSizeHint();
            response.setSizeHint(sizeHint);
            const response_stream = response.getBodyReadableStream(globalThis) catch |err| {
                const body_error = try Body.Value.ValueError.fromFailure(err, globalThis);
                this.abortTask();
                try response.getBodyValue().toErrorInstance(body_error, globalThis);
                return;
            };
            if (response_stream) |readable| {
                var owned_readable = readable;
                defer owned_readable.deinit();
                log("onBodyReceived CurrentResponse BodyReadableStream", .{});
                if (owned_readable.byteStream()) |byte_stream| {
                    var buffer = this.takeResponseBuffer();
                    defer buffer.deinit();
                    const chunk = buffer.list.items;
                    if (chunk.len == 0 and this.result.has_more) return;

                    if (this.result.has_more) {
                        try byte_stream.onData(
                            .{
                                .temporary = chunk,
                            },
                            bun.default_allocator,
                        );
                    } else {
                        this.clearStreamCancelHandler();
                        response.getBodyValue().finishStreaming(&this.body_source, &owned_readable);
                        try byte_stream.onData(
                            .{
                                .temporary_and_done = chunk,
                            },
                            bun.default_allocator,
                        );
                    }

                    return;
                }
            }

            // we will reach here when not streaming, this is also the only case we dont wanna to reset the buffer
            buffer_reset = false;
            if (!this.result.has_more) {
                var scheduled_response_buffer = this.scheduled_response_buffer.list;
                const body = response.getBodyValue();
                // done resolve body
                var old = body.*;
                const body_value = Body.Value{
                    .InternalBlob = .{
                        .bytes = .fromManaged(scheduled_response_buffer.toManaged(bun.default_allocator)),
                    },
                };
                body.* = body_value;
                log("onBodyReceived body_value length={}", .{body_value.InternalBlob.bytes.length()});

                this.scheduled_response_buffer = .{
                    .allocator = bun.default_allocator,
                    .list = .{
                        .items = &.{},
                        .capacity = 0,
                    },
                };

                if (old == .Locked) {
                    log("onBodyReceived old.resolve", .{});
                    try old.resolve(body, this.global_this, response.getFetchHeaders());
                }
            }
        }
    }

    fn takeResponseBuffer(this: *FetchTasklet) MutableString {
        const buffer = this.scheduled_response_buffer;
        this.scheduled_response_buffer = .{ .allocator = bun.default_allocator, .list = .empty };
        return buffer;
    }

    pub fn onProgressUpdate(this: *FetchTasklet) bun.JSError!void {
        log("onProgressUpdate", .{});
        const native = this.http_task;
        var update = native.progress.take();
        defer update.deinit();
        const is_done = update.has_result and !update.result.has_more;
        const vm = this.javascript_vm;
        defer if (is_done and !this.detached) {
            this.finished = true;
            native.registry.detach(&native.entry);
        };
        defer if (native.progress.finishDelivery()) {
            _ = native.registry.notify(&native.entry);
        };
        if (vm.isShuttingDown()) return;
        defer if (update.request_drained and !is_done and !this.detached) this.resumeRequestDataStream();
        if (!update.has_result) return;

        if (update.result.metadata) |metadata| {
            if (this.metadata) |*previous| previous.deinit(bun.default_allocator);
            this.metadata = metadata;
            update.result.metadata = null;
        }
        if (update.result.certificate_info == null) {
            update.result.certificate_info = this.result.certificate_info;
        } else if (this.result.certificate_info) |previous| {
            previous.deinit(bun.default_allocator);
        }
        this.result = update.result;
        update.result.certificate_info = null;
        this.body_size = this.result.body_size;
        if (this.scheduled_response_buffer.list.items.len == 0) {
            std.mem.swap(MutableString, &this.scheduled_response_buffer, &update.body);
        } else {
            _ = this.scheduled_response_buffer.write(update.body.list.items) catch allocation_failure: {
                native.progress.failAllocation();
                this.result.fail = error.OutOfMemory;
                this.scheduled_response_buffer.reset();
                break :allocation_failure 0;
            };
        }
        if (this.result.fail) |failure| {
            if (failure == error.OutOfMemory) this.abortTask();
        }

        const globalThis = this.global_this;
        if (this.is_waiting_request_stream_start and this.result.can_stream and this.result.isSuccess()) {
            // start streaming
            this.startRequestStream();
        }
        if (this.detached) return;
        // if we already respond the metadata and still need to process the body
        if (this.is_waiting_body) {
            // Progress-only notifications must not satisfy a stream pull with an empty chunk.
            if (this.scheduled_response_buffer.list.items.len == 0 and
                this.result.has_more and
                this.result.isSuccess())
            {
                return;
            }
            this.onBodyReceived() catch |err| switch (err) {
                error.JSTerminated => return error.JSTerminated,
                error.JSError, error.OutOfMemory => globalThis.reportActiveExceptionAsUnhandled(err),
            };
            return;
        }
        if (this.metadata == null and this.result.isSuccess()) return;

        // if we abort because of cert error
        // we wait the Http Client because we already have the response
        // we just need to deinit
        if (this.is_waiting_abort) {
            return;
        }
        if (this.completion == null) {
            log("onProgressUpdate: completion already settled", .{});
            return;
        }

        if (this.result.certificate_info) |certificate_info| {
            this.result.certificate_info = null;
            defer certificate_info.deinit(bun.default_allocator);

            // we receive some error
            const identity_accepted = !this.reject_unauthorized or (this.checkServerIdentity(certificate_info) catch |err| {
                if (this.detached) return;
                if (err != error.OutOfMemory) return err;
                var completion = this.completion.?;
                this.completion = null;
                this.abortTask();
                completion.outOfMemory();
                return;
            });
            if (this.detached) return;
            if (!identity_accepted) {
                log("onProgressUpdate: aborted due certError", .{});
                // we need to abort the request
                var completion = this.completion.?;
                this.completion = null;
                return this.completeResponse(&completion);
            }
            // checkServerIdentity passed. Fall through to resolve/reject below.
            //
            // We can reach this point with `metadata == null` when the
            // connection failed after the TLS handshake but before response
            // headers arrived (e.g. an mTLS server closing the socket because
            // the client didn't present a certificate) — the certificate_info
            // from the first progress update is coalesced into the later
            // failure result. The `metadata == null && isSuccess()` case is
            // already handled by the early return above, so the fall-through
            // here always has either metadata to resolve with or a failure to
            // reject with.
        }

        var completion = this.completion.?;
        this.completion = null;
        try this.completeResponse(&completion);
    }

    fn completeResponse(this: *FetchTasklet, completion: *FetchCompletions.Owned) bun.JSError!void {
        const payload = this.responsePayload() catch |err| {
            this.abortTask();
            if (err == error.OutOfMemory) {
                completion.outOfMemory();
                return;
            }
            completion.release();
            return err;
        };
        completeFetch(completion, payload);
    }

    fn responsePayload(this: *FetchTasklet) bun.JSError!FetchPayload {
        const global = this.global_this;
        switch (this.result.isSuccess()) {
            true => {
                const response = this.onResolve() catch |err| {
                    var failure = try Body.Value.ValueError.fromFailure(err, global);
                    defer failure.deinit();
                    if (failure == .OutOfMemory) return error.OutOfMemory;
                    var reason = try failure.toRoot(global);
                    this.abortTask();
                    return .{ .js_error = reason.takeOptional() };
                };
                return .{ .response = response };
            },
            false => {
                var value = try this.onReject();
                defer value.deinit();
                var rooted_error = try value.toRoot(global);
                defer rooted_error.deinit();
                if (this.sink) |sink| {
                    sink.cancel(&rooted_error);
                }
                return .{ .js_error = rooted_error.takeOptional() };
            },
        }
    }

    fn retainFailure(this: *FetchTasklet, failure: bun.JSError) bun.JSError!bun.bindgen.Root {
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(this.global_this);
        defer scope.deinit();
        var thrown = try scope.takeThrownValue(failure);
        defer thrown.deinit();
        return thrown.toRoot();
    }

    fn rejectServerIdentityWithFailure(this: *FetchTasklet, failure: bun.JSError) bun.JSError!bool {
        var reason = try this.retainFailure(failure);
        defer reason.deinit();
        this.abort_reason.setRoot(&reason);
        return this.rejectServerIdentity();
    }

    pub fn checkServerIdentity(this: *FetchTasklet, certificate_info: http.CertificateInfo) bun.JSError!bool {
        if (this.check_server_identity) |*stored_callback| {
            var check_server_identity = stored_callback.clone();
            defer check_server_identity.deinit();
            if (certificate_info.cert.len > 0) {
                const cert = certificate_info.cert;
                var cert_ptr = cert.ptr;
                if (BoringSSL.d2i_X509(null, &cert_ptr, @intCast(cert.len))) |x509| {
                    const globalObject = this.global_this;
                    defer x509.free();
                    var certificate = X509Engine.legacyCertificate(globalObject, x509) catch |err| {
                        return this.rejectServerIdentityWithFailure(err);
                    };
                    defer certificate.deinit();
                    var hostname = bun.bindgen.DOMString.fromUTF8(certificate_info.hostname) catch |err| {
                        return this.rejectServerIdentityWithFailure(err);
                    };
                    defer hostname.deinit();
                    var invocation: FetchCheckServerIdentityCallback.Invocation = undefined;
                    check_server_identity.beginInvocation(&invocation);
                    defer invocation.deinit();
                    const check_result = invocation.call(.{
                        .hostname = hostname.operand(),
                        .certificate = certificate.value,
                    }) catch |err| {
                        if (this.detached) return err;
                        return this.rejectServerIdentityWithFailure(err);
                    };
                    if (this.detached) return true;

                    if (check_result) |result| {
                        var rooted_result = try result.toRoot();
                        defer rooted_result.deinit();
                        this.abort_reason.setRoot(&rooted_result);
                        return this.rejectServerIdentity();
                    }

                    // > On success, returns <undefined>
                    // We treat any non-error value as a success.
                    return true;
                }
            }
        }
        this.result.fail = error.ERR_TLS_CERT_ALTNAME_INVALID;
        return false;
    }

    fn rejectServerIdentity(this: *FetchTasklet) bool {
        this.is_waiting_abort = this.result.has_more;
        this.http_task.abort();
        this.result.fail = error.ERR_TLS_CERT_ALTNAME_INVALID;
        return false;
    }

    fn getAbortError(this: *FetchTasklet) bun.JSError!?Body.Value.ValueError {
        if (this.abort_reason.has()) {
            defer this.clearAbortSignal();
            const out = this.abort_reason;

            this.abort_reason = .empty;
            return Body.Value.ValueError{ .JSValue = out };
        }

        if (this.signal) |signal| {
            if (try signal.reasonIfAbortedRoot(this.global_this)) |reason| {
                var engine_reason = reason;
                defer engine_reason.deinit();
                var root = engine_reason.takeAnyRoot();
                defer root.deinit();
                var result = Body.Value.ValueError{ .JSValue = .empty };
                result.JSValue.setRoot(&root);
                this.clearAbortSignal();
                return result;
            }
        }

        return null;
    }

    fn clearAbortSignal(this: *FetchTasklet) void {
        const signal = this.signal orelse return;
        this.signal = null;
        defer {
            signal.pendingActivityUnref();
            signal.unref();
        }

        signal.removeListener(&this.abort_listener);
    }

    pub fn onReject(this: *FetchTasklet) bun.JSError!Body.Value.ValueError {
        bun.assert(this.result.fail != null);
        log("onReject", .{});

        if (try this.getAbortError()) |err| {
            return err;
        }

        if (this.result.fail) |failure| {
            if (failure == error.OutOfMemory) return .OutOfMemory;
        }

        if (this.result.abortReason()) |reason| {
            return .{ .AbortReason = reason };
        }

        // Fetch-spec "network error" cases that callers feature-detect via
        // `instanceof TypeError`. Keep this list narrow; the catch-all
        // SystemError below is still a plain Error for backwards compat.
        switch (this.result.fail.?) {
            error.RequestBodyNotReusable => return .{
                .TypeError = .adopt(bun.String.static("Request body is a ReadableStream and cannot be replayed for this redirect")),
            },
            else => {},
        }

        // some times we don't have metadata so we also check http.url
        const path = if (this.metadata) |metadata|
            bun.String.cloneUTF8(metadata.url)
        else if (this.http_task.http) |http_|
            bun.String.cloneUTF8(http_.url.href)
        else
            bun.String.empty;

        const fetch_error = bun.sys.SystemError{
            .code = bun.String.cloneLatin1(switch (this.result.fail.?) {
                error.ConnectionClosed => "ECONNRESET",
                else => |e| @errorName(e),
            }),
            .message = switch (this.result.fail.?) {
                error.ConnectionClosed => bun.String.static("The socket connection was closed unexpectedly. For more information, pass `verbose: true` in the second argument to fetch()"),
                error.FailedToOpenSocket => bun.String.static("Was there a typo in the url or port?"),
                error.TooManyRedirects => bun.String.static("The response redirected too many times. For more information, pass `verbose: true` in the second argument to fetch()"),
                error.ConnectionRefused => bun.String.static("Unable to connect. Is the computer able to access the url?"),
                error.RedirectURLInvalid => bun.String.static("Redirect URL in Location header is invalid."),

                error.UNABLE_TO_GET_ISSUER_CERT => bun.String.static("unable to get issuer certificate"),
                error.UNABLE_TO_GET_CRL => bun.String.static("unable to get certificate CRL"),
                error.UNABLE_TO_DECRYPT_CERT_SIGNATURE => bun.String.static("unable to decrypt certificate's signature"),
                error.UNABLE_TO_DECRYPT_CRL_SIGNATURE => bun.String.static("unable to decrypt CRL's signature"),
                error.UNABLE_TO_DECODE_ISSUER_PUBLIC_KEY => bun.String.static("unable to decode issuer public key"),
                error.CERT_SIGNATURE_FAILURE => bun.String.static("certificate signature failure"),
                error.CRL_SIGNATURE_FAILURE => bun.String.static("CRL signature failure"),
                error.CERT_NOT_YET_VALID => bun.String.static("certificate is not yet valid"),
                error.CRL_NOT_YET_VALID => bun.String.static("CRL is not yet valid"),
                error.CERT_HAS_EXPIRED => bun.String.static("certificate has expired"),
                error.CRL_HAS_EXPIRED => bun.String.static("CRL has expired"),
                error.ERROR_IN_CERT_NOT_BEFORE_FIELD => bun.String.static("format error in certificate's notBefore field"),
                error.ERROR_IN_CERT_NOT_AFTER_FIELD => bun.String.static("format error in certificate's notAfter field"),
                error.ERROR_IN_CRL_LAST_UPDATE_FIELD => bun.String.static("format error in CRL's lastUpdate field"),
                error.ERROR_IN_CRL_NEXT_UPDATE_FIELD => bun.String.static("format error in CRL's nextUpdate field"),
                error.OUT_OF_MEM => bun.String.static("out of memory"),
                error.DEPTH_ZERO_SELF_SIGNED_CERT => bun.String.static("self signed certificate"),
                error.SELF_SIGNED_CERT_IN_CHAIN => bun.String.static("self signed certificate in certificate chain"),
                error.UNABLE_TO_GET_ISSUER_CERT_LOCALLY => bun.String.static("unable to get local issuer certificate"),
                error.UNABLE_TO_VERIFY_LEAF_SIGNATURE => bun.String.static("unable to verify the first certificate"),
                error.CERT_CHAIN_TOO_LONG => bun.String.static("certificate chain too long"),
                error.CERT_REVOKED => bun.String.static("certificate revoked"),
                error.INVALID_CA => bun.String.static("invalid CA certificate"),
                error.INVALID_NON_CA => bun.String.static("invalid non-CA certificate (has CA markings)"),
                error.PATH_LENGTH_EXCEEDED => bun.String.static("path length constraint exceeded"),
                error.PROXY_PATH_LENGTH_EXCEEDED => bun.String.static("proxy path length constraint exceeded"),
                error.PROXY_CERTIFICATES_NOT_ALLOWED => bun.String.static("proxy certificates not allowed, please set the appropriate flag"),
                error.INVALID_PURPOSE => bun.String.static("unsupported certificate purpose"),
                error.CERT_UNTRUSTED => bun.String.static("certificate not trusted"),
                error.CERT_REJECTED => bun.String.static("certificate rejected"),
                error.APPLICATION_VERIFICATION => bun.String.static("application verification failure"),
                error.SUBJECT_ISSUER_MISMATCH => bun.String.static("subject issuer mismatch"),
                error.AKID_SKID_MISMATCH => bun.String.static("authority and subject key identifier mismatch"),
                error.AKID_ISSUER_SERIAL_MISMATCH => bun.String.static("authority and issuer serial number mismatch"),
                error.KEYUSAGE_NO_CERTSIGN => bun.String.static("key usage does not include certificate signing"),
                error.UNABLE_TO_GET_CRL_ISSUER => bun.String.static("unable to get CRL issuer certificate"),
                error.UNHANDLED_CRITICAL_EXTENSION => bun.String.static("unhandled critical extension"),
                error.KEYUSAGE_NO_CRL_SIGN => bun.String.static("key usage does not include CRL signing"),
                error.KEYUSAGE_NO_DIGITAL_SIGNATURE => bun.String.static("key usage does not include digital signature"),
                error.UNHANDLED_CRITICAL_CRL_EXTENSION => bun.String.static("unhandled critical CRL extension"),
                error.INVALID_EXTENSION => bun.String.static("invalid or inconsistent certificate extension"),
                error.INVALID_POLICY_EXTENSION => bun.String.static("invalid or inconsistent certificate policy extension"),
                error.NO_EXPLICIT_POLICY => bun.String.static("no explicit policy"),
                error.DIFFERENT_CRL_SCOPE => bun.String.static("Different CRL scope"),
                error.UNSUPPORTED_EXTENSION_FEATURE => bun.String.static("Unsupported extension feature"),
                error.UNNESTED_RESOURCE => bun.String.static("RFC 3779 resource not subset of parent's resources"),
                error.PERMITTED_VIOLATION => bun.String.static("permitted subtree violation"),
                error.EXCLUDED_VIOLATION => bun.String.static("excluded subtree violation"),
                error.SUBTREE_MINMAX => bun.String.static("name constraints minimum and maximum not supported"),
                error.UNSUPPORTED_CONSTRAINT_TYPE => bun.String.static("unsupported name constraint type"),
                error.UNSUPPORTED_CONSTRAINT_SYNTAX => bun.String.static("unsupported or invalid name constraint syntax"),
                error.UNSUPPORTED_NAME_SYNTAX => bun.String.static("unsupported or invalid name syntax"),
                error.CRL_PATH_VALIDATION_ERROR => bun.String.static("CRL path validation error"),
                error.SUITE_B_INVALID_VERSION => bun.String.static("Suite B: certificate version invalid"),
                error.SUITE_B_INVALID_ALGORITHM => bun.String.static("Suite B: invalid public key algorithm"),
                error.SUITE_B_INVALID_CURVE => bun.String.static("Suite B: invalid ECC curve"),
                error.SUITE_B_INVALID_SIGNATURE_ALGORITHM => bun.String.static("Suite B: invalid signature algorithm"),
                error.SUITE_B_LOS_NOT_ALLOWED => bun.String.static("Suite B: curve not allowed for this LOS"),
                error.SUITE_B_CANNOT_SIGN_P_384_WITH_P_256 => bun.String.static("Suite B: cannot sign P-384 with P-256"),
                error.HOSTNAME_MISMATCH => bun.String.static("Hostname mismatch"),
                error.EMAIL_MISMATCH => bun.String.static("Email address mismatch"),
                error.IP_ADDRESS_MISMATCH => bun.String.static("IP address mismatch"),
                error.INVALID_CALL => bun.String.static("Invalid certificate verification context"),
                error.STORE_LOOKUP => bun.String.static("Issuer certificate lookup error"),
                error.NAME_CONSTRAINTS_WITHOUT_SANS => bun.String.static("Issuer has name constraints but leaf has no SANs"),
                error.UNKNOWN_CERTIFICATE_VERIFICATION_ERROR => bun.String.static("unknown certificate verification error"),

                else => |e| bun.String.createFormat("{s} fetching \"{f}\". For more information, pass `verbose: true` in the second argument to fetch()", .{
                    @errorName(e),
                    path,
                }) catch |err| bun.handleOom(err),
            },
            .path = path,
        };

        return Body.Value.ValueError.fromSystemError(fetch_error);
    }

    pub fn onReadableStreamAvailable(this: *FetchTasklet, globalThis: *jsc.JSGlobalObject, readable: *const jsc.WebCore.ReadableStream.Strong) void {
        _ = globalThis;
        if (this.detached) return;
        this.readable_stream_ref = readable.clone();
        if (readable.byteStream()) |byte_stream| {
            byte_stream.consume_callback = .{ .context = .init(this), .run = onResponseBytesConsumed };
            this.http_task.signal_store.response_body_backpressure.store(true, .release);
            if (this.http_task.http) |request| http.http_thread.scheduleResponseBodyDrain(request.async_http_id);
        }
    }

    fn onResponseBytesConsumed(ctx: bun.bindgen.NativeCallbackContext(.vm), count: usize) void {
        const this = ctx.get(*FetchTasklet);
        if (!this.detached) this.http_task.consumeResponseBytes(count);
    }

    pub fn onStartStreamingHTTPResponseBody(this: *FetchTasklet) jsc.WebCore.DrainResult {
        if (this.detached or this.http_task.signal_store.aborted.load(.monotonic)) {
            return jsc.WebCore.DrainResult{
                .aborted = {},
            };
        }

        if (this.http_task.http) |http_| {
            http_.enableResponseBodyStreaming();

            // If the server sent the headers and the response body in two separate socket writes
            // and if the server doesn't close the connection by itself
            // and doesn't send any follow-up data
            // then we must make sure the HTTP thread flushes.
            bun.http.http_thread.scheduleResponseBodyDrain(http_.async_http_id);
        }

        const size_hint = this.getSizeHint();

        var scheduled_response_buffer = this.scheduled_response_buffer.list;
        // This means we have received part of the body but not the whole thing
        if (scheduled_response_buffer.items.len > 0) {
            this.scheduled_response_buffer = .{
                .allocator = bun.default_allocator,
                .list = .{
                    .items = &.{},
                    .capacity = 0,
                },
            };

            return .{
                .owned = .{
                    .list = scheduled_response_buffer.toManaged(bun.default_allocator),
                    .size_hint = size_hint,
                },
            };
        }

        return .{
            .estimated_size = size_hint,
        };
    }

    fn getSizeHint(this: *FetchTasklet) Blob.SizeType {
        return switch (this.body_size) {
            .content_length => @truncate(this.body_size.content_length),
            .total_received => @truncate(this.body_size.total_received),
            .unknown => 0,
        };
    }

    /// Clear the cancel_handler on the ByteStream.Source to prevent use-after-free.
    /// Must be called before releasing readable_stream_ref, while the Strong ref
    /// still keeps the ReadableStream (and thus the ByteStream.Source) alive.
    fn clearStreamCancelHandler(this: *FetchTasklet) void {
        this.http_task.signal_store.response_body_backpressure.store(false, .release);
        if (!this.finished) {
            if (this.http_task.http) |request| http.http_thread.scheduleResponseBodyDrain(request.async_http_id);
        }
        if (this.readable_stream_ref.byteStream()) |byte_stream| {
            byte_stream.consume_callback = null;
            const source = byte_stream.parent();
            source.cancel_handler = null;
            source.cancel_ctx = null;
        }
    }

    fn onStreamCancelled(this: *FetchTasklet) void {
        if (this.detached or this.ignore_data) return;
        this.ignoreRemainingResponseBody();
    }

    fn toBodyValue(this: *FetchTasklet) bun.JSError!Body.Value {
        if (try this.getAbortError()) |err| {
            return .{ .Error = err };
        }
        if (this.is_waiting_body) {
            var response = Body.Value{
                .Locked = .{
                    .size_hint = this.getSizeHint(),
                    .global = .init(this.global_this),
                },
            };
            response.Locked.setSource(&this.body_source);
            return response;
        }

        var scheduled_response_buffer = this.scheduled_response_buffer.list;
        const response = Body.Value{
            .InternalBlob = .{
                .bytes = .fromManaged(scheduled_response_buffer.toManaged(bun.default_allocator)),
            },
        };
        this.scheduled_response_buffer = .{
            .allocator = bun.default_allocator,
            .list = .{
                .items = &.{},
                .capacity = 0,
            },
        };

        return response;
    }

    fn toResponse(this: *FetchTasklet) bun.JSError!Response {
        log("toResponse", .{});
        bun.assert(this.metadata != null);
        // at this point we always should have metadata
        const metadata = this.metadata.?;
        const http_response = metadata.response;
        var headers = try FetchHeaders.createFromPicoHeaders(http_response.headers);
        errdefer headers.deinit();
        var status_text = try bun.bindgen.DOMString.fromBunString(bun.api.StringEngine.createAtomIfPossible(http_response.status));
        errdefer status_text.deinit();
        var url = try bun.bindgen.DOMString.fromBunString(bun.api.StringEngine.createAtomIfPossible(metadata.url));
        errdefer url.deinit();
        this.is_waiting_body = this.result.has_more;
        return Response.init(
            .{
                .headers = headers,
                .status_code = @as(u16, @truncate(http_response.status_code)),
                .status_text = status_text,
            },
            Body{
                .value = try this.toBodyValue(),
            },
            url,
            this.result.redirected,
        );
    }

    fn ignoreRemainingResponseBody(this: *FetchTasklet) void {
        log("ignoreRemainingResponseBody", .{});
        this.http_task.progress.ignoreData();
        // enabling streaming will make the http thread to drain into the main thread (aka stop buffering)
        // without a stream ref, response body or response instance alive it will just ignore the result
        if (this.http_task.http) |http_| {
            http_.enableResponseBodyStreaming();
        }
        // we should not keep the process alive if we are ignoring the body
        const vm = this.javascript_vm;
        this.poll_ref.unref(vm);
        // clean any remaining references
        this.clearStreamCancelHandler();
        this.readable_stream_ref.deinit();
        this.response.deinit();

        if (this.native_response) |response| {
            response.unref();
            this.native_response = null;
        }

        this.ignore_data = true;
    }

    fn onResponseFinalize(this: *FetchTasklet) void {
        if (this.detached) return;
        log("onResponseFinalize", .{});
        if (this.native_response) |response| {
            const body = response.getBodyValue();
            // Three scenarios:
            //
            // 1. We are streaming, in which case we should not ignore the body.
            // 2. We were buffering, in which case an active body consumption
            //    must keep loading and otherwise the body can be ignored.
            // 3. We never started buffering, in which case we should ignore the body.
            //
            if (body.* != .Locked or this.readable_stream_ref.has()) {
                // Scenario 1 or 3.
                return;
            }

            if (!body.Locked.hasStartedConsumption()) {
                // Scenario 2a or 3.
                this.ignoreRemainingResponseBody();
            }
        }
    }

    pub fn onResolve(this: *FetchTasklet) bun.JSError!Response.Ref {
        log("onResolve", .{});
        const response = try bun.default_allocator.create(Response);
        response.* = this.toResponse() catch |err| {
            bun.default_allocator.destroy(response);
            return err;
        };
        var response_ref = try response.toClassRef(this.global_this);
        errdefer response_ref.deinit();
        this.response = try ResponseHandle.initRef(&response_ref, this, onResponseFinalize);
        this.native_response = response.ref();
        return response_ref;
    }

    pub fn get(
        globalThis: *jsc.JSGlobalObject,
        fetch_options: *FetchOptions,
        completion: FetchCompletions.Owned,
    ) bun.JSError!*FetchTasklet {
        errdefer fetch_options.deinit();
        var owned_completion = completion;
        var completion_transferred = false;
        errdefer if (!completion_transferred) owned_completion.release();
        const jsc_vm = globalThis.bunVM();
        const registry = try (try jsc_vm.tryRareData()).nativeCompletionRegistry(jsc_vm);
        const native = try FetchHTTPTask.create(registry, jsc_vm.io);
        var native_transferred = false;
        errdefer if (!native_transferred) native.deref();
        const fetch_tasklet = try bun.default_allocator.create(FetchTasklet);
        fetch_tasklet.* = .{
            .http_task = native,
            .scheduled_response_buffer = .{
                .allocator = bun.default_allocator,
                .list = .{
                    .items = &.{},
                    .capacity = 0,
                },
            },
            .javascript_vm = jsc_vm,
            .request_body = fetch_options.body.take(),
            .global_this = globalThis,
            .completion = completion,
            .check_server_identity = if (fetch_options.check_server_identity) |*identity_callback| identity_callback.take() else null,
            .reject_unauthorized = fetch_options.reject_unauthorized,
            .upgraded_connection = fetch_options.upgraded_connection,
            .request_has_content_length = fetch_options.headers.get("content-length") != null and fetch_options.headers.get("transfer-encoding") == null,
        };
        native_transferred = true;
        native.request_headers = fetch_options.headers;
        native.url_proxy_buffer = fetch_options.url_proxy_buffer;
        native.hostname = fetch_options.hostname;
        completion_transferred = true;
        fetch_options.headers = .{ .allocator = fetch_options.headers.allocator };
        fetch_options.url_proxy_buffer = "";
        fetch_options.hostname = null;
        fetch_options.check_server_identity = null;
        errdefer fetch_tasklet.deref();

        native.signals = native.signal_store.to();
        if (fetch_tasklet.request_body == .AnyBlob) {
            native.request_bytes = try bun.default_allocator.dupe(u8, fetch_tasklet.request_body.slice());
            fetch_tasklet.request_body.detach();
        } else if (fetch_tasklet.request_body == .Sendfile) {
            native.sendfile = fetch_tasklet.request_body.Sendfile;
            fetch_tasklet.request_body = HTTPRequestBody.Empty;
        }

        var url = fetch_options.url;
        var proxy: ?ZigURL = null;
        if (fetch_options.proxy) |proxy_opt| {
            if (!proxy_opt.isEmpty()) { //if is empty just ignore proxy
                // Check NO_PROXY even for explicitly-provided proxies
                if (!jsc_vm.transpiler.env.isNoProxy(url.hostname, url.host)) {
                    proxy = proxy_opt;
                }
            }
            // else: proxy: "" means explicitly no proxy (direct connection)
        } else {
            // no proxy provided, use default proxy resolution
            if (jsc_vm.transpiler.env.getHttpProxyFor(url)) |env_proxy| {
                // env_proxy.href may be a slice into a RefCountedEnvValue's bytes which can
                // be freed by a subsequent `process.env.HTTP_PROXY = "..."` assignment while
                // this fetch is in flight on the HTTP thread. Clone it into url_proxy_buffer
                // alongside the request URL — the same pattern fetch.zig uses for the explicit
                // `fetch(url, { proxy: "..." })` option.
                if (env_proxy.href.len > 0) {
                    const old_url_len = url.href.len;
                    const new_buffer = try std.fmt.allocPrint(bun.default_allocator, "{s}{s}", .{ native.url_proxy_buffer, env_proxy.href });
                    if (native.url_proxy_buffer.len > 0) {
                        bun.default_allocator.free(native.url_proxy_buffer);
                    }
                    native.url_proxy_buffer = new_buffer;
                    url = ZigURL.parse(new_buffer[0..old_url_len]);
                    proxy = ZigURL.parse(new_buffer[old_url_len..]);
                } else {
                    proxy = env_proxy;
                }
            }
        }

        if (fetch_tasklet.check_server_identity != null and fetch_tasklet.reject_unauthorized) {
            native.signal_store.cert_errors.store(true, .monotonic);
        } else {
            native.signals.cert_errors = null;
        }

        // This task gets queued on the HTTP thread.
        native.http = try bun.default_allocator.create(http.AsyncHTTP);
        native.http.?.* = http.AsyncHTTP.init(
            bun.default_allocator,
            fetch_options.method,
            url,
            native.request_headers.entries,
            native.request_headers.buf.items,
            &native.response_buffer,
            native.request_bytes,
            http.HTTPClientResult.Callback.New(
                *FetchHTTPTask,
                FetchHTTPTask.onResult,
            ).init(native),
            fetch_options.redirect_type,
            .{
                .javascript_semantics = jsc_vm.transpiler.engine_capabilities.javascript_semantics,
                .http_proxy = proxy,
                .proxy_headers = fetch_options.proxy_headers,
                .hostname = native.hostname,
                .signals = native.signals,
                .unix_socket_path = fetch_options.unix_socket_path,
                .disable_timeout = fetch_options.disable_timeout,
                .disable_keepalive = fetch_options.disable_keepalive,
                .disable_decompression = fetch_options.disable_decompression,
                .reject_unauthorized = fetch_options.reject_unauthorized,
                .verbose = fetch_options.verbose,
                .tls_props = fetch_options.ssl_config,
            },
        );
        fetch_options.proxy_headers = null;
        fetch_options.unix_socket_path = bun.String.Slice.empty;
        fetch_options.ssl_config = null;
        // enable streaming the write side
        const isStream = fetch_tasklet.request_body == .ReadableStream;
        native.http.?.client.flags.is_streaming_request_body = isStream;
        native.http.?.client.flags.force_http2 = fetch_options.force_http2;
        native.http.?.client.flags.force_http3 = fetch_options.force_http3;
        native.http.?.client.flags.force_http1 = fetch_options.force_http1;
        fetch_tasklet.is_waiting_request_stream_start = isStream;
        if (isStream) {
            const buffer = try bun.tryNew(http.ThreadSafeStreamBuffer, .{ .io = jsc_vm.io });
            buffer.setDrainCallback(FetchHTTPTask, FetchHTTPTask.onDrain, native);
            native.stream_buffer = buffer;
            native.http.?.request_body = .{
                .stream = .{
                    .buffer = buffer,
                    .ended = false,
                },
            };
        }
        // TODO is this necessary? the http client already sets the redirect type,
        // so manually setting it here seems redundant
        if (fetch_options.redirect_type != FetchRedirect.follow) {
            native.http.?.client.remaining_redirect_count = 0;
        }

        // we want to return after headers are received
        native.signal_store.header_progress.store(true, .monotonic);

        if (native.sendfile) |body| {
            bun.assert(url.isHTTP());
            bun.assert(fetch_options.proxy == null);
            native.http.?.request_body = .{ .sendfile = body };
        }

        if (fetch_options.signal) |signal| {
            signal.pendingActivityRef();
            fetch_tasklet.signal = signal.listen(fetch_tasklet.global_this, &fetch_tasklet.abort_listener, fetch_tasklet, FetchTasklet.abortListener) catch |err| {
                signal.pendingActivityUnref();
                return err;
            };
            fetch_options.signal = null;
        }
        return fetch_tasklet;
    }

    pub fn abortListener(this: *FetchTasklet, reason: bun.bindgen.EngineValueView) void {
        log("abortListener", .{});
        var engine_reason = reason.toRoot() catch |err| {
            this.abortTask();
            return this.global_this.reportActiveExceptionAsUnhandled(err);
        };
        defer engine_reason.deinit();
        var reason_root = engine_reason.takeAnyRoot();
        defer reason_root.deinit();
        this.abort_reason.setRoot(&reason_root);
        this.abortTask();
        if (this.sink) |sink| {
            sink.cancel(&reason_root);
            return;
        }
        // Abort fired before the HTTP thread asked for the body, so the
        // ReadableStream was never wired into a sink. Cancel it directly so
        // the underlying source's cancel(reason) callback still observes the
        // signal's reason (https://fetch.spec.whatwg.org/#abort-fetch step 5).
        if (this.is_waiting_request_stream_start and this.request_body == .ReadableStream) {
            this.is_waiting_request_stream_start = false;
            this.request_body.ReadableStream.cancelWithReasonRoot(this.global_this, &reason_root);
        }
    }

    fn resumeRequestDataStream(this: *FetchTasklet) void {
        log("resumeRequestDataStream", .{});
        if (this.sink) |sink| {
            if (this.signal) |signal| {
                if (signal.aborted()) {
                    // already aborted; nothing to drain
                    return;
                }
            }
            sink.drain();
        }
    }

    /// Whether the request body should skip chunked transfer encoding framing.
    /// True for upgraded connections (e.g. WebSocket) or when the user explicitly
    /// set Content-Length without setting Transfer-Encoding.
    fn skipChunkedFraming(this: *const FetchTasklet) bool {
        return this.upgraded_connection or
            this.result.is_http2 or
            this.request_has_content_length;
    }

    pub fn writeRequestData(this: *FetchTasklet, data: []const u8) bun.OOM!ResumableSinkBackpressure {
        log("writeRequestData {}", .{data.len});
        if (this.detached) return .done;
        if (this.signal) |signal| {
            if (signal.aborted()) {
                return .done;
            }
        }
        const thread_safe_stream_buffer = this.http_task.stream_buffer orelse return .done;
        const stream_buffer = thread_safe_stream_buffer.acquire();
        defer thread_safe_stream_buffer.release();
        const highWaterMark = if (this.sink) |sink| sink.highWaterMark else 16384;
        // Only writeEndRequest may emit the zero-length chunk that terminates an HTTP body.
        if (data.len == 0) {
            return if (stream_buffer.size() >= highWaterMark) .backpressure else .want_more;
        }

        var needs_schedule = false;
        defer if (needs_schedule) {
            // wakeup the http thread to write the data
            http.http_thread.scheduleRequestWrite(this.http_task.http.?, .data);
        };

        // dont have backpressure so we will schedule the data to be written
        // if we have backpressure the onWritable will drain the buffer
        const was_empty = stream_buffer.isEmpty();
        if (this.skipChunkedFraming()) {
            try stream_buffer.write(data);
        } else {
            //16 is the max size of a hex number size that represents 64 bits + 2 for the \r\n
            var formated_size_buffer: [18]u8 = undefined;
            const formated_size = std.fmt.bufPrint(
                formated_size_buffer[0..],
                "{x}\r\n",
                .{data.len},
            ) catch |err| switch (err) {
                error.NoSpaceLeft => unreachable,
            };
            try stream_buffer.ensureUnusedCapacity(formated_size.len + data.len + 2);
            stream_buffer.writeAssumeCapacity(formated_size);
            stream_buffer.writeAssumeCapacity(data);
            stream_buffer.writeAssumeCapacity("\r\n");
        }
        needs_schedule = was_empty;

        // pause the stream if we hit the high water mark
        return if (stream_buffer.size() >= highWaterMark) .backpressure else .want_more;
    }

    pub fn writeEndRequest(this: *FetchTasklet, failed: bool, reason: ?*const bun.bindgen.Root) void {
        log("writeEndRequest hasError? {}", .{failed});
        defer this.deref();
        if (this.detached) return;
        if (failed) {
            if (this.http_task.signal_store.aborted.load(.monotonic) or this.abort_reason.has()) {
                return;
            }
            if (reason) |value| {
                this.abort_reason.setRoot(value);
            }
            this.abortTask();
        } else {
            if (!this.skipChunkedFraming()) {
                const write_error: ?bun.OOM = write_eof: {
                    const thread_safe_stream_buffer = this.http_task.stream_buffer orelse return;
                    const stream_buffer = thread_safe_stream_buffer.acquire();
                    defer thread_safe_stream_buffer.release();
                    stream_buffer.write(http.end_of_chunked_http1_1_encoding_response_body) catch |err| break :write_eof err;
                    break :write_eof null;
                };
                if (write_error) |err| {
                    if (!this.abort_reason.has()) {
                        var write_failure = this.retainFailure(err) catch |failure| {
                            this.abortTask();
                            this.global_this.reportActiveExceptionAsUnhandled(failure);
                            return;
                        };
                        defer write_failure.deinit();
                        this.abort_reason.setRoot(&write_failure);
                    }
                    this.abortTask();
                    return;
                }
            }
            if (this.http_task.http) |http_| {
                http.http_thread.scheduleRequestWrite(http_, .end);
            }
        }
    }

    pub fn abortTask(this: *FetchTasklet) void {
        this.http_task.abort();
    }

    pub const FetchOptions = struct {
        method: Method,
        headers: Headers,
        body: HTTPRequestBody,
        disable_timeout: bool,
        disable_keepalive: bool,
        disable_decompression: bool,
        reject_unauthorized: bool,
        url: ZigURL,
        verbose: http.HTTPVerboseLevel = .none,
        redirect_type: FetchRedirect = FetchRedirect.follow,
        proxy: ?ZigURL = null,
        proxy_headers: ?Headers = null,
        url_proxy_buffer: []const u8 = "",
        signal: ?*jsc.WebCore.AbortSignal = null,
        globalThis: ?*JSGlobalObject,
        // Custom Hostname
        hostname: ?[]u8 = null,
        check_server_identity: ?FetchCheckServerIdentityCallback = null,
        unix_socket_path: bun.String.Slice,
        ssl_config: ?SSLConfig.SharedPtr = null,
        upgraded_connection: bool = false,
        force_http2: bool = false,
        force_http3: bool = false,
        force_http1: bool = false,

        fn deinit(this: *FetchOptions) void {
            this.headers.deinit();
            this.body.detach();
            if (this.proxy_headers) |*headers| headers.deinit();
            this.proxy_headers = null;
            bun.default_allocator.free(this.url_proxy_buffer);
            this.url_proxy_buffer = "";
            if (this.signal) |signal| signal.unref();
            this.signal = null;
            if (this.hostname) |hostname| bun.default_allocator.free(hostname);
            this.hostname = null;
            if (this.check_server_identity) |*callback| callback.deinit();
            this.check_server_identity = null;
            this.unix_socket_path.deinit();
            this.unix_socket_path = bun.String.Slice.empty;
            if (this.ssl_config) |*config| config.deinit();
            this.ssl_config = null;
        }
    };

    pub fn queue(
        global: *JSGlobalObject,
        fetch_options: *FetchOptions,
        completion: FetchCompletions.Owned,
    ) bun.JSError!void {
        http.HTTPThread.init(global.bunVM().io, &.{});
        const node = try get(
            global,
            fetch_options,
            completion,
        );

        const native = node.http_task;
        native.entry = .{ .context = .init(node), .deliver = deliver, .detach = detach, .delivery = .repeating };
        if (!native.registry.register(&native.entry)) {
            node.deref();
            return global.throwTypeError("Cannot start fetch in a closed execution context", .{});
        }
        node.poll_ref.ref(global.bunVM());
        native.start();
    }
};

const X509Core = @import("../../api/bun/x509.zig");
const FetchHTTPTask = @import("./FetchHTTPTask.zig");
const X509Engine = @import("../../api/bun/X509Engine.zig");
const std = @import("std");
const Method = @import("../../../http_types/Method.zig").Method;
const ZigURL = @import("../../../url/url.zig").URL;

const bun = @import("bun");
const Async = bun.Async;
const MutableString = bun.MutableString;
const Output = bun.Output;
const BoringSSL = bun.BoringSSL.c;
const FetchHeaders = bun.webcore.FetchHeaders;
const SSLConfig = bun.api.server.ServerConfig.SSLConfig;

const http = bun.http;
const FetchRedirect = http.FetchRedirect;
const Headers = bun.http.Headers;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const VirtualMachine = jsc.VirtualMachine;
const FetchCheckServerIdentityCallbackSchema = bun.bindgen.CallbackSchema("FetchCheckServerIdentityCallback");
const FetchCheckServerIdentityCallback = bun.bindgen.Callback(FetchCheckServerIdentityCallbackSchema);

const Body = jsc.WebCore.Body;
const Response = jsc.WebCore.Response;
const ResumableSinkBackpressure = jsc.WebCore.ResumableSinkBackpressure;

const Blob = jsc.WebCore.Blob;
const AnyBlob = jsc.WebCore.Blob.Any;
