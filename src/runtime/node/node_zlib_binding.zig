pub fn crc32(
    context: bun.bindgen.CallContext(Crc32Schema),
    args: bun.bindgen.Args(Crc32Schema),
) bun.JSError!u32 {
    _ = context;
    const data: bun.String.Slice = switch (args.data) {
        .string => |value| try value.toUTF8(bun.default_allocator),
        .view => |view| bun.String.Slice.fromUTF8NeverFree(
            view.unsafePtr("the generated entry frame owns the copied bytes until crc32 finishes reading them"),
        ),
    };
    defer data.deinit();

    const slice_u8 = data.slice();
    var checksum = args.value;
    var offset: usize = 0;
    while (offset < slice_u8.len) {
        const length = @min(slice_u8.len - offset, std.math.maxInt(u32));
        checksum = @intCast(bun.zlib.crc32(checksum, slice_u8[offset..].ptr, @intCast(length)));
        offset += length;
    }
    return checksum;
}

pub fn CompressionJSBinding(comptime Backend: type, comptime ClassSchema: type) type {
    return struct {
        const Self = @This();
        const RefCount = bun.ptr.ThreadSafeRefCount(Self, "ref_count", deinit, .{});
        const ConstructorSchema = ClassSchema.constructor();
        const CloseSchema = ClassSchema.member("close");
        const InitSchema = ClassSchema.member("init");
        const ParamsSchema = ClassSchema.member("params");
        const ResetSchema = ClassSchema.member("reset");
        const WriteSchema = ClassSchema.member("write");
        const WriteSyncSchema = ClassSchema.member("writeSync");
        const CompressionError = @typeInfo(bun.bindgen.Return(InitSchema)).optional.child;
        const WriteResult = bun.bindgen.Return(WriteSchema);

        pub const ref = RefCount.ref;
        pub const deref = RefCount.deref;
        pub const derefDeferred = RefCount.derefDeferred;
        pub const destroyAfterDeferred = RefCount.destroyAfterDeferred;

        ref_count: RefCount,
        bindgen_state: bun.bindgen.ClassState = .{},
        mutex: std.atomic.Mutex = .unlocked,
        backend: bun.bindgen.OwnedNative(Backend, .any),
        write_in_progress: bool = false,
        pending_close: bool = false,
        initialized: bool = false,
        closed: bool = false,

        const PreparedWrite = struct {
            flush: u32,
            input: bun.bindgen.OwnedBytes,
            input_present: bool,
            output: bun.bindgen.OwnedBytes,

            fn init(
                comptime FunctionSchema: type,
                context: bun.bindgen.CallContext(FunctionSchema),
                args: bun.bindgen.Args(FunctionSchema),
            ) bun.bindgen.CallError(FunctionSchema)!PreparedWrite {
                _ = std.enums.fromInt(bun.zlib.FlushValue, args.flush) orelse {
                    return context.fail(.invalid_flush, {});
                };

                var input = bun.bindgen.OwnedBytes.empty();
                errdefer input.deinit();
                const input_present = args.input != null;
                if (args.input) |view| {
                    const requested_end = @as(u64, args.inputOffset) + @as(u64, args.inputLength);
                    if (requested_end > view.length()) {
                        var message_buffer: [192]u8 = undefined;
                        const message = std.fmt.bufPrint(
                            &message_buffer,
                            "in_off + in_len ({d}) exceeds input buffer length ({d})",
                            .{ requested_end, view.length() },
                        ) catch unreachable;
                        return context.fail(
                            .input_out_of_range,
                            try bun.bindgen.ThreadSafeDOMString.fromUTF8(message),
                        );
                    }
                    input = try bun.bindgen.OwnedBytes.initUninitialized(args.inputLength);
                    if (!view.read(args.inputOffset, input.mutableSlice())) unreachable;
                }

                const output_end = @as(u64, args.outputOffset) + @as(u64, args.outputLength);
                if (output_end > args.output.length()) {
                    var message_buffer: [192]u8 = undefined;
                    const message = std.fmt.bufPrint(&message_buffer, "out_off + out_len ({d}) exceeds output buffer length ({d})", .{ output_end, args.output.length() }) catch unreachable;
                    return context.fail(.output_out_of_range, try bun.bindgen.ThreadSafeDOMString.fromUTF8(message));
                }

                var output = try bun.bindgen.OwnedBytes.initUninitialized(args.outputLength);
                @memset(output.mutableSlice(), 0);
                return .{
                    .flush = args.flush,
                    .input = input,
                    .input_present = input_present,
                    .output = output,
                };
            }

            fn deinit(prepared: *PreparedWrite) void {
                prepared.input.deinit();
                prepared.output.deinit();
            }
        };

        const WriteAttachment = struct {
            input: ?bun.bindgen.OwnedLease(u8),
            output: bun.bindgen.OwnedMutableLease(u8),

            fn deinit(attachment: *@This()) void {
                if (attachment.input) |*input| input.deinit();
                attachment.output.deinit();
            }
        };

        const WriteTask = struct {
            const Task = @This();
            const Job = BackgroundJob(Task, "job", run, cancel);

            job: Job,
            owner: bun.bindgen.RefNative(Self, .any),
            completion: Completion.Owned,
            result: ?WriteResult = null,
            output_offset: u32,
            flush: u32,
            input: bun.bindgen.OwnedBytes,
            input_present: bool,
            output: bun.bindgen.OwnedBytes,

            const CompletionOps = struct {
                pub fn materialize(
                    comptime FunctionSchema: type,
                    _: bun.bindgen.MaterializationContext(FunctionSchema),
                    attachment: *WriteAttachment,
                    task: *Task,
                ) WriteResult {
                    const result = task.result.?;
                    const written = task.output.slice().len - result.availOut;
                    if (!attachment.output.write(result.outputOffset, task.output.slice()[0..written])) unreachable;
                    task.result = null;
                    return result;
                }

                pub const destroyPayload = Task.deinit;

                pub fn destroyAttachment(attachment: *WriteAttachment) void {
                    attachment.deinit();
                }
            };
            const Completion = bun.bindgen.MaterializedCompletion(WriteSchema, Task, WriteAttachment, CompletionOps);

            fn run(task: *Task) void {
                task.owner.get().runAsyncWrite(task);
            }

            fn cancel(task: *Task) void {
                task.owner.get().cancelAsyncWrite();
                task.completion.release();
                task.deinit();
            }

            fn deinit(task: *Task) void {
                if (task.result) |result| {
                    if (result.failure) |value| deinitErrorInfo(value);
                }
                task.input.deinit();
                task.output.deinit();
                task.owner.deinit();
                bun.destroy(task);
            }
        };

        pub fn construct(
            _: bun.bindgen.CallContext(ConstructorSchema),
            args: bun.bindgen.Args(ConstructorSchema),
        ) bun.JSError!*Self {
            const result = try bun.default_allocator.create(Self);
            errdefer bun.default_allocator.destroy(result);
            const backend = try bun.default_allocator.create(Backend);
            backend.* = Backend.create(args.mode);
            result.* = .{
                .ref_count = .init(),
                .backend = .init(backend),
            };
            return result;
        }

        pub fn memoryUsage(this: *const Self, _: bun.bindgen.MemoryUsageContext(.any)) usize {
            const mutable: *Self = @constCast(this);
            mutable.lockState();
            defer mutable.mutex.unlock();
            return @sizeOf(Self) + this.backend.get().estimatedSize();
        }

        pub fn bindClose(
            this: *Self,
            _: bun.bindgen.CallContext(CloseSchema),
            _: bun.bindgen.Args(CloseSchema),
        ) bun.JSError!void {
            this.lockState();
            defer this.mutex.unlock();
            if (this.closed) return;
            if (this.write_in_progress) {
                this.pending_close = true;
                return;
            }
            this.backend.get().close();
            this.initialized = false;
            this.closed = true;
        }

        pub fn bindInit(
            this: *Self,
            _: bun.bindgen.CallContext(InitSchema),
            args: bun.bindgen.Args(InitSchema),
        ) bun.bindgen.CallError(InitSchema)!bun.bindgen.Return(InitSchema) {
            this.lockState();
            defer this.mutex.unlock();
            if (this.write_in_progress) {
                return try errorInfo(.init("Write already in progress", -1, "ERR_INVALID_STATE"));
            }
            if (this.initialized or this.closed) {
                return try errorInfo(.init("Compression stream is already initialized or closed", -1, "ERR_INVALID_STATE"));
            }
            const err = try this.backend.get().initFromBindgen(args);
            this.initialized = err == null;
            return if (err) |value| try errorInfo(value) else null;
        }

        pub fn bindParams(
            this: *Self,
            context: bun.bindgen.CallContext(ParamsSchema),
            args: bun.bindgen.Args(ParamsSchema),
        ) bun.bindgen.CallError(ParamsSchema)!bun.bindgen.Return(ParamsSchema) {
            this.lockState();
            defer this.mutex.unlock();
            try this.checkWritableState(ParamsSchema, context);
            const err = this.backend.get().paramsFromBindgen(args);
            return if (err) |value| try errorInfo(value) else null;
        }

        pub fn bindReset(
            this: *Self,
            context: bun.bindgen.CallContext(ResetSchema),
            _: bun.bindgen.Args(ResetSchema),
        ) bun.bindgen.CallError(ResetSchema)!bun.bindgen.Return(ResetSchema) {
            this.lockState();
            defer this.mutex.unlock();
            if (!this.initialized or this.closed) return null;
            if (this.write_in_progress) return context.fail(.write_in_progress, {});
            const err = this.backend.get().reset();
            if (err.isError()) this.initialized = false;
            return if (err.isError()) try errorInfo(err) else null;
        }

        pub fn bindWrite(
            this: *Self,
            context: bun.bindgen.CallContext(WriteSchema),
            args: bun.bindgen.Args(WriteSchema),
        ) bun.bindgen.CallError(WriteSchema)!void {
            var prepared = try PreparedWrite.init(WriteSchema, context, args);
            defer prepared.deinit();

            const task = bun.default_allocator.create(WriteTask) catch return error.OutOfMemory;
            errdefer bun.default_allocator.destroy(task);

            var input_lease = if (args.input) |input| try input.toOwned() else null;
            const output_lease = args.output.toOwned() catch |err| {
                if (input_lease) |*input| input.deinit();
                return err;
            };
            var attachment: ?WriteAttachment = .{
                .input = input_lease,
                .output = output_lease,
            };
            defer if (attachment) |*value| value.deinit();
            try this.beginWrite(WriteSchema, context);
            errdefer this.cancelAsyncWrite();
            var completion = context.completion();
            const retained = attachment.?;
            attachment = null;
            const owned_completion = try WriteTask.Completion.take(&completion, retained);
            task.* = .{
                .job = undefined,
                .owner = bun.bindgen.RefNative(Self, .any).init(this),
                .completion = owned_completion,
                .output_offset = args.outputOffset,
                .flush = prepared.flush,
                .input = prepared.input.take(),
                .input_present = prepared.input_present,
                .output = prepared.output.take(),
            };
            task.job.init();

            task.job.schedule(bun.current_runtime.backgroundTasks()) catch |err| {
                this.cancelAsyncWrite();
                var message_buffer: [256]u8 = undefined;
                const message = std.fmt.bufPrint(
                    &message_buffer,
                    "Failed to start compression work: {s}",
                    .{@errorName(err)},
                ) catch unreachable;
                const payload = bun.bindgen.ThreadSafeDOMString.fromUTF8(message) catch {
                    task.completion.outOfMemory();
                    task.deinit();
                    return;
                };
                task.completion.fail(.schedule_failed, payload);
                task.deinit();
            };
        }

        pub fn bindWriteSync(
            this: *Self,
            context: bun.bindgen.CallContext(WriteSyncSchema),
            args: bun.bindgen.Args(WriteSyncSchema),
        ) bun.bindgen.CallError(WriteSyncSchema)!bun.bindgen.Return(WriteSyncSchema) {
            var prepared = try PreparedWrite.init(WriteSyncSchema, context, args);
            defer prepared.deinit();

            this.lockState();
            defer this.mutex.unlock();
            try this.checkWritableState(WriteSyncSchema, context);

            this.backend.get().stream.process(
                if (prepared.input_present) prepared.input.slice() else null,
                prepared.output.mutableSlice(),
                @intCast(prepared.flush),
            );

            var avail_in: u32 = 0;
            var avail_out: u32 = 0;
            this.backend.get().stream.updateWriteResult(&avail_in, &avail_out);
            const raw_error = this.backend.get().stream.getErrorInfo();
            const owned_error = if (raw_error.isError()) try errorInfo(raw_error) else null;
            const written = prepared.output.slice().len - avail_out;
            const output = args.output.unsafeMutPtr("the generated frame retains the validated destination lease through the synchronous write");
            @memcpy(output[args.outputOffset..][0..written], prepared.output.slice()[0..written]);
            return .{
                .outputOffset = args.outputOffset,
                .availIn = avail_in,
                .availOut = avail_out,
                .failure = owned_error,
            };
        }

        fn beginWrite(this: *Self, comptime FunctionSchema: type, context: bun.bindgen.CallContext(FunctionSchema)) bun.bindgen.CallError(FunctionSchema)!void {
            this.lockState();
            defer this.mutex.unlock();
            try this.checkWritableState(FunctionSchema, context);
            this.write_in_progress = true;
        }

        fn checkWritableState(this: *Self, comptime FunctionSchema: type, context: bun.bindgen.CallContext(FunctionSchema)) bun.bindgen.CallError(FunctionSchema)!void {
            if (this.write_in_progress) return context.fail(.write_in_progress, {});
            if (this.pending_close) return context.fail(.pending_close, {});
            if (this.closed or !this.initialized) return context.fail(.closed, {});
        }

        fn runAsyncWrite(this: *Self, task: *WriteTask) void {
            this.backend.get().stream.process(
                if (task.input_present) task.input.slice() else null,
                task.output.mutableSlice(),
                @intCast(task.flush),
            );

            var avail_in: u32 = 0;
            var avail_out: u32 = 0;
            this.backend.get().stream.updateWriteResult(&avail_in, &avail_out);

            var write_error: ?CompressionError = null;
            const raw_write_error = this.backend.get().stream.getErrorInfo();
            if (raw_write_error.isError()) {
                write_error = errorInfo(raw_write_error) catch {
                    this.finishAsyncWrite();
                    task.completion.outOfMemory();
                    task.deinit();
                    return;
                };
            }

            this.finishAsyncWrite();

            task.result = .{
                .outputOffset = task.output_offset,
                .availIn = avail_in,
                .availOut = avail_out,
                .failure = write_error,
            };
            task.completion.complete(task);
        }

        fn finishAsyncWrite(this: *Self) void {
            this.lockState();
            defer this.mutex.unlock();

            if (this.pending_close and !this.closed) {
                this.pending_close = false;
                this.backend.get().close();
                this.initialized = false;
                this.closed = true;
            }
            this.write_in_progress = false;
        }

        fn cancelAsyncWrite(this: *Self) void {
            this.lockState();
            defer this.mutex.unlock();
            if (!this.write_in_progress) return;
            if (this.pending_close and !this.closed) {
                this.pending_close = false;
                this.backend.get().close();
                this.initialized = false;
                this.closed = true;
            }
            this.write_in_progress = false;
        }

        fn errorInfo(err: Error) bun.OOM!CompressionError {
            if (err.allocation_failed) return error.OutOfMemory;
            var message = try bun.bindgen.ThreadSafeDOMString.fromUTF8(if (err.msg) |value| std.mem.span(value) else "");
            errdefer message.deinit();
            var code = try bun.bindgen.ThreadSafeDOMString.fromUTF8(if (err.code) |value| std.mem.span(value) else "");
            errdefer code.deinit();
            return .{
                .message = message,
                .errorNumber = @intCast(err.err),
                .code = code,
            };
        }

        fn deinitErrorInfo(value: CompressionError) void {
            var info: bun.bindgen.Return(InitSchema) = value;
            bun.bindgen.deinitReturn(InitSchema, &info);
        }

        fn lockState(this: *Self) void {
            while (!this.mutex.tryLock()) std.atomic.spinLoopHint();
        }

        fn deinit(this: *Self) void {
            bun.debugAssert(!this.write_in_progress);
            this.backend.deinit();
            bun.destroy(this);
        }
    };
}

