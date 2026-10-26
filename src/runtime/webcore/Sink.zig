const Sink = @This();

ptr: *anyopaque,
vtable: VTable,
status: Status = Status.closed,
used: bool = false,

pub const ArrayBufferSink = @import("./ArrayBufferSink.zig");

pub const Status = enum {
    ready,
    closed,
};

pub const Data = union(enum) {
    utf16: streams.Result,
    latin1: streams.Result,
    bytes: streams.Result,
};

pub const BindingBuffer = struct {
    bytes: bindgen.OwnedBytes,
    as_uint8_array: bool,
};

pub const BindingOperation = union(enum) {
    writable: streams.Result.Writable,
    count: usize,
    pending_count: *SinkPending,
    count_promise: SinkPending.OwnedPromise,
    resolved_count: usize,
    undefined,
    buffer: BindingBuffer,

    pub fn deinit(this: *BindingOperation) void {
        if (this.* == .buffer) this.buffer.bytes.deinit();
        if (this.* == .count_promise) this.count_promise.deinit();
        this.* = .undefined;
    }
};

pub const PendingCountPromiseResult = SinkPending.PromiseResult;
pub const PendingCountPromise = SinkPending.OwnedPromise;

pub fn initWithType(comptime Type: type, handler: *Type) Sink {
    return .{
        .ptr = handler,
        .vtable = VTable.wrap(Type),
        .status = .ready,
        .used = false,
    };
}

pub fn init(handler: anytype) Sink {
    return initWithType(std.meta.Child(@TypeOf(handler)), handler);
}

pub const VTable = struct {
    pub const WriteUTF16Fn = *const (fn (this: *anyopaque, data: streams.Result) streams.Result.Writable);
    pub const WriteUTF8Fn = *const (fn (this: *anyopaque, data: streams.Result) streams.Result.Writable);
    pub const WriteLatin1Fn = *const (fn (this: *anyopaque, data: streams.Result) streams.Result.Writable);
    pub const EndFn = *const (fn (this: *anyopaque, err: ?Syscall.Error) bun.sys.Maybe(void));
    pub const ConnectFn = *const (fn (this: *anyopaque, signal: streams.Signal) bun.sys.Maybe(void));

    connect: ConnectFn,
    write: WriteUTF8Fn,
    writeLatin1: WriteLatin1Fn,
    writeUTF16: WriteUTF16Fn,
    end: EndFn,

    pub fn wrap(
        comptime Wrapped: type,
    ) VTable {
        const Functions = struct {
            pub fn onWrite(this: *anyopaque, data: streams.Result) streams.Result.Writable {
                return Wrapped.write(@as(*Wrapped, @ptrCast(@alignCast(this))), data);
            }
            pub fn onConnect(this: *anyopaque, signal: streams.Signal) bun.sys.Maybe(void) {
                return Wrapped.connect(@as(*Wrapped, @ptrCast(@alignCast(this))), signal);
            }
            pub fn onWriteLatin1(this: *anyopaque, data: streams.Result) streams.Result.Writable {
                return Wrapped.writeLatin1(@as(*Wrapped, @ptrCast(@alignCast(this))), data);
            }
            pub fn onWriteUTF16(this: *anyopaque, data: streams.Result) streams.Result.Writable {
                return Wrapped.writeUTF16(@as(*Wrapped, @ptrCast(@alignCast(this))), data);
            }
            pub fn onEnd(this: *anyopaque, err: ?Syscall.Error) bun.sys.Maybe(void) {
                return Wrapped.end(@as(*Wrapped, @ptrCast(@alignCast(this))), err);
            }
        };

        return VTable{
            .write = Functions.onWrite,
            .writeLatin1 = Functions.onWriteLatin1,
            .writeUTF16 = Functions.onWriteUTF16,
            .end = Functions.onEnd,
            .connect = Functions.onConnect,
        };
    }
};

pub fn end(this: *Sink, err: ?Syscall.Error) bun.sys.Maybe(void) {
    if (this.status == .closed) {
        return .success;
    }

    this.status = .closed;
    return this.vtable.end(this.ptr, err);
}

