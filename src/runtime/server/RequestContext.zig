pub const AdditionalOnAbortCallback = @import("./AdditionalOnAbortCallback.zig");

pub fn NewRequestContext(comptime ssl_enabled: bool, comptime ThisServer: type, comptime http3: bool) type {
    return struct {
        const RequestContext = @This();
        const callback_prefix = if (http3) "h3" else if (ssl_enabled) "https" else "http";
        const BindingModule = bun.bindgen.Module("RequestContext");
        const OnResolveSchema = BindingModule.function(callback_prefix ++ "OnResolve");
        const OnRejectSchema = BindingModule.function(callback_prefix ++ "OnReject");
        const OnResolveStreamSchema = BindingModule.function(callback_prefix ++ "OnResolveStream");
        const OnRejectStreamSchema = BindingModule.function(callback_prefix ++ "OnRejectStream");
        const PromiseBindings = bun.bindgen.Module("promises");
        const PromiseStatusSchema = PromiseBindings.engineShim("promiseStatus");
        const PromiseRejectionReasonSchema = PromiseBindings.engineShim("promiseRejectionReason");
        const PromiseReaction = bun.bindgen.PromiseReaction(OnResolveSchema.args[1].ArgumentType, RequestContext);
        const OnResolveResult = @FieldType(bun.bindgen.Args(OnResolveSchema), "result");
        const OnResolveBinding = bun.bindgen.Fn(OnResolveSchema, bindOnResolve);
        const OnRejectBinding = bun.bindgen.Fn(OnRejectSchema, bindOnReject);
        const OnResolveStreamBinding = bun.bindgen.Fn(OnResolveStreamSchema, bindOnResolveStream);
        const OnRejectStreamBinding = bun.bindgen.Fn(OnRejectStreamSchema, bindOnRejectStream);

        const App = if (http3) struct {
            pub const Response = uws.H3.Response;
        } else uws.NewApp(ssl_enabled);
        /// uWS request type for this transport. The H3 wrapper mirrors
        /// uws.Request's surface so callers stay duck-typed.
        pub const Req = if (http3) uws.H3.Request else uws.Request;
        pub const Resp = App.Response;
        pub const is_h3 = http3;
        const UpgradeContext = union(enum) {
            none,
            available: *uws.WebSocketUpgradeContext,
            consumed,
        };
        pub threadlocal var pool: ?*RequestContext.RequestContextStackAllocator = null;
        pub const ResponseStream = jsc.WebCore.HTTPServerWritable(ssl_enabled, http3);

        // This pre-allocates up to 2,048 RequestContext structs.
        // It costs about 655,632 bytes.
        pub const RequestContextStackAllocator = bun.HiveArray(RequestContext, if (bun.heap_breakdown.enabled) 0 else 2048).Fallback;

        server: ?*ThisServer,
        routes: ?*ThisServer.RouteGeneration = null,
        resp: ?*App.Response,
        /// thread-local default heap allocator
        /// this prevents an extra pthread_getspecific() call which shows up in profiling
        allocator: std.mem.Allocator,
        req: ?*Req,
        request_weakref: Request.WeakRef = .empty,
        signal: ?*jsc.WebCore.AbortSignal = null,
        method: HTTP.Method,
        cookies: ?CookieMap.Owner = null,

        flags: Flags = .{},
        upgrade_context: UpgradeContext = .none,

        /// We can only safely free once the request body promise is finalized
        /// and the response is rejected
        response_root: ?Response.Ref = null,
        ref_count: u8 = 1,

        /// Tracks the native Response for stream cleanup without extending
        /// its lifetime after response_root is released.
        response_weakref: Response.WeakRef = .empty,
        blob: jsc.WebCore.Blob.Any = jsc.WebCore.Blob.Any{ .Blob = .{} },

        sendfile: SendfileContext = undefined,
        range: RangeRequest.Raw = .none,

        request_body_readable_stream_ref: jsc.WebCore.ReadableStream.Strong = .{},
        request_body_source: WebCore.Body.PendingValue.Source = .init(RequestContext, "request_body_source", .{
            .on_start_buffering = onStartBuffering,
            .on_start_streaming = onStartStreamingRequestBody,
            .on_readable_stream_available = onRequestBodyReadableStreamAvailable,
            .retain_owner = ref,
            .release_owner = deref,
        }),
        response_body_receiver: WebCore.Body.PendingValue.Receiver = .init(RequestContext, "response_body_receiver", .{
            .on_receive = doRenderWithBodyLocked,
            .on_drop = dropResponseBodyReceiver,
        }),
        request_body: ?*WebCore.Body.Value.HiveRef = null,
        request_body_buf: std.ArrayList(u8) = .empty,
        request_body_content_len: usize = 0,
        request_body_received: usize = 0,

        sink: ?*ResponseStream = null,
        byte_stream: ?*jsc.WebCore.ByteStream = null,
        /// This keeps the Response body's ReadableStream alive.
        response_body_readable_stream_ref: jsc.WebCore.ReadableStream.Strong = .{},

        /// Used in errors
        pathname: bun.String = bun.String.empty,

        /// Used either for temporary blob data or fallback
        /// When the response body is a temporary value
        response_buf_owned: std.ArrayList(u8) = .empty,

        /// Defer finalization until after the request handler task is completed?
        defer_deinit_until_callback_completes: ?*bool = null,

        additional_on_abort: ?AdditionalOnAbortCallback = null,

        // TODO: support builtin compression

        pub fn setSignalAborted(this: *RequestContext, reason: CommonAbortReason) void {
            if (this.signal) |signal| {
                if (this.server) |server| {
                    signal.signal(server.globalThis, reason);
                }
            }
        }

        pub fn devServer(this: *const RequestContext) ?*bun.bake.DevServer {
            const server = this.server orelse return null;
            return server.dev_server;
        }

        pub fn memoryCost(this: *const RequestContext) usize {
            // The Sink and ByteStream aren't owned by this.
            return @sizeOf(RequestContext) + this.request_body_buf.capacity + this.response_buf_owned.capacity + this.blob.memoryCost();
        }

        pub inline fn isAsync(this: *const RequestContext) bool {
            return this.defer_deinit_until_callback_completes == null;
        }

        fn drainMicrotasks(this: *const RequestContext) void {
            if (this.isAsync()) return;
            if (this.server) |server| {
                server.vm.drainMicrotasks() catch |err|
                    server.globalThis.reportActiveExceptionAsUnhandled(err);
            }
        }

        pub fn setAbortHandler(this: *RequestContext) void {
            if (this.flags.has_abort_handler) return;
            if (this.resp) |resp| {
                this.flags.has_abort_handler = true;
                resp.onAborted(*RequestContext, RequestContext.onAbort, this);
            }
        }

        pub fn setCookies(this: *RequestContext, cookie_map: ?*CookieMap) void {
            const replacement = if (cookie_map) |cookies| cookies.retain() else null;
            if (this.cookies) |*cookies| cookies.deinit();
            this.cookies = replacement;
        }

        fn bindOnResolve(
            _: bun.bindgen.CallContext(OnResolveSchema),
            args: bun.bindgen.Args(OnResolveSchema),
        ) bun.JSError!bun.bindgen.Return(OnResolveSchema) {
            ctxLog("onResolve", .{});

            const ctx = PromiseReaction.take(args.context) orelse {
                // The cell's destructor already released the ref (the Promise
                // was collected before a prior microtask turn reached us).
                return;
            };
            defer ctx.deref();

            handleResolve(ctx, args.result);
        }

        fn renderMissingInvalidResponse(ctx: *RequestContext) void {
            if (ctx.server) |server| {
                const globalThis: *jsc.JSGlobalObject = server.globalThis;
                Output.enableBuffering();
                const writer = Output.errorWriter();
                Output.errGeneric("Expected a Response object", .{});
                Output.flush();
                if (!globalThis.hasException()) {
                    jsc.ConsoleObject.writeTrace(@TypeOf(writer), writer, globalThis) catch {
                        _ = globalThis.clearExceptionExceptTermination();
                    };
                }
                Output.flush();
            }
            ctx.renderMissing();
        }

        fn handleResolve(ctx: *RequestContext, result: OnResolveResult) void {
            if (ctx.isAbortedOrEnded() or ctx.didUpgradeWebSocket()) {
                return;
            }

            switch (result) {
                .response => |response| ctx.handleResponseRef(response),
                .ignored => ctx.renderMissingInvalidResponse(),
            }
        }

        fn handleResponseRef(ctx: *RequestContext, response_ref: bun.bindgen.ClassRefView(Response.ResponseSchema)) void {
            if (ctx.server == null) {
                ctx.renderMissingInvalidResponse();
                return;
            }
            const response = response_ref.get(Response);
            var retained = response_ref.toOwned() catch |err| return ctx.fail(err);
            defer retained.deinit();
            ctx.retainResponse(&retained);

            if (ctx.method == .HEAD) {
                if (ctx.resp) |resp| {
                    var pair = HeaderResponsePair{ .this = ctx, .response = response };
                    ctx.runCorked(resp, *HeaderResponsePair, doRenderHeadResponse, &pair);
                }
                return;
            }

            ctx.render(response);
        }

        pub fn shouldRenderMissing(this: *RequestContext) bool {
            // If we did not respond yet, we should render missing
            // To allow this all the conditions above should be true:
            // 1 - still has a response (not detached)
            // 2 - not aborted
            // 3 - not marked completed
            // 4 - not marked pending
            // 5 - is the only reference of the context
            // 6 - is not waiting for request body
            // 7 - did not call sendfile
            ctxLog("RequestContext(0x{x}).shouldRenderMissing {s} {s} {s} {s} {s} {s} {s}", .{
                @intFromPtr(this),
                if (this.resp != null) "has response" else "no response",
                if (this.flags.aborted) "aborted" else "not aborted",
                if (this.flags.has_marked_complete) "marked complete" else "not marked complete",
                if (this.flags.has_marked_pending) "marked pending" else "not marked pending",
                if (this.ref_count == 1) "only reference" else "not only reference",
                if (this.flags.is_waiting_for_request_body) "waiting for request body" else "not waiting for request body",
                if (this.flags.has_sendfile_ctx) "has sendfile context" else "no sendfile context",
            });
            return this.resp != null and
                !this.flags.aborted and
                !this.flags.has_marked_complete and
                !this.flags.has_marked_pending and
                this.ref_count == 1 and
                !this.flags.is_waiting_for_request_body and
                !this.flags.has_sendfile_ctx;
        }

        pub fn isDeadRequest(this: *RequestContext) bool {
            // check if has pending promise or extra reference (aka not the only reference)
            if (this.ref_count > 1) return false;
            // check if the body is Locked (streaming)
            if (this.request_body) |body| {
                if (body.value == .Locked) {
                    return false;
                }
            }

            return true;
        }

        /// destroy RequestContext, should be only called by deref or if defer_deinit_until_callback_completes is ref is set to true
        pub fn deinit(this: *RequestContext) void {
            ctxLog("deinit", .{});
            this.detachResponse();
            this.endRequestStreamingAndDrain();
            // TODO: has_marked_complete is doing something?
            this.flags.has_marked_complete = true;

            if (this.defer_deinit_until_callback_completes) |defer_deinit| {
                defer_deinit.* = true;
                ctxLog("deferred deinit ({*})", .{this});
                return;
            }

            ctxLog("deinit ({*})", .{this});
            if (comptime Environment.isDebug)
                assert(this.flags.has_finalized);

            this.request_body_buf.clearAndFree(this.allocator);
            this.response_buf_owned.clearAndFree(this.allocator);
            this.response_weakref.deref();

            if (this.request_body) |body| {
                _ = body.unref();
                this.request_body = null;
            }

            if (this.additional_on_abort) |cb| {
                cb.deref();
                this.additional_on_abort = null;
            }

            if (this.routes) |routes| routes.deref();
            this.routes = null;

            if (this.server) |server| {
                this.server = null;
                if (comptime http3) server.h3_request_pool_allocator.put(this) else server.request_pool_allocator.put(this);
                server.onRequestComplete();
            }
        }

        pub fn deref(this: *RequestContext) void {
            streamLog("deref {d} -> {d}", .{ this.ref_count, this.ref_count - 1 });
            assert(this.ref_count > 0);
            const ref_count = this.ref_count;
            this.ref_count -= 1;
            if (ref_count == 1) {
                this.finalizeWithoutDeinit();
                this.deinit();
            }
        }

        pub fn ref(this: *RequestContext) void {
            streamLog("ref {d} -> {d}", .{ this.ref_count, this.ref_count + 1 });
            this.ref_count += 1;
        }

        pub fn releasePromiseReactionRef(this: *RequestContext) void {
            this.deref();
        }

        fn bindOnReject(
            context: bun.bindgen.CallContext(OnRejectSchema),
            args: bun.bindgen.Args(OnRejectSchema),
        ) bun.JSError!bun.bindgen.Return(OnRejectSchema) {
            ctxLog("onReject", .{});

            const ctx = PromiseReaction.take(args.context) orelse {
                // The cell's destructor already released the ref (the Promise
                // was collected before a prior microtask turn reached us).
                return;
            };
            defer ctx.deref();

            handleRejectView(ctx, context, args.result);
        }

        fn handleRejectView(ctx: *RequestContext, context: anytype, value: anytype) void {
            if (ctx.isAbortedOrEnded() or ctx.didUpgradeWebSocket()) return;

            const resp = ctx.resp.?;
            if (!resp.hasResponded()) {
                const original_state = ctx.defer_deinit_until_callback_completes;
                var should_deinit_context = if (original_state) |defer_deinit| defer_deinit.* else false;
                ctx.defer_deinit_until_callback_completes = &should_deinit_context;
                ctx.runErrorHandlerView(context, value);
                ctx.defer_deinit_until_callback_completes = original_state;
                if (should_deinit_context) {
                    ctx.deinit();
                    return;
                }
            }
            if (ctx.isAbortedOrEnded() or ctx.didUpgradeWebSocket()) return;

            if (!resp.hasResponded() and !ctx.flags.has_marked_pending and !ctx.flags.is_error_promise_pending) {
                ctx.renderMissing();
            }
        }

        pub fn fail(ctx: *RequestContext, failure: bun.JSError) void {
            ctx.handleFailure(failure, false);
        }

        pub fn failCallback(ctx: *RequestContext, failure: bun.JSError) void {
            ctx.handleFailure(failure, true);
        }

        fn handleFailure(ctx: *RequestContext, failure: bun.JSError, drain_microtasks: bool) void {
            const global = ctx.server.?.globalThis;
            var scope: bun.bindgen.FocusedEngineScope = undefined;
            scope.init(global);
            defer scope.deinit();
            const thrown = scope.takeThrownException(failure) catch |termination| {
                bun.bindgen.voidFromJSError(termination, global);
                return;
            };
            if (drain_microtasks) ctx.drainMicrotasks();
            ctx.handleRejectView(&scope, thrown);
        }

        pub fn renderMissing(ctx: *RequestContext) void {
            if (ctx.resp) |resp| {
                ctx.runCorked(resp, *RequestContext, renderMissingCorked, ctx);
            }
        }

        pub fn renderMissingCorked(ctx: *RequestContext) void {
            if (ctx.resp) |resp| {
                if (!ctx.server.?.config.isDevelopment()) {
                    if (!ctx.flags.has_written_status)
                        resp.writeStatus("204 No Content") catch |err| return ctx.failWrite(err);
                    ctx.flags.has_written_status = true;
                    ctx.end("", ctx.shouldCloseConnection());
                    return;
                }
                // avoid writing the status again and mismatching the content-length
                if (ctx.flags.has_written_status) {
                    ctx.end("", ctx.shouldCloseConnection());
                    return;
                }

                if (ctx.flags.is_web_browser_navigation) {
                    resp.writeStatus("200 OK") catch |err| return ctx.failWrite(err);
                    ctx.flags.has_written_status = true;

                    resp.writeHeader("content-type", MimeType.html.value) catch |err| return ctx.failWrite(err);
                    resp.writeHeader("content-encoding", "gzip") catch |err| return ctx.failWrite(err);
                    resp.writeHeaderInt("content-length", welcome_page_html_gz.len) catch |err| return ctx.failWrite(err);
                    ctx.end(welcome_page_html_gz, ctx.shouldCloseConnection());
                    return;
                }
                const missing_content = "Welcome to Bun! To get started, return a Response object.";
                resp.writeStatus("200 OK") catch |err| return ctx.failWrite(err);
                resp.writeHeader("content-type", MimeType.text.value) catch |err| return ctx.failWrite(err);
                resp.writeHeaderInt("content-length", missing_content.len) catch |err| return ctx.failWrite(err);
                ctx.flags.has_written_status = true;
                ctx.end(missing_content, ctx.shouldCloseConnection());
            }
        }

        pub fn renderDefaultError(
            this: *RequestContext,
            arena_allocator: std.mem.Allocator, // used for to allocate memory to render the fallback
            log: *logger.Log,
            err: anyerror,
            exceptions: []Api.JsException,
            comptime fmt: string,
            args: anytype,
        ) void {
            if (!this.flags.has_written_status) {
                if (this.resp) |resp| {
                    resp.writeStatus("500 Internal Server Error") catch |failure| return this.failWrite(failure);
                    this.flags.has_written_status = true;
                    resp.writeHeader("content-type", MimeType.html.value) catch |failure| return this.failWrite(failure);
                }
            }

            const fallback_container = arena_allocator.create(Api.FallbackMessageContainer) catch unreachable;
            defer arena_allocator.destroy(fallback_container);
            fallback_container.* = Api.FallbackMessageContainer{
                .message = std.fmt.allocPrint(arena_allocator, comptime Output.prettyFmt(fmt, false), args) catch unreachable,
                .router = null,
                .reason = .fetch_event_handler,
                .cwd = VirtualMachine.get().transpiler.fs.top_level_dir,
                .problems = Api.Problems{
                    .code = @as(u16, @truncate(@intFromError(err))),
                    .name = @errorName(err),
                    .exceptions = exceptions,
                    .build = log.toAPI(arena_allocator) catch unreachable,
                },
            };

            if (comptime fmt.len > 0) Output.prettyErrorln(fmt, args);
            Output.flush();

            // Explicitly use `this.allocator` and *not* the arena
            var bb = std.array_list.Managed(u8).init(this.allocator);
            defer bb.deinit();
            var bb_writer_state = bun.ManagedWriter.init(&bb);
            const bb_writer = bb_writer_state.writer();

            Fallback.renderBackend(
                this.server.?.globalThis.bunVM().io,
                arena_allocator,
                fallback_container,
                @TypeOf(bb_writer),
                bb_writer,
            ) catch unreachable;
            bb_writer_state.finish();
            const resp = this.resp orelse return;
            this.response_buf_owned.clearAndFree(this.allocator);
            this.response_buf_owned = bb.moveToUnmanaged();
            _ = this.sendWritableBytesForCompleteResponseBuffer(this.response_buf_owned.items, 0, resp);
        }

        fn drainResponseBufferAndMetadata(this: *RequestContext) void {
            if (this.renderMetadata()) |failure| return this.failMetadata(failure);
            if (this.response_buf_owned.items.len == 0) return;
            if (this.resp) |resp| {
                _ = resp.write(this.response_buf_owned.items) catch |err| return this.failWrite(err);
            }
            this.response_buf_owned.items.len = 0;
        }

        pub fn end(this: *RequestContext, data: []const u8, closeConnection: bool) void {
            ctxLog("end", .{});
            if (this.resp) |resp| {
                this.detachResponse();
                resp.end(data, closeConnection) catch |err| {
                    if (err != error.ConnectionClosed) anyResponse(resp).forceClose();
                    this.abortDetachedResponse();
                    return;
                };
                this.endRequestStreamingAndDrain();
                this.deref();
            }
        }

        pub fn endStream(this: *RequestContext, closeConnection: bool) void {
            ctxLog("endStream", .{});
            if (this.resp) |resp| {
                const pending = resp.state().isResponsePending();
                this.detachResponse();
                if (pending) resp.endStream(closeConnection) catch |err| {
                    if (err != error.ConnectionClosed) anyResponse(resp).forceClose();
                    this.abortDetachedResponse();
                    return;
                };
                this.endRequestStreamingAndDrain();
                this.deref();
            }
        }

        pub fn endWithoutBody(this: *RequestContext, closeConnection: bool) void {
            ctxLog("endWithoutBody", .{});
            if (this.resp) |resp| {
                this.detachResponse();
                resp.endWithoutBody(closeConnection) catch |err| {
                    if (err != error.ConnectionClosed) anyResponse(resp).forceClose();
                    this.abortDetachedResponse();
                    return;
                };
                this.endRequestStreamingAndDrain();
                this.deref();
            }
        }

        pub fn forceClose(this: *RequestContext) void {
            if (this.resp) |resp| {
                this.detachResponse();
                anyResponse(resp).forceClose();
                this.abortDetachedResponse();
            }
        }

        fn failWrite(this: *RequestContext, failure: uws.ResponseWriteError) void {
            const resp = this.resp orelse return;
            if (failure == error.ConnectionClosed) {
                this.releaseResponseState();
            } else {
                this.detachResponse();
                resp.clearOnWritable();
                anyResponse(resp).forceClose();
            }
            this.abortDetachedResponse();
        }

        fn runCorked(this: *RequestContext, resp: *App.Response, comptime Data: type, comptime handler: fn (Data) void, data: Data) void {
            this.ref();
            defer this.deref();
            resp.runCorkedWithType(Data, handler, data) catch |err| this.failWrite(err);
        }

        pub fn onWritableResponseBuffer(this: *RequestContext, _: u64, resp: *App.Response) bool {
            ctxLog("onWritableResponseBuffer", .{});

            assert(this.resp == resp);
            if (this.isAbortedOrEnded()) {
                return false;
            }
            this.end("", this.shouldCloseConnection());
            return false;
        }

        // TODO: should we cork?
        pub fn onWritableCompleteResponseBufferAndMetadata(this: *RequestContext, write_offset: u64, resp: *App.Response) bool {
            ctxLog("onWritableCompleteResponseBufferAndMetadata", .{});
            assert(this.resp == resp);

            if (this.isAbortedOrEnded()) {
                return false;
            }

            if (!this.flags.has_written_status) {
                if (this.renderMetadata()) |failure| {
                    this.failMetadata(failure);
                    return false;
                }
            }

            if (this.method == .HEAD) {
                this.endWithoutBody(this.shouldCloseConnection());
                return false;
            }

            return this.sendWritableBytesForCompleteResponseBuffer(this.response_buf_owned.items, write_offset, resp);
        }

        pub fn onWritableCompleteResponseBuffer(this: *RequestContext, write_offset: u64, resp: *App.Response) bool {
            ctxLog("onWritableCompleteResponseBuffer", .{});
            assert(this.resp == resp);
            if (this.isAbortedOrEnded()) {
                return false;
            }
            return this.sendWritableBytesForCompleteResponseBuffer(this.response_buf_owned.items, write_offset, resp);
        }

        inline fn anyResponse(r: *App.Response) uws.AnyResponse {
            return if (comptime http3) .{ .H3 = r } else if (comptime ssl_enabled) .{ .SSL = r } else .{ .TCP = r };
        }

        pub fn create(this: *RequestContext, server: *ThisServer, req: *Req, resp: *App.Response, should_deinit_context: ?*bool, method: ?bun.http.Method) void {
            this.* = .{
                .allocator = server.allocator,
                .resp = resp,
                .req = req,
                .method = method orelse HTTP.Method.which(req.method()) orelse .GET,
                .server = server,
                .routes = server.retainRoutes(),
                .defer_deinit_until_callback_completes = should_deinit_context,
                .range = RangeRequest.rawFromRequest(if (comptime http3) .{ .h3 = req } else .{ .h1 = req }),
            };

            ctxLog("create ({*})", .{this});
        }

        pub fn onAbort(this: *RequestContext, resp: *App.Response) void {
            ctxLog("onAbort", .{});
            assert(this.resp == resp);
            // An HTTP/3 stream is destroyed once both sides FIN, so this also
            // fires after a successful end(). HTTP/1 sockets persist for
            // keep-alive, so the equivalent never happens there. Drop the
            // pointer; everything else cleans up via the resolve/reject path.
            if (comptime http3) {
                if (resp.hasResponded()) {
                    this.completeResponse();
                    return;
                }
            }
            this.detachResponse();
            this.abortDetachedResponse();
        }

        fn abortDetachedResponse(this: *RequestContext) void {
            assert(this.resp == null);
            assert(!this.flags.aborted);
            assert(this.server != null);
            // mark request as aborted
            this.flags.aborted = true;
            if (this.additional_on_abort) |abort| {
                defer abort.deref();
                this.additional_on_abort = null;
                abort.cb(abort.data);
            }

            var any_js_calls = false;
            var vm = this.server.?.vm;
            const globalThis = this.server.?.globalThis;
            defer {
                // This is a task in the event loop.
                // If we called into JavaScript, we must drain the microtask queue
                if (any_js_calls) {
                    vm.drainMicrotasks() catch |err|
                        globalThis.reportActiveExceptionAsUnhandled(err);
                }
                this.deref();
            }

            if (this.request_weakref.get()) |request| {
                request.request_context = AnyRequestContext.Null;
                this.request_weakref.deref();
            }
            // if signal is not aborted, abort the signal
            if (this.signal) |signal| {
                this.signal = null;
                defer {
                    signal.pendingActivityUnref();
                    signal.unref();
                }
                if (!signal.aborted()) {
                    signal.signal(globalThis, .ConnectionClosed);
                    any_js_calls = true;
                }
            }

            //if have sink, call onAborted on sink
            if (this.sink) |wrapper| {
                wrapper.abort();
                return;
            }

            // if we can, free the request now.
            if (this.isDeadRequest()) {
                this.finalizeWithoutDeinit();
            } else {
                const did_call_js = this.endRequestStreaming() catch |err| failed: {
                    globalThis.reportActiveExceptionAsUnhandled(err);
                    break :failed true;
                };
                if (did_call_js) {
                    any_js_calls = true;
                }

                if (this.response_weakref.get()) |response| {
                    const response_stream = response.getBodyReadableStream(globalThis) catch |err| {
                        any_js_calls = true;
                        const body_error = WebCore.Body.Value.ValueError.fromFailure(err, globalThis) catch |failure|
                            return globalThis.reportActiveExceptionAsUnhandled(failure);
                        response.detachReadableStream(globalThis) catch |failure|
                            globalThis.reportActiveExceptionAsUnhandled(failure);
                        response.getBodyValue().toErrorInstance(body_error, globalThis) catch |failure|
                            globalThis.reportActiveExceptionAsUnhandled(failure);
                        return;
                    };
                    if (response_stream) |stream| {
                        var owned_stream = stream;
                        defer owned_stream.deinit();
                        response.detachReadableStream(globalThis) catch |err|
                            globalThis.reportActiveExceptionAsUnhandled(err);
                        owned_stream.abort(globalThis);
                        any_js_calls = true;
                    }
                }
            }
        }

        // This function may be called multiple times
        // so it's important that we can safely do that
        pub fn finalizeWithoutDeinit(this: *RequestContext) void {
            ctxLog("finalizeWithoutDeinit ({*})", .{this});
            this.blob.detach();
            assert(this.server != null);
            const globalThis = this.server.?.globalThis;

            if (comptime Environment.isDebug) {
                ctxLog("finalizeWithoutDeinit: has_finalized {}", .{this.flags.has_finalized});
                this.flags.has_finalized = true;
            }

            if (this.response_root) |*response| {
                ctxLog("finalizeWithoutDeinit: clearing response_root", .{});
                response.deinit();
                this.response_root = null;
            }
            this.response_weakref.deref();

            this.request_body_readable_stream_ref.deinit();

            if (this.cookies) |*cookies| {
                cookies.deinit();
                this.cookies = null;
            }

            if (this.request_weakref.get()) |request| {
                request.request_context = AnyRequestContext.Null;
                this.request_weakref.deref();
            }

            // if signal is not aborted, abort the signal
            if (this.signal) |signal| {
                this.signal = null;
                defer {
                    signal.pendingActivityUnref();
                    signal.unref();
                }
                if (this.flags.aborted and !signal.aborted()) {
                    signal.signal(globalThis, .ConnectionClosed);
                }
            }

            // Case 1:
            // User called .blob(), .json(), text(), or .arrayBuffer() on the Request object
            // but we received nothing or the connection was aborted
            // the promise is pending
            // Case 2:
            // User ignored the body and the connection was aborted or ended
            // Case 3:
            // Stream was not consumed and the connection was aborted or ended
            _ = this.endRequestStreaming() catch |err|
                globalThis.reportActiveExceptionAsUnhandled(err);

            if (this.byte_stream) |stream| {
                ctxLog("finalizeWithoutDeinit: stream != null", .{});

                this.byte_stream = null;
                stream.unpipe();
            }

            this.response_body_readable_stream_ref.deinit();

            if (!this.pathname.isEmpty()) {
                this.pathname.deref();
                this.pathname = bun.String.empty;
            }
        }

        fn onFileStreamComplete(ctx: FileResponseStream.Context) void {
            const this = ctx.get(*RequestContext);
            this.releaseResponseState();
            this.endRequestStreamingAndDrain();
            this.deref();
        }

        fn onFileStreamAbort(ctx: FileResponseStream.Context, resp: uws.AnyResponse) void {
            const this = ctx.get(*RequestContext);
            // Route through the real onAbort so flags.aborted, request.signal,
            // and additional_on_abort fire exactly as they did pre-consolidation.
            this.onAbort(if (comptime http3) resp.H3 else if (comptime ssl_enabled) resp.SSL else resp.TCP);
        }

        fn onFileStreamError(ctx: FileResponseStream.Context, _: FileResponseStream.Failure) void {
            // FileResponseStream already force-closed the socket; just clean up.
            onFileStreamComplete(ctx);
        }

        pub fn onWritableBytes(this: *RequestContext, write_offset: u64, resp: *App.Response) bool {
            ctxLog("onWritableBytes", .{});
            assert(this.resp == resp);
            if (this.isAbortedOrEnded()) {
                return false;
            }

            // Copy to stack memory to prevent aliasing issues in release builds
            const blob = this.blob;
            const bytes = blob.slice();

            return this.sendWritableBytesForBlob(bytes, write_offset, resp);
        }

        pub fn sendWritableBytesForBlob(this: *RequestContext, bytes_: []const u8, write_offset_: u64, resp: *App.Response) bool {
            return this.sendWritableBytes(bytes_, write_offset_, resp, false);
        }

        pub fn sendWritableBytesForCompleteResponseBuffer(this: *RequestContext, bytes_: []const u8, write_offset_: u64, resp: *App.Response) bool {
            return this.sendWritableBytes(bytes_, write_offset_, resp, true);
        }

        fn sendWritableBytes(this: *RequestContext, bytes_: []const u8, write_offset: u64, resp: *App.Response, comptime buffered: bool) bool {
            assert(this.resp == resp);
            this.ref();
            defer this.deref();

            const bytes = bytes_[@min(bytes_.len, write_offset)..];
            resp.clearAborted();
            this.flags.has_abort_handler = false;
            resp.clearOnWritable();
            const finished = resp.tryEnd(bytes, bytes_.len, this.shouldCloseConnection()) catch |err| {
                this.failWrite(err);
                return false;
            };
            if (this.resp == null) return false;
            if (finished) {
                if (buffered) this.response_buf_owned.items.len = 0;
                this.releaseResponseState();
                this.endRequestStreamingAndDrain();
                this.deref();
            } else {
                this.flags.has_marked_pending = true;
                this.setAbortHandler();
                resp.onWritable(*RequestContext, if (buffered) onWritableCompleteResponseBuffer else onWritableBytes, this);
            }

            return true;
        }

        pub fn doSendfile(this: *RequestContext, blob: Blob) void {
            if (this.isAbortedOrEnded()) return;
            if (this.flags.has_sendfile_ctx) return;

            if (this.resp == null or this.server == null) return;
            const globalThis = this.server.?.globalThis;
            const resp = this.resp.?;

            this.blob = .{ .Blob = blob };
            const file = &this.blob.store().?.data.file;
            var file_buf: bun.PathBuffer = undefined;
            const auto_close = file.pathlike != .fd;
            const fd: bun.FD = if (!auto_close)
                file.pathlike.fd
            else switch (bun.sys.open(file.pathlike.path.sliceZ(&file_buf), bun.O.RDONLY | bun.O.NONBLOCK | bun.O.CLOEXEC, 0)) {
                .result => |_fd| _fd,
                .err => |err| {
                    var error_root = bun.api.SystemErrorBindings.toRoot(err.withPath(file.pathlike.path.slice()), globalThis) catch |failure|
                        return this.finishRunningErrorHandlerFailure(failure, 500);
                    defer error_root.deinit();
                    return this.runErrorHandler(&error_root);
                },
            };

            const stat: bun.Stat = switch (bun.sys.fstat(fd)) {
                .result => |s| s,
                .err => |err| {
                    if (auto_close) fd.close();
                    var error_root = bun.api.SystemErrorBindings.toRoot(err.withPathLike(file.pathlike), globalThis) catch |failure|
                        return this.finishRunningErrorHandlerFailure(failure, 500);
                    defer error_root.deinit();
                    return this.runErrorHandler(&error_root);
                },
            };

            const is_regular = bun.isRegularFile(stat.mode);
            const file_type: bun.io.FileType, const pollable: bool = brk: {
                if (bun.S.ISFIFO(@intCast(stat.mode)) or bun.S.ISCHR(@intCast(stat.mode))) break :brk .{ .pipe, true };
                if (bun.S.ISSOCK(@intCast(stat.mode))) break :brk .{ .socket, true };
                if (bun.S.ISDIR(@intCast(stat.mode))) {
                    if (auto_close) fd.close();
                    var sys = (bun.sys.Error{
                        .errno = @backingInt(bun.sys.E.ISDIR),
                        .syscall = .read,
                    }).withPathLike(file.pathlike).toSystemError();
                    sys.message = bun.String.static("Cannot stream a directory as a response body");
                    var error_root = bun.api.SystemErrorBindings.systemErrorToRoot(sys, globalThis) catch |failure|
                        return this.finishRunningErrorHandlerFailure(failure, 500);
                    defer error_root.deinit();
                    return this.runErrorHandler(&error_root);
                }
                break :brk .{ .file, false };
            };

            const original_size = this.blob.Blob.size;
            const stat_size: Blob.SizeType = @intCast(@max(stat.size, 0));
            this.blob.Blob.size = if (is_regular) stat_size else @min(original_size, stat_size);

            this.flags.needs_content_length = true;
            this.sendfile = .{
                .remain = this.blob.Blob.offset + original_size,
                .offset = this.blob.Blob.offset,
            };
            if (is_regular and auto_close) {
                this.flags.needs_content_range = (this.sendfile.remain -| this.sendfile.offset) != stat_size;
            }
            if (is_regular) {
                this.sendfile.offset = @min(this.sendfile.offset, stat_size);
                this.sendfile.remain = @min(@max(this.sendfile.remain, this.sendfile.offset), stat_size) -| this.sendfile.offset;
            }

            // Honor an incoming Range: header for whole-file responses. We
            // don't compose Range with a user-supplied .slice() because the
            // Content-Range arithmetic gets ambiguous; the slice path keeps
            // its existing slice-as-range behavior. `offset == 0` alone is
            // insufficient — `Bun.file(p).slice(0, n)` has offset 0 — so we
            // also check the size: an unsliced blob has either the unset-size
            // sentinel or, if JS already read `.size`, the stat'd size; a
            // `.slice(0, n)` blob has `n < stat_size`. Skip if the user
            // already set Content-Range or a non-200 status — they're
            // managing partial responses themselves.
            const user_handles_range = if (this.response_weakref.get()) |r|
                r.statusCode() != 200 or (if (r.getInitHeaders()) |h| h.fastHas(.ContentRange) else false)
            else
                false;
            const is_whole_file = this.blob.Blob.offset == 0 and (original_size == Blob.max_size or original_size == stat_size);
            // RFC 9110 §14.2: Range is only defined for GET (HEAD mirrors GET's headers).
            const method_allows_range = this.method == .GET or this.method == .HEAD;
            if (is_regular and method_allows_range and !user_handles_range and is_whole_file and this.range != .none) {
                switch (this.range.resolve(stat_size)) {
                    .none => {},
                    .satisfiable => |r| {
                        this.sendfile.offset = @intCast(r.start);
                        this.sendfile.remain = @intCast(r.end - r.start + 1);
                        this.sendfile.total = stat_size;
                        this.flags.needs_content_range = true;
                    },
                    .unsatisfiable => {
                        if (auto_close) fd.close();
                        var crbuf: [64]u8 = undefined;
                        this.doWriteStatus(416) catch |err| return this.failWrite(err);
                        if (this.response_weakref.get()) |response| {
                            if (response.retainInitHeaders()) |value| {
                                var headers = value;
                                defer headers.deinit();
                                this.doWriteHeaders(headers.get()) catch |err| return this.failWrite(err);
                            }
                        }
                        resp.writeHeader("content-range", std.fmt.bufPrint(&crbuf, "bytes */{d}", .{stat_size}) catch unreachable) catch |err| return this.failWrite(err);
                        resp.writeHeader("accept-ranges", "bytes") catch |err| return this.failWrite(err);
                        this.end("", this.shouldCloseConnection());
                        return;
                    },
                }
            }

            if (this.renderMetadataCorked()) |failure| {
                if (auto_close) fd.close();
                return this.failMetadata(failure);
            }

            if ((is_regular and this.sendfile.remain == 0) or !this.method.hasBody()) {
                if (auto_close) fd.close();
                this.end("", this.shouldCloseConnection());
                return;
            }

            // FileResponseStream owns the abort and writable registrations until completion.
            this.flags.has_sendfile_ctx = true;
            this.flags.has_abort_handler = true;
            this.flags.has_marked_pending = true;

            FileResponseStream.start(.{
                .fd = fd,
                .auto_close = auto_close,
                .resp = anyResponse(resp),
                .runtime_loop = this.server.?.vm.runtimeLoopHandle(),
                .file_type = file_type,
                .pollable = pollable,
                .offset = this.sendfile.offset,
                .length = if (is_regular) @as(u64, this.sendfile.remain) else null,
                .idle_timeout = this.server.?.config.idleTimeout,
                .ctx = .init(this),
                .on_complete = onFileStreamComplete,
                .on_abort = onFileStreamAbort,
                .on_error = onFileStreamError,
            });
        }

        pub fn doRenderWithBodyLocked(this: *RequestContext, value: *jsc.WebCore.Body.Value) void {
            defer this.deref();
            doRenderWithBody(this, value, null);
        }

        fn dropResponseBodyReceiver(this: *RequestContext) void {
            this.deref();
        }

        fn renderWithBlobFromBodyValue(this: *RequestContext) void {
            if (this.isAbortedOrEnded()) {
                return;
            }

            if (this.blob.needsToReadFile()) {
                if (!this.flags.has_sendfile_ctx)
                    this.doSendfile(this.blob.Blob);
                return;
            }

            this.doRenderBlob();
        }

        const StreamPair = struct { this: *RequestContext, stream: *jsc.WebCore.ReadableStream.Strong };

        fn doRenderStream(pair: *StreamPair) void {
            ctxLog("doRenderStream", .{});
            var this = pair.this;
            this.ref();
            defer this.deref();
            var retained_stream = pair.stream.clone();
            defer retained_stream.deinit();
            const stream = &retained_stream;
            assert(this.server != null);
            const globalThis = this.server.?.globalThis;

            if (this.isAbortedOrEnded()) {
                stream.cancel(globalThis);
                this.response_body_readable_stream_ref.deinit();
                return;
            }
            const resp = this.resp.?;

            var response_stream = this.allocator.create(ResponseStream) catch |err| return this.fail(err);
            response_stream.* = .{
                .res = resp,
                .allocator = this.allocator,
                .buffer = bun.ByteList{},
                .globalThis = globalThis,
            };
            response_stream.ref();
            defer response_stream.deref();
            // we need to render metadata before assignToStream because the stream can call res.end
            // and this would auto write an 200 status
            if (!this.flags.has_written_status) {
                if (this.renderMetadata()) |failure| {
                    response_stream.destroy();
                    return this.failMetadata(failure);
                }
            }

            var signal = &response_stream.signal;
            this.sink = response_stream;
            signal.clear();
            assert(signal.isDead());

            // We are already corked!
            var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
            engine_scope.init(globalThis);
            defer engine_scope.deinit();
            var owned_stream = stream.cloneOwned() orelse @panic("cannot render an empty readable stream");
            defer owned_stream.deinit();
            var assignment_result = ResponseStream.JSSink.assignToStream(
                globalThis,
                &owned_stream,
                response_stream,
            ) catch |err| {
                streamLog("assignToStream failed", .{});
                return this.failStream(err);
            };
            defer if (assignment_result) |*promise| promise.deinit();

            this.abortFromSink(response_stream);

            if (response_stream.done and !response_stream.aborted and response_stream.res == null) {
                streamLog("done", .{});
                this.discardResponseSink();
                stream.done(globalThis);
                this.response_body_readable_stream_ref.deinit();
                return;
            }

            // Synchronous assignment can finish while the transport still has a pending drain.
            const EffectivePromise = union(enum) {
                assignment: *const ResponseStream.JSSink.AssignToStreamResult,
                transport_flush: *const WebCore.Sink.PendingCountPromise,
            };
            var transport_flush_promise: ?WebCore.Sink.PendingCountPromise = null;
            defer if (transport_flush_promise) |*promise| promise.deinit();
            const effective_result: ?EffectivePromise = if (assignment_result) |*promise| .{
                .assignment = promise,
            } else if (response_stream.pending_flush.has()) pending: {
                transport_flush_promise = response_stream.pending_flush.existingPromiseOwned();
                break :pending .{ .transport_flush = &transport_flush_promise.? };
            } else null;

            if (effective_result) |effective_promise| switch (effective_promise) {
                inline else => |promise| {
                    streamLog("returned a promise", .{});
                    this.drainMicrotasks();
                    if (response_stream.done and !response_stream.aborted and response_stream.res == null) {
                        this.discardResponseSink();
                        stream.done(globalThis);
                        this.response_body_readable_stream_ref.deinit();
                        return;
                    }
                    if (this.isAbortedOrEnded()) {
                        this.discardResponseSink();
                        stream.cancel(globalThis);
                        this.response_body_readable_stream_ref.deinit();
                        return;
                    }

                    switch (engine_scope.engine(PromiseStatusSchema).call(.{ .promise = promise.operand(&engine_scope).asPromise() })) {
                        .pending => {
                            streamLog("promise still Pending", .{});
                            assert(this.flags.has_written_status);

                            if (this.response_weakref.get()) |response| {
                                const body = response.getBodyValue();
                                if (body.* == .Locked) {
                                    var previous = body.Locked.readable;
                                    body.Locked.readable = stream.clone();
                                    previous.deinit();
                                }
                            }
                            this.flags.has_marked_pending = true;
                            this.ref();
                            PromiseReaction.attach(
                                &engine_scope,
                                promise.operand(&engine_scope).asPromise(),
                                this,
                                OnResolveStreamBinding,
                                OnRejectStreamBinding,
                            ) catch |failure| return this.failStream(failure);
                        },
                        .fulfilled => {
                            streamLog("promise Fulfilled", .{});
                            stream.done(globalThis);
                            var response_body_readable_stream_ref = this.response_body_readable_stream_ref;
                            this.response_body_readable_stream_ref = .{};
                            defer response_body_readable_stream_ref.deinit();

                            this.handleResolveStream();
                        },
                        .rejected => {
                            streamLog("promise Rejected", .{});
                            stream.cancel(globalThis);
                            var response_body_readable_stream_ref = this.response_body_readable_stream_ref;
                            this.response_body_readable_stream_ref = .{};
                            defer response_body_readable_stream_ref.deinit();
                            const reason = engine_scope.engine(PromiseRejectionReasonSchema).call(.{
                                .promise = promise.operand(&engine_scope).asPromise(),
                            }) catch |failure| return this.failStream(failure);
                            if (reason) |value| {
                                this.handleRejectStream(&engine_scope, value, true, .direct);
                            } else {
                                this.handleRejectStream(&engine_scope, bun.bindgen.AnyResult.initUndefined(&engine_scope), false, .direct);
                            }
                        },
                    }
                    return;
                },
            };

            if (this.isAbortedOrEnded()) {
                this.discardResponseSink();
                stream.cancel(globalThis);
                this.response_body_readable_stream_ref.deinit();
                return;
            }
            const is_in_progress = response_stream.has_backpressure or !(response_stream.wrote == 0 and
                response_stream.buffer.len == 0);

            if (!stream.isLocked(globalThis) and !is_in_progress) {
                const previous_source = stream.sourceTag();
                stream.refreshSource() catch |err| return this.failStream(err);
                if (stream.sourceTag() == previous_source) {
                    streamLog("is not locked", .{});
                    this.discardResponseSink();
                    this.response_body_readable_stream_ref.deinit();
                    this.renderMissing();
                    return;
                }
            }

            streamLog("is in progress, but did not return a Promise. Finalizing request context", .{});
            this.discardResponseSink();
            stream.cancel(globalThis);
            this.response_body_readable_stream_ref.deinit();
            if (is_in_progress) this.forceClose() else this.renderMissing();
        }

        const streamLog = Output.scoped(.ReadableStream, .visible);

        pub fn didUpgradeWebSocket(this: *RequestContext) bool {
            return this.upgrade_context == .consumed;
        }

        fn toAsyncWithoutAbortHandler(ctx: *RequestContext, req: *Req, request_object: *Request) bun.OOM!void {
            assert(ctx.server != null);

            // For HTTP/3, prepareJsRequestContextFor() already eagerly
            // populated url+headers (the lazy getRequest() path is H1-only),
            // so the guards below short-circuit and `req` is never read.
            if (comptime !http3) request_object.request_context.setRequest(req);
            defer request_object.request_context.detachRequest();

            try request_object.ensureURL();

            // we have to clone the request headers here since they will soon belong to a different request
            if (!request_object.hasFetchHeaders()) {
                if (comptime !http3) request_object.setFetchHeaders(try WebCore.FetchHeaders.createFromUWS(req));
            }
        }

        pub fn toAsync(
            ctx: *RequestContext,
            req: *Req,
            request_object: *Request,
        ) bun.OOM!void {
            ctxLog("toAsync", .{});
            try ctx.toAsyncWithoutAbortHandler(req, request_object);
            if (ctx.server.?.config.isDevelopment()) {
                var pathname = request_object.url.clone();
                ctx.pathname = pathname.takeBunString();
            }
            ctx.setAbortHandler();
        }

        fn endRequestStreamingAndDrain(this: *RequestContext) void {
            assert(this.server != null);

            const server = this.server.?;
            const did_call_js = this.endRequestStreaming() catch |err| {
                server.globalThis.reportActiveExceptionAsUnhandled(err);
                return;
            };
            if (did_call_js) {
                server.vm.drainMicrotasks() catch |err|
                    server.globalThis.reportActiveExceptionAsUnhandled(err);
            }
        }
        fn endRequestStreaming(this: *RequestContext) bun.JSError!bool {
            assert(this.server != null);

            this.request_body_buf.clearAndFree(bun.default_allocator);

            // if we cannot, we have to reject pending promises
            // first, we reject the request body promise
            if (this.request_body) |body| {
                // User called .blob(), .json(), text(), or .arrayBuffer() on the Request object
                // but we received nothing or the connection was aborted
                if (body.value == .Locked) {
                    try body.value.toErrorInstance(.{ .AbortReason = .ConnectionClosed }, this.server.?.globalThis);
                    return true;
                }
            }
            return false;
        }
        fn detachResponse(this: *RequestContext) void {
            if (this.resp) |resp| {
                this.resp = null;

                if (this.flags.is_waiting_for_request_body) {
                    this.flags.is_waiting_for_request_body = false;
                    resp.clearOnData();
                }
                if (this.flags.has_abort_handler) {
                    resp.clearAborted();
                    this.flags.has_abort_handler = false;
                }
            }
            this.releaseResponseState();
        }

        fn releaseResponseState(this: *RequestContext) void {
            this.resp = null;
            this.flags.is_waiting_for_request_body = false;
            this.flags.has_abort_handler = false;
            this.request_body_buf.clearAndFree(bun.default_allocator);
        }

        fn completeResponse(this: *RequestContext) void {
            if (this.resp == null) return;
            if (comptime http3) {
                this.detachResponse();
            } else {
                this.releaseResponseState();
            }
            this.endRequestStreamingAndDrain();
            this.deref();
        }

        pub fn isAbortedOrEnded(this: *const RequestContext) bool {
            // resp == null or aborted or server.stop(true)
            return this.resp == null or this.flags.aborted or this.server == null or this.server.?.flags.terminated;
        }
        const HeaderResponseSizePair = struct { this: *RequestContext, size: usize };
        pub fn doRenderHeadResponseAfterS3SizeResolved(pair: *HeaderResponseSizePair) void {
            var this = pair.this;
            if (this.renderMetadata()) |failure| return this.failMetadata(failure);

            if (this.resp) |resp| {
                resp.writeHeaderInt("content-length", pair.size) catch |err| return this.failWrite(err);
            }
            this.endWithoutBody(this.shouldCloseConnection());
        }
        pub fn onS3SizeResolved(result: S3.S3StatResult, opaque_this: S3.CallbackContext) void {
            const this = opaque_this.get(*RequestContext);
            defer {
                this.deref();
            }
            if (this.resp) |resp| {
                var pair = HeaderResponseSizePair{ .this = this, .size = switch (result) {
                    .out_of_memory => return this.fail(error.OutOfMemory),
                    .failure, .not_found => 0,
                    .success => |stat| stat.size,
                } };
                this.runCorked(resp, *HeaderResponseSizePair, doRenderHeadResponseAfterS3SizeResolved, &pair);
            }
        }
        const HeaderResponsePair = struct { this: *RequestContext, response: *jsc.WebCore.Response };

        fn doRenderHeadResponse(pair: *HeaderResponsePair) void {
            var this = pair.this;
            var response = pair.response;
            if (this.resp == null) {
                return;
            }
            // we will render the content-length header later manually so we set this to false
            this.flags.needs_content_length = false;
            // Always this.renderMetadata() before sending the content-length or transfer-encoding header so status is sent first

            const resp = this.resp.?;
            this.setResponse(response);
            const server = this.server.?;
            if (response.getFetchHeaders()) |headers| {
                // first respect the headers
                if (comptime !http3) if (headers.fastGet(.TransferEncoding) catch |err| return this.fail(err)) |owned_transfer_encoding| {
                    var transfer_encoding = owned_transfer_encoding;
                    defer transfer_encoding.deinit();
                    const transfer_encoding_str = transfer_encoding.toUTF8(server.allocator) catch |err| return this.fail(err);
                    defer transfer_encoding_str.deinit();
                    if (this.renderMetadata()) |failure| return this.failMetadata(failure);
                    resp.writeHeader("transfer-encoding", transfer_encoding_str.slice()) catch |err| return this.failWrite(err);
                    this.endWithoutBody(this.shouldCloseConnection());

                    return;
                };
                if (headers.fastGet(.ContentLength) catch |err| return this.fail(err)) |owned_content_length| {
                    var content_length = owned_content_length;
                    defer content_length.deinit();
                    const content_length_str = content_length.toUTF8(server.allocator) catch |err| return this.fail(err);
                    const len = std.fmt.parseInt(usize, content_length_str.slice(), 10) catch 0;
                    content_length_str.deinit();

                    if (this.renderMetadata()) |failure| return this.failMetadata(failure);
                    resp.writeHeaderInt("content-length", len) catch |err| return this.failWrite(err);
                    this.endWithoutBody(this.shouldCloseConnection());
                    return;
                }
            }
            // not content-length or transfer-encoding so we need to respect the body
            const bodyValue = response.getBodyValue();
            bodyValue.toBlobIfPossible() catch |err| return this.fail(err);
            switch (bodyValue.*) {
                .InternalBlob, .WTFStringImpl => {
                    var blob = bodyValue.useAsAnyBlobAllowNonUTF8String() catch |err| return this.fail(err);
                    defer blob.detach();
                    const size = blob.size();
                    if (this.renderMetadata()) |failure| return this.failMetadata(failure);

                    if (size == Blob.max_size) {
                        resp.writeHeaderInt("content-length", 0) catch |err| return this.failWrite(err);
                    } else {
                        resp.writeHeaderInt("content-length", size) catch |err| return this.failWrite(err);
                    }
                    this.endWithoutBody(this.shouldCloseConnection());
                },

                .Blob => |*blob| {
                    if (blob.isS3()) {
                        // we need to read the size asynchronously
                        // in this case should always be a redirect so should not hit this path, but in case we change it in the future lets handle it
                        this.ref();

                        const credentials = blob.storePtr().?.data.s3.getCredentials();
                        const path = blob.storePtr().?.data.s3.path();
                        const env = server.vm.transpiler.env;

                        S3.stat(credentials, path, onS3SizeResolved, .init(this), if (env.getHttpProxy(true, null, null)) |proxy| proxy.href else null, blob.storePtr().?.data.s3.request_payer);
                        return;
                    }
                    if (this.renderMetadata()) |failure| return this.failMetadata(failure);

                    blob.resolveSize();
                    if (blob.size == Blob.max_size) {
                        resp.writeHeaderInt("content-length", 0) catch |err| return this.failWrite(err);
                    } else {
                        resp.writeHeaderInt("content-length", blob.size) catch |err| return this.failWrite(err);
                    }
                    this.endWithoutBody(this.shouldCloseConnection());
                },
                .Locked => {
                    if (this.renderMetadata()) |failure| return this.failMetadata(failure);
                    if (comptime !http3) resp.writeHeader("transfer-encoding", "chunked") catch |err| return this.failWrite(err);
                    this.endWithoutBody(this.shouldCloseConnection());
                },
                .Used, .Null, .Empty, .Error => {
                    if (this.renderMetadata()) |failure| return this.failMetadata(failure);
                    resp.writeHeaderInt("content-length", 0) catch |err| return this.failWrite(err);
                    this.endWithoutBody(this.shouldCloseConnection());
                },
            }
        }

        // Each HTTP request or TCP socket connection is effectively a "task".
        //
        // However, unlike the regular task queue, we don't drain the microtask
        // queue at the end.
        //
        // Instead, we drain it multiple times, at the points that would
        // otherwise "halt" the Response from being rendered.
        //
        // - If you return a Promise, we drain before and after attaching its response reaction.
        // - If you return a streaming Response, we drain before rendering its body.
        pub fn onResponseFromCallback(
            ctx: *RequestContext,
            this: *ThisServer,
            invocation: anytype,
            response_value: anytype,
        ) void {
            _ = this;
            ctx.drainMicrotasks();

            if (ctx.isAbortedOrEnded() or ctx.didUpgradeWebSocket()) return;

            switch (response_value.*) {
                .response => |response_ref| ctx.handleResponseRef(response_ref),
                .promise => |promise| {
                    ctx.ref();
                    PromiseReaction.attach(
                        invocation,
                        promise.operand(invocation).asPromise(),
                        ctx,
                        RequestContext.OnResolveBinding,
                        RequestContext.OnRejectBinding,
                    ) catch |failure| ctx.fail(failure);
                    // A settled handler must finish before parsing the next pipelined request.
                    ctx.drainMicrotasks();
                },
                .error_value => |error_value| ctx.runErrorHandlerView(invocation, error_value),
                .nulled, .undefined, .invalid => ctx.renderMissingInvalidResponse(),
            }
        }

        pub fn handleResolveStream(req: *RequestContext) void {
            req.finishResponseStream(.done);
        }

        fn abortFromSink(req: *RequestContext, sink: *const ResponseStream) void {
            if (!sink.aborted or req.resp == null) return;
            req.detachResponse();
            req.abortDetachedResponse();
        }

        fn finishResponseStream(req: *RequestContext, completion: enum { done, cancel }) void {
            req.ref();
            defer req.deref();
            streamLog("handleResolveStream", .{});

            var wrote_anything = false;
            if (req.sink) |wrapper| {
                wrapper.ref();
                defer wrapper.deref();
                req.abortFromSink(wrapper);
                wrote_anything = wrapper.wrote > 0;

                wrapper.finalize();
                req.abortFromSink(wrapper);
                req.sink = null;
                if (wrapper.res == null and !wrapper.aborted) req.completeResponse();
                ResponseStream.JSSink.detach(wrapper);
                wrapper.destroy();
            }

            req.finishResponseBodyStream(completion == .cancel) catch |err| return req.failStream(err);

            if (req.isAbortedOrEnded()) {
                return;
            }

            streamLog("onResolve({})", .{wrote_anything});
            if (!req.flags.has_written_status) {
                if (req.renderMetadata()) |failure| return req.failMetadata(failure);
            }
            req.endStream(req.shouldCloseConnection());
        }

        fn bindOnResolveStream(
            _: bun.bindgen.CallContext(OnResolveStreamSchema),
            args: bun.bindgen.Args(OnResolveStreamSchema),
        ) bun.JSError!bun.bindgen.Return(OnResolveStreamSchema) {
            streamLog("onResolveStream", .{});
            const req = PromiseReaction.take(args.context) orelse return;
            defer req.deref();
            req.handleResolveStream();
        }
        fn bindOnRejectStream(
            context: bun.bindgen.CallContext(OnRejectStreamSchema),
            args: bun.bindgen.Args(OnRejectStreamSchema),
        ) bun.JSError!bun.bindgen.Return(OnRejectStreamSchema) {
            streamLog("onRejectStream", .{});
            const req = PromiseReaction.take(args.context) orelse return;
            defer req.deref();

            if (args.result) |reason| {
                req.handleRejectStream(context, reason, true, .promise_reaction);
            } else {
                req.handleRejectStream(context, bun.bindgen.AnyResult.initUndefined(context), false, .promise_reaction);
            }
        }

        fn discardResponseSink(req: *RequestContext) void {
            req.ref();
            defer req.deref();
            if (req.sink) |wrapper| {
                req.sink = null;
                wrapper.ref();
                defer wrapper.deref();
                const response_completed = wrapper.res == null and !wrapper.aborted;
                req.abortFromSink(wrapper);
                wrapper.markDone();
                wrapper.finalize();
                wrapper.res = null;
                if (response_completed) {
                    wrapper.resolvePendingFlush();
                    req.completeResponse();
                } else {
                    wrapper.pending_flush.deinit();
                }
                ResponseStream.JSSink.detach(wrapper);
                wrapper.destroy();
            }
        }

        fn finishResponseBodyStream(req: *RequestContext, cancel: bool) bun.JSError!void {
            const global = req.server.?.globalThis;
            var readable = req.response_body_readable_stream_ref.take();
            defer readable.deinit();
            if (req.response_weakref.get()) |response| {
                _ = response.ref();
                defer response.unref();
                if (!readable.has()) readable = (try response.getBodyReadableStream(global)) orelse .{};
                if (cancel) readable.cancel(global) else readable.done(global);
                try response.detachReadableStream(global);
                if (response.getBodyValue().* == .Locked) response.getBodyValue().markUsed();
            } else {
                if (cancel) readable.cancel(global) else readable.done(global);
            }
        }

        fn failStream(req: *RequestContext, failure: bun.JSError) void {
            req.ref();
            defer req.deref();
            const global = req.server.?.globalThis;
            var scope: bun.bindgen.FocusedEngineScope = undefined;
            scope.init(global);
            defer scope.deinit();
            const thrown = scope.takeThrownException(failure) catch |termination| {
                req.discardResponseSink();
                req.forceClose();
                bun.bindgen.voidFromJSError(termination, global);
                return;
            };
            req.handleRejectStream(&scope, thrown, true, .direct);
        }

        const StreamFailureDelivery = enum { direct, promise_reaction };

        pub fn handleRejectStream(req: *@This(), error_context: anytype, err: anytype, has_error: bool, delivery: StreamFailureDelivery) void {
            req.ref();
            defer req.deref();
            streamLog("handleRejectStream", .{});
            const can_finish = if (req.sink) |sink|
                sink.res != null and !sink.aborted and sink.wrote == 0
            else
                false;
            const render_error_body = has_error and can_finish and req.devServer() != null and
                !req.sink.?.res.?.state().isHttpWriteCalled();
            if (req.flags.has_written_status and can_finish and !render_error_body) {
                req.finishResponseStream(.cancel);
                if (has_error and !req.flags.aborted) error_context.runErrorHandler(err.operand(error_context).asAny());
                return;
            }
            req.discardResponseSink();

            req.finishResponseBodyStream(true) catch |failure| {
                req.forceClose();
                return req.fail(failure);
            };

            if (req.isAbortedOrEnded()) {
                return;
            }

            streamLog("onReject()", .{});

            if (render_error_body) {
                req.finishRunningErrorHandlerView(error_context, err, 500);
                return;
            }
            if (req.flags.has_written_status) {
                const report_error = has_error and (delivery == .direct or req.server.?.config.isDevelopment());
                req.forceClose();
                if (report_error) error_context.runErrorHandler(err.operand(error_context).asAny());
                return;
            }
            if (has_error) req.runErrorHandlerView(error_context, err) else req.renderMissing();
        }

        pub fn doRenderWithBody(this: *RequestContext, value: *jsc.WebCore.Body.Value, owned_readable: ?*const jsc.WebCore.ReadableStream.Strong) void {
            this.drainMicrotasks();

            // If a ReadableStream can trivially be converted to a Blob, do so.
            // If it's a WTFStringImpl and it cannot be used as a UTF-8 string, convert it to a Blob.
            const globalThis = this.server.?.globalThis;
            if (value.* == .Locked and value.Locked.hasStartedConsumption()) {
                return this.fail(globalThis.throwInvalidArguments("Response body already used", .{}));
            }
            value.toBlobIfPossible() catch |err| return this.fail(err);
            switch (value.*) {
                .Error => |*err_ref| {
                    if (this.isAbortedOrEnded()) {
                        return;
                    }
                    var error_root = err_ref.toRoot(globalThis) catch |failure| return this.fail(failure);
                    defer error_root.deinit();
                    this.runErrorHandler(&error_root);
                    return;
                },
                // .InlineBlob,
                .WTFStringImpl,
                .InternalBlob,
                .Blob,
                => {
                    // toBlobIfPossible checks for WTFString needing a conversion.
                    this.blob = value.useAsAnyBlobAllowNonUTF8String() catch |err| return this.fail(err);
                    this.renderWithBlobFromBodyValue();
                    return;
                },
                .Locked => |*lock| {
                    if (this.isAbortedOrEnded()) {
                        return;
                    }
                    const has_readable_stream = brk: {
                        if (lock.readable.has()) {
                            this.response_body_readable_stream_ref.deinit();
                            this.response_body_readable_stream_ref = lock.readable.clone();
                            break :brk true;
                        }
                        if (owned_readable) |stream| {
                            this.response_body_readable_stream_ref.deinit();
                            this.response_body_readable_stream_ref = stream.clone();
                            break :brk true;
                        }
                        break :brk false;
                    };
                    if (has_readable_stream) {
                        const stream = &this.response_body_readable_stream_ref;
                        if (stream.isLocked(globalThis) or stream.isDisturbed(globalThis)) {
                            streamLog("was locked but it shouldn't be", .{});
                            const err = bun.sys.SystemError{
                                .code = bun.String.static(@tagName(bun.api.node.ErrorCode.ERR_STREAM_CANNOT_PIPE)),
                                .message = bun.String.static("Stream already used, please create a new one"),
                            };
                            var error_root = bun.api.SystemErrorBindings.systemErrorToRoot(err, globalThis) catch |failure|
                                return this.finishRunningErrorHandlerFailure(failure, 500);
                            defer error_root.deinit();
                            this.runErrorHandler(&error_root);
                            return;
                        }
                        lock.action = .{ .consumed = {} };

                        switch (stream.sourceTag()) {
                            .Invalid => {
                                this.response_body_readable_stream_ref.deinit();
                                // Stream is invalid, render empty body
                                this.doRenderBlob();
                                return;
                            },
                            // toBlobIfPossible will typically convert .Blob streams, or .File streams into a Blob object, but cannot always.
                            .Blob,
                            .File,
                            // These are the common scenario:
                            .JavaScript,
                            .Direct,
                            => {
                                if (this.resp) |resp| {
                                    var pair = StreamPair{ .stream = stream, .this = this };
                                    this.runCorked(resp, *StreamPair, doRenderStream, &pair);
                                }
                                return;
                            },

                            .Bytes => {
                                const byte_stream = stream.byteStream().?;
                                assert(byte_stream.pipe.isEmpty());
                                assert(this.byte_stream == null);
                                if (this.resp == null) {
                                    // we don't have a response, so we can discard the stream
                                    stream.done(globalThis);
                                    this.response_body_readable_stream_ref.deinit();
                                    return;
                                }
                                const resp = this.resp.?;
                                // If we've received the complete body by the time this function is called
                                // we can avoid streaming it and just send it all at once.
                                if (byte_stream.has_received_last_chunk) {
                                    var byte_list = byte_stream.drain();
                                    this.blob = .fromArrayList(byte_list.moveToListManaged(bun.default_allocator));
                                    this.response_body_readable_stream_ref.deinit();
                                    this.doRenderBlob();
                                    return;
                                }
                                byte_stream.pipe = jsc.WebCore.Pipe.Wrap(@This(), onPipe).init(this);
                                this.byte_stream = byte_stream;
                                var response_buf = byte_stream.drain();
                                this.response_buf_owned = response_buf.moveToList();

                                // we don't set size here because even if we have a hint
                                // uWebSockets won't let us partially write streaming content
                                this.blob.detach();

                                this.runCorked(resp, *RequestContext, drainResponseBufferAndMetadata, this);
                                return;
                            },
                        }
                    }

                    // when there's no stream, we need to
                    this.ref();
                    lock.setReceiver(&this.response_body_receiver);

                    return;
                },
                else => {},
            }

            this.doRenderBlob();
        }

        pub fn onPipe(this: *RequestContext, stream: jsc.WebCore.streams.Result, allocator: std.mem.Allocator) void {
            var stream_ = stream;
            const stream_needs_deinit = stream == .owned or stream == .owned_and_done or stream == .err;
            const is_done = stream.isDone();
            defer {
                if (stream_needs_deinit) {
                    switch (stream_) {
                        .owned_and_done => |*owned| owned.deinit(allocator),
                        .owned => |*owned| owned.deinit(allocator),
                        .err => stream_.deinit(),
                        else => unreachable,
                    }
                }
            }

            if (this.isAbortedOrEnded()) {
                return;
            }
            if (stream_ == .err) {
                this.forceClose();
                return;
            }
            const resp = this.resp.?;

            const chunk = stream.slice();
            const result = resp.write(chunk) catch |err| return this.failWrite(err);
            if (result == .want_more) {
                if (is_done) {
                    this.endStream(this.shouldCloseConnection());
                }
            } else {
                // when it's the last one, we just want to know if it's done
                if (is_done) {
                    this.flags.has_marked_pending = true;
                    resp.onWritable(*RequestContext, onWritableResponseBuffer, this);
                }
            }
        }

        pub fn doRenderBlob(this: *RequestContext) void {
            // We are not corked
            // The body is small
            // Faster to do the memcpy than to do the two network calls
            // We are not streaming
            // This is an important performance optimization
            if (this.flags.has_abort_handler and this.blob.fastSize() < 16384 - 1024) {
                if (this.resp) |resp| {
                    this.runCorked(resp, *RequestContext, doRenderBlobCorked, this);
                }
            } else {
                this.doRenderBlobCorked();
            }
        }

        pub fn doRenderBlobCorked(this: *RequestContext) void {
            if (this.renderMetadata()) |failure| return this.failMetadata(failure);
            this.renderBytes();
        }

        pub fn doRender(this: *RequestContext) void {
            ctxLog("doRender", .{});

            if (this.isAbortedOrEnded()) {
                return;
            }
            var response = this.response_weakref.get().?;
            const global = this.server.?.globalThis;
            var readable = response.getBodyReadableStream(global) catch |err| return this.fail(err);
            defer if (readable) |*stream| stream.deinit();
            this.doRenderWithBody(response.getBodyValue(), if (readable) |*stream| stream else null);
        }

        pub fn renderProductionError(this: *RequestContext, status: u16) void {
            if (this.resp) |resp| {
                switch (status) {
                    404 => {
                        if (!this.flags.has_written_status) {
                            resp.writeStatus("404 Not Found") catch |err| return this.failWrite(err);
                            this.flags.has_written_status = true;
                        }
                        this.endWithoutBody(this.shouldCloseConnection());
                    },
                    else => {
                        if (!this.flags.has_written_status) {
                            resp.writeStatus("500 Internal Server Error") catch |err| return this.failWrite(err);
                            resp.writeHeader("content-type", "text/plain") catch |err| return this.failWrite(err);
                            this.flags.has_written_status = true;
                        }

                        this.end("Something went wrong!", this.shouldCloseConnection());
                    },
                }
            }
        }

        pub fn runErrorHandler(
            this: *RequestContext,
            value: *const bun.bindgen.Root,
        ) void {
            var scope: bun.bindgen.FocusedEngineScope = undefined;
            scope.init(this.server.?.globalThis);
            defer scope.deinit();
            this.runErrorHandlerInContext(&scope, value);
        }

        const PathnameFormatter = struct {
            ctx: *RequestContext,

            pub fn format(formatter: @This(), writer: *std.Io.Writer) !void {
                var this = formatter.ctx;

                if (!this.pathname.isEmpty()) {
                    try this.pathname.format(writer);
                    return;
                }

                if (!this.flags.has_abort_handler) {
                    if (this.req) |req| {
                        try writer.writeAll(req.url());
                        return;
                    }
                }

                try writer.writeAll("/");
            }
        };

        fn ensurePathname(this: *RequestContext) PathnameFormatter {
            return .{ .ctx = this };
        }

        pub inline fn shouldCloseConnection(this: *const RequestContext) bool {
            if (this.resp) |resp| {
                return resp.shouldCloseConnection();
            }
            return false;
        }

        fn finishRunningErrorHandlerFailure(this: *RequestContext, failure: bun.JSError, status: u16) void {
            const global = this.server.?.globalThis;
            var scope: bun.bindgen.FocusedEngineScope = undefined;
            scope.init(global);
            defer scope.deinit();
            const thrown = scope.takeThrownException(failure) catch |termination| {
                bun.bindgen.voidFromJSError(termination, global);
                return;
            };
            this.finishRunningErrorHandlerView(&scope, thrown, status);
        }

        fn finishRunningErrorHandlerView(
            this: *RequestContext,
            context: anytype,
            value: anytype,
            status: u16,
        ) void {
            if (this.server == null) return this.renderProductionError(status);
            const vm = this.server.?.vm;
            if (this.server.?.config.isDevelopment()) {
                var arena = std.heap.ArenaAllocator.init(this.allocator);
                defer arena.deinit();
                const allocator = arena.allocator();
                var exception_list: std.array_list.Managed(Api.JsException) = .init(allocator);
                defer exception_list.deinit();
                context.collectUnhandledException(value.operand(context).asAny(), &exception_list);

                this.renderDefaultError(
                    allocator,
                    vm.log,
                    error.ExceptionOcurred,
                    exception_list.items,
                    "<r><red>{s}<r> - <b>{f}<r> failed",
                    .{ @as(string, @tagName(this.method)), this.ensurePathname() },
                );
            } else {
                if (status != 404) {
                    context.reportUnhandledException(value.operand(context).asAny());
                }
                this.renderProductionError(status);
            }

            vm.log.reset();
        }

        pub fn runErrorHandlerView(
            this: *RequestContext,
            source_context: anytype,
            error_value: anytype,
        ) void {
            if (this.resp == null or this.resp.?.hasResponded()) return;

            var source_error = error_value.toRoot() catch |failure|
                return this.finishRunningErrorHandlerFailure(failure, 500);
            var original_error = if (comptime @TypeOf(source_error) == bun.bindgen.EngineRoot)
                source_error.takeAnyRoot()
            else
                source_error.take();
            defer original_error.deinit();

            this.runErrorHandlerInContext(source_context, &original_error);
        }

        fn runErrorHandlerInContext(
            this: *RequestContext,
            source_context: anytype,
            original_error: *const bun.bindgen.Root,
        ) void {
            if (this.resp == null or this.resp.?.hasResponded()) return;

            if (this.server) |server| {
                if (server.config.onError.configured and !this.flags.has_called_error_handler) {
                    this.flags.has_called_error_handler = true;
                    var callback_call: ThisServer.ErrorCallbackCall = undefined;
                    callback_call.init(server) catch |err| return this.finishRunningErrorHandlerFailure(err, 500);
                    defer callback_call.deinit();
                    var result = callback_call.invoke(original_error) catch |err| {
                        return this.finishRunningErrorHandlerFailure(err, 500);
                    };
                    defer callback_call.deinitResult(&result);

                    switch (result) {
                        .response => |response_ref| {
                            this.handleResponseRef(response_ref);
                            return;
                        },
                        .promise => |promise| {
                            this.flags.is_error_promise_pending = true;
                            this.ref();
                            PromiseReaction.attach(
                                &callback_call.invocation,
                                promise.operand(&callback_call.invocation).asPromise(),
                                this,
                                RequestContext.OnResolveBinding,
                                RequestContext.OnRejectBinding,
                            ) catch |failure| {
                                this.flags.is_error_promise_pending = false;
                                this.finishRunningErrorHandlerFailure(failure, 500);
                            };
                            return;
                        },
                        .error_value => |returned_error| {
                            this.finishRunningErrorHandlerView(&callback_call.invocation, returned_error, 500);
                            return;
                        },
                        .nulled, .undefined, .invalid => {
                            this.finishRunningErrorHandlerView(
                                &callback_call.invocation,
                                original_error,
                                500,
                            );
                            return;
                        },
                    }
                }
            }

            this.finishRunningErrorHandlerView(
                source_context,
                original_error,
                500,
            );
        }

        const MetadataFailure = union(enum) { engine: bun.JSError, write: uws.ResponseWriteError };

        fn failMetadata(this: *RequestContext, failure: MetadataFailure) void {
            switch (failure) {
                .engine => |err| this.fail(err),
                .write => |err| this.failWrite(err),
            }
        }

        fn renderMetadataCorked(this: *RequestContext) ?MetadataFailure {
            const resp = this.resp orelse return null;
            this.ref();
            defer this.deref();
            const Operation = struct {
                context: *RequestContext,
                failure: ?MetadataFailure = null,

                fn run(operation: *@This()) void {
                    operation.failure = operation.context.renderMetadata();
                }
            };
            var operation: Operation = .{ .context = this };
            const flushed = resp.runCorkedWithType(*Operation, Operation.run, &operation);
            if (operation.failure) |failure| return failure;
            flushed catch |err| return .{ .write = err };
            return null;
        }

        pub fn renderMetadata(this: *RequestContext) ?MetadataFailure {
            if (this.resp == null) return null;
            const resp = this.resp.?;

            // For plain in-memory bodies this runs synchronously from
            // render() before any backpressure gap, so the Response is
            // always live here. File / stream bodies that call this after
            // an async hop keep the Response wrapper rooted.
            var response: *jsc.WebCore.Response = this.response_weakref.get().?;
            var status = response.statusCode();
            var needs_content_range = this.flags.needs_content_range and (this.sendfile.total > 0 or this.sendfile.remain < this.blob.size());

            const size = if (needs_content_range)
                this.sendfile.remain
            else
                this.blob.size();

            status = if (status == 200 and size == 0 and !this.blob.isDetached())
                204
            else
                status;

            const content_type = getContentType(
                response.getInitHeaders(),
                &this.blob,
            ) catch |err| return .{ .engine = err };
            var cookie_headers: ?CookieMapEngine.PreparedHeaders = if (this.cookies) |*cookies|
                CookieMapEngine.prepare(cookies.get(), this.server.?.globalThis) catch |err| return .{ .engine = err }
            else
                null;
            defer if (cookie_headers) |*prepared| prepared.deinit();
            var has_content_disposition = false;
            var has_content_range = false;
            if (response.retainInitHeaders()) |value| {
                var headers = value;
                defer headers.deinit();
                has_content_disposition = headers.get().fastHas(.ContentDisposition);
                has_content_range = headers.get().fastHas(.ContentRange);
                // For .slice()-driven ranges, only promote to 206 if the user
                // also set Content-Range (preserves the old contract). For an
                // incoming Range: header (sendfile.total > 0) we always 206.
                needs_content_range = needs_content_range and (this.sendfile.total > 0 or has_content_range);
                if (needs_content_range) {
                    status = 206;
                }

                this.doWriteStatus(status) catch |err| return .{ .write = err };
                this.doWriteHeaders(headers.get()) catch |err| return .{ .write = err };
            } else if (needs_content_range) {
                status = 206;
                this.doWriteStatus(status) catch |err| return .{ .write = err };
            } else {
                this.doWriteStatus(status) catch |err| return .{ .write = err };
            }

            if (this.cookies) |*cookies| {
                CookieMapEngine.write(&cookie_headers.?, anyResponse(resp)) catch |err| return .{ .write = err };
                cookies.deinit();
                this.cookies = null;
            }

            if (content_type.value) |value| resp.writeHeader("content-type", value) catch |err| return .{ .write = err };

            // Advertise the QUIC endpoint on H1/H2 responses so browsers can
            // discover it (RFC 7838). Multiple Alt-Svc fields are valid, so a
            // user-supplied one composes rather than conflicts.
            if (comptime !http3 and @hasDecl(ThisServer, "h3AltSvc")) {
                if (this.server.?.h3AltSvc()) |alt| resp.writeHeader("alt-svc", alt) catch |err| return .{ .write = err };
            }

            // automatically include the filename when:
            // 1. Bun.file("foo")
            // 2. The content-disposition header is not present
            if (!has_content_disposition and content_type.category.autosetFilename()) {
                if (this.blob.getFileName()) |filename| {
                    const basename = std.fs.path.basename(filename);
                    if (basename.len > 0) {
                        var filename_buf: [1024]u8 = undefined;

                        resp.writeHeader(
                            "content-disposition",
                            std.fmt.bufPrint(&filename_buf, "filename=\"{s}\"", .{basename[0..@min(basename.len, 1024 - 32)]}) catch "",
                        ) catch |err| return .{ .write = err };
                    }
                }
            }

            if (this.flags.needs_content_length) {
                resp.writeHeaderInt("content-length", size) catch |err| return .{ .write = err };
                resp.markWroteContentLengthHeader();
                this.flags.needs_content_length = false;
            }

            if (needs_content_range and !has_content_range) {
                var content_range_buf: [1024]u8 = undefined;

                resp.writeHeader(
                    "content-range",
                    if (this.sendfile.total > 0)
                        // We resolved an incoming Range header against the
                        // stat'd size, so the total is meaningful.
                        std.fmt.bufPrint(&content_range_buf, "bytes {d}-{d}/{d}", .{
                            this.sendfile.offset,
                            this.sendfile.offset + (this.sendfile.remain -| 1),
                            this.sendfile.total,
                        }) catch "bytes */*"
                    else
                        // For .slice()-driven ranges we omit the full size:
                        // it can change between requests and may leak PII.
                        std.fmt.bufPrint(&content_range_buf, "bytes {d}-{d}/*", .{
                            this.sendfile.offset,
                            this.sendfile.offset + (this.sendfile.remain -| 1),
                        }) catch "bytes */*",
                ) catch |err| return .{ .write = err };
                if (this.sendfile.total > 0) resp.writeHeader("accept-ranges", "bytes") catch |err| return .{ .write = err };
                this.flags.needs_content_range = false;
            }
            return null;
        }

        fn doWriteStatus(this: *RequestContext, status: u16) uws.ResponseWriteError!void {
            assert(!this.flags.has_written_status);

            const resp = this.resp orelse return;
            var buffer: [6]u8 = undefined;
            try resp.writeStatus(HTTPStatusText.format(status, &buffer));
            this.flags.has_written_status = true;
        }

        fn doWriteHeaders(this: *RequestContext, headers: *WebCore.FetchHeaders) uws.ResponseWriteError!void {
            ctxLog("writeHeaders", .{});
            if (this.resp) |resp| try headers.writeToResponse(anyResponse(resp), .{
                .omit_framing = true,
                .omit_connection = http3,
            });
        }

        pub fn renderBytes(this: *RequestContext) void {
            const resp = this.resp orelse return;
            const blob = this.blob;
            const bytes = blob.slice();
            _ = this.sendWritableBytesForBlob(bytes, 0, resp);
        }

        /// Replace the tracked Response. Drops the previous weak ref (if any)
        /// before taking a new one so the old Response's allocation can be
        /// freed once its own strong refs go to zero.
        fn setResponse(this: *RequestContext, response: *jsc.WebCore.Response) void {
            if (this.response_weakref.raw_ptr == response) return;
            this.response_weakref.deref();
            this.response_weakref = .initRef(response);
        }

        fn retainResponse(this: *RequestContext, response: *Response.Ref) void {
            if (this.response_root) |*root| root.deinit();
            this.response_root = response.take();
        }

        pub fn render(this: *RequestContext, response: *jsc.WebCore.Response) void {
            ctxLog("render", .{});
            this.setResponse(response);

            this.doRender();
        }

        pub fn onBufferedBodyChunk(this: *RequestContext, resp: *App.Response, chunk: []const u8, last: bool) void {
            ctxLog("onBufferedBodyChunk {} {}", .{ chunk.len, last });

            assert(this.resp == resp);

            this.flags.is_waiting_for_request_body = last == false;
            if (this.isAbortedOrEnded() or this.flags.has_marked_complete) return;
            if (!last and chunk.len == 0) {
                // Sometimes, we get back an empty chunk
                // We have to ignore those chunks unless it's the last one
                return;
            }
            const vm = this.server.?.vm;
            const globalThis = this.server.?.globalThis;
            this.ref();
            defer this.deref();

            const received = std.math.add(usize, this.request_body_received, chunk.len) catch
                return this.rejectRequestBodyTooLarge();
            if (received > this.server.?.config.max_request_body_size) return this.rejectRequestBodyTooLarge();
            this.request_body_received = received;

            // After the user does request.body,
            // if they then do .text(), .arrayBuffer(), etc
            // we can no longer hold the strong reference from the body value ref.
            var readable = this.request_body_readable_stream_ref.clone();
            defer readable.deinit();
            if (readable.byteStream()) |byte_stream| {
                assert(this.request_body_buf.items.len == 0);
                vm.eventLoop().enter();
                defer vm.eventLoop().exit();

                if (!last) {
                    byte_stream.onData(
                        .{
                            .temporary = chunk,
                        },
                        bun.default_allocator,
                    ) catch |err| globalThis.reportActiveExceptionAsUnhandled(err);
                } else {
                    var strong = this.request_body_readable_stream_ref.take();
                    defer strong.deinit();
                    if (bun.take(&this.request_body)) |request_body| {
                        request_body.value.finishStreaming(&this.request_body_source, &strong);
                        _ = request_body.unref();
                    }

                    byte_stream.onData(
                        .{
                            .temporary_and_done = chunk,
                        },
                        bun.default_allocator,
                    ) catch |err| globalThis.reportActiveExceptionAsUnhandled(err);
                }

                return;
            }

            // This is the start of a task, so it's a good time to drain
            if (this.request_body) |pending_body| {
                const body = pending_body.ref();
                defer body.deref();
                if (body.value != .Locked) {
                    this.request_body_buf.clearAndFree(this.allocator);
                    return;
                }

                if (last) {
                    var bytes = &this.request_body_buf;
                    const total = std.math.add(usize, bytes.items.len, chunk.len) catch
                        return this.failRequestBodyAllocation(body);
                    bytes.ensureTotalCapacityPrecise(this.allocator, total) catch
                        return this.failRequestBodyAllocation(body);
                    bytes.appendSliceAssumeCapacity(chunk);
                    const buffer = bytes.toManaged(this.allocator);
                    this.request_body_buf = .empty;

                    var old = body.value;
                    body.value = .{ .InternalBlob = .{ .bytes = .fromManaged(buffer) } };
                    const loop = vm.eventLoop();
                    loop.enter();
                    defer loop.exit();

                    old.resolve(&body.value, globalThis, null) catch |err|
                        globalThis.reportActiveExceptionAsUnhandled(err);
                    return;
                }

                if (this.request_body_buf.capacity == 0) {
                    this.request_body_buf.ensureTotalCapacityPrecise(this.allocator, @min(this.request_body_content_len, max_request_body_preallocate_length)) catch
                        return this.failRequestBodyAllocation(body);
                }
                this.request_body_buf.appendSlice(this.allocator, chunk) catch
                    return this.failRequestBodyAllocation(body);
            }
        }

        fn rejectRequestBodyTooLarge(this: *RequestContext) void {
            const global = this.server.?.globalThis;
            const loop = this.server.?.vm.eventLoop();
            loop.enter();
            defer loop.exit();
            if (this.resp) |resp| resp.clearOnData();
            this.flags.is_waiting_for_request_body = false;
            this.request_body_buf.clearAndFree(this.allocator);
            var readable = this.request_body_readable_stream_ref.take();
            defer readable.deinit();
            var failure: WebCore.Body.Value.ValueError = .{
                .Message = .adopt(bun.String.static("Request body exceeded maxRequestBodySize")),
            };
            defer failure.deinit();
            if (this.request_body) |pending_body| {
                const body = pending_body.ref();
                defer body.deref();
                body.value.toErrorInstance(failure.dupe(), global) catch |err|
                    global.reportActiveExceptionAsUnhandled(err);
            }
            if (readable.byteStream()) |bytes| {
                if (!bytes.done) {
                    const stream_error: WebCore.streams.Result.StreamError = failure.toStreamError(global) catch |err| switch (err) {
                        error.OutOfMemory => .OutOfMemory,
                        else => {
                            this.forceClose();
                            return global.reportActiveExceptionAsUnhandled(err);
                        },
                    };
                    bytes.onData(.{ .err = stream_error }, bun.default_allocator) catch |err|
                        global.reportActiveExceptionAsUnhandled(err);
                }
            } else {
                readable.cancel(global);
            }

            if (this.isAbortedOrEnded()) return;
            if (this.flags.has_written_status) return this.forceClose();
            this.resp.?.writeStatus("413 Payload Too Large") catch |err| return this.failWrite(err);
            this.flags.has_written_status = true;
            this.endWithoutBody(comptime !http3);
        }

        fn failRequestBodyAllocation(this: *RequestContext, body: *WebCore.Body.Value.HiveRef) void {
            const global = this.server.?.globalThis;
            const loop = this.server.?.vm.eventLoop();
            loop.enter();
            defer loop.exit();
            if (this.resp) |resp| resp.clearOnData();
            this.flags.is_waiting_for_request_body = false;
            this.request_body_buf.clearAndFree(this.allocator);
            body.value.toErrorInstance(.OutOfMemory, global) catch |err|
                global.reportActiveExceptionAsUnhandled(err);
            this.failWrite(error.OutOfMemory);
        }

        pub fn onStartStreamingRequestBody(this: *RequestContext) jsc.WebCore.DrainResult {
            ctxLog("onStartStreamingRequestBody", .{});
            if (this.isAbortedOrEnded()) {
                return jsc.WebCore.DrainResult{
                    .aborted = {},
                };
            }

            // This means we have received part of the body but not the whole thing
            if (this.request_body_buf.items.len > 0) {
                var emptied = this.request_body_buf;
                this.request_body_buf = .empty;
                return .{
                    .owned = .{
                        .list = emptied.toManaged(this.allocator),
                        .size_hint = if (emptied.capacity < max_request_body_preallocate_length)
                            emptied.capacity
                        else
                            0,
                    },
                };
            }

            return .{
                .estimated_size = this.request_body_content_len,
            };
        }
        const max_request_body_preallocate_length = 1024 * 256;
        pub fn onStartBuffering(this: *RequestContext) void {
            if (this.server) |server| {
                ctxLog("onStartBuffering", .{});
                // HTTP/3 (RFC 9114): Content-Length is optional; the body is
                // delimited by stream FIN, so the H1 "no CL + no TE ⇒ empty"
                // shortcut would drop it.
                if (!http3 and this.flags.is_transfer_encoding == false and this.request_body_content_len == 0) {
                    // no content-length or 0 content-length
                    // no transfer-encoding
                    if (this.request_body) |pending_body| {
                        const body = pending_body.ref();
                        defer body.deref();
                        var old = body.value;
                        body.value = .{ .Null = {} };
                        old.resolve(&body.value, server.globalThis, null) catch |err|
                            server.globalThis.reportActiveExceptionAsUnhandled(err);
                    }
                }
            }
        }

        pub fn onRequestBodyReadableStreamAvailable(this: *RequestContext, globalThis: *jsc.JSGlobalObject, readable: *const jsc.WebCore.ReadableStream.Strong) void {
            _ = globalThis;
            bun.debugAssert(this.request_body_readable_stream_ref.isEmpty());
            this.request_body_readable_stream_ref = readable.clone();
        }

        pub fn getRemoteSocketInfo(this: *RequestContext) ?uws.SocketAddress {
            return (this.resp orelse return null).getRemoteSocketInfo();
        }

        pub fn setTimeout(this: *RequestContext, seconds: c_uint) bool {
            if (this.resp) |resp| {
                resp.timeout(@min(seconds, 255));
                if (seconds == 0) {
                    // if the timeout is 0, we don't need to trigger the timeout event
                    resp.clearTimeout();
                }
                return true;
            }
            return false;
        }

        comptime {
            _ = OnResolveBinding;
            _ = OnRejectBinding;
            _ = OnResolveStreamBinding;
            _ = OnRejectStreamBinding;
        }
    };
}

