/// ResumableSink allows a simplified way of reading a stream into a native Writable Interface, allowing to pause and resume the stream without the use of promises.
/// returning false on `onWrite` will pause the stream and calling .drain() will resume the stream consumption.
/// onEnd is always called when the stream is done or errored.
/// Calling `cancel` will cancel the stream, onEnd will be called with the reason passed to cancel.
/// Different from JSSink this is not intended to be exposed to the users, like FileSink or HTTPRequestSink etc.
pub fn ResumableSink(
    comptime ClassSchema: type,
    comptime Context: type,
) type {
    return struct {
        const log = bun.Output.scoped(.ResumableSink, .visible);

        const ThisSink = @This();
        pub const Binding = bindgen.Class(ClassSchema, ThisSink);
        const StartSchema = ClassSchema.member("start");
        const WriteSchema = ClassSchema.member("write");
        const EndSchema = ClassSchema.member("end");
        const SetHandlersSchema = ClassSchema.member("setHandlers");
        const DrainHandlerSchema = SetHandlersSchema.args[0].ArgumentType;
        const CancelHandlerSchema = SetHandlersSchema.args[1].ArgumentType;
        const onWrite = Context.writeRequestData;
        const onEnd = Context.writeEndRequest;

        const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{ .debug_name = ClassSchema.class_name });
        pub const ref = RefCount.ref;
        pub const deref = RefCount.deref;
        pub const derefDeferred = RefCount.derefDeferred;
        pub const destroyAfterDeferred = RefCount.destroyAfterDeferred;
        ref_count: RefCount,
        bindgen_state: bindgen.ClassState = .{},
        js_this: ?bindgen.ClassRef(ClassSchema) = null,
        stream: jsc.WebCore.ReadableStream.Strong = .{},
        drain_handler: ?bindgen.Callback(DrainHandlerSchema) = null,
        cancel_handler: ?bindgen.Callback(CancelHandlerSchema) = null,
        context: ?bindgen.BorrowedNative(Context, .vm),
        highWaterMark: i64 = 16384,
        status: Status = .started,

        const Status = enum(u8) {
            started,
            piped,
            paused,
            done,
        };

        pub fn init(globalThis: *jsc.JSGlobalObject, stream: *const jsc.WebCore.ReadableStream.Strong, context: *Context) bun.JSError!*ThisSink {
            const this = try bun.default_allocator.create(ThisSink);
            this.* = .{
                .context = bindgen.BorrowedNative(Context, .vm).init(context),
                .ref_count = .init(),
            };
            errdefer this.deref();
            if (stream.isLocked(globalThis) or stream.isDisturbed(globalThis)) {
                const err = bun.sys.SystemError{
                    .code = bun.String.static(@tagName(bun.api.node.ErrorCode.ERR_STREAM_CANNOT_PIPE)),
                    .message = bun.String.static("Stream already used, please create a new one"),
                };
                var payload = try bindgen.SystemError.fromSystemError(&err);
                defer payload.deinit();
                var scope: bindgen.FocusedEngineScope = undefined;
                scope.init(globalThis);
                defer scope.deinit();
                var error_value = try payload.toErrorInstance(&scope);
                defer error_value.deinit();
                this.status = .done;
                var rooted_error = try error_value.toRoot();
                defer rooted_error.deinit();
                this.finishContext(true, &rooted_error);
                return this;
            }
            this.stream = stream.clone();
            if (stream.byteStream()) |byte_stream| {
                // if pipe is empty, we can pipe
                if (byte_stream.pipe.isEmpty()) {
                    // equivalent to onStart to get the highWaterMark
                    this.highWaterMark = if (byte_stream.highWaterMark < std.math.maxInt(i64))
                        @intCast(byte_stream.highWaterMark)
                    else
                        std.math.maxInt(i64);

                    if (byte_stream.has_received_last_chunk) {
                        this.status = .done;
                        var rooted_error = if (byte_stream.pending.result == .err)
                            try this.stream.retainStreamError(&byte_stream.pending.result.err)
                        else
                            null;
                        defer if (rooted_error) |*value| value.deinit();

                        var bytes = byte_stream.drain();
                        defer bytes.deinit(bun.default_allocator);
                        log("onWrite {}", .{bytes.len});
                        _ = try onWrite(this.nativeContext(), bytes.slice());
                        this.finishContext(
                            rooted_error != null,
                            if (rooted_error) |*value| value else null,
                        );
                        return this;
                    }
                    // We can pipe but we also wanna to drain as much as possible first
                    var bytes = byte_stream.drain();
                    defer bytes.deinit(bun.default_allocator);
                    // lets write and see if we can still pipe or if we have backpressure
                    if (bytes.len > 0) {
                        log("onWrite {}", .{bytes.len});
                        // we ignore the return value here because we dont want to pause the stream
                        // if we pause will just buffer in the pipe and we can do the buffer in one place
                        _ = try onWrite(this.nativeContext(), bytes.slice());
                    }
                    this.status = .piped;
                    byte_stream.pipe = jsc.WebCore.Pipe.Wrap(@This(), onStreamPipe).init(this);

                    // we only need the stream, we dont need to touch JS side yet
                    return this;
                }
            }
            // lets go JS side route
            this.ref();
            var sink_ref = try Binding.adoptNativeRef(this, globalThis);
            defer sink_ref.deinit();
            this.js_this = sink_ref.clone();

            var stream_value = stream.cloneOwned() orelse @panic("cannot attach an empty readable stream");
            defer stream_value.deinit();
            const AssignStreamSchema = if (ClassSchema == ResumableFetchSinkSchema)
                AssignFetchStreamSchema
            else if (ClassSchema == ResumableS3UploadSinkSchema)
                AssignS3UploadStreamSchema
            else
                @compileError("unsupported resumable sink class");
            var scope: bindgen.FocusedEngineScope = undefined;
            stream_value.initScope(&scope);
            defer scope.deinit();
            scope.engine(AssignStreamSchema).call(.{
                .stream = stream_value.operand(&scope),
                .sink = sink_ref.operand(&scope),
            }) catch |err| {
                this.status = .done;
                this.detachJS();
                return err;
            };

            return this;
        }

        pub fn setHandlers(
            this: *ThisSink,
            _: bindgen.CallContext(SetHandlersSchema),
            args: bindgen.Args(SetHandlersSchema),
        ) bun.JSError!void {
            if (this.status == .done) return;
            var drain_handler = try args.ondrain.toOwned();
            defer drain_handler.deinit();
            var cancel_handler = try args.oncancel.toOwned();
            defer cancel_handler.deinit();
            if (this.drain_handler) |*handler| handler.deinit();
            if (this.cancel_handler) |*handler| handler.deinit();
            this.drain_handler = drain_handler.take();
            this.cancel_handler = cancel_handler.take();
        }

        pub fn start(
            this: *ThisSink,
            _: bindgen.CallContext(StartSchema),
            args: bindgen.Args(StartSchema),
        ) bun.JSError!void {
            if (args.options.high_water_mark) |high_water_mark| {
                this.highWaterMark = high_water_mark;
            }
        }

        pub fn write(
            this: *ThisSink,
            _: bindgen.CallContext(WriteSchema),
            args: bindgen.Args(WriteSchema),
        ) bun.JSError!bool {
            // ignore any call if detached
            if (this.isDetached()) return true;

            const write_result = switch (args.chunk) {
                .string => |string| blk: {
                    var utf8 = try string.toUTF8(bun.default_allocator);
                    defer utf8.deinit();
                    log("write {}", .{utf8.length()});
                    break :blk try onWrite(this.nativeContext(), utf8.slice());
                },
                .view => |view| blk: {
                    const bytes = view.unsafePtr("the generated entry frame owns the chunk lease until onWrite consumes or copies its bytes");
                    log("write {}", .{bytes.len});
                    break :blk try onWrite(this.nativeContext(), bytes);
                },
            };
            if (this.status == .done) return true;
            switch (write_result) {
                .backpressure => {
                    log("paused", .{});
                    this.status = .paused;
                },
                .done => {},
                .want_more => {
                    this.status = .started;
                },
            }

            return this.status != .paused;
        }

        pub fn end(
            this: *ThisSink,
            _: bindgen.CallContext(EndSchema),
            args: bindgen.Args(EndSchema),
        ) bun.JSError!void {
            // ignore any call if detached
            if (this.isDetached()) return;
            var rooted_reason = if (args.reason) |reason| try reason.toRoot() else null;
            defer if (rooted_reason) |*reason| reason.deinit();
            this.detachJS();
            log("end", .{});
            this.status = .done;

            if (rooted_reason) |*reason| {
                this.finishContext(true, reason);
            } else {
                this.finishContext(false, null);
            }
        }

        pub fn drain(this: *ThisSink) void {
            log("drain", .{});
            if (this.status != .paused) {
                return;
            }
            const handler = if (this.drain_handler) |*value| value else return;
            this.status = .started;
            var invocation: @TypeOf(handler.*).Invocation = undefined;
            handler.beginInvocation(&invocation);
            defer invocation.deinit();
            invocation.dispatch(.{});
        }

        pub fn cancel(this: *ThisSink, reason: *const bindgen.Root) void {
            this.cancelWithReason(reason);
        }

        pub fn cancelOnError(this: *ThisSink, err: bun.JSError) void {
            if (this.status == .done) return;
            const global = this.stream.storedGlobal().?;
            var scope: bindgen.FocusedEngineScope = undefined;
            scope.init(global);
            defer scope.deinit();
            var value = scope.takeThrownValue(err) catch |termination| {
                this.cancelWithReason(null);
                bindgen.voidFromJSError(termination, global);
                return;
            };
            defer value.deinit();
            var reason = value.toRoot() catch |failure| {
                this.cancelWithReason(null);
                bindgen.voidFromJSError(failure, global);
                return;
            };
            defer reason.deinit();
            this.cancelWithReason(&reason);
        }

        fn cancelWithReason(this: *ThisSink, reason: ?*const bindgen.Root) void {
            // onEnd must fire at most once.
            if (this.status == .done) return;
            if (this.status == .piped) {
                this.endPipe(true, reason);
                return;
            }
            if (this.js_this != null) {
                this.status = .done;
                var callback: ?bindgen.Callback(CancelHandlerSchema) = if (this.cancel_handler) |*handler|
                    handler.take()
                else
                    null;
                this.cancel_handler = null;
                defer if (callback) |*handler| handler.deinit();

                // detach first so if cancel calls end will be a no-op
                this.detachJS();

                // call onEnd to indicate the native side that the stream errored
                this.finishContext(true, reason);

                if (reason) |rooted_reason| if (callback) |*handler| {
                    var invocation: @TypeOf(handler.*).Invocation = undefined;
                    handler.beginInvocation(&invocation);
                    defer invocation.deinit();
                    _ = invocation.call(.{
                        .unused = false,
                        .reason = rooted_reason.operand(&invocation),
                    }) catch |err| invocation.reportActiveException(err);
                };
            }
        }

        pub fn abandon(this: *ThisSink) void {
            this.ref();
            defer this.deref();
            const was_active = this.status != .done;
            const was_piped = this.status == .piped;
            this.status = .done;
            if (was_piped) {
                if (this.stream.byteStream()) |byte_stream| byte_stream.unpipe();
            }
            this.detachJS();
            this.stream.deinit();
            this.deinitHandlers();
            if (was_active) this.finishContext(true, null);
        }

        pub fn isDetached(this: *const ThisSink) bool {
            return this.js_this == null or this.status == .done;
        }

        fn nativeContext(this: *const ThisSink) *Context {
            return (this.context orelse @panic("resumable sink context was already completed")).get();
        }

        fn finishContext(this: *ThisSink, failed: bool, reason: ?*const bindgen.Root) void {
            const context = bun.take(&this.context) orelse return;
            onEnd(context.get(), failed, reason);
        }

        fn detachJS(this: *ThisSink) void {
            if (bun.take(&this.js_this)) |reference| {
                var wrapper = reference;
                wrapper.deinit();
                this.stream.deinit();
                this.deinitHandlers();
            }
        }
        pub fn deinit(this: *ThisSink) void {
            this.detachJS();
            this.stream.deinit();
            this.deinitHandlers();
            bun.destroy(this);
        }

        fn deinitHandlers(this: *ThisSink) void {
            if (this.drain_handler) |*handler| handler.deinit();
            if (this.cancel_handler) |*handler| handler.deinit();
            this.drain_handler = null;
            this.cancel_handler = null;
        }

        fn onStreamPipe(
            this: *ThisSink,
            stream: bun.webcore.streams.Result,
            allocator: std.mem.Allocator,
        ) void {
            this.ref();
            defer this.deref();
            var stream_ = stream;
            const stream_needs_deinit = stream == .owned or stream == .owned_and_done or stream == .err;

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
            if (this.status == .done) return;
            if (stream_ == .err) {
                const global = this.stream.storedGlobal().?;
                var rooted_error = this.stream.retainStreamError(&stream_.err) catch |termination| {
                    this.endPipe(true, null);
                    bindgen.voidFromJSError(termination, global);
                    return;
                };
                defer rooted_error.deinit();
                this.endPipe(true, &rooted_error);
                return;
            }

            const chunk = stream.slice();
            log("onWrite {}", .{chunk.len});
            _ = onWrite(this.nativeContext(), chunk) catch |err| {
                this.cancelOnError(err);
                return;
            };
            if (stream.isDone()) this.endPipe(false, null);
        }

        fn endPipe(this: *ThisSink, failed: bool, reason: ?*const bindgen.Root) void {
            log("endPipe", .{});
            if (this.status != .piped) return;
            this.ref();
            defer this.deref();
            bun.assert(this.js_this == null);
            this.status = .done;
            if (this.stream.has()) {
                if (this.stream.byteStream()) |byte_stream| byte_stream.unpipe();
                if (failed) {
                    this.stream.cancelInStoredRealm();
                } else {
                    this.stream.doneInStoredRealm();
                }
                var stream = this.stream;
                this.stream = .{};
                stream.deinit();
            }

            this.finishContext(failed, reason);
        }
    };
}
pub const ResumableSinkBackpressure = @import("./ResumableSinkBackpressure.zig").ResumableSinkBackpressure;
const BindingModule = bindgen.Module("resumable_sink");
const CancelHandlerCallbackSchema = bindgen.CallbackSchema("ResumableSinkCancelHandler");
const ResumableFetchSinkSchema = BindingModule.class("ResumableFetchSink");
const ResumableS3UploadSinkSchema = BindingModule.class("ResumableS3UploadSink");
pub const ResumableFetchSink = ResumableSink(ResumableFetchSinkSchema, FetchTasklet);
pub const ResumableS3UploadSink = ResumableSink(ResumableS3UploadSinkSchema, S3UploadStreamWrapper);

comptime {
    _ = ResumableFetchSink.Binding;
    _ = ResumableS3UploadSink.Binding;
}

const std = @import("std");
const FetchTasklet = @import("./fetch.zig").FetchTasklet;
const S3UploadStreamWrapper = @import("./s3/ClientStreamEngine.zig").S3UploadStreamWrapper;

const bun = @import("bun");
const jsc = bun.jsc;
const bindgen = bun.bindgen;
const AssignFetchStreamSchema = BindingModule.engineShim("assignStreamIntoFetchSink");
const AssignS3UploadStreamSchema = BindingModule.engineShim("assignStreamIntoS3UploadSink");