pub fn writeLatin1(this: *Sink, data: streams.Result) streams.Result.Writable {
    if (this.status == .closed) {
        return .{ .done = {} };
    }

    const res = this.vtable.writeLatin1(this.ptr, data);
    this.status = if ((res.isDone()) or this.status == .closed)
        Status.closed
    else
        Status.ready;
    this.used = true;
    return res;
}

pub fn writeBytes(this: *Sink, data: streams.Result) streams.Result.Writable {
    if (this.status == .closed) {
        return .{ .done = {} };
    }

    const res = this.vtable.write(this.ptr, data);
    this.status = if ((res.isDone()) or this.status == .closed)
        Status.closed
    else
        Status.ready;
    this.used = true;
    return res;
}

pub fn writeUTF16(this: *Sink, data: streams.Result) streams.Result.Writable {
    if (this.status == .closed) {
        return .{ .done = {} };
    }

    const res = this.vtable.writeUTF16(this.ptr, data);
    this.status = if ((res.isDone()) or this.status == .closed)
        Status.closed
    else
        Status.ready;
    this.used = true;
    return res;
}

pub fn write(this: *Sink, data: Data) streams.Result.Writable {
    switch (data) {
        .utf16 => |str| {
            return this.writeUTF16(str);
        },
        .latin1 => |str| {
            return this.writeLatin1(str);
        },
        .bytes => |bytes| {
            return this.writeBytes(bytes);
        },
    }
}

