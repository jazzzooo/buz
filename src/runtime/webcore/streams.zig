pub const ReadableStart = union(enum) {
    empty,
    ready,
    chunk_size: Blob.SizeType,
    err: bun.bindgen.SystemError,
    out_of_memory,
    owned_and_done: bun.ByteList,

    pub fn deinit(this: *ReadableStart) void {
        switch (this.*) {
            .err => |*err| err.deinit(),
            .owned_and_done => |*bytes| bytes.deinit(bun.default_allocator),
            else => {},
        }
        this.* = .empty;
    }
};

pub const Start = union(Tag) {
    empty: void,
    err: Syscall.Error,
    chunk_size: Blob.SizeType,
    ArrayBufferSink: struct {
        chunk_size: Blob.SizeType,
        as_uint8array: bool,
        stream: bool,
    },
    FileSink: FileSink.Options,
    HTTPSResponseSink: void,
    HTTPResponseSink: void,
    H3ResponseSink: void,
    NetworkSink: void,

    pub const Tag = enum {
        empty,
        err,
        chunk_size,
        ArrayBufferSink,
        FileSink,
        HTTPSResponseSink,
        HTTPResponseSink,
        H3ResponseSink,
        NetworkSink,
    };

    pub fn deinit(this: *Start) void {
        if (this.* == .FileSink) this.FileSink.input_path.deinit();
        this.* = .{ .empty = {} };
    }

    pub fn fromBindingOptions(options: anytype, comptime tag: Tag) bun.OOM!Start {
        switch (comptime tag) {
            .ArrayBufferSink => {
                const chunk_size = bindingHighWaterMark(options);
                if (options.as_uint8_array == null and options.stream == null and chunk_size == null) {
                    return .{ .empty = {} };
                }
                return .{ .ArrayBufferSink = .{
                    .chunk_size = chunk_size orelse 0,
                    .as_uint8array = options.as_uint8_array orelse false,
                    .stream = options.stream orelse false,
                } };
            },
            .FileSink => {
                const chunk_size = bindingHighWaterMark(options) orelse 0;
                if (comptime @hasField(@TypeOf(options), "path")) {
                    if (options.path) |path| switch (path) {
                        .string => |value| return .{ .FileSink = .{
                            .chunk_size = chunk_size,
                            .input_path = .{ .path = try value.toUTF8(default_allocator) },
                        } },
                        .ignored => return bindingFileSinkError(.EINVAL),
                    };
                }
                if (comptime @hasField(@TypeOf(options), "fd")) {
                    if (options.fd) |fd| {
                        if (fd < 0) return bindingFileSinkError(.EBADF);
                        return .{ .FileSink = .{
                            .chunk_size = chunk_size,
                            .input_path = .{ .fd = .fromUV(@intCast(fd)) },
                        } };
                    }
                }
                return .{ .chunk_size = chunk_size };
            },
            .NetworkSink, .HTTPSResponseSink, .HTTPResponseSink, .H3ResponseSink => {
                return if (bindingHighWaterMark(options)) |chunk_size|
                    .{ .chunk_size = chunk_size }
                else
                    .{ .empty = {} };
            },
            else => @compileError("Unsupported stream start tag"),
        }
    }

    pub fn bindingHighWaterMark(options: anytype) ?Blob.SizeType {
        const input = options.high_water_mark orelse return null;
        return switch (input) {
            .number => |number| @intFromFloat(number),
            .ignored => null,
        };
    }

    fn bindingFileSinkError(comptime errno: bun.sys.SystemErrno) Start {
        return .{ .err = .{
            .errno = @backingInt(errno),
            .syscall = .write,
        } };
    }
};