pub const Error = struct {
    msg: ?[*:0]const u8,
    err: c_int,
    code: ?[*:0]const u8,
    allocation_failed: bool = false,

    pub const ok: Error = init(null, 0, null);
    pub const out_of_memory: Error = .{ .msg = null, .err = 0, .code = null, .allocation_failed = true };

    pub fn init(msg: ?[*:0]const u8, err: c_int, code: ?[*:0]const u8) Error {
        return .{
            .msg = msg,
            .err = err,
            .code = code,
        };
    }

    pub fn isError(this: Error) bool {
        return this.allocation_failed or this.msg != null;
    }
};

fn BackgroundJob(
    comptime Owner: type,
    comptime field_name: []const u8,
    comptime run_owner: fn (*Owner) void,
    comptime cancel_owner: fn (*Owner) void,
) type {
    return struct {
        storage: [@sizeOf(bun.BackgroundTaskGroup.Task)]u8 align(@alignOf(bun.BackgroundTaskGroup.Task)),

        const Self = @This();

        pub fn init(job: *Self) void {
            job.rawTask().* = .{
                .callback = run,
                .on_cancel = cancel,
            };
        }

        pub fn schedule(job: *Self, group: *bun.BackgroundTaskGroup) std.Io.ConcurrentError!void {
            try bun.BackgroundWork.schedule(group, job.rawTask());
        }

        fn rawTask(job: *Self) *bun.BackgroundTaskGroup.Task {
            return @ptrCast(@alignCast(&job.storage));
        }

        fn owner(task: *bun.BackgroundTaskGroup.Task) *Owner {
            const job: *Self = @ptrCast(@alignCast(task));
            return @alignCast(@fieldParentPtr(field_name, job));
        }

        fn run(task: *bun.BackgroundTaskGroup.Task) void {
            run_owner(owner(task));
        }

        fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
            cancel_owner(owner(task));
        }
    };
}

const std = @import("std");
const bun = @import("bun");

const NodeZlibBindings = bun.bindgen.Module("NodeZlib");
const Crc32Schema = NodeZlibBindings.function("crc32");
const Crc32Binding = bun.bindgen.Fn(Crc32Schema, crc32);

comptime {
    _ = Crc32Binding;
}