pub fn JSSink(
    comptime SinkType: type,
    comptime abi_name: []const u8,
    comptime sink_id: u8,
) type {
    return struct {
        const API = @This();
        const BindingModule = bindgen.Module("JSSink");
        const StartDirectStreamSchema = BindingModule.function("startDirectStream");
        const MainSchema = BindingModule.class(abi_name);
        pub const Ref = bindgen.ClassRef(MainSchema);
        const ControllerSchema = BindingModule.class("Readable" ++ abi_name ++ "Controller");
        pub const ReadableStreamHandle = bindgen.WeakValueHandle(StartDirectStreamSchema.args[0].ArgumentType);
        pub const PullCallback = bindgen.Callback(StartDirectStreamSchema.args[1].ArgumentType);
        pub const CloseCallback = bindgen.Callback(StartDirectStreamSchema.args[2].ArgumentType);
        const AssignToStreamSchema = bindgen.Module("readable_streams").engineShim("assignTo" ++ abi_name ++ "Stream");
        pub const AssignToStreamResult = bindgen.OwnedBrandedValue(AssignToStreamSchema.ReturnType.child);

        const Action = enum { flush, end, write };
        const NativeOwner = bindgen.RefNative(SinkType, .vm);

        fn finalizeOwner(owner: *NativeOwner) void {
            if (owner.getOptional() != null) SinkType.releaseBindingRef(owner.take());
        }

        pub const Main = struct {
            bindgen_state: bindgen.ClassState = .{},
            native: NativeOwner,
            js_ref_count: u32 = 1,

            const This = @This();
            pub const Binding = bindgen.Class(MainSchema, This);
            const ConstructorSchema = MainSchema.constructor();
            const CloseSchema = MainSchema.member("close");
            const FlushSchema = MainSchema.member("flush");
            const EndSchema = MainSchema.member("end");
            const StartSchema = MainSchema.member("start");
            const WriteSchema = MainSchema.member("write");
            const RefSchema = MainSchema.member("ref");
            const UnrefSchema = MainSchema.member("unref");
            const GetFdSchema = MainSchema.member("_getFd");
            const SinkIdSchema = MainSchema.member("sinkId");

            pub fn construct(
                _: bindgen.CallContext(ConstructorSchema),
                _: bindgen.Args(ConstructorSchema),
            ) bun.JSError!*This {
                return create();
            }

            pub fn call(
                context: bindgen.CallContext(MainSchema.constructorCall()),
                _: bindgen.Args(MainSchema.constructorCall()),
            ) bun.JSError!bindgen.Return(MainSchema.constructorCall()) {
                return Binding.adoptResult(try create(), context);
            }

            fn create() bun.OOM!*This {
                const native = try bun.default_allocator.create(SinkType);
                native.construct(bun.default_allocator);
                errdefer native.releaseBindingRef();
                const adapter = try bun.default_allocator.create(This);
                adapter.* = .{ .native = .adopt(native) };
                return adapter;
            }

            fn resultFromBinding(
                this: *This,
                comptime operation: Action,
                context: anytype,
                args: anytype,
            ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
                return switch (operation) {
                    .flush => flushNative(
                        try this.requireNative(context),
                        context,
                        args.wait orelse false,
                    ),
                    .end => endNative(try this.requireNative(context), context),
                    .write => writeNative(try this.requireNative(context), context, args.chunk),
                };
            }

            pub fn close(
                this: *This,
                context: bindgen.CallContext(CloseSchema),
                _: bindgen.Args(CloseSchema),
            ) bindgen.CallError(CloseSchema)!void {
                var native = this.takeNative();
                defer finalizeOwner(&native);
                try closeNative(native.getOptional() orelse return, context);
            }

            pub fn flush(
                this: *This,
                context: bindgen.CallContext(FlushSchema),
                args: bindgen.Args(FlushSchema),
            ) bindgen.CallError(FlushSchema)!bindgen.Return(FlushSchema) {
                return this.resultFromBinding(.flush, context, args);
            }

            pub fn end(
                this: *This,
                context: bindgen.CallContext(EndSchema),
                args: bindgen.Args(EndSchema),
            ) bindgen.CallError(EndSchema)!bindgen.Return(EndSchema) {
                return this.resultFromBinding(.end, context, args);
            }

            pub fn start(
                this: *This,
                context: bindgen.CallContext(StartSchema),
                args: bindgen.Args(StartSchema),
            ) bindgen.CallError(StartSchema)!bindgen.Return(StartSchema) {
                return startNative(
                    try this.requireNative(context),
                    context,
                    args.options,
                );
            }

            pub fn write(
                this: *This,
                context: bindgen.CallContext(WriteSchema),
                args: bindgen.Args(WriteSchema),
            ) bindgen.CallError(WriteSchema)!bindgen.Return(WriteSchema) {
                return this.resultFromBinding(.write, context, args);
            }

            pub fn ref(
                this: *This,
                _: bindgen.CallContext(RefSchema),
                _: bindgen.Args(RefSchema),
            ) bun.JSError!void {
                const native = this.nativePtr() orelse return;
                this.js_ref_count +|= 1;
                if (this.js_ref_count == 1 and comptime @hasDecl(SinkType, "updateRef")) {
                    native.updateRef(true);
                }
            }

            pub fn unref(
                this: *This,
                _: bindgen.CallContext(UnrefSchema),
                _: bindgen.Args(UnrefSchema),
            ) bun.JSError!void {
                const native = this.nativePtr() orelse return;
                this.js_ref_count -|= 1;
                if (this.js_ref_count == 0 and comptime @hasDecl(SinkType, "updateRef")) {
                    native.updateRef(false);
                }
            }

            pub fn getFd(
                this: *This,
                _: bindgen.CallContext(GetFdSchema),
                _: bindgen.Args(GetFdSchema),
            ) bun.JSError!?i32 {
                const native = this.nativePtr() orelse return null;
                if (comptime @hasDecl(SinkType, "getFd")) return native.getFd();
                return null;
            }

            pub fn sinkId(
                _: *This,
                _: bindgen.CallContext(SinkIdSchema),
                _: bindgen.Args(SinkIdSchema),
            ) bun.JSError!u8 {
                return sink_id;
            }

            pub fn memoryUsage(this: *const This, _: bindgen.MemoryUsageContext(.vm)) usize {
                const native = this.nativePtr() orelse return @sizeOf(This);
                return @sizeOf(This) + @sizeOf(SinkType) + SinkType.memoryCost(native);
            }

            pub fn hasPendingActivity(this: *const This) bool {
                const native = this.nativePtr() orelse return false;
                if (comptime @hasDecl(SinkType, "hasPendingActivity")) return native.hasPendingActivity();
                return false;
            }

            pub fn destroy(this: *This) void {
                var native = this.takeNative();
                defer finalizeOwner(&native);
                bun.destroy(this);
            }

            fn nativePtr(this: *const This) ?*SinkType {
                return this.native.getOptional();
            }

            fn takeNative(this: *This) NativeOwner {
                const native = this.native;
                this.native = .empty;
                return native;
            }

            fn requireNative(this: *const This, context: anytype) bun.bindgen.CallError(@TypeOf(context))!*SinkType {
                return this.nativePtr() orelse context.fail(.detached, {});
            }
        };

        pub const Controller = struct {
            bindgen_state: bindgen.ClassState = .{},
            native: NativeOwner,
            wrapper: bindgen.ClassWrapperHandle(ControllerSchema, .weak) = .empty,
            readable_stream: ReadableStreamHandle = .empty,
            on_pull: ?PullCallback = null,
            on_close: ?CloseCallback = null,

            const This = @This();
            pub const Binding = bindgen.Class(ControllerSchema, This);
            const CloseSchema = ControllerSchema.member("close");
            const FlushSchema = ControllerSchema.member("flush");
            const EndSchema = ControllerSchema.member("end");
            const StartSchema = ControllerSchema.member("start");
            const WriteSchema = ControllerSchema.member("write");
            const SinkIdSchema = ControllerSchema.member("sinkId");
            fn resultFromBinding(
                this: *This,
                comptime operation: Action,
                context: anytype,
                args: anytype,
            ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
                return switch (operation) {
                    .flush => flushNative(
                        try this.requireNative(context),
                        context,
                        args.wait orelse false,
                    ),
                    .end => result: {
                        var native = this.detach();
                        defer native.deinit();
                        break :result if (native.getOptional()) |pointer|
                            endNative(pointer, context)
                        else
                            .{ .undefined = true };
                    },
                    .write => writeNative(try this.requireNative(context), context, args.chunk),
                };
            }

            pub fn close(
                this: *This,
                context: bindgen.CallContext(CloseSchema),
                _: bindgen.Args(CloseSchema),
            ) bindgen.CallError(CloseSchema)!void {
                var native = this.detach();
                defer finalizeOwner(&native);
                try closeNative(native.getOptional() orelse return, context);
            }

            pub fn flush(
                this: *This,
                context: bindgen.CallContext(FlushSchema),
                args: bindgen.Args(FlushSchema),
            ) bindgen.CallError(FlushSchema)!bindgen.Return(FlushSchema) {
                return this.resultFromBinding(.flush, context, args);
            }

            pub fn end(
                this: *This,
                context: bindgen.CallContext(EndSchema),
                args: bindgen.Args(EndSchema),
            ) bindgen.CallError(EndSchema)!bindgen.Return(EndSchema) {
                return this.resultFromBinding(.end, context, args);
            }

            pub fn start(
                this: *This,
                context: bindgen.CallContext(StartSchema),
                args: bindgen.Args(StartSchema),
            ) bindgen.CallError(StartSchema)!bindgen.Return(StartSchema) {
                return startNative(
                    try this.requireNative(context),
                    context,
                    args.options,
                );
            }

            pub fn write(
                this: *This,
                context: bindgen.CallContext(WriteSchema),
                args: bindgen.Args(WriteSchema),
            ) bindgen.CallError(WriteSchema)!bindgen.Return(WriteSchema) {
                return this.resultFromBinding(.write, context, args);
            }

            pub fn sinkId(
                _: *This,
                _: bindgen.CallContext(SinkIdSchema),
                _: bindgen.Args(SinkIdSchema),
            ) bun.JSError!u8 {
                return sink_id;
            }

            pub fn memoryUsage(this: *const This, _: bindgen.MemoryUsageContext(.vm)) usize {
                const native = this.nativePtr() orelse return @sizeOf(This);
                return @sizeOf(This) + @sizeOf(SinkType) + SinkType.memoryCost(native);
            }

            pub fn onClose(this: *This, _: ?Syscall.Error) void {
                var native = this.detach();
                finalizeOwner(&native);
            }

            pub fn onReady(this: *This, amount: ?usize, offset: ?usize) void {
                const callback = if (this.on_pull) |*value| value else return;
                var invocation: PullCallback.Invocation = undefined;
                callback.beginInvocation(&invocation);
                defer invocation.deinit();
                var controller = (this.wrapper.toOwned() catch |err| return invocation.reportActiveException(err)) orelse return;
                defer controller.deinit();
                const ControllerArgument = @FieldType(bindgen.Args(StartDirectStreamSchema.args[1].ArgumentType), "controller");
                const member_name = comptime member: {
                    const info = @typeInfo(ControllerArgument).@"union";
                    for (info.field_names, info.field_types) |name, Value| {
                        if (Value == bindgen.ClassRefView(ControllerSchema)) break :member name;
                    }
                    @compileError("direct stream pull callback does not declare this controller");
                };
                invocation.dispatch(.{
                    .controller = @unionInit(ControllerArgument, member_name, controller.operand(&invocation)),
                    .amount = amount,
                    .offset = offset,
                });
            }

            pub fn onStart(_: *This) void {}

            pub fn destroy(this: *This) void {
                var native = this.takeNative();
                defer finalizeOwner(&native);
                if (native.getOptional()) |ptr| this.clearSignal(ptr);
                this.wrapper.deinit();
                this.readable_stream.deinit();
                this.deinitCallbacks();
                bun.destroy(this);
            }

            fn configure(
                this: *This,
                wrapper: bindgen.ClassRefView(ControllerSchema),
                readable_stream: *ReadableStreamHandle,
                on_pull: *?PullCallback,
                on_close: *?CloseCallback,
            ) bun.JSError!void {
                const replacement = try Binding.WeakWrapper.initView(wrapper);
                this.wrapper.deinit();
                this.wrapper = replacement;
                this.readable_stream.deinit();
                this.readable_stream = readable_stream.take();
                this.deinitCallbacks();
                if (on_pull.*) |*callback| this.on_pull = callback.take();
                if (on_close.*) |*callback| this.on_close = callback.take();
            }

            fn detach(this: *This) NativeOwner {
                const native = this.takeNative();
                if (native.getOptional()) |ptr| this.clearSignal(ptr);

                var on_pull = bun.take(&this.on_pull);
                defer if (on_pull) |*callback| callback.deinit();
                var on_close = bun.take(&this.on_close);
                defer if (on_close) |*callback| callback.deinit();
                var wrapper = this.wrapper;
                this.wrapper = .empty;
                defer wrapper.deinit();
                var readable_stream = this.readable_stream;
                this.readable_stream = .{};
                defer readable_stream.deinit();
                if (on_close) |*callback| {
                    const alive = wrapper.isAlive() catch |err| {
                        var invocation: CloseCallback.Invocation = undefined;
                        callback.beginInvocation(&invocation);
                        defer invocation.deinit();
                        invocation.reportActiveException(err);
                        return native;
                    };
                    if (alive) {
                        var invocation: CloseCallback.Invocation = undefined;
                        callback.beginInvocation(&invocation);
                        defer invocation.deinit();
                        var stream = readable_stream.toOwned() catch |err| {
                            invocation.reportActiveException(err);
                            return native;
                        };
                        defer if (stream) |*value| value.deinit();
                        invocation.dispatch(.{ .stream = if (stream) |*value| value.operand(&invocation) else null, .reason = false });
                    }
                }
                return native;
            }

            fn deinitCallbacks(this: *This) void {
                if (this.on_pull) |*callback| callback.deinit();
                if (this.on_close) |*callback| callback.deinit();
                this.on_pull = null;
                this.on_close = null;
            }

            fn clearSignal(this: *This, native: *SinkType) void {
                if (comptime @hasField(SinkType, "signal")) {
                    if (native.signal.matches(this)) {
                        native.signal.clear();
                    }
                }
            }

            fn nativePtr(this: *const This) ?*SinkType {
                return this.native.getOptional();
            }

            fn takeNative(this: *This) NativeOwner {
                const native = this.native;
                this.native = .empty;
                return native;
            }

            fn requireNative(this: *const This, context: anytype) bun.bindgen.CallError(@TypeOf(context))!*SinkType {
                return this.nativePtr() orelse context.fail(.detached, {});
            }
        };

        pub fn createRef(
            global: *JSGlobalObject,
            native: *SinkType,
        ) bun.JSError!Ref {
            const adapter = bun.default_allocator.create(Main) catch |err| {
                native.releaseBindingRef();
                return err;
            };
            adapter.* = .{
                .native = .adopt(native),
            };
            return Main.Binding.adoptNativeRef(adapter, global);
        }

        pub fn createResult(
            context: anytype,
            native: *SinkType,
        ) bun.JSError!bindgen.ClassRef(MainSchema) {
            const adapter = bun.default_allocator.create(Main) catch |err| {
                native.releaseBindingRef();
                return err;
            };
            adapter.* = .{
                .native = .adopt(native),
            };
            return Main.Binding.adoptResult(adapter, context);
        }

        pub fn nativeFromMain(adapter: *Main) ?*SinkType {
            return adapter.nativePtr();
        }

        pub fn assignToStream(
            global: *JSGlobalObject,
            stream: *const webcore.ReadableStream.Owned,
            native: *SinkType,
        ) bun.JSError!?AssignToStreamResult {
            const controller = try bun.default_allocator.create(Controller);
            controller.* = .{
                .native = .empty,
            };
            var controller_ref = try Controller.Binding.adoptNativeRef(controller, global);
            defer controller_ref.deinit();
            controller.wrapper = try Controller.Binding.WeakWrapper.initRef(&controller_ref);
            controller.native = .init(native);
            if (comptime @hasField(SinkType, "signal")) {
                native.signal = streams.Signal.init(controller);
            }

            var scope: bindgen.FocusedEngineScope = undefined;
            scope.init(global);
            defer scope.deinit();
            const assignment: bun.JSError!?AssignToStreamResult = assigned: {
                const result = (scope.engine(AssignToStreamSchema).call(.{
                    .stream = stream.operand(&scope),
                    .controller = controller_ref.operand(&scope),
                }) catch |err| break :assigned err) orelse break :assigned null;
                const retained = result.toOwned() catch |err| break :assigned err;
                break :assigned retained;
            };
            return assignment catch |err| {
                var thrown = scope.takeThrownException(err) catch |termination| {
                    var native_owner = controller.detach();
                    native_owner.deinit();
                    return termination;
                };
                defer thrown.deinit();
                var native_owner = controller.detach();
                native_owner.deinit();
                return thrown.throwException(&scope);
            };
        }

        pub fn detach(native: *SinkType) void {
            if (comptime @hasField(SinkType, "signal")) {
                const controller = native.signal.get(Controller) orelse return;
                var native_owner = controller.detach();
                native_owner.deinit();
            }
        }

        pub fn startDirectStream(
            controller: *Controller,
            wrapper: bindgen.ClassRefView(ControllerSchema),
            readable_stream: *ReadableStreamHandle,
            on_pull: *?PullCallback,
            on_close: *?CloseCallback,
        ) bun.JSError!bool {
            if (controller.nativePtr() == null) return false;
            try controller.configure(wrapper, readable_stream, on_pull, on_close);
            return true;
        }

        fn systemFailure(context: anytype, err: Syscall.Error) bun.bindgen.CallError(@TypeOf(context)) {
            if (err.getErrno() == .NOMEM) return error.OutOfMemory;
            const payload = bindgen.SystemError.fromSysError(err) catch return error.OutOfMemory;
            return context.fail(.system, payload);
        }

        fn closeNative(native: *SinkType, context: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
            native.ref();
            defer native.deref();
            if (comptime std.mem.eql(u8, abi_name, "NetworkSink")) return native.endChecked(null);
            switch (native.end(null)) {
                .result => {},
                .err => |err| return systemFailure(context, err),
            }
        }

        fn flushNative(
            native: *SinkType,
            context: anytype,
            wait: bool,
        ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
            native.ref();
            defer native.deref();
            if (comptime std.mem.eql(u8, abi_name, "NetworkSink")) return native.flushFromBinding(context, wait);
            const maybe: bun.sys.Maybe(BindingOperation) = if (comptime std.mem.eql(u8, abi_name, "ArrayBufferSink"))
                try native.flushFromBinding(wait)
            else if (comptime std.mem.eql(u8, abi_name, "FileSink"))
                native.flushFromBinding(wait)
            else
                native.flushFromBinding(wait);
            var operation = switch (maybe) {
                .result => |result| result,
                .err => |err| return systemFailure(context, err),
            };
            defer operation.deinit();

            if (comptime std.mem.eql(u8, abi_name, "ArrayBufferSink")) {
                return switch (operation) {
                    .count => |count| .{ .count = count },
                    .buffer => |*buffer| if (buffer.as_uint8_array)
                        .{ .uint8_array = buffer.bytes.take() }
                    else
                        .{ .array_buffer = buffer.bytes.take() },
                    else => @panic("ArrayBufferSink returned an invalid flush result"),
                };
            }
            if (comptime std.mem.eql(u8, abi_name, "FileSink")) {
                return switch (operation) {
                    .writable => |writable| writableBindingResult(context, writable),
                    .undefined => .{ .undefined = true },
                    else => @panic("FileSink returned an invalid flush result"),
                };
            }
            return switch (operation) {
                .count => |count| .{ .count = count },
                .pending_count, .resolved_count => .{ .pending = try operationPromiseResult(
                    context,
                    operation,
                    @FieldType(bun.bindgen.Return(@TypeOf(context)), "pending"),
                ) },
                .writable => |writable| switch (writable) {
                    .out_of_memory => error.OutOfMemory,
                    else => @panic("HTTP response sink returned an invalid flush failure"),
                },
                else => @panic("HTTP response sink returned an invalid flush result"),
            };
        }

        fn startNative(native: *SinkType, context: anytype, options: anytype) bun.bindgen.CallError(@TypeOf(context))!bindgen.Return(@TypeOf(context)) {
            native.ref();
            defer native.deref();
            var start_value: streams.Start = if (options) |input|
                switch (input) {
                    .options => |resolved| try streams.Start.fromBindingOptions(resolved, comptime @field(streams.Start.Tag, abi_name)),
                    .ignored => .{ .empty = {} },
                }
            else
                .{ .empty = {} };
            defer start_value.deinit();
            const result: bun.OOM!bun.sys.Maybe(void) = native.start(start_value);
            switch (result catch {
                if (comptime std.mem.eql(u8, abi_name, "ArrayBufferSink"))
                    return startFailure(context, Syscall.Error.fromCode(.NOMEM, .read));
                return error.OutOfMemory;
            }) {
                .result => return if (comptime std.mem.eql(u8, abi_name, "ArrayBufferSink")) null else {},
                .err => |err| return startFailure(context, err),
            }
        }

        fn startFailure(context: anytype, err: Syscall.Error) bun.bindgen.CallError(@TypeOf(context))!bindgen.Return(@TypeOf(context)) {
            if (comptime std.mem.eql(u8, abi_name, "ArrayBufferSink")) {
                var payload = try bindgen.SystemError.fromSysError(err);
                defer payload.deinit();
                return try payload.toErrorInstance(context);
            }
            return systemFailure(context, err);
        }

        fn writeNative(
            native: *SinkType,
            context: anytype,
            chunk: anytype,
        ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
            native.ref();
            defer native.deref();
            const writable = switch (chunk) {
                .string => |string| switch (string.unsafePtr("The generated entry frame owns the converted string through the native write; the sink consumes or copies temporary input before returning")) {
                    .latin1 => |units| native.writeLatin1(.{
                        .temporary = units,
                    }),
                    .utf16 => |units| native.writeUTF16(.{
                        .temporary = std.mem.sliceAsBytes(units),
                    }),
                },
                .view => |view| native.writeBytes(.{
                    .temporary = view.unsafePtr("The generated entry frame owns the byte lease until dispatch returns; the sink consumes or copies temporary input before returning"),
                }),
            };
            return writableBindingResult(context, writable);
        }

        fn endNative(
            native: *SinkType,
            context: anytype,
        ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
            native.ref();
            defer native.deref();
            if (comptime std.mem.eql(u8, abi_name, "NetworkSink")) return native.endFromBinding(context);
            const maybe: bun.sys.Maybe(BindingOperation) = if (comptime std.mem.eql(u8, abi_name, "ArrayBufferSink"))
                try native.endFromBinding()
            else if (comptime std.mem.eql(u8, abi_name, "FileSink"))
                native.endFromBinding()
            else
                native.endFromBinding();
            var operation = switch (maybe) {
                .result => |result| result,
                .err => |err| return systemFailure(context, err),
            };
            defer operation.deinit();

            if (comptime std.mem.eql(u8, abi_name, "ArrayBufferSink")) {
                return switch (operation) {
                    .buffer => |*buffer| if (buffer.as_uint8_array)
                        .{ .uint8_array = buffer.bytes.take() }
                    else
                        .{ .array_buffer = buffer.bytes.take() },
                    .undefined => .{ .undefined = true },
                    else => @panic("ArrayBufferSink returned an invalid end result"),
                };
            }
            return switch (operation) {
                .count => |count| .{ .count = count },
                .count_promise => |*promise| .{ .pending = promise.toResult(context) },
                .pending_count => |pending| .{ .pending = try pending.promiseResult(context) },
                .writable => |writable| switch (writable) {
                    .pending => |pending_write| .{ .pending = try pending_write.promiseResult(context) },
                    .err => |err| return systemFailure(context, err),
                    .out_of_memory => error.OutOfMemory,
                    .done => .{ .count = 0 },
                    inline else => |count| .{ .count = count },
                },
                .undefined => .{ .undefined = true },
                else => @panic("sink returned an invalid end result"),
            };
        }

        fn writableBindingResult(
            context: anytype,
            writable: streams.Result.Writable,
        ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
            return switch (writable) {
                .err => |err| if (err.getErrno() == .NOMEM)
                    error.OutOfMemory
                else
                    .{ .pending = try SinkPending.rejectedSystem(context, err) },
                .out_of_memory => error.OutOfMemory,
                .done => .{ .closed = true },
                .pending => |pending_write| .{ .pending = try pending_write.promiseResult(context) },
                inline else => |count| .{ .count = count },
            };
        }

        fn operationPromiseResult(
            context: anytype,
            operation: BindingOperation,
            comptime Result: type,
        ) bun.JSError!Result {
            return switch (operation) {
                .pending_count => |pending| pending.promiseResult(context),
                .resolved_count => |count| context.promiseResolvedAs(Result, count),
                else => @panic("sink operation did not produce a promise"),
            };
        }

        comptime {
            _ = Main.Binding;
            _ = Controller.Binding;
        }
    };
}

const std = @import("std");

const bun = @import("bun");
const Output = bun.Output;
const Syscall = bun.sys;

const jsc = bun.jsc;
const bindgen = bun.bindgen;
const JSGlobalObject = jsc.JSGlobalObject;

const webcore = bun.webcore;
const Blob = webcore.Blob;
const streams = webcore.streams;
const SinkPending = @import("./SinkPending.zig");