pub const Result = union(Tag) {
    pub const IntoArray = struct {
        len: usize,
    };

    pending: *Pending,
    err: StreamError,
    done: void,
    owned: bun.ByteList,
    owned_and_done: bun.ByteList,
    temporary_and_done: []const u8,
    temporary: []const u8,
    into_array: IntoArray,
    into_array_and_done: IntoArray,

    pub fn deinit(this: *Result) void {
        switch (this.*) {
            .owned => |*owned| owned.clearAndFree(bun.default_allocator),
            .owned_and_done => |*owned_and_done| owned_and_done.clearAndFree(bun.default_allocator),
            .err => |*err| err.deinit(),
            else => {},
        }
    }

    pub fn take(this: *Result) Result {
        const result = this.*;
        this.* = .{ .temporary = &.{} };
        return result;
    }

    pub const StreamError = union(enum) {
        OutOfMemory,
        Error: bun.bindgen.SystemError,
        AbortReason: jsc.CommonAbortReason,
        JSValue: bun.bindgen.Root.Optional,
        consumed: void,

        pub fn deinit(this: *@This()) void {
            switch (this.*) {
                .JSValue => |*root| root.deinit(),
                .Error => |*err| err.deinit(),
                .OutOfMemory, .AbortReason, .consumed => {},
            }
            this.* = .{ .consumed = {} };
        }

        pub fn take(this: *@This()) @This() {
            if (this.* == .consumed) @panic("stream error was consumed twice");
            const value = this.*;
            this.* = .{ .consumed = {} };
            return value;
        }

        pub fn fromSysError(err: Syscall.Error) @This() {
            if (err.getErrno() == .NOMEM) return .OutOfMemory;
            return .{ .Error = bun.bindgen.SystemError.fromSysError(err) catch return .OutOfMemory };
        }

        pub fn takeSystem(this: *@This()) bun.bindgen.SystemError {
            const value = this.Error;
            this.* = .{ .consumed = {} };
            return value;
        }

        pub fn toRoot(this: *const @This(), global: *JSGlobalObject) bun.JSError!bun.bindgen.Root {
            return @import("./BodyErrorEngine.zig").retainStreamError(this, global);
        }
    };

    pub const Tag = enum {
        pending,
        err,
        done,
        owned,
        owned_and_done,
        temporary_and_done,
        temporary,
        into_array,
        into_array_and_done,
    };

    pub fn slice16(this: *const Result) []const u16 {
        const bytes = this.slice();
        return @as([*]const u16, @ptrCast(@alignCast(bytes.ptr)))[0..std.mem.bytesAsSlice(u16, bytes).len];
    }

    pub fn slice(this: *const Result) []const u8 {
        return switch (this.*) {
            .owned => |owned| owned.slice(),
            .owned_and_done => |owned_and_done| owned_and_done.slice(),
            .temporary_and_done => |bytes| bytes,
            .temporary => |bytes| bytes,
            else => "",
        };
    }

    pub const Writable = union(enum) {
        pending: *Writable.Pending,

        err: Syscall.Error,
        out_of_memory,
        done: void,

        owned: usize,
        owned_and_done: usize,
        temporary_and_done: usize,
        temporary: usize,
        into_array: usize,
        into_array_and_done: usize,

        pub const Pending = struct {
            future: Future = .{ .none = {} },
            result: Writable,
            state: Result.Pending.State = .none,

            pub fn deinit(this: *@This()) void {
                this.future.deinit();
            }

            pub const Future = union(enum) {
                none: void,
                promise: SinkPending,
                handler: Handler,

                pub fn deinit(this: *@This()) void {
                    if (this.* == .promise) {
                        this.promise.deinit();
                        this.* = .{ .none = {} };
                    }
                }
            };

            pub fn promiseResult(this: *Writable.Pending, context: anytype) bun.JSError!SinkPending.PromiseResult {
                const result = switch (this.future) {
                    .promise => |*promise| try promise.promiseResult(context),
                    else => fresh: {
                        var promise: SinkPending = .{};
                        const promise_result = try promise.promiseResult(context);
                        this.future = .{ .promise = promise };
                        break :fresh promise_result;
                    },
                };
                this.state = .pending;
                return result;
            }

            pub const Handler = struct {
                ctx: bun.bindgen.NativeCallbackContext(.vm),
                handler: Fn,

                pub const Fn = *const fn (ctx: bun.bindgen.NativeCallbackContext(.vm), result: Result.Writable) void;

                pub fn init(this: *Handler, comptime Context: type, ctx: *Context, comptime handler_fn: fn (*Context, Result.Writable) void) void {
                    this.ctx = .init(ctx);
                    this.handler = struct {
                        const handler = handler_fn;
                        pub fn onHandle(ctx_: bun.bindgen.NativeCallbackContext(.vm), result: Result.Writable) void {
                            @call(bun.callmod_inline, handler, .{ ctx_.get(*Context), result });
                        }
                    }.onHandle;
                }
            };

            pub fn run(this: *Writable.Pending) void {
                if (this.state != .pending) {
                    return;
                }
                this.state = .used;

                switch (this.future) {
                    .promise => |pending_promise| {
                        var promise = pending_promise;
                        this.future = .none;
                        Writable.fulfillPromise(this.result, &promise);
                    },
                    .handler => |h| {
                        h.handler(h.ctx, this.result);
                    },
                    .none => {},
                }
            }
        };

        pub fn isDone(this: *const Writable) bool {
            return switch (this.*) {
                .owned_and_done, .temporary_and_done, .into_array_and_done, .done, .err, .out_of_memory => true,
                else => false,
            };
        }

        pub fn fulfillPromise(result: Writable, promise: *SinkPending) void {
            switch (result) {
                .err => |err| promise.rejectSystem(err),
                .out_of_memory => promise.outOfMemory(),
                .done => promise.resolve(0),
                .pending => @panic("pending sink write completed with another pending result"),
                inline else => |count| promise.resolve(count),
            }
        }
    };

    pub const Pending = struct {
        promise: ReadablePending = .{},
        result: Result = .{ .done = {} },
        state: State = .none,
        pull_view: ?bun.bindgen.OwnedMutableLease(u8) = null,

        pub fn deinit(this: *Pending) void {
            this.promise.deinit();
            this.result.deinit();
            this.releasePullView();
            this.* = .{};
        }

        pub fn retainPullView(this: *Pending, view: bun.bindgen.OwnedMutableLease(u8)) void {
            bun.assert(this.pull_view == null);
            this.pull_view = view;
        }

        pub fn releasePullView(this: *Pending) void {
            if (this.pull_view) |*view| view.release();
            this.pull_view = null;
        }

        pub fn promiseResult(this: *Pending, context: anytype) bun.JSError!ReadablePending.PromiseResult {
            const result = try this.promise.promiseResult(context);
            this.state = .pending;
            return result;
        }

        pub const State = enum {
            none,
            pending,
            used,
        };

        pub fn run(this: *Pending) void {
            if (this.state != .pending) {
                this.releasePullView();
                return;
            }
            var pull_view = bun.take(&this.pull_view);
            defer if (pull_view) |*view| view.release();
            this.state = .used;
            bun.assert(this.promise.has());
            Result.fulfillPromise(&this.result, &this.promise);
        }
    };

    pub fn isDone(this: *const Result) bool {
        return switch (this.*) {
            .owned_and_done, .temporary_and_done, .into_array_and_done, .done, .err => true,
            else => false,
        };
    }

    pub fn toSettledPullResult(this: *Result) bun.OOM!ReadablePending.SettledResult {
        const Value = @FieldType(ReadablePending.SettledResult, "value");
        const value: Value = switch (this.*) {
            .owned, .owned_and_done => |*list| .{
                .bytes = .fromDefaultAllocatedSlice(try list.toOwnedSlice(bun.default_allocator)),
            },
            .temporary, .temporary_and_done => |bytes| .{
                .bytes = try bun.bindgen.OwnedBytes.fromSlice(bytes),
            },
            .into_array, .into_array_and_done => |array| .{ .count = array.len },
            .done => .{ .closed = false },
            .pending => @panic("pending readable result cannot settle another pending result"),
            .err => @panic("errored readable result cannot be converted to a settled value"),
        };
        const done = this.isDone();
        this.* = .{ .temporary = &.{} };
        return .{ .value = value, .done = done };
    }

    pub fn toDirectPullResult(this: *Result) bun.OOM!ReadablePending.DirectResult {
        var settled = try this.toSettledPullResult();
        return ReadablePending.directFromSettled(&settled);
    }

    pub fn rejectedPullPromiseResult(
        this: *Result,
        context: anytype,
    ) bun.JSError!ReadablePending.PromiseResult {
        if (this.* != .err) @panic("only a readable stream error can create a rejected pull promise");
        var pending: ReadablePending = .{};
        defer pending.deinit();
        const promise = try pending.promiseResult(context);
        Result.fulfillPromise(this, &pending);
        return promise;
    }

    pub fn fulfillPromise(result: *Result, pending: *ReadablePending) void {
        if (result.* == .err) {
            var stream_error = result.err.take();
            result.* = .{ .temporary = &.{} };
            switch (stream_error) {
                .OutOfMemory => pending.outOfMemory(),
                .Error => pending.rejectOwnedSystem(stream_error.takeSystem()),
                .AbortReason => |reason| pending.rejectAbort(reason),
                .JSValue => |*root_slot| {
                    var root = root_slot.takeRoot() orelse @panic("stored stream error has no JS value");
                    pending.rejectRoot(&root);
                },
                .consumed => @panic("consumed stream error cannot settle a promise"),
            }
            return;
        }

        const settled = result.toSettledPullResult() catch {
            result.deinit();
            result.* = .{ .temporary = &.{} };
            pending.outOfMemory();
            return;
        };
        pending.resolve(settled);
    }
};