// Retained only for `renderMetadata` to compute Content-Range / Content-Length
// for file-blob bodies; the actual fd/socket bookkeeping lives in
// `FileResponseStream` now.
const SendfileContext = struct {
    remain: Blob.SizeType = 0,
    offset: Blob.SizeType = 0,
    /// When non-zero, the Content-Range total (`/{total}` instead of `/*`).
    total: Blob.SizeType = 0,
};

const Flags = packed struct(u16) {
    has_marked_complete: bool = false,
    has_marked_pending: bool = false,
    has_abort_handler: bool = false,
    has_sendfile_ctx: bool = false,
    has_called_error_handler: bool = false,
    needs_content_length: bool = false,
    needs_content_range: bool = false,
    /// Used to avoid looking at the uws.Request struct after it's been freed
    is_transfer_encoding: bool = false,

    /// Used to identify if request can be safely deinitialized
    is_waiting_for_request_body: bool = false,
    /// Used in renderMissing in development mode to show the user an HTML page
    /// Used to avoid looking at the uws.Request struct after it's been freed
    is_web_browser_navigation: bool = false,
    has_written_status: bool = false,
    aborted: bool = false,
    has_finalized: bun.DebugOnly(bool) = if (Environment.isDebug) false,

    is_error_promise_pending: bool = false,

    _padding: PaddingInt = 0,

    const PaddingInt = @Int(.unsigned, if (Environment.isDebug) 2 else 3);
};

