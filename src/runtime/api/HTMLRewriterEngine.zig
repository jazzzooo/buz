const SelectorMap = std.ArrayList(*LOLHTML.HTMLSelector);
pub const LOLHTMLContext = struct {
    const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;

    ref_count: RefCount,
    selectors: SelectorMap = .empty,
    element_handlers: std.ArrayList(*ElementHandler) = .empty,
    document_handlers: std.ArrayList(*DocumentHandler) = .empty,
    // Shared handlers borrow the failure slot of the currently executing rewriter.
    active_failure: ?*?CallbackFailure = null,

    const CallbackFailure = union(enum) {
        exception: struct {
            value: bindgen.Root,
            carrier: ?bindgen.EngineRoot = null,
        },
        terminated,
        capture_failure: bun.JSError,

        fn deinit(this: *CallbackFailure) void {
            if (this.* == .exception) {
                this.exception.value.deinit();
                if (this.exception.carrier) |*carrier| carrier.deinit();
            }
            this.* = .terminated;
        }
    };

    fn captureError(this: *LOLHTMLContext, error_root: bindgen.Root) void {
        var owned = error_root;
        defer owned.deinit();
        const slot = this.active_failure orelse @panic("HTML callback ran outside its rewriter");
        if (slot.* == null) slot.* = .{ .exception = .{ .value = owned.take() } };
    }

    fn captureException(this: *LOLHTMLContext, invocation: anytype, err: bun.JSError) void {
        if (err == error.OutOfMemory or err == error.JSTerminated) return this.captureFailure(err);
        var carrier = invocation.takeExceptionRoot(err) catch |failure| return this.captureFailure(failure);
        defer carrier.deinit();
        var thrown = invocation.engineIn("errors", "exceptionThrownValue").call(.{
            .exception = carrier.operand(invocation).asEngine(),
        });
        defer thrown.deinit();
        var value = thrown.asAny(invocation).toRoot() catch |failure| return this.captureFailure(failure);
        defer value.deinit();
        const slot = this.active_failure orelse @panic("HTML callback ran outside its rewriter");
        if (slot.* == null) slot.* = .{ .exception = .{
            .value = value.take(),
            .carrier = carrier.take(),
        } };
    }

    fn captureFailure(this: *LOLHTMLContext, failure: bun.JSError) void {
        const slot = this.active_failure orelse @panic("HTML callback ran outside its rewriter");
        if (failure == error.JSTerminated) {
            if (slot.*) |*previous| previous.deinit();
            slot.* = .terminated;
        } else if (slot.* == null) {
            slot.* = .{ .capture_failure = failure };
        }
    }

    fn hasFailure(this: *const LOLHTMLContext) bool {
        const slot = this.active_failure orelse @panic("HTML callback ran outside its rewriter");
        return slot.* != null;
    }

    fn deinit(this: *LOLHTMLContext) void {
        bun.assert(this.active_failure == null);
        for (this.selectors.items) |selector| {
            selector.deinit();
        }
        this.selectors.deinit(bun.default_allocator);
        this.selectors = .empty;

        for (this.element_handlers.items) |handler| {
            handler.deinit();
            bun.default_allocator.destroy(handler);
        }
        this.element_handlers.deinit(bun.default_allocator);
        this.element_handlers = .empty;

        for (this.document_handlers.items) |handler| {
            handler.deinit();
            bun.default_allocator.destroy(handler);
        }
        this.document_handlers.deinit(bun.default_allocator);
        this.document_handlers = .empty;

        bun.destroy(this);
    }
};