pub const Signal = struct {
    target: Target = .none,

    const Target = union(enum) {
        none,
        array_buffer: bun.bindgen.BorrowedNative(Sink.ArrayBufferSink.JSSink.Controller, .vm),
        file: bun.bindgen.BorrowedNative(WebCore.FileSink.JSSink.Controller, .vm),
        http: bun.bindgen.BorrowedNative(HTTPServerWritable(false, false).JSSink.Controller, .vm),
        https: bun.bindgen.BorrowedNative(HTTPServerWritable(true, false).JSSink.Controller, .vm),
        http3: bun.bindgen.BorrowedNative(HTTPServerWritable(true, true).JSSink.Controller, .vm),
        network: bun.bindgen.BorrowedNative(NetworkSink.JSSink.Controller, .vm),
        subprocess_stdin: bun.bindgen.BorrowedNative(@import("../api/bun/SubprocessEngine.zig").Writable, .vm),
    };

    pub fn clear(this: *Signal) void {
        this.* = .{};
    }

    pub fn isDead(this: Signal) bool {
        return this.target == .none;
    }

    pub fn initWithType(comptime Type: type, handler: *Type) Signal {
        inline for (@typeInfo(Target).@"union".field_names, @typeInfo(Target).@"union".field_types) |name, Reference| {
            if (Reference != void and Reference == bun.bindgen.BorrowedNative(Type, .vm)) {
                return .{ .target = @unionInit(Target, name, Reference.init(handler)) };
            }
        }
        @compileError("unsupported stream signal target: " ++ @typeName(Type));
    }

    pub fn init(handler: anytype) Signal {
        return initWithType(std.meta.Child(@TypeOf(handler)), handler);
    }

    pub fn get(this: Signal, comptime Type: type) ?*Type {
        return switch (this.target) {
            .none => null,
            inline else => |reference| if (comptime @TypeOf(reference) == bun.bindgen.BorrowedNative(Type, .vm)) reference.get() else null,
        };
    }

    pub fn matches(this: Signal, handler: anytype) bool {
        const pointer = this.get(std.meta.Child(@TypeOf(handler))) orelse return false;
        return pointer == handler;
    }

    pub fn close(this: *Signal, err: ?Syscall.Error) void {
        const target = this.target;
        this.clear();
        switch (target) {
            .none => {},
            inline else => |reference| reference.get().onClose(err),
        }
    }

    pub fn ready(this: *Signal, amount: ?usize, offset: ?usize) void {
        switch (this.target) {
            .none => {},
            inline else => |reference| reference.get().onReady(amount, offset),
        }
    }

    pub fn start(this: *Signal) void {
        switch (this.target) {
            .none => {},
            inline else => |reference| reference.get().onStart(),
        }
    }
};