fn getContentType(headers: ?*WebCore.FetchHeaders, blob: *const WebCore.Blob.Any) bun.OOM!struct { value: ?[]const u8, category: MimeType.Category } {
    if (headers) |fetch_headers| {
        if (try fetch_headers.fastGet(.ContentType)) |owned_content| {
            var content = owned_content;
            defer content.deinit();
            return .{ .value = null, .category = MimeType.categoryForText(content.unsafePtr("content owns the header until MIME classification returns").textView()) };
        }
    }

    const content_type = if (blob.contentType().len > 0)
        MimeType.byName(blob.contentType())
    else if (MimeType.sniff(blob.slice())) |content|
        content
    else if (blob.wasString())
        MimeType.text
    else
        MimeType.other;

    return .{
        .value = if (blob.isDetached() and content_type.value.ptr == MimeType.other.value.ptr) null else content_type.value,
        .category = content_type.category,
    };
}

const welcome_page_html_gz = @embedFile("../api/welcome-page.html.gz");

const ctxLog = Output.scoped(.RequestContext, .visible);
const string = []const u8;

const std = @import("std");
const Fallback = @import("../../js_parser/runtime.zig").Fallback;

const bun = @import("bun");
const Environment = bun.Environment;
const JSError = bun.JSError;
const Output = bun.Output;
const S3 = bun.S3;
const String = bun.String;
const assert = bun.assert;
const logger = bun.logger;
const uws = bun.uws;
const Api = bun.schema.api;

const FileResponseStream = bun.api.server.FileResponseStream;
const HTTPStatusText = bun.api.server.HTTPStatusText;
const RangeRequest = bun.api.server.RangeRequest;

const HTTP = bun.http;
const MimeType = bun.http.MimeType;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const VirtualMachine = jsc.VirtualMachine;

const AnyRequestContext = jsc.API.AnyRequestContext;
const WebCore = jsc.WebCore;
const CookieMap = @import("../webcore/CookieMap.zig").CookieMap;
const CookieMapEngine = @import("../webcore/CookieMapEngine.zig");
const CommonAbortReason = @import("../../http_types/CommonAbortReason.zig").CommonAbortReason;
const Blob = jsc.WebCore.Blob;
const Body = jsc.WebCore.Body;
const FetchHeaders = jsc.WebCore.FetchHeaders;
const Request = jsc.WebCore.Request;
const Response = jsc.WebCore.Response;