pub const HTMLRewriter = struct {
    const TransformError = bun.JSError || error{ BodyAlreadyUsed, StreamAlreadyUsed };

    bindgen_state: bindgen.ClassState = .{},
    builder: bindgen.OwnedNative(LOLHTML.HTMLRewriter.Builder, .vm),
    context: bindgen.RefNative(LOLHTMLContext, .vm),

    pub fn construct(
        _: bindgen.CallContext(HTMLRewriterConstructorSchema),
        _: bindgen.Args(HTMLRewriterConstructorSchema),
    ) bun.JSError!*HTMLRewriter {
        const rewriter = try bun.default_allocator.create(HTMLRewriter);
        errdefer bun.default_allocator.destroy(rewriter);
        const context = try bun.default_allocator.create(LOLHTMLContext);
        context.* = .{ .ref_count = .init() };
        rewriter.* = .{
            .builder = .init(LOLHTML.HTMLRewriter.Builder.init()),
            .context = .adopt(context),
        };
        bun.analytics.Features.html_rewriter += 1;
        return rewriter;
    }

    fn addElementHandler(
        this: *HTMLRewriter,
        context: anytype,
        selector_name: bun.TextView,
        listener: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!void {
        const selector_slice = try std.fmt.allocPrint(bun.default_allocator, "{f}", .{selector_name});
        defer bun.default_allocator.free(selector_slice);

        var selector = LOLHTML.HTMLSelector.parse(selector_slice) catch
            return failLOLHTMLOperation(HTMLRewriterOnSchema, context);
        errdefer selector.deinit();

        const converted = try listener.convert(context);
        const handler = try bun.default_allocator.create(ElementHandler);
        errdefer bun.default_allocator.destroy(handler);
        handler.* = try ElementHandler.init(this.context.get(), &converted.value, try converted.value.listener_identity.toOwned());
        errdefer handler.deinit();

        const rewriter_context = this.context.get();
        try rewriter_context.selectors.ensureUnusedCapacity(bun.default_allocator, 1);
        try rewriter_context.element_handlers.ensureUnusedCapacity(bun.default_allocator, 1);

        this.builder.get().addElementContentHandlers(
            selector,

            ElementHandler,
            ElementHandler.onElement,
            if (handler.onElementCallback != null)
                handler
            else
                null,

            ElementHandler,
            ElementHandler.onComment,
            if (handler.onCommentCallback != null)
                handler
            else
                null,

            ElementHandler,
            ElementHandler.onText,
            if (handler.onTextCallback != null)
                handler
            else
                null,
        ) catch {
            return failLOLHTMLOperation(HTMLRewriterOnSchema, context);
        };

        rewriter_context.selectors.appendAssumeCapacity(selector);
        rewriter_context.element_handlers.appendAssumeCapacity(handler);
    }

    fn addDocumentHandler(
        this: *HTMLRewriter,
        listener: anytype,
    ) bun.JSError!void {
        const handler = try bun.default_allocator.create(DocumentHandler);
        errdefer bun.default_allocator.destroy(handler);
        handler.* = try DocumentHandler.init(this.context.get(), &listener, try listener.listener_identity.toOwned());
        errdefer handler.deinit();

        const rewriter_context = this.context.get();
        try rewriter_context.document_handlers.ensureUnusedCapacity(bun.default_allocator, 1);

        // If this fails, subsequent calls to write or end should throw
        this.builder.get().addDocumentContentHandlers(
            DocumentHandler,
            DocumentHandler.onDocType,
            if (handler.onDocTypeCallback != null)
                handler
            else
                null,

            DocumentHandler,
            DocumentHandler.onComment,
            if (handler.onCommentCallback != null)
                handler
            else
                null,

            DocumentHandler,
            DocumentHandler.onText,
            if (handler.onTextCallback != null)
                handler
            else
                null,

            DocumentHandler,
            DocumentHandler.onEnd,
            if (handler.onEndCallback != null)
                handler
            else
                null,
        );

        rewriter_context.document_handlers.appendAssumeCapacity(handler);
    }

    pub fn destroy(this: *HTMLRewriter) void {
        this.context.deinit();
        this.builder.deinit();
        bun.destroy(this);
    }

    fn beginTransform(this: *HTMLRewriter, global: *JSGlobalObject, response: *Response) TransformError!Response.Ref {
        const new_context = this.context.get();
        new_context.ref();
        return BufferOutputSink.init(new_context, global, response, this.builder.get());
    }

    fn transformResponse(this: *HTMLRewriter, global: *JSGlobalObject, response: *Response) TransformError!Response.Ref {
        if (response.getBodyValue().* == .Used) {
            return error.BodyAlreadyUsed;
        }
        return this.beginTransform(global, response);
    }

    fn transformBody(
        this: *HTMLRewriter,
        global: *JSGlobalObject,
        body: Body,
        comptime as_string: bool,
    ) TransformError!if (as_string) bindgen.DOMString else bindgen.OwnedBytes {
        var owned_body = body;
        const response = bun.default_allocator.create(Response) catch |err| {
            owned_body.value.deinit();
            return err;
        };
        response.* = Response.init(
            .{ .status_code = 200 },
            owned_body,
            .empty(),
            false,
        );
        defer response.finalize();

        var transformed = try this.beginTransform(global, response);
        defer transformed.deinit();
        var blob = try transformed.get(Response).getBodyValue().useAsAnyBlobAllowNonUTF8String();
        defer blob.detach();
        if (comptime as_string) {
            return switch (blob) {
                .WTFStringImpl => result: {
                    const impl = blob.WTFStringImpl.take();
                    blob = .{ .Blob = .{} };
                    break :result bindgen.DOMString.fromBunString(bun.String.init(impl));
                },
                .Blob, .InternalBlob => result: {
                    _, const bytes = bun.strings.BOM.detectAndSplit(blob.slice());
                    break :result bindgen.DOMString.fromUTF8(bytes);
                },
            };
        }
        return bindgen.OwnedBytes.fromSlice(blob.slice());
    }

    pub fn on(
        this: *HTMLRewriter,
        context: bindgen.CallContext(HTMLRewriterOnSchema),
        args: bindgen.Args(HTMLRewriterOnSchema),
    ) bindgen.CallError(HTMLRewriterOnSchema)!bindgen.Return(HTMLRewriterOnSchema) {
        const selector_arg = args.selector orelse return context.fail(.missing_argument, {});
        const listener = args.listener orelse return context.fail(.missing_argument, {});
        try this.addElementHandler(context, selector_arg.unsafePtr("the generated entry frame owns the selector until addElementHandler copies it").textView(), listener);
        return args.bindingThis.toOwned();
    }

    pub fn onDocument(
        this: *HTMLRewriter,
        context: bindgen.CallContext(HTMLRewriterOnDocumentSchema),
        args: bindgen.Args(HTMLRewriterOnDocumentSchema),
    ) bindgen.CallError(HTMLRewriterOnDocumentSchema)!bindgen.Return(HTMLRewriterOnDocumentSchema) {
        const listener = args.listener orelse return context.fail(.missing_argument, {});
        try this.addDocumentHandler(listener);
        return args.bindingThis.toOwned();
    }

    pub fn transform(
        this: *HTMLRewriter,
        context: bindgen.CallContext(HTMLRewriterTransformSchema),
        args: bindgen.Args(HTMLRewriterTransformSchema),
    ) bindgen.CallError(HTMLRewriterTransformSchema)!bindgen.Return(HTMLRewriterTransformSchema) {
        return this.transformFromBinding(context, args) catch |err| switch (err) {
            error.BodyAlreadyUsed => context.fail(.body_already_used, {}),
            error.StreamAlreadyUsed => context.fail(.stream_already_used, {}),
            else => |js_error| return js_error,
        };
    }

    fn transformFromBinding(
        this: *HTMLRewriter,
        context: anytype,
        args: bindgen.Args(HTMLRewriterTransformSchema),
    ) TransformError!bindgen.Return(HTMLRewriterTransformSchema) {
        const global = context.viewToken().globalObject();
        return switch (args.input) {
            .response => |response| .{ .response = try this.transformResponse(global, response.get(Response)) },
            .body => |body| switch (body) {
                .string => |body_string| string_body: {
                    if (body_string.length() == 0) {
                        break :string_body .{ .text = try this.transformBody(global, .{ .value = .{ .Empty = {} } }, true) };
                    }
                    var owned = body_string.toOwned();
                    const impl = owned.impl.?;
                    owned.impl = null;
                    break :string_body .{ .text = try this.transformBody(global, .{ .value = .{ .WTFStringImpl = .adopt(impl) } }, true) };
                },
                .buffer => |buffer| buffer_body: {
                    if (buffer.length() == 0) {
                        break :buffer_body .{ .array_buffer = try this.transformBody(global, .{ .value = .{ .Empty = {} } }, false) };
                    }
                    const copy = try bun.default_allocator.alloc(u8, buffer.length());
                    if (!buffer.read(0, copy)) unreachable;
                    break :buffer_body .{ .array_buffer = try this.transformBody(global, .{ .value = .{ .InternalBlob = .{
                        .bytes = .fromOwnedSlice(bun.default_allocator, copy),
                        .was_string = false,
                    } } }, false) };
                },
            },
        };
    }

    pub const BufferOutputSink = struct {
        const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
        const InputReaction = bindgen.PromiseReaction(OnInputSchema.args[1].ArgumentType, @This());
        pub const ref = RefCount.ref;
        pub const deref = RefCount.deref;

        ref_count: RefCount,
        global: *JSGlobalObject,
        vm: bindgen.BorrowedNative(jsc.VirtualMachine, .vm),
        bytes: bun.MutableString,
        rewriter: ?*LOLHTML.HTMLRewriter = null,
        context: *LOLHTMLContext,
        response: *Response,
        response_ref: ?Response.Ref = null,
        body_source: jsc.WebCore.Body.PendingValue.Source = .init(BufferOutputSink, "body_source", .{
            .on_readable_stream_available = onReadableStreamAvailable,
            .retain_owner = ref,
            .release_owner = deref,
        }),
        output_stream: jsc.WebCore.ReadableStream.Strong = .{},
        input_promise_pending: bool = false,
        input_finished: bool = false,
        sync_error: bindgen.Root.Optional = .empty,
        sync_exception: ?bindgen.EngineRoot = null,
        callback_failure: ?LOLHTMLContext.CallbackFailure = null,
        terminated: bool = false,
        output_failed: bool = false,

        fn onReadableStreamAvailable(
            sink: *BufferOutputSink,
            _: *JSGlobalObject,
            readable: *const jsc.WebCore.ReadableStream.Strong,
        ) void {
            bun.assert(!sink.output_stream.has());
            sink.output_stream = readable.clone();
        }

        pub fn init(context: *LOLHTMLContext, global: *JSGlobalObject, original: *Response, builder: *LOLHTML.HTMLRewriter.Builder) TransformError!Response.Ref {
            var scope: bindgen.FocusedEngineScope = undefined;
            scope.init(global);
            defer scope.deinit();
            const sink = bun.default_allocator.create(BufferOutputSink) catch |err| {
                context.deref();
                return err;
            };
            sink.* = .{
                .ref_count = .init(),
                .global = global,
                .vm = .init(global.bunVM()),
                .bytes = bun.MutableString.initEmpty(bun.default_allocator),
                .rewriter = null,
                .context = context,
                .response = undefined,
            };
            defer sink.deref();
            const result = try bun.default_allocator.create(Response);
            result.* = Response.init(
                .{
                    .status_code = 200,
                },
                .{
                    .value = .{
                        .Locked = .{
                            .global = .init(global),
                        },
                    },
                },
                .empty(),
                false,
            );
            var unwrapped_response: ?*Response = result;
            defer if (unwrapped_response) |owned| owned.finalize();

            sink.response = result;
            result.getBodyValue().Locked.setSource(&sink.body_source);
            const input_size = original.getBodyLen();

            sink.rewriter = builder.build(
                .UTF8,
                .{
                    .preallocated_parsing_buffer_size = if (input_size == jsc.WebCore.Blob.max_size)
                        1024
                    else
                        @max(input_size, 1024),
                    .max_allowed_memory_usage = std.math.maxInt(u32),
                },
                false,
                BufferOutputSink,
                sink,
                BufferOutputSink.write,
                BufferOutputSink.done,
            ) catch {
                var failure = try createLOLHTMLValue(&scope);
                defer failure.deinit();
                return failure.throwException(&scope);
            };

            result.setInit(
                original.getMethod(),
                original.getInitStatusCode(),
                original.getInitStatusText().clone(),
            );

            if (original.getInitHeaders()) |_headers| {
                result.setInitHeaders(try _headers.cloneThis());
            }

            unwrapped_response = null;
            var response_ref = try result.toClassRef(sink.global);
            errdefer response_ref.deinit();
            errdefer {
                result.getBodyValue().deinit();
                if (bun.take(&sink.response_ref)) |owned| {
                    var reference = owned;
                    reference.deinit();
                }
            }
            sink.response_ref = response_ref.clone();

            result.setUrl(original.getUrl().clone());

            try sink.startInput(original);

            if (sink.terminated) return error.JSTerminated;

            if (bun.take(&sink.sync_exception)) |exception| {
                var carrier = exception;
                defer carrier.deinit();
                var error_root = carrier.takeAnyRoot();
                defer error_root.deinit();
                return error_root.throwException(&scope);
            }

            if (sink.sync_error.takeRoot()) |root_value| {
                var sync_error = root_value;
                defer sync_error.deinit();
                return sync_error.throwException(&scope);
            }

            return response_ref;
        }

        fn startInput(sink: *BufferOutputSink, original: *Response) TransformError!void {
            if (try original.getBodyUsed(sink.global)) return error.StreamAlreadyUsed;
            var readable = try original.getBodyReadableStream(sink.global);
            defer if (readable) |*stream| stream.deinit();
            if (readable) |*stream| {
                if (stream.isLocked(sink.global)) return error.StreamAlreadyUsed;
            }

            const value = original.getBodyValue();
            try value.toBlobIfPossible();
            switch (value.*) {
                .Used => return error.StreamAlreadyUsed,
                .Empty, .Null => try sink.writeInput("", false),
                .Error => |*err| try sink.failInput(err, false),
                .WTFStringImpl, .InternalBlob, .Blob => {
                    var input = try value.useAsAnyBlobAllowNonUTF8String();
                    defer input.detach();
                    if (input == .Blob) {
                        try sink.readInputBlob(&input.Blob, false);
                    } else {
                        try sink.writeInput(input.slice(), false);
                    }
                },
                .Locked => {
                    var body_promise = try original.getBlobWithoutWrapper(sink.global);
                    defer body_promise.deinit();
                    var promise = body_promise.toOwned();
                    defer promise.deinit();
                    sink.ref();
                    var reaction_scope: bun.bindgen.FocusedEngineScope = undefined;
                    reaction_scope.init(sink.global);
                    defer reaction_scope.deinit();
                    try InputReaction.attach(&reaction_scope, promise.operand(&reaction_scope).asPromise(), sink, OnInputBinding, OnInputErrorBinding);
                    // Only an attached reaction may abort the output when it is collected.
                    sink.input_promise_pending = true;
                },
            }
        }

        fn readInputBlob(sink: *BufferOutputSink, input: *jsc.WebCore.Blob, is_async: bool) bun.JSError!void {
            if (input.needsToReadFile() or input.isS3()) {
                sink.ref();
                errdefer sink.deref();
                try input.readBytesToHandler(BufferOutputSink, sink, sink.global);
                return;
            }
            try sink.writeInput(input.sharedView(), is_async);
        }

        pub fn onReadBytes(sink: *BufferOutputSink, result: jsc.WebCore.Blob.ReadBytesResult) void {
            defer sink.deref();
            if (sink.vm.get().isShuttingDown()) {
                var owned = result;
                owned.deinit();
                sink.discardOutput();
                return;
            }
            switch (result) {
                .ok => |bytes| {
                    defer bun.default_allocator.free(bytes);
                    sink.writeInput(bytes, true) catch |err| sink.global.reportActiveExceptionAsUnhandled(err);
                },
                .err => |err| {
                    var body_error = Body.Value.ValueError.fromSystemErrorPayload(err);
                    defer body_error.deinit();
                    sink.failInput(&body_error, true) catch |failure| sink.global.reportActiveExceptionAsUnhandled(failure);
                },
                .out_of_memory => {
                    const err: Body.Value.ValueError = .OutOfMemory;
                    sink.failInput(&err, true) catch |failure| sink.global.reportActiveExceptionAsUnhandled(failure);
                },
                .cancelled => sink.discardOutput(),
            }
        }

        fn bindOnInput(_: bindgen.CallContext(OnInputSchema), args: bindgen.Args(OnInputSchema)) bindgen.CallError(OnInputSchema)!void {
            const sink = InputReaction.take(args.context) orelse return;
            sink.input_promise_pending = false;
            defer sink.releasePromiseReactionRef();
            const blob = jsc.WebCore.Blob.fromClassRef(args.blob);
            sink.readInputBlob(blob, true) catch |failure| {
                if (failure != error.OutOfMemory or sink.input_finished) return failure;
                const err: Body.Value.ValueError = .OutOfMemory;
                try sink.failInput(&err, true);
            };
            if (sink.terminated) return error.JSTerminated;
        }

        fn bindOnInputError(context: bindgen.CallContext(OnInputErrorSchema), args: bindgen.Args(OnInputErrorSchema)) bindgen.CallError(OnInputErrorSchema)!void {
            const sink = InputReaction.take(args.context) orelse return;
            sink.input_promise_pending = false;
            defer sink.releasePromiseReactionRef();
            var err: Body.Value.ValueError = .{ .JSValue = .empty };
            err.JSValue.set(args.errorValue.operand(context)) catch |failure| {
                if (failure != error.OutOfMemory) return failure;
                const allocation_error: Body.Value.ValueError = .OutOfMemory;
                return sink.failInput(&allocation_error, true);
            };
            defer err.deinit();
            try sink.failInput(&err, true);
            if (sink.terminated) return error.JSTerminated;
        }

        pub fn releasePromiseReactionRef(sink: *BufferOutputSink) void {
            defer sink.deref();
            if (!sink.input_promise_pending) return;
            sink.input_promise_pending = false;
            if (!sink.body_source.attached) return;
            if (sink.vm.get().isShuttingDown()) {
                sink.discardOutput();
            } else {
                const err: Body.Value.ValueError = .{ .AbortReason = .UserAbort };
                sink.failInput(&err, true) catch |failure| sink.global.reportActiveExceptionAsUnhandled(failure);
            }
        }

        fn discardOutput(sink: *BufferOutputSink) void {
            if (!sink.body_source.attached) return;
            const body = sink.response.getBodyValue();
            body.deinit();
            body.* = .{ .Null = {} };
        }

        fn writeInput(sink: *BufferOutputSink, bytes: []const u8, is_async: bool) bun.JSError!void {
            bun.assert(!sink.input_finished);
            sink.input_finished = true;
            const result = sink.runOutputSink(bytes, is_async) catch |err| {
                if (err != error.OutOfMemory) return err;
                return sink.failOutputAllocation(is_async);
            };
            if (result) |ret_err| {
                var error_root = ret_err;
                defer error_root.deinit();
                sink.sync_error.setRoot(&error_root);
            }
        }

        fn failInput(sink: *BufferOutputSink, err: *const Body.Value.ValueError, is_async: bool) bun.JSError!void {
            bun.assert(!sink.input_finished);
            sink.input_finished = true;
            const result = sink.failBody(err, is_async) catch |failure| {
                if (failure != error.OutOfMemory) return failure;
                return sink.failOutputAllocation(is_async);
            };
            if (result) |ret_err| {
                var error_root = ret_err;
                defer error_root.deinit();
                sink.sync_error.setRoot(&error_root);
            }
        }

        fn failOutputAllocation(sink: *BufferOutputSink, is_async: bool) bun.JSError!void {
            const failure: Body.Value.ValueError = .OutOfMemory;
            _ = try sink.failBody(&failure, true);
            if (!is_async) return error.OutOfMemory;
        }

        fn failBody(sink: *BufferOutputSink, err: *const Body.Value.ValueError, is_async: bool) bun.JSError!?bindgen.Root {
            const body = sink.response.getBodyValue();
            try body.toErrorInstanceWithReadable(
                err.dupe(),
                sink.global,
                if (sink.output_stream.has()) &sink.output_stream else null,
            );
            if (is_async) return null;
            var owned = err.dupe();
            defer owned.deinit();
            return try owned.toRoot(sink.global);
        }

        fn failRewrite(sink: *BufferOutputSink, is_async: bool) bun.JSError!?bindgen.Root {
            var failure = bun.take(&sink.callback_failure);
            defer if (failure) |*owned| owned.deinit();
            if (failure != null and failure.? == .capture_failure) return failure.?.capture_failure;
            if (failure != null and failure.? == .terminated) {
                sink.terminated = true;
                sink.response.getBodyValue().deinit();
                return error.JSTerminated;
            }
            if (!is_async) {
                if (failure) |*owned| {
                    if (owned.exception.carrier) |*carrier| sink.sync_exception = carrier.take();
                }
            }
            var error_value = if (failure) |*owned|
                owned.exception.value.clone()
            else
                try createLOLHTMLError(sink.global);
            var err: Body.Value.ValueError = .{
                .JSValue = error_value.takeOptional(),
            };
            defer err.deinit();
            return sink.failBody(&err, is_async);
        }

        pub fn runOutputSink(
            sink: *BufferOutputSink,
            bytes: []const u8,
            is_async: bool,
        ) bun.JSError!?bindgen.Root {
            const previous_failure = sink.context.active_failure;
            sink.context.active_failure = &sink.callback_failure;
            defer sink.context.active_failure = previous_failure;

            sink.bytes.growBy(bytes.len) catch {
                const err: Body.Value.ValueError = .OutOfMemory;
                return sink.failBody(&err, is_async);
            };

            sink.rewriter.?.write(bytes) catch {
                return sink.failRewrite(is_async);
            };
            if (sink.output_failed or sink.callback_failure != null) return sink.failRewrite(is_async);

            sink.rewriter.?.end() catch {
                return sink.failRewrite(is_async);
            };
            if (sink.output_failed or sink.callback_failure != null) return sink.failRewrite(is_async);

            return null;
        }

        pub fn done(this: *BufferOutputSink) void {
            if (this.output_failed or this.callback_failure != null) return;
            const bodyValue = this.response.getBodyValue();
            if (this.output_stream.byteStream()) |byte_stream| {
                var stream = this.output_stream.take();
                defer stream.deinit();
                var bytes = this.bytes.list.toManaged(bun.default_allocator);
                this.bytes.list = .empty;
                bodyValue.finishStreaming(&this.body_source, &stream);
                byte_stream.onData(
                    .{ .owned_and_done = bun.ByteList.moveFromList(&bytes) },
                    bun.default_allocator,
                ) catch |err| this.global.reportActiveExceptionAsUnhandled(err);
                return;
            }
            var prev_value = bodyValue.*;
            bodyValue.* = jsc.WebCore.Body.Value{
                .InternalBlob = .{
                    .bytes = .fromManaged(this.bytes.list.toManaged(bun.default_allocator)),
                },
            };

            this.bytes = .initEmpty(bun.default_allocator);

            prev_value.resolve(
                bodyValue,
                this.global,
                null,
            ) catch |err| this.global.reportActiveExceptionAsUnhandled(err);
        }

        pub fn write(this: *BufferOutputSink, bytes: []const u8) void {
            if (this.output_failed or this.callback_failure != null) return;
            this.bytes.append(bytes) catch {
                this.output_failed = true;
                this.context.captureFailure(error.OutOfMemory);
            };
        }

        fn deinit(this: *BufferOutputSink) void {
            bun.debugAssert(!this.body_source.attached);
            this.bytes.deinit();
            this.output_stream.deinit();
            this.sync_error.deinit();
            if (this.sync_exception) |*carrier| carrier.deinit();
            if (this.callback_failure) |*failure| failure.deinit();

            this.context.deref();
            if (this.response_ref) |*reference| reference.deinit();
            if (this.rewriter) |rewriter| {
                rewriter.deinit();
            }

            bun.destroy(this);
        }
    };
};

const DocumentHandler = struct {
    context: *LOLHTMLContext,
    onDocTypeCallback: ?bindgen.Callback(DoctypeHandlerCallbackSchema) = null,
    onCommentCallback: ?bindgen.Callback(DocumentCommentHandlerCallbackSchema) = null,
    onTextCallback: ?bindgen.Callback(DocumentTextHandlerCallbackSchema) = null,
    onEndCallback: ?bindgen.Callback(DocumentEndHandlerCallbackSchema) = null,
    thisObject: HandlerReceiver,

    pub const onDocType = HandlerCallback(
        DocumentHandler,
        DocType,
        LOLHTML.DocType,
        DocTypeClass,
        DoctypeHandlerCallbackSchema,
        "doctype",
        "onDocTypeCallback",
    );
    pub const onComment = HandlerCallback(
        DocumentHandler,
        Comment,
        LOLHTML.Comment,
        CommentClass,
        DocumentCommentHandlerCallbackSchema,
        "comment",
        "onCommentCallback",
    );
    pub const onText = HandlerCallback(
        DocumentHandler,
        TextChunk,
        LOLHTML.TextChunk,
        TextChunkClass,
        DocumentTextHandlerCallbackSchema,
        "text_chunk",
        "onTextCallback",
    );
    pub const onEnd = HandlerCallback(
        DocumentHandler,
        DocEnd,
        LOLHTML.DocEnd,
        DocEndClass,
        DocumentEndHandlerCallbackSchema,
        "doc_end",
        "onEndCallback",
    );

    const Listener = ListenerLifecycle(@This(), .{
        .{ "doctype", "onDocTypeCallback" },
        .{ "comments", "onCommentCallback" },
        .{ "text", "onTextCallback" },
        .{ "end", "onEndCallback" },
    });
    pub const init = Listener.init;

    pub const deinit = Listener.deinit;
};

fn releaseHandlerCallbacks(handler: anytype, comptime names: anytype) void {
    inline for (names) |name| {
        if (bun.take(&@field(handler, name))) |owned| {
            var callback = owned;
            callback.deinit();
        }
    }
}

fn HandlerCallback(
    comptime HandlerType: type,
    comptime ZigType: type,
    comptime LOLHTMLType: type,
    comptime ClassBinding: type,
    comptime CallbackSchema: type,
    comptime field_name: string,
    comptime callback_name: string,
) (fn (*HandlerType, *LOLHTMLType) bool) {
    return struct {
        pub fn callback(this: *HandlerType, value: *LOLHTMLType) bool {
            if (this.context.hasFailure()) return true;
            const wrapper = (if (comptime @hasDecl(ZigType, "initForHandler"))
                ZigType.initForHandler(value, this)
            else
                ZigType.init(value)) catch |err| {
                this.context.captureFailure(err);
                return true;
            };
            wrapper.ref();

            defer {
                wrapper.invalidate();
                wrapper.deref();
            }

            const handler_callback = if (@field(this, callback_name)) |*stored_callback| stored_callback else unreachable;
            var invocation: bindgen.Callback(CallbackSchema).Invocation = undefined;
            handler_callback.beginInvocation(&invocation);
            defer invocation.deinit();
            var callback_args: bindgen.Args(CallbackSchema) = undefined;
            var wrapper_ref = ClassBinding.adoptNativeRef(wrapper, invocation.viewToken().globalObject()) catch |err| {
                this.context.captureException(&invocation, err);
                return true;
            };
            defer wrapper_ref.deinit();
            inline for (@typeInfo(@TypeOf(callback_args)).@"struct".field_names) |name| {
                @field(callback_args, name) = if (comptime std.mem.eql(u8, name, field_name))
                    wrapper_ref.operand(&invocation)
                else if (comptime std.mem.eql(u8, name, "bindingThis"))
                    this.thisObject.operand(&invocation)
                else
                    @compileError("unhandled HTMLRewriter callback argument: " ++ name);
            }

            const result = invocation.call(callback_args) catch |err| {
                this.context.captureException(&invocation, err);
                return true;
            };

            return handlerResultFailed(this.context, &invocation, result) catch |err| {
                this.context.captureException(&invocation, err);
                return true;
            };
        }
    }.callback;
}

fn handlerResultFailed(context: *LOLHTMLContext, invocation: anytype, result: anytype) bun.JSError!bool {
    switch (result) {
        inline .error_value, .exception => |value| {
            context.captureError(try value.toRoot());
            return true;
        },
        .promise => |promise| {
            var owned_promise = try promise.toOwned();
            defer owned_promise.deinit();
            if (try invocation.waitForPromiseRejection(owned_promise.operand(invocation).asPromise())) |rejection| {
                context.captureError(try rejection.asAny(invocation).toRoot());
                return true;
            }
        },
        .ignored => {},
    }
    return false;
}

const ElementHandler = struct {
    context: *LOLHTMLContext,
    onElementCallback: ?bindgen.Callback(ElementHandlerCallbackSchema) = null,
    onCommentCallback: ?bindgen.Callback(ElementCommentHandlerCallbackSchema) = null,
    onTextCallback: ?bindgen.Callback(ElementTextHandlerCallbackSchema) = null,
    end_tag_handlers: std.ArrayList(*EndTag.Handler) = .empty,
    thisObject: HandlerReceiver,

    const Listener = ListenerLifecycle(@This(), .{
        .{ "element", "onElementCallback" },
        .{ "comments", "onCommentCallback" },
        .{ "text", "onTextCallback" },
    });
    pub const init = Listener.init;

    pub fn deinit(this: *ElementHandler) void {
        for (this.end_tag_handlers.items) |handler| {
            handler.deinit();
            bun.default_allocator.destroy(handler);
        }
        this.end_tag_handlers.deinit(bun.default_allocator);
        this.end_tag_handlers = .empty;

        Listener.deinit(this);
    }

    pub const onElement = HandlerCallback(
        ElementHandler,
        Element,
        LOLHTML.Element,
        ElementClass,
        ElementHandlerCallbackSchema,
        "element",
        "onElementCallback",
    );

    pub const onComment = HandlerCallback(
        ElementHandler,
        Comment,
        LOLHTML.Comment,
        CommentClass,
        ElementCommentHandlerCallbackSchema,
        "comment",
        "onCommentCallback",
    );

    pub const onText = HandlerCallback(
        ElementHandler,
        TextChunk,
        LOLHTML.TextChunk,
        TextChunkClass,
        ElementTextHandlerCallbackSchema,
        "text_chunk",
        "onTextCallback",
    );
};

fn createLOLHTMLError(global: *JSGlobalObject) bun.JSError!bindgen.Root {
    var scope: bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    var value = try createLOLHTMLValue(&scope);
    defer value.deinit();
    return value.toRoot();
}

fn createLOLHTMLValue(scope: *bindgen.FocusedEngineScope) bun.JSError!bindgen.AnyResult {
    const global = scope.viewToken().globalObject();
    if (global.hasException()) {
        var thrown = try scope.takeThrownValue(error.JSError);
        defer thrown.deinit();
        return thrown.asAny(scope);
    }

    const err = LOLHTML.HTMLString.lastError();
    defer err.deinit();
    var message = try bindgen.DOMString.fromUTF8(err.slice());
    defer message.deinit();
    var value = scope.engine(CreateHTMLRewriterErrorSchema).call(.{ .message = message.operand() }) catch |failure| {
        var thrown = try scope.takeThrownValue(failure);
        defer thrown.deinit();
        return thrown.asAny(scope);
    };
    defer value.deinit();
    return value.asAny(scope);
}
fn failLOLHTMLOperation(comptime Schema: type, context: bindgen.CallContext(Schema)) bindgen.CallError(Schema) {
    const err = LOLHTML.HTMLString.lastError();
    defer err.deinit();
    return context.fail(.operation_failed, try bindgen.DOMString.fromUTF8(err.slice()));
}

fn domStringFromHTMLString(input: LOLHTML.HTMLString) bun.OOM!bindgen.DOMString {
    defer input.deinit();
    return bindgen.DOMString.fromUTF8(input.slice());
}

fn StringGetter(comptime Wrapper: type, comptime field: []const u8, comptime Schema: type, comptime getter: anytype, comptime empty_is_null: bool) type {
    return struct {
        pub fn call(this: *Wrapper, _: bindgen.CallContext(Schema), _: bindgen.Args(Schema)) bun.JSError!bindgen.Return(Schema) {
            const native = @field(this, field).value orelse return null;
            const text: LOLHTML.HTMLString = getter(native);
            defer text.deinit();
            if (empty_is_null and text.len == 0) return null;
            return try bindgen.DOMString.fromUTF8(text.slice());
        }
    };
}

fn ContentMethod(comptime Wrapper: type, comptime field: []const u8, comptime Schema: type, comptime callback: anytype) type {
    return struct {
        pub fn call(this: *Wrapper, context: bindgen.CallContext(Schema), args: bindgen.Args(Schema)) bindgen.CallError(Schema)!bindgen.Return(Schema) {
            const native = @field(this, field).value orelse return args.bindingThis.toOwned();
            const Callback = fn (@TypeOf(native), []const u8, bool) LOLHTML.Error!void;
            const invoke: Callback = callback;
            const content = try args.content.toUTF8(bun.default_allocator);
            defer content.deinit();
            invoke(native, content.slice(), if (args.options orelse null) |options| options.html else false) catch
                return failLOLHTMLOperation(Schema, context);
            return args.bindingThis.toOwned();
        }
    };
}

fn RemovalMethod(comptime Wrapper: type, comptime field: []const u8, comptime Schema: type, comptime remove: anytype) type {
    return struct {
        pub fn call(this: *Wrapper, _: bindgen.CallContext(Schema), args: bindgen.Args(Schema)) bun.JSError!bindgen.Return(Schema) {
            if (@field(this, field).value) |native| remove(native);
            return args.bindingThis.toOwned();
        }
    };
}

fn PredicateGetter(comptime Wrapper: type, comptime field: []const u8, comptime Schema: type, comptime predicate: anytype) type {
    return struct {
        pub fn call(this: *Wrapper, _: bindgen.CallContext(Schema), _: bindgen.Args(Schema)) bun.JSError!bindgen.Return(Schema) {
            const native = @field(this, field).value orelse return null;
            return predicate(native);
        }
    };
}

fn StringSetter(comptime Wrapper: type, comptime field: []const u8, comptime Schema: type, comptime setter: anytype) type {
    return struct {
        pub fn call(this: *Wrapper, context: bindgen.CallContext(Schema), args: bindgen.Args(Schema)) bindgen.CallError(Schema)!void {
            if (@field(this, field).value == null) return;
            const value = (try args.value.convert(context)).value;
            const native = @field(this, field).value orelse return;
            const text = try value.toUTF8(bun.default_allocator);
            defer text.deinit();
            setter(native, text.slice()) catch return failLOLHTMLOperation(Schema, context);
        }
    };
}

fn CallbackLifecycle(comptime Wrapper: type, comptime Native: type, comptime field: []const u8) type {
    return struct {
        pub const RefCount = bun.ptr.RefCount(Wrapper, "ref_count", deinit, .{});

        pub fn init(native: *Native) bun.OOM!*Wrapper {
            const wrapper = try bun.default_allocator.create(Wrapper);
            wrapper.* = .{ .ref_count = .init() };
            @field(wrapper, field) = .init(native);
            return wrapper;
        }

        pub fn invalidate(wrapper: *Wrapper) void {
            @field(wrapper, field).clear();
        }

        fn deinit(wrapper: *Wrapper) void {
            invalidate(wrapper);
            bun.destroy(wrapper);
        }
    };
}

pub const TextChunk = struct {
    const Lifecycle = CallbackLifecycle(@This(), LOLHTML.TextChunk, "text_chunk");
    const RefCount = Lifecycle.RefCount;
    pub const init = Lifecycle.init;
    pub const invalidate = Lifecycle.invalidate;
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;
    pub const derefDeferred = RefCount.derefDeferred;
    pub const destroyAfterDeferred = RefCount.destroyAfterDeferred;

    ref_count: RefCount,
    bindgen_state: bindgen.ClassState = .{},
    text_chunk: bindgen.CallbackBorrow(LOLHTML.TextChunk, .vm) = .empty,

    pub const before = ContentMethod(@This(), "text_chunk", TextChunkBeforeSchema, LOLHTML.TextChunk.before).call;

    pub const after = ContentMethod(@This(), "text_chunk", TextChunkAfterSchema, LOLHTML.TextChunk.after).call;

    pub const replace = ContentMethod(@This(), "text_chunk", TextChunkReplaceSchema, LOLHTML.TextChunk.replace).call;

    pub const remove = RemovalMethod(@This(), "text_chunk", TextChunkRemoveSchema, LOLHTML.TextChunk.remove).call;

    pub fn getText(
        this: *TextChunk,
        _: bindgen.CallContext(TextChunkTextSchema),
        _: bindgen.Args(TextChunkTextSchema),
    ) bun.JSError!?bindgen.DOMString {
        const text_chunk = this.text_chunk.value orelse return null;
        return try bindgen.DOMString.fromUTF8(text_chunk.getContent().slice());
    }

    pub const removed = PredicateGetter(@This(), "text_chunk", TextChunkRemovedSchema, LOLHTML.TextChunk.isRemoved).call;

    pub const lastInTextNode = PredicateGetter(@This(), "text_chunk", TextChunkLastInTextNodeSchema, LOLHTML.TextChunk.isLastInTextNode).call;
};

pub const DocType = struct {
    const Lifecycle = CallbackLifecycle(@This(), LOLHTML.DocType, "doctype");
    const RefCount = Lifecycle.RefCount;
    pub const init = Lifecycle.init;
    pub const invalidate = Lifecycle.invalidate;
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;
    pub const derefDeferred = RefCount.derefDeferred;
    pub const destroyAfterDeferred = RefCount.destroyAfterDeferred;

    ref_count: RefCount,
    bindgen_state: bindgen.ClassState = .{},
    doctype: bindgen.CallbackBorrow(LOLHTML.DocType, .vm) = .empty,

    /// The doctype name.
    pub const name = StringGetter(@This(), "doctype", DocTypeNameSchema, LOLHTML.DocType.getName, true).call;

    pub const systemId = StringGetter(@This(), "doctype", DocTypeSystemIdSchema, LOLHTML.DocType.getSystemId, true).call;

    pub const publicId = StringGetter(@This(), "doctype", DocTypePublicIdSchema, LOLHTML.DocType.getPublicId, true).call;

    pub const remove = RemovalMethod(@This(), "doctype", DocTypeRemoveSchema, LOLHTML.DocType.remove).call;

    pub const removed = PredicateGetter(@This(), "doctype", DocTypeRemovedSchema, LOLHTML.DocType.isRemoved).call;
};

pub const DocEnd = struct {
    const Lifecycle = CallbackLifecycle(@This(), LOLHTML.DocEnd, "doc_end");
    const RefCount = Lifecycle.RefCount;
    pub const init = Lifecycle.init;
    pub const invalidate = Lifecycle.invalidate;
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;
    pub const derefDeferred = RefCount.derefDeferred;
    pub const destroyAfterDeferred = RefCount.destroyAfterDeferred;

    ref_count: RefCount,
    bindgen_state: bindgen.ClassState = .{},
    doc_end: bindgen.CallbackBorrow(LOLHTML.DocEnd, .vm) = .empty,

    pub const append = ContentMethod(@This(), "doc_end", DocEndAppendSchema, LOLHTML.DocEnd.append).call;
};

pub const Comment = struct {
    const Lifecycle = CallbackLifecycle(@This(), LOLHTML.Comment, "comment");
    const RefCount = Lifecycle.RefCount;
    pub const init = Lifecycle.init;
    pub const invalidate = Lifecycle.invalidate;
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;
    pub const derefDeferred = RefCount.derefDeferred;
    pub const destroyAfterDeferred = RefCount.destroyAfterDeferred;

    ref_count: RefCount,
    bindgen_state: bindgen.ClassState = .{},
    comment: bindgen.CallbackBorrow(LOLHTML.Comment, .vm) = .empty,

    pub const before = ContentMethod(@This(), "comment", CommentBeforeSchema, LOLHTML.Comment.before).call;

    pub const after = ContentMethod(@This(), "comment", CommentAfterSchema, LOLHTML.Comment.after).call;

    pub const replace = ContentMethod(@This(), "comment", CommentReplaceSchema, LOLHTML.Comment.replace).call;

    pub const remove = RemovalMethod(@This(), "comment", CommentRemoveSchema, LOLHTML.Comment.remove).call;

    pub const getText = StringGetter(@This(), "comment", CommentTextSchema, LOLHTML.Comment.getText, false).call;

    pub const setText = StringSetter(@This(), "comment", CommentTextSetterSchema, LOLHTML.Comment.setText).call;

    pub const removed = PredicateGetter(@This(), "comment", CommentRemovedSchema, LOLHTML.Comment.isRemoved).call;
};

pub const EndTag = struct {
    const Lifecycle = CallbackLifecycle(@This(), LOLHTML.EndTag, "end_tag");
    const RefCount = Lifecycle.RefCount;
    pub const init = Lifecycle.init;
    pub const invalidate = Lifecycle.invalidate;
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;
    pub const derefDeferred = RefCount.derefDeferred;
    pub const destroyAfterDeferred = RefCount.destroyAfterDeferred;

    ref_count: RefCount,
    bindgen_state: bindgen.ClassState = .{},
    end_tag: bindgen.CallbackBorrow(LOLHTML.EndTag, .vm) = .empty,

    pub const Handler = struct {
        context: *LOLHTMLContext,
        callback: ?bindgen.Callback(ElementEndTagCallbackSchema),

        pub fn deinit(this: *Handler) void {
            releaseHandlerCallbacks(this, .{"callback"});
        }

        pub fn onEndTag(this: *Handler, value: *LOLHTML.EndTag) bool {
            if (this.callback == null) return false;
            defer this.deinit();
            return HandlerCallback(Handler, EndTag, LOLHTML.EndTag, EndTagClass, ElementEndTagCallbackSchema, "end_tag", "callback")(this, value);
        }

        pub const onEndTagHandler = LOLHTML.DirectiveHandler(LOLHTML.EndTag, Handler, onEndTag);
    };

    pub const before = ContentMethod(@This(), "end_tag", EndTagBeforeSchema, LOLHTML.EndTag.before).call;

    pub const after = ContentMethod(@This(), "end_tag", EndTagAfterSchema, LOLHTML.EndTag.after).call;

    pub const remove = RemovalMethod(@This(), "end_tag", EndTagRemoveSchema, LOLHTML.EndTag.remove).call;

    pub const getName = StringGetter(@This(), "end_tag", EndTagNameSchema, LOLHTML.EndTag.getName, false).call;

    pub const setName = StringSetter(@This(), "end_tag", EndTagNameSetterSchema, LOLHTML.EndTag.setName).call;
};

pub const AttributeIterator = struct {
    const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;
    pub const derefDeferred = RefCount.derefDeferred;
    pub const destroyAfterDeferred = RefCount.destroyAfterDeferred;

    ref_count: RefCount,
    bindgen_state: bindgen.ClassState = .{},
    iterator: ?bindgen.OwnedNative(LOLHTML.Attribute.Iterator, .vm) = null,

    pub fn init(iterator: *LOLHTML.Attribute.Iterator) bun.OOM!*AttributeIterator {
        const wrapper = try bun.default_allocator.create(AttributeIterator);
        wrapper.* = .{
            .ref_count = .init(),
            .iterator = .init(iterator),
        };
        return wrapper;
    }

    fn detach(this: *AttributeIterator) void {
        if (this.iterator) |*iter| {
            iter.deinit();
            this.iterator = null;
        }
    }

    fn deinit(this: *AttributeIterator) void {
        this.detach();
        bun.destroy(this);
    }

    pub fn next(
        this: *AttributeIterator,
        _: bindgen.CallContext(AttributeIteratorNextSchema),
        _: bindgen.Args(AttributeIteratorNextSchema),
    ) bun.JSError!bindgen.Return(AttributeIteratorNextSchema) {
        if (this.iterator == null) {
            return .{ .done = true, .value = null };
        }

        const attribute = this.iterator.?.get().next() orelse {
            this.detach();
            return .{ .done = true, .value = null };
        };

        const value = attribute.value();
        defer value.deinit();
        const name = attribute.name();
        defer name.deinit();
        return .{
            .done = false,
            .value = try AttributeIteratorValue.fromUTF8Slices(&.{ name.slice(), value.slice() }),
        };
    }

    pub fn getThis(
        _: *AttributeIterator,
        _: bindgen.CallContext(AttributeIteratorGetThisSchema),
        args: bindgen.Args(AttributeIteratorGetThisSchema),
    ) bun.JSError!bindgen.Return(AttributeIteratorGetThisSchema) {
        return args.bindingThis.toOwned();
    }
};
pub const Element = struct {
    const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;
    pub const derefDeferred = RefCount.derefDeferred;
    pub const destroyAfterDeferred = RefCount.destroyAfterDeferred;

    ref_count: RefCount,
    bindgen_state: bindgen.ClassState = .{},
    element: bindgen.CallbackBorrow(LOLHTML.Element, .vm),
    handler_owner: bindgen.BorrowedNative(ElementHandler, .vm),
    attribute_iterators: AttributeIteratorList = .empty,

    pub fn initForHandler(element: *LOLHTML.Element, handler_owner: *ElementHandler) bun.OOM!*Element {
        const wrapper = try bun.default_allocator.create(Element);
        wrapper.* = .{
            .ref_count = .init(),
            .element = .init(element),
            .handler_owner = .init(handler_owner),
        };
        return wrapper;
    }

    fn detachAttributeIterators(this: *Element) void {
        const iterators = this.attribute_iterators.getOptional() orelse return;
        for (iterators.items) |iter| {
            iter.detach();
            iter.deref();
        }
        iterators.clearRetainingCapacity();
    }

    pub fn invalidate(this: *Element) void {
        this.element.clear();
        this.attribute_iterators.deinit();
    }

    fn deinit(this: *Element) void {
        this.invalidate();
        bun.destroy(this);
    }

    pub fn onEndTag(
        this: *Element,
        context: bindgen.CallContext(ElementOnEndTagSchema),
        args: bindgen.Args(ElementOnEndTagSchema),
    ) bindgen.CallError(ElementOnEndTagSchema)!bindgen.Return(ElementOnEndTagSchema) {
        const element = this.element.value orelse
            return args.bindingThis.toOwned();
        var callback = try args.callback.toOwned();
        defer callback.deinit();
        const end_tag_handler = try bun.default_allocator.create(EndTag.Handler);
        end_tag_handler.* = .{
            .context = this.handler_owner.value.context,
            .callback = callback.take(),
        };
        errdefer {
            end_tag_handler.deinit();
            bun.default_allocator.destroy(end_tag_handler);
        }
        try this.handler_owner.value.end_tag_handlers.ensureUnusedCapacity(bun.default_allocator, 1);

        element.onEndTag(EndTag.Handler.onEndTagHandler, end_tag_handler) catch {
            return failLOLHTMLOperation(ElementOnEndTagSchema, context);
        };

        this.handler_owner.value.end_tag_handlers.appendAssumeCapacity(end_tag_handler);
        return args.bindingThis.toOwned();
    }

    pub fn getAttribute(
        this: *Element,
        context: bindgen.CallContext(ElementGetAttributeSchema),
        args: bindgen.Args(ElementGetAttributeSchema),
    ) bindgen.CallError(ElementGetAttributeSchema)!bindgen.Return(ElementGetAttributeSchema) {
        const element = this.element.value orelse return null;
        var name = try args.name.toUTF8(bun.default_allocator);
        defer name.deinit();
        const exists = element.hasAttribute(name.slice()) catch return failLOLHTMLOperation(ElementGetAttributeSchema, context);
        if (!exists) return null;
        return try domStringFromHTMLString(element.getAttribute(name.slice()));
    }

    pub fn hasAttribute(
        this: *Element,
        context: bindgen.CallContext(ElementHasAttributeSchema),
        args: bindgen.Args(ElementHasAttributeSchema),
    ) bindgen.CallError(ElementHasAttributeSchema)!bool {
        const element = this.element.value orelse return false;
        var name = try args.name.toUTF8(bun.default_allocator);
        defer name.deinit();
        return element.hasAttribute(name.slice()) catch return failLOLHTMLOperation(ElementHasAttributeSchema, context);
    }

    pub fn setAttribute(
        this: *Element,
        context: bindgen.CallContext(ElementSetAttributeSchema),
        args: bindgen.Args(ElementSetAttributeSchema),
    ) bindgen.CallError(ElementSetAttributeSchema)!bindgen.Return(ElementSetAttributeSchema) {
        const element = this.element.value orelse
            return args.bindingThis.toOwned();
        this.detachAttributeIterators();

        var name = try args.name.toUTF8(bun.default_allocator);
        defer name.deinit();
        var value = try args.value.toUTF8(bun.default_allocator);
        defer value.deinit();

        element.setAttribute(name.slice(), value.slice()) catch
            return failLOLHTMLOperation(ElementSetAttributeSchema, context);
        return args.bindingThis.toOwned();
    }

    pub fn removeAttribute(
        this: *Element,
        context: bindgen.CallContext(ElementRemoveAttributeSchema),
        args: bindgen.Args(ElementRemoveAttributeSchema),
    ) bindgen.CallError(ElementRemoveAttributeSchema)!bindgen.Return(ElementRemoveAttributeSchema) {
        const element = this.element.value orelse
            return args.bindingThis.toOwned();
        this.detachAttributeIterators();

        var name = try args.name.toUTF8(bun.default_allocator);
        defer name.deinit();
        element.removeAttribute(name.slice()) catch
            return failLOLHTMLOperation(ElementRemoveAttributeSchema, context);
        return args.bindingThis.toOwned();
    }

    pub const before = ContentMethod(@This(), "element", ElementBeforeSchema, LOLHTML.Element.before).call;

    pub const after = ContentMethod(@This(), "element", ElementAfterSchema, LOLHTML.Element.after).call;

    pub const prepend = ContentMethod(@This(), "element", ElementPrependSchema, LOLHTML.Element.prepend).call;

    pub const append = ContentMethod(@This(), "element", ElementAppendSchema, LOLHTML.Element.append).call;

    pub const replace = ContentMethod(@This(), "element", ElementReplaceSchema, LOLHTML.Element.replace).call;

    pub const setInnerContent = ContentMethod(@This(), "element", ElementSetInnerContentSchema, LOLHTML.Element.setInnerContent).call;

    pub const remove = RemovalMethod(@This(), "element", ElementRemoveSchema, LOLHTML.Element.remove).call;

    pub const removeAndKeepContent = RemovalMethod(@This(), "element", ElementRemoveAndKeepContentSchema, LOLHTML.Element.removeAndKeepContent).call;

    pub const getTagName = StringGetter(@This(), "element", ElementTagNameSchema, LOLHTML.Element.tagName, false).call;

    pub const setTagName = StringSetter(@This(), "element", ElementTagNameSetterSchema, LOLHTML.Element.setTagName).call;

    pub const getRemoved = PredicateGetter(@This(), "element", ElementRemovedSchema, LOLHTML.Element.isRemoved).call;

    pub const getSelfClosing = PredicateGetter(@This(), "element", ElementSelfClosingSchema, LOLHTML.Element.isSelfClosing).call;

    pub const getCanHaveContent = PredicateGetter(@This(), "element", ElementCanHaveContentSchema, LOLHTML.Element.canHaveContent).call;

    pub fn getNamespaceURI(
        this: *Element,
        _: bindgen.CallContext(ElementNamespaceURISchema),
        _: bindgen.Args(ElementNamespaceURISchema),
    ) bun.JSError!?bindgen.DOMString {
        const element = this.element.value orelse return null;
        return try bindgen.DOMString.fromUTF8(std.mem.span(element.namespaceURI()));
    }

    pub fn getAttributes(
        this: *Element,
        context: bindgen.CallContext(ElementAttributesSchema),
        _: bindgen.Args(ElementAttributesSchema),
    ) bindgen.CallError(ElementAttributesSchema)!bindgen.Return(ElementAttributesSchema) {
        const element = this.element.value orelse return null;
        const iterators = this.attribute_iterators.getOptional() orelse create: {
            const list = try bun.default_allocator.create(std.ArrayList(*AttributeIterator));
            list.* = .empty;
            this.attribute_iterators = .init(list);
            break :create list;
        };
        try iterators.ensureUnusedCapacity(bun.default_allocator, 1);
        const iter = element.attributes() orelse return failLOLHTMLOperation(ElementAttributesSchema, context);
        const attr_iter = AttributeIterator.init(iter) catch |err| {
            iter.deinit();
            return err;
        };
        attr_iter.ref();
        errdefer attr_iter.deref();
        const result = try AttributeIteratorClass.adoptResult(attr_iter, context);
        iterators.appendAssumeCapacity(attr_iter);
        return result;
    }
};

const string = []const u8;

const std = @import("std");

const bun = @import("bun");
const JSError = bun.JSError;
const LOLHTML = bun.LOLHTML;
const Response = bun.webcore.Response;

const jsc = bun.jsc;
const bindgen = bun.bindgen;
const Body = jsc.WebCore.Body;
const JSGlobalObject = jsc.JSGlobalObject;

fn ListenerLifecycle(comptime Handler: type, comptime callbacks: anytype) type {
    return struct {
        pub fn init(rewriter_context: *LOLHTMLContext, generated: anytype, thisObject: HandlerReceiver) bun.JSError!Handler {
            var handler: Handler = .{ .context = rewriter_context, .thisObject = thisObject };
            errdefer handler.deinit();
            inline for (callbacks) |pair| {
                switch (@field(generated, pair[0])) {
                    .callback => |*callback| @field(handler, pair[1]) = try callback.toOwned(),
                    .absent => {},
                }
            }
            return handler;
        }

        pub fn deinit(handler: *Handler) void {
            inline for (callbacks) |pair| releaseHandlerCallbacks(handler, .{pair[1]});
            handler.thisObject.deinit();
        }
    };
}

const HTMLRewriterBindingModule = bindgen.Module("HTMLRewriter");
const HTMLRewriterInputModule = bindgen.Module("HTMLRewriterInput");
const OnInputSchema = HTMLRewriterInputModule.function("onInput");
const OnInputErrorSchema = HTMLRewriterInputModule.function("onInputError");
const OnInputBinding = bindgen.Fn(OnInputSchema, HTMLRewriter.BufferOutputSink.bindOnInput);
const OnInputErrorBinding = bindgen.Fn(OnInputErrorSchema, HTMLRewriter.BufferOutputSink.bindOnInputError);
const CreateHTMLRewriterErrorSchema = HTMLRewriterBindingModule.engineShim("createHTMLRewriterError");
const HTMLRewriterSchema = HTMLRewriterBindingModule.class("HTMLRewriter");
const HTMLRewriterConstructorSchema = HTMLRewriterSchema.constructor();
const HTMLRewriterOnSchema = HTMLRewriterSchema.member("on");
const HTMLRewriterOnDocumentSchema = HTMLRewriterSchema.member("onDocument");
const HandlerReceiver = bindgen.OwnedBrandedValue(bindgen.DictionaryFieldType(HTMLRewriterOnDocumentSchema.args[0].ArgumentType, "listener_identity"));
const HTMLRewriterTransformSchema = HTMLRewriterSchema.member("transform");
const HTMLRewriterClass = bindgen.Class(HTMLRewriterSchema, HTMLRewriter);
const ElementHandlerCallbackSchema = bindgen.CallbackSchema("HTMLRewriterElementHandler");
const ElementCommentHandlerCallbackSchema = bindgen.CallbackSchema("HTMLRewriterCommentHandler");
const ElementTextHandlerCallbackSchema = bindgen.CallbackSchema("HTMLRewriterTextHandler");
const DoctypeHandlerCallbackSchema = bindgen.CallbackSchema("HTMLRewriterDoctypeHandler");
const DocumentCommentHandlerCallbackSchema = ElementCommentHandlerCallbackSchema;
const DocumentTextHandlerCallbackSchema = ElementTextHandlerCallbackSchema;
const DocumentEndHandlerCallbackSchema = bindgen.CallbackSchema("HTMLRewriterDocumentEndHandler");

const AttributeIteratorBindingModule = bindgen.Module("AttributeIterator");
const AttributeIteratorSchema = AttributeIteratorBindingModule.class("AttributeIterator");
const AttributeIteratorGetThisSchema = AttributeIteratorSchema.member("iterator");
const AttributeIteratorNextSchema = AttributeIteratorSchema.member("next");
const AttributeIteratorValue = bindgen.ResultType(bindgen.DictionaryFieldType(AttributeIteratorNextSchema.ReturnType, "value").child);
const AttributeIteratorClass = bindgen.Class(AttributeIteratorSchema, AttributeIterator);

fn deinitAttributeIteratorList(iterators: *std.ArrayList(*AttributeIterator)) void {
    for (iterators.items) |iterator| {
        iterator.detach();
        iterator.deref();
    }
    iterators.deinit(bun.default_allocator);
    bun.destroy(iterators);
}

const AttributeIteratorList = bindgen.OwnedNativeWithDestructor(
    std.ArrayList(*AttributeIterator),
    deinitAttributeIteratorList,
    .vm,
);

const DocEndBindingModule = bindgen.Module("DocEnd");
const DocEndSchema = DocEndBindingModule.class("DocEnd");
const DocEndAppendSchema = DocEndSchema.member("append");
const DocEndClass = bindgen.Class(DocEndSchema, DocEnd);
const DocTypeBindingModule = bindgen.Module("DocType");
const DocTypeSchema = DocTypeBindingModule.class("DocType");
const DocTypeNameSchema = DocTypeSchema.member("name");
const DocTypePublicIdSchema = DocTypeSchema.member("publicId");
const DocTypeRemoveSchema = DocTypeSchema.member("remove");
const DocTypeRemovedSchema = DocTypeSchema.member("removed");
const DocTypeSystemIdSchema = DocTypeSchema.member("systemId");
const DocTypeClass = bindgen.Class(DocTypeSchema, DocType);
const CommentBindingModule = bindgen.Module("Comment");
const CommentSchema = CommentBindingModule.class("Comment");
const CommentAfterSchema = CommentSchema.member("after");
const CommentBeforeSchema = CommentSchema.member("before");
const CommentRemoveSchema = CommentSchema.member("remove");
const CommentRemovedSchema = CommentSchema.member("removed");
const CommentReplaceSchema = CommentSchema.member("replace");
const CommentTextSchema = CommentSchema.memberKind("text", .getter);
const CommentTextSetterSchema = CommentSchema.memberKind("text", .setter);
const CommentClass = bindgen.Class(CommentSchema, Comment);
const EndTagBindingModule = bindgen.Module("EndTag");
const EndTagSchema = EndTagBindingModule.class("EndTag");
const EndTagAfterSchema = EndTagSchema.member("after");
const EndTagBeforeSchema = EndTagSchema.member("before");
const EndTagNameSchema = EndTagSchema.memberKind("name", .getter);
const EndTagNameSetterSchema = EndTagSchema.memberKind("name", .setter);
const EndTagRemoveSchema = EndTagSchema.member("remove");
const EndTagClass = bindgen.Class(EndTagSchema, EndTag);
const ElementBindingModule = bindgen.Module("Element");
const ElementSchema = ElementBindingModule.class("Element");
const ElementAfterSchema = ElementSchema.member("after");
const ElementAppendSchema = ElementSchema.member("append");
const ElementAttributesSchema = ElementSchema.member("attributes");
const ElementBeforeSchema = ElementSchema.member("before");
const ElementCanHaveContentSchema = ElementSchema.member("canHaveContent");
const ElementGetAttributeSchema = ElementSchema.member("getAttribute");
const ElementHasAttributeSchema = ElementSchema.member("hasAttribute");
const ElementNamespaceURISchema = ElementSchema.member("namespaceURI");
const ElementOnEndTagSchema = ElementSchema.member("onEndTag");
const ElementEndTagCallbackSchema = ElementOnEndTagSchema.args[0].ArgumentType;
const ElementPrependSchema = ElementSchema.member("prepend");
const ElementRemoveSchema = ElementSchema.member("remove");
const ElementRemoveAndKeepContentSchema = ElementSchema.member("removeAndKeepContent");
const ElementRemoveAttributeSchema = ElementSchema.member("removeAttribute");
const ElementRemovedSchema = ElementSchema.member("removed");
const ElementReplaceSchema = ElementSchema.member("replace");
const ElementSelfClosingSchema = ElementSchema.member("selfClosing");
const ElementSetAttributeSchema = ElementSchema.member("setAttribute");
const ElementSetInnerContentSchema = ElementSchema.member("setInnerContent");
const ElementTagNameSchema = ElementSchema.memberKind("tagName", .getter);
const ElementTagNameSetterSchema = ElementSchema.memberKind("tagName", .setter);
const ElementClass = bindgen.Class(ElementSchema, Element);
const TextChunkBindingModule = bindgen.Module("TextChunk");
const TextChunkSchema = TextChunkBindingModule.class("TextChunk");
const TextChunkAfterSchema = TextChunkSchema.member("after");
const TextChunkBeforeSchema = TextChunkSchema.member("before");
const TextChunkLastInTextNodeSchema = TextChunkSchema.member("lastInTextNode");
const TextChunkRemoveSchema = TextChunkSchema.member("remove");
const TextChunkRemovedSchema = TextChunkSchema.member("removed");
const TextChunkReplaceSchema = TextChunkSchema.member("replace");
const TextChunkTextSchema = TextChunkSchema.member("text");
const TextChunkClass = bindgen.Class(TextChunkSchema, TextChunk);

comptime {
    _ = HTMLRewriterClass;
    _ = OnInputBinding;
    _ = OnInputErrorBinding;
    _ = AttributeIteratorClass;
    _ = DocEndClass;
    _ = DocTypeClass;
    _ = CommentClass;
    _ = EndTagClass;
    _ = ElementClass;
    _ = TextChunkClass;
}