pub fn HTTPServerWritable(comptime ssl: bool, comptime http3: bool) type {
    return struct {
        const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
        pub const ref = RefCount.ref;
        pub const deref = RefCount.deref;
        const UWSResponse = if (http3) uws.H3.Response else uws.NewApp(ssl).Response;
        ref_count: RefCount = .init(),
        res: ?*UWSResponse,
        buffer: bun.ByteList,
        pooled_buffer: ?*WebCore.ByteListPool.Node = null,
        offset: usize = 0,

        is_listening_for_abort: bool = false,
        wrote: usize = 0,

        allocator: std.mem.Allocator,
        done: bool = false,
        signal: Signal = .{},
        pending_flush: SinkPending = .{},
        wrote_at_start_of_flush: usize = 0,
        globalThis: *JSGlobalObject = undefined,
        highWaterMark: Blob.SizeType = 2048,

        requested_end: bool = false,

        has_backpressure: bool = false,
        end_len: ?usize = null,
        aborted: bool = false,
        write_failure: ?uws.ResponseWriteError = null,

        auto_flusher: WebCore.AutoFlusher = .{},

        const log = Output.scoped(.HTTPServerWritable, .visible);

        pub fn connect(this: *@This(), signal: Signal) void {
            this.signal = signal;
        }

        // Don't include @sizeOf(This) because it's already included in the memoryCost of the sink
        pub fn memoryCost(this: *@This()) usize {
            // TODO: include Socket send buffer size. We can't here because we
            // don't track if it's still accessible.
            // Since this is a JSSink, the NewJSSink function does @sizeOf(JSSink) which includes @sizeOf(ArrayBufferSink).
            return this.buffer.cap;
        }

        fn handleWrote(this: *@This(), amount: usize) void {
            this.wrote += amount;
            if (this.buffer.len == 0) return;
            bun.assert(amount <= this.buffer.len - this.offset);
            this.offset += amount;
            if (this.offset == this.buffer.len) {
                this.offset = 0;
                this.buffer.len = 0;
            }
        }

        fn hasBackpressure(this: *const @This()) bool {
            return this.has_backpressure;
        }
        fn hasBackpressureAndIsTryEnd(this: *const @This()) bool {
            return this.has_backpressure and this.end_len != null;
        }
        fn sendWithoutAutoFlusher(this: *@This(), buf: []const u8) uws.ResponseWriteError!bool {
            this.ref();
            defer this.deref();
            if (this.write_failure) |failure| return failure;
            bun.assert(!this.done);
            const res = this.res orelse return error.ConnectionClosed;
            if (buf.len > std.math.maxInt(usize) - this.wrote) return error.OutOfMemory;
            res.clearOnWritable();
            if (this.end_len) |total| {
                const before = res.getWriteOffset();
                const success = try res.tryEnd(buf, total, false);
                if (this.res == null) return error.ConnectionClosed;
                if (success) {
                    this.has_backpressure = false;
                    this.res = null;
                    this.handleWrote(buf.len);
                } else {
                    const accepted = res.getWriteOffset() - before;
                    bun.assert(accepted <= buf.len);
                    this.handleWrote(@intCast(accepted));
                    this.has_backpressure = true;
                    res.onWritable(*@This(), onWritable, this);
                }
                return success;
            }
            // `buf` is released after this call, so this path needs uWebSockets' owned backpressure.
            if (this.requested_end) {
                try res.end(buf, false);
                this.res = null;
                this.has_backpressure = false;
            } else {
                this.has_backpressure = (try res.write(buf)) == .backpressure;
            }
            this.handleWrote(buf.len);
            return true;
        }

        fn send(this: *@This(), buf: []const u8) uws.ResponseWriteError!bool {
            this.unregisterAutoFlusher();
            return this.sendWithoutAutoFlusher(buf);
        }

        fn writeError(failure: uws.ResponseWriteError) Syscall.Error {
            return Syscall.Error.fromCode(switch (failure) {
                error.OutOfMemory => .NOMEM,
                error.ConnectionClosed => .CONNRESET,
                error.WriteFailed => .PIPE,
            }, .write);
        }

        fn failWrite(this: *@This(), failure: uws.ResponseWriteError) void {
            this.ref();
            defer this.deref();
            if (this.write_failure != null) return;
            this.write_failure = failure;
            const res = this.res;
            this.res = null;
            this.done = true;
            this.aborted = true;
            this.has_backpressure = false;
            this.unregisterAutoFlusher();
            if (failure != error.ConnectionClosed) if (res) |response| response.clearOnWritable();
            if (failure != error.ConnectionClosed) if (res) |response| uws.AnyResponse.init(response).forceClose();
            const err = writeError(failure);
            if (failure == error.OutOfMemory) this.pending_flush.outOfMemory() else this.pending_flush.rejectSystem(err);
            this.finalize();
            this.signal.close(err);
        }

        fn failedWrite(this: *@This(), failure: uws.ResponseWriteError) Result.Writable {
            const result: Result.Writable = if (failure == error.OutOfMemory) .out_of_memory else .{ .err = writeError(failure) };
            this.failWrite(failure);
            return result;
        }

        fn bindingFailure(this: *@This(), failure: uws.ResponseWriteError) bun.sys.Maybe(Sink.BindingOperation) {
            this.failWrite(failure);
            return if (failure == error.OutOfMemory)
                .{ .result = .{ .writable = .out_of_memory } }
            else
                .{ .err = writeError(failure) };
        }

        fn readableSlice(this: *@This()) []const u8 {
            return this.buffer.ptr[this.offset..this.buffer.len];
        }

        pub fn onWritable(this: *@This(), write_offset: u64, _: *UWSResponse) bool {
            this.ref();
            defer this.deref();
            // write_offset is the amount of data that was written not how much we need to write
            log("onWritable ({d})", .{write_offset});
            // onWritable reset backpressure state to allow flushing
            this.has_backpressure = false;
            if (this.aborted) {
                return false;
            }
            var total_written: usize = 0;

            // do not write more than available
            // if we do, it will cause this to be delayed until the next call, each time
            // TODO: should we break it in smaller chunks?
            const chunk = this.readableSlice();
            // if we have nothing to write, we are done
            if (chunk.len == 0) {
                if (this.done) {
                    this.resolvePendingFlush();
                    this.finalize();
                    this.signal.close(null);
                    return true;
                }
            } else {
                if (!(this.send(chunk) catch |err| {
                    this.failWrite(err);
                    return false;
                })) {
                    // if we were unable to send it, retry
                    return false;
                }
                total_written = chunk.len;

                if (this.requested_end) {
                    this.markDone();
                    this.resolvePendingFlush();
                    this.finalize();
                    this.signal.close(null);
                    return true;
                }
            }

            // flush the javascript promise from calling .flush()
            this.resolvePendingFlush();

            // pending_flush or callback could have caused another send()
            // so we check again if we should report readiness
            if (!this.done and !this.requested_end and !this.hasBackpressure()) {
                // no pending and total_written > 0
                if (total_written > 0 and this.readableSlice().len == 0) {
                    this.signal.ready(total_written, null);
                }
            }

            return true;
        }

        pub fn start(this: *@This(), stream_start: Start) bun.OOM!bun.sys.Maybe(void) {
            this.ref();
            defer this.deref();
            if (this.aborted or this.res == null or this.res.?.hasResponded()) {
                this.markDone();
                this.signal.close(null);
                return .success;
            }

            this.wrote = 0;
            this.wrote_at_start_of_flush = 0;
            this.resolvePendingFlush();

            if (this.buffer.cap == 0) {
                bun.assert(this.pooled_buffer == null);
                if (comptime FeatureFlags.http_buffer_pooling) {
                    if (WebCore.ByteListPool.getIfExists()) |pooled_node| {
                        this.pooled_buffer = pooled_node;
                        this.buffer = this.pooled_buffer.?.data;
                    }
                }
            }

            this.buffer.len = 0;

            switch (stream_start) {
                .chunk_size => |chunk_size| {
                    if (chunk_size > 0) {
                        this.highWaterMark = chunk_size;
                    }
                },
                else => {},
            }

            this.buffer.clearRetainingCapacity();
            try this.buffer.ensureTotalCapacityPrecise(this.allocator, this.highWaterMark);

            this.done = false;
            this.signal.start();
            log("start({d})", .{this.highWaterMark});
            return .success;
        }

        fn flushFromBindingNoWait(this: *@This()) bun.sys.Maybe(Sink.BindingOperation) {
            log("flushFromBindingNoWait", .{});
            const count = this.flushNoWait();
            if (this.write_failure) |failure| return this.bindingFailure(failure);
            return .{ .result = .{ .count = count } };
        }

        pub fn flushNoWait(this: *@This()) usize {
            this.ref();
            defer this.deref();
            if (this.hasBackpressureAndIsTryEnd() or this.done) {
                return 0;
            }

            const slice = this.readableSlice();
            if (slice.len == 0) {
                return 0;
            }

            const success = this.send(slice) catch |err| {
                this.failWrite(err);
                return 0;
            };
            if (success) {
                return slice.len;
            }

            return 0;
        }

        pub fn flushFromBinding(this: *@This(), wait: bool) bun.sys.Maybe(Sink.BindingOperation) {
            this.ref();
            defer this.deref();
            log("flushFromBinding({})", .{wait});
            if (this.write_failure) |failure| return this.bindingFailure(failure);
            this.unregisterAutoFlusher();

            if (!wait) {
                return this.flushFromBindingNoWait();
            }

            if (this.pending_flush.has()) {
                return .{ .result = .{ .pending_count = &this.pending_flush } };
            }

            if (this.buffer.len == 0 or this.done) {
                return .{ .result = .{ .resolved_count = 0 } };
            }

            this.wrote_at_start_of_flush = this.wrote;
            if (!this.hasBackpressureAndIsTryEnd()) {
                const slice = this.readableSlice();
                assert(slice.len > 0);
                const success = this.send(slice) catch |err| return this.bindingFailure(err);
                if (success) {
                    return .{ .result = .{ .resolved_count = slice.len } };
                }
            }
            return .{ .result = .{ .pending_count = &this.pending_flush } };
        }

        pub fn flush(this: *@This()) bun.sys.Maybe(void) {
            this.ref();
            defer this.deref();
            log("flush()", .{});
            this.unregisterAutoFlusher();

            if (!this.hasBackpressure() or this.done) {
                return .success;
            }

            if (this.res == null or this.res.?.hasResponded()) {
                this.markDone();
                this.signal.close(null);
            }

            return .success;
        }

        pub fn write(this: *@This(), data: Result) Result.Writable {
            this.ref();
            defer this.deref();
            if (this.write_failure) |failure| return this.failedWrite(failure);
            if (this.done or this.requested_end) {
                return .{ .owned = 0 };
            }

            const bytes = data.slice();
            const len = bytes.len;
            log("write({d})", .{bytes.len});

            if (this.buffer.len == 0 and len >= this.highWaterMark) {
                // fast path:
                // - large-ish chunk
                // - no backpressure
                if (this.send(bytes) catch |err| return this.failedWrite(err)) {
                    return .{ .owned = len };
                }

                _ = this.buffer.write(this.allocator, bytes) catch {
                    return this.failedWrite(error.OutOfMemory);
                };
            } else if (len >= this.highWaterMark -| this.buffer.len) {

                // TODO: attempt to write both in a corked buffer?
                _ = this.buffer.write(this.allocator, bytes) catch {
                    return this.failedWrite(error.OutOfMemory);
                };
                const slice = this.readableSlice();
                if (this.send(slice) catch |err| return this.failedWrite(err)) {
                    return .{ .owned = len };
                }
            } else {
                // queue the data wait until highWaterMark is reached or the auto flusher kicks in
                _ = this.buffer.write(this.allocator, bytes) catch {
                    return this.failedWrite(error.OutOfMemory);
                };
            }

            this.registerAutoFlusher();

            return .{ .owned = len };
        }
        pub const writeBytes = write;
        pub fn writeLatin1(this: *@This(), data: Result) Result.Writable {
            this.ref();
            defer this.deref();
            if (this.write_failure) |failure| return this.failedWrite(failure);
            if (this.done or this.requested_end) {
                return .{ .owned = 0 };
            }

            if (this.res == null or this.res.?.hasResponded()) {
                this.markDone();
                this.signal.close(null);
                return .{ .done = {} };
            }

            const bytes = data.slice();
            log("writeLatin1({d})", .{bytes.len});
            if (strings.isAllASCII(bytes)) return this.write(data);

            const written = this.buffer.writeLatin1(this.allocator, bytes) catch {
                return this.failedWrite(error.OutOfMemory);
            };
            const readable = this.readableSlice();
            if (readable.len >= this.highWaterMark or this.hasBackpressure()) {
                if (this.send(readable) catch |err| return this.failedWrite(err)) {
                    return .{ .owned = written };
                }
            }

            this.registerAutoFlusher();

            return .{ .owned = written };
        }
        pub fn writeUTF16(this: *@This(), data: Result) Result.Writable {
            this.ref();
            defer this.deref();
            if (this.write_failure) |failure| return this.failedWrite(failure);
            if (this.done or this.requested_end) {
                return .{ .owned = 0 };
            }

            if (this.res == null or this.res.?.hasResponded()) {
                this.markDone();
                this.signal.close(null);
                return .{ .done = {} };
            }

            const bytes = data.slice();

            log("writeUTF16({d})", .{bytes.len});

            // we must always buffer UTF-16
            // we assume the case of all-ascii UTF-16 string is pretty uncommon
            const written = this.buffer.writeUTF16(this.allocator, @alignCast(std.mem.bytesAsSlice(u16, bytes))) catch {
                return this.failedWrite(error.OutOfMemory);
            };

            const readable = this.readableSlice();
            if (readable.len >= this.highWaterMark or this.hasBackpressure()) {
                if (this.send(readable) catch |err| return this.failedWrite(err)) {
                    return .{ .owned = written };
                }
            }

            this.registerAutoFlusher();
            return .{ .owned = written };
        }

        pub fn markDone(this: *@This()) void {
            this.done = true;
            this.unregisterAutoFlusher();
        }

        // In this case, it's always an error
        pub fn end(this: *@This(), err: ?Syscall.Error) bun.sys.Maybe(void) {
            this.ref();
            defer this.deref();
            log("end({?f})", .{err});

            if (this.requested_end) {
                return .success;
            }

            if (this.done or this.res == null or this.res.?.hasResponded()) {
                this.markDone();
                this.finalize();
                this.signal.close(err);
                return .success;
            }

            this.requested_end = true;
            const readable = this.readableSlice();
            this.end_len = if (!this.res.?.state().isHttpWriteCalled()) readable.len else null;

            if (readable.len == 0) {
                this.markDone();
                // we do not close the stream here
                // this.res.endStream(false);
                this.finalize();
                this.signal.close(err);
                return .success;
            }
            return .success;
        }

        pub fn endFromBinding(this: *@This()) bun.sys.Maybe(Sink.BindingOperation) {
            this.ref();
            defer this.deref();
            if (this.write_failure) |failure| return this.bindingFailure(failure);
            log("endFromBinding()", .{});

            if (this.requested_end) {
                return .{ .result = .{ .count = 0 } };
            }

            if (this.done or this.res == null or this.res.?.hasResponded()) {
                this.requested_end = true;
                this.markDone();
                this.finalize();
                this.signal.close(null);
                return .{ .result = .{ .count = 0 } };
            }

            this.requested_end = true;
            if (!this.pending_flush.has()) this.wrote_at_start_of_flush = this.wrote;
            const readable = this.readableSlice();
            this.end_len = if (!this.res.?.state().isHttpWriteCalled()) readable.len else null;

            if (readable.len > 0) {
                if (!(this.send(readable) catch |err| return this.bindingFailure(err))) {
                    return .{ .result = .{ .pending_count = &this.pending_flush } };
                }
            } else {
                if (this.res) |res| {
                    res.end("", false) catch |err| return this.bindingFailure(err);
                    this.res = null;
                }
            }

            this.markDone();
            this.resolvePendingFlush();
            this.finalize();
            const wrote = this.wrote;
            this.signal.close(null);
            return .{ .result = .{ .count = wrote } };
        }

        pub fn sink(this: *@This()) Sink {
            return Sink.init(this);
        }

        pub fn abort(this: *@This()) void {
            this.ref();
            defer this.deref();
            log("onAborted()", .{});
            if (this.aborted) return;
            this.done = true;
            this.res = null;
            this.aborted = true;
            this.write_failure = error.ConnectionClosed;
            this.unregisterAutoFlusher();
            const failure = Syscall.Error.fromCode(.CONNRESET, .write);
            this.pending_flush.rejectSystem(failure);
            this.finalize();
            this.signal.close(failure);
        }

        fn unregisterAutoFlusher(this: *@This()) void {
            if (this.auto_flusher.isRegistered())
                AutoFlusherEngine.unregisterUnchecked(@This(), this, &this.auto_flusher, this.globalThis.bunVM());
        }

        fn registerAutoFlusher(this: *@This()) void {
            const res = this.res orelse return;
            // if we enqueue data we should reset the timeout
            res.resetTimeout();
            if (!this.auto_flusher.isRegistered())
                AutoFlusherEngine.registerUnchecked(@This(), this, &this.auto_flusher, this.globalThis.bunVM());
        }

        pub fn onAutoFlush(this: *@This()) bool {
            this.ref();
            defer this.deref();
            log("onAutoFlush()", .{});
            if (this.done) {
                return false;
            }

            const readable = this.readableSlice();

            if ((this.hasBackpressureAndIsTryEnd()) or readable.len == 0) {
                return false;
            }

            if (!(this.sendWithoutAutoFlusher(readable) catch |err| {
                this.failWrite(err);
                return false;
            })) {
                return true;
            }
            return false;
        }

        pub fn destroy(this: *@This()) void {
            log("destroy()", .{});
            this.deref();
        }

        fn deinit(this: *@This()) void {
            if (this.res) |res| res.clearOnWritable();
            this.pending_flush.deinit();
            this.buffer.deinit(this.allocator);
            this.unregisterAutoFlusher();
            this.allocator.destroy(this);
        }

        pub fn finalize(this: *@This()) void {
            this.ref();
            defer this.deref();
            log("finalize()", .{});
            this.unregisterAutoFlusher();
            if (this.res) |res| res.clearOnWritable();
            if (!this.done) {
                if (this.res != null) {
                    // Finalization cannot keep the sink's borrowed write callback
                    // alive. Transfer any remaining bytes to native backpressure.
                    this.requested_end = true;
                    this.end_len = null;
                    _ = this.sendWithoutAutoFlusher(this.readableSlice()) catch |err| return this.failWrite(err);
                }
                this.markDone();
                this.resolvePendingFlush();
            }

            if (comptime !FeatureFlags.http_buffer_pooling) {
                assert(this.pooled_buffer == null);
            }

            if (this.pooled_buffer) |pooled| {
                this.buffer.len = 0;
                if (this.buffer.cap > 64 * 1024) {
                    this.buffer.clearAndFree(bun.default_allocator);
                }
                pooled.data = this.buffer;

                this.buffer = bun.ByteList.empty;
                this.pooled_buffer = null;
                pooled.release();
            } else if (this.buffer.cap == 0) {
                //
            } else if (FeatureFlags.http_buffer_pooling and !WebCore.ByteListPool.full()) {
                const buffer = this.buffer;
                this.buffer = bun.ByteList.empty;
                WebCore.ByteListPool.push(this.allocator, buffer);
            } else {
                // Don't release this buffer until destroy() is called
                this.buffer.len = 0;
            }
        }

        pub fn releaseBindingRef(this: *@This()) void {
            this.finalize();
            this.deref();
        }

        pub fn resolvePendingFlush(this: *@This()) void {
            if (this.pending_flush.has()) {
                log("resolvePendingFlush()", .{});

                const count = this.wrote -| this.wrote_at_start_of_flush;
                this.wrote_at_start_of_flush = this.wrote;
                this.pending_flush.resolve(count);
            }
        }

        pub const name = if (http3) "H3ResponseSink" else if (ssl) "HTTPSResponseSink" else "HTTPResponseSink";
        pub const JSSink = Sink.JSSink(@This(), name, if (http3) 7 else if (ssl) 5 else 4);
    };
}
pub const HTTPSResponseSink = HTTPServerWritable(true, false);
pub const HTTPResponseSink = HTTPServerWritable(false, false);
pub const H3ResponseSink = HTTPServerWritable(true, true);
pub const NetworkSink = struct {
    const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;

    const CompletionResult = union(enum) {
        success,
        out_of_memory,
        failure: bun.S3.completions.OwnedS3Error,
    };

    ref_count: RefCount = .init(),
    task: ?*bun.S3.MultiPartUpload = null,
    completion_result: ?CompletionResult = null,
    signal: Signal = .{},
    highWaterMark: Blob.SizeType = 2048,
    pending_flush: SinkPending = .{},
    unreported_flushed_bytes: usize = 0,
    pending_end: SinkPending = .{},
    ended: bool = false,
    done: bool = false,
    cancel: bool = false,

    const log = bun.Output.scoped(.NetworkSink, .visible);

    pub fn create() bun.OOM!*@This() {
        const this = try bun.default_allocator.create(@This());
        this.* = .{};
        return this;
    }

    pub fn complete(result: bun.S3.S3UploadResult, opaque_sink: bun.S3.MultiPartUpload.CallbackContext) void {
        const this = opaque_sink.get(*@This());
        defer this.deref();
        defer this.detachWritable();
        bun.assert(this.completion_result == null);
        this.completion_result = switch (result) {
            .success => .success,
            .out_of_memory => .out_of_memory,
            .failure => |err| if (bun.S3.completions.OwnedS3Error.init(err, this.path())) |owned|
                .{ .failure = owned }
            else |_|
                .out_of_memory,
        };
        this.ended = true;
        this.done = true;
        this.settle(.flush);
        this.settle(.end);
        this.closeSignal(null);
    }

    fn takeFlushedBytes(this: *@This()) usize {
        const count = this.unreported_flushed_bytes;
        this.unreported_flushed_bytes = 0;
        return count;
    }

    fn settle(this: *@This(), comptime operation: enum { flush, end }) void {
        const pending = switch (operation) {
            .flush => &this.pending_flush,
            .end => &this.pending_end,
        };
        if (!pending.has()) return;
        switch (this.completion_result orelse return) {
            .success => pending.resolve(if (operation == .flush) this.takeFlushedBytes() else 0),
            .out_of_memory => pending.outOfMemory(),
            .failure => |err| pending.rejectOwnedS3(&err),
        }
    }

    fn closeSignal(this: *@This(), err: ?Syscall.Error) void {
        var signal = this.signal;
        this.signal.clear();
        signal.close(err);
    }

    pub fn path(this: *@This()) ?[]const u8 {
        if (this.task) |task| {
            return task.path;
        }
        return null;
    }

    pub fn start(this: *@This(), stream_start: Start) bun.sys.Maybe(void) {
        if (this.ended) {
            return .success;
        }

        switch (stream_start) {
            .chunk_size => |chunk_size| {
                if (chunk_size > 0) {
                    this.highWaterMark = chunk_size;
                }
            },
            else => {},
        }
        this.ended = false;
        this.signal.start();
        return .success;
    }

    pub fn connect(this: *@This(), signal: Signal) void {
        this.signal = signal;
    }
    pub fn sink(this: *@This()) Sink {
        return Sink.init(this);
    }
    pub fn finalize(this: *@This()) void {
        this.signal.clear();
        if (this.task) |task| {
            if (!task.activated) {
                this.detachWritable();
            } else if (!this.ended and task.state != .finished) {
                task.fail(.{ .code = "AbortError", .message = "Upload was aborted" });
            }
        }
        this.deref();
    }
    pub const releaseBindingRef = finalize;

    fn deinit(this: *@This()) void {
        bun.assert(this.task == null);
        this.pending_flush.deinit();
        this.pending_end.deinit();
        if (this.completion_result) |*result| {
            if (result.* == .failure) result.failure.deinit();
        }
        bun.destroy(this);
    }

    fn detachWritable(this: *@This()) void {
        if (this.task) |task| {
            this.task = null;
            task.deref();
        }
    }

    pub fn onWritable(task: *bun.S3.MultiPartUpload, capture: bun.S3.MultiPartUpload.CallbackContext, flushed: u64) void {
        const this = capture.get(*@This());
        log("onWritable flushed: {d} state: {s}", .{ flushed, @tagName(task.state) });
        this.unreported_flushed_bytes += @intCast(flushed);
        if (this.pending_flush.has()) this.pending_flush.resolve(this.takeFlushedBytes());
    }

    pub fn flush(_: *@This()) bun.sys.Maybe(void) {
        return .success;
    }

    pub fn flushFromBinding(this: *@This(), context: anytype, _: bool) bun.JSError!SinkPending.PromiseResult {
        if (this.pending_flush.has()) {
            return this.pending_flush.existingPromiseResult(context);
        }
        if (this.completion_result != null) {
            const promise = try this.pending_flush.promiseResult(context);
            this.settle(.flush);
            return promise;
        }
        if (this.unreported_flushed_bytes > 0) {
            const promise = try context.promiseResolvedAs(SinkPending.PromiseResult, this.unreported_flushed_bytes);
            this.unreported_flushed_bytes = 0;
            return promise;
        }
        if (this.task) |task| {
            if (!task.isQueueEmpty()) {
                return this.pending_flush.promiseResult(context);
            }
        }
        return context.promiseResolvedAs(SinkPending.PromiseResult, @as(usize, 0));
    }
    pub fn abort(this: *@This()) void {
        this.ref();
        defer this.deref();
        this.ended = true;
        this.done = true;
        this.closeSignal(null);
        this.cancel = true;
        if (this.task) |task| {
            if (task.activated and task.state != .finished) {
                task.fail(.{ .code = "AbortError", .message = "Upload was aborted" });
            }
        }
    }

    pub fn write(this: *@This(), data: Result) Result.Writable {
        this.ref();
        defer this.deref();
        if (this.ended) {
            return .{ .owned = 0 };
        }
        const bytes = data.slice();
        const len = bytes.len;

        if (this.task) |task| {
            _ = task.writeBytes(bytes, false) catch {
                task.failOutOfMemory();
                return .out_of_memory;
            };
        }
        return .{ .owned = len };
    }

    pub const writeBytes = write;
    pub fn writeLatin1(this: *@This(), data: Result) Result.Writable {
        this.ref();
        defer this.deref();
        if (this.ended) {
            return .{ .owned = 0 };
        }

        const bytes = data.slice();
        const len = bytes.len;

        if (this.task) |task| {
            _ = task.writeLatin1(bytes, false) catch {
                task.failOutOfMemory();
                return .out_of_memory;
            };
        }
        return .{ .owned = len };
    }
    pub fn writeUTF16(this: *@This(), data: Result) Result.Writable {
        this.ref();
        defer this.deref();
        if (this.ended) {
            return .{ .owned = 0 };
        }
        const bytes = data.slice();
        if (this.task) |task| {
            // we must always buffer UTF-16
            // we assume the case of all-ascii UTF-16 string is pretty uncommon
            _ = task.writeUTF16(bytes, false) catch {
                task.failOutOfMemory();
                return .out_of_memory;
            };
        }

        return .{ .owned = bytes.len };
    }

    pub fn end(this: *@This(), err: ?Syscall.Error) bun.sys.Maybe(void) {
        this.endChecked(err) catch return .{ .err = Syscall.Error.fromCode(.NOMEM, .write) };
        return .success;
    }

    pub fn endChecked(this: *@This(), err: ?Syscall.Error) bun.OOM!void {
        this.ref();
        defer this.deref();
        if (this.ended) return;
        this.ended = true;
        if (this.task) |task| {
            _ = task.writeBytes("", true) catch |allocation_error| {
                task.failOutOfMemory();
                this.closeSignal(err);
                return allocation_error;
            };
        }
        this.closeSignal(err);
    }

    pub fn endFromBinding(this: *@This(), context: anytype) bun.JSError!bun.bindgen.Return(@TypeOf(context)) {
        this.ref();
        defer this.deref();
        if (this.completion_result) |result| {
            if (result == .success) return .{ .count = 0 };
        }
        const promise = try this.pending_end.promiseResult(context);
        if (this.completion_result != null) {
            this.settle(.end);
        } else {
            this.endChecked(null) catch {
                this.settle(.end);
            };
        }
        return .{ .pending = promise };
    }
    pub fn memoryCost(this: *const @This()) usize {
        var size: usize = if (this.task) |task| task.buffered.memoryCost() + task.metadata.len else 0;
        if (this.completion_result) |result| {
            if (result == .failure) {
                size += result.failure.memoryCost();
            }
        }
        return size;
    }

    pub const name = "NetworkSink";
    pub const JSSink = Sink.JSSink(@This(), name, 6);
};

pub const ReadResult = union(enum) {
    pending: void,
    err: Syscall.Error,
    done: void,
    read: []u8,

    pub fn toStream(this: ReadResult, pending: *Result.Pending, buf: []u8, close_on_empty: bool) Result {
        return toStreamWithIsDone(
            this,
            pending,
            buf,
            close_on_empty,
            false,
        );
    }
    pub fn toStreamWithIsDone(this: ReadResult, pending: *Result.Pending, buf: []u8, close_on_empty: bool, is_done: bool) Result {
        return switch (this) {
            .pending => .{ .pending = pending },
            .err => .{ .err = .fromSysError(this.err) },
            .done => .{ .done = {} },
            .read => |slice| brk: {
                const owned = slice.ptr != buf.ptr;
                const done = is_done or (close_on_empty and slice.len == 0);

                break :brk if (owned and done)
                    Result{ .owned_and_done = bun.ByteList.fromOwnedSlice(slice) }
                else if (owned)
                    Result{ .owned = bun.ByteList.fromOwnedSlice(slice) }
                else if (done)
                    Result{ .into_array_and_done = .{ .len = slice.len } }
                else
                    Result{ .into_array = .{ .len = slice.len } };
            },
        };
    }
};

const std = @import("std");

const bun = @import("bun");
const FeatureFlags = bun.FeatureFlags;
const Output = bun.Output;
const Syscall = bun.sys;
const assert = bun.assert;
const default_allocator = bun.default_allocator;
const strings = bun.strings;
const uws = bun.uws;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;

const WebCore = jsc.WebCore;
const AutoFlusher = WebCore.AutoFlusher;
const AutoFlusherEngine = WebCore.AutoFlusherEngine;
const FileSink = WebCore.FileSink;
const Response = jsc.WebCore.Response;
const Sink = WebCore.Sink;
const SinkPending = @import("./SinkPending.zig");
const ReadablePending = @import("./ReadablePending.zig");

const Blob = bun.webcore.Blob;
