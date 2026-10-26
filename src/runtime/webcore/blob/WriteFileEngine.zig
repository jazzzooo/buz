const Core = @import("./write_file.zig");

pub const WriteFile = Core.WriteFile;
pub const WriteFileResultType = Core.WriteFileResultType;
pub const WriteFileTask = jsc.WorkTask(WriteFile);
pub const StoreRange = Core.StoreRange;

pub fn startUV(event_loop: *jsc.EventLoop, file: StoreRange, bytes: StoreRange, handler: *WriteFileAcceptorHandler, mkdirp: bool, mode: ?bun.Mode) bun.OOM!void {
    const Operation = @import("./WriteFileUV.zig");
    const Endpoint = @import("../../../event_loop/NativeIOEndpoint.zig").NativeIOEndpoint(Operation, WriteFileResultType);
    const Handler = struct {
        fn run(context: *anyopaque, result: WriteFileResultType) void {
            WriteFileAcceptorHandler.run(@ptrCast(@alignCast(context)), result);
        }
    };
    const vm = event_loop.virtual_machine;
    const endpoint = try Endpoint.create(vm, handler, Handler.run);
    errdefer endpoint.deinitUnstarted();
    const operation = try Operation.create(vm.uvLoop(), file, bytes, .{
        .context = endpoint,
        .callback = Endpoint.receive,
    }, mkdirp, mode);
    endpoint.start(operation);
}

/// One settled outcome of a `Bun.write`-style operation.
pub const WriteResult = union(enum) {
    written: u64,
    abort_reason: jsc.CommonAbortReason,
    s3_error: S3Completions.OwnedS3Error,

    pub fn deinit(this: *WriteResult) void {
        switch (this.*) {
            .written => {},
            .abort_reason => {},
            .s3_error => |*payload| payload.deinit(),
        }
        this.* = .{ .written = 0 };
    }
};

const WriteCompletionOps = struct {
    pub fn materialize(
        comptime FunctionSchema: type,
        context: bun.bindgen.MaterializationContext(FunctionSchema),
        result: *WriteResult,
    ) bun.bindgen.MaterializationError(FunctionSchema)!bun.bindgen.Return(FunctionSchema) {
        return switch (result.*) {
            .written => |count| count,
            .abort_reason => |reason| {
                const operation = context.engineIn("abort_signals", "commonAbortReasonToJS");
                var error_value = try operation.call(.{
                    .value = reason.toBinding(@FieldType(@TypeOf(operation).Args, "value")),
                });
                defer error_value.deinit();
                var error_root = try error_value.toRoot();
                return context.reject(&error_root, .{ .attach_async_stack = true });
            },
            .s3_error => |*payload| {
                return context.fail(.s3, payload.takeFailure());
            },
        };
    }

    pub fn destroyPayload(result: *WriteResult) void {
        result.deinit();
        bun.destroy(result);
    }

};

const S3ClientClassSchema = bun.bindgen.Module("S3Client").class("S3Client");

pub const WriteCompletions = bun.bindgen.MaterializedCompletionSet(.{
    WriteFunctionSchema,
    BlobWriteSchema,
    S3ClientClassSchema.memberKind("write", .method),
    S3ClientClassSchema.memberKind("write", .static_method),
}, WriteResult, WriteCompletionOps);

pub const WriteAcceptor = struct {
    const State = struct {
        completion: WriteCompletions.Owned,
        payload: bun.bindgen.OwnedNativeWithDestructor(WriteResult, WriteCompletionOps.destroyPayload, .any),
    };
    state: ?State = null,

    pub fn fromCompletion(owned: WriteCompletions.Owned) ?WriteAcceptor {
        var completion = owned;
        const payload = bun.default_allocator.create(WriteResult) catch {
            completion.outOfMemory();
            return null;
        };
        payload.* = .{ .written = 0 };
        return .{ .state = .{ .completion = completion, .payload = .init(payload) } };
    }

    pub fn complete(this: *WriteAcceptor, result: WriteResult) void {
        var state = this.takeState();
        state.payload.get().* = result;
        state.completion.complete(state.payload.take());
    }

    pub fn completeError(this: *WriteAcceptor, value: Body.Value.ValueError) void {
        var err = value;
        defer err.deinit();
        switch (err) {
            .OutOfMemory => this.outOfMemory(),
            .AbortReason => |reason| this.complete(.{ .abort_reason = reason }),
            .SystemError => |system_error| {
                const payload = system_error.get().borrow().clone() catch {
                    this.outOfMemory();
                    return;
                };
                this.fail(.system, payload);
            },
            inline .Message, .TypeError => |message, tag| {
                const payload = bun.bindgen.ThreadSafeDOMString.fromBunString(message.get().dupeRef()) catch {
                    this.outOfMemory();
                    return;
                };
                this.fail(if (tag == .Message) .write_failed else .write_type_error, payload);
            },
            .JSValue => |*value_root| {
                var root = value_root.takeRoot() orelse @panic("body JS error was already consumed");
                this.reject(&root);
            },
        }
    }

    pub fn reject(this: *WriteAcceptor, root: *bun.bindgen.Root) void {
        var completion = this.takeCompletion();
        completion.reject(root, .{ .attach_async_stack = true });
    }

    pub fn completeS3Error(this: *WriteAcceptor, err: bun.S3.Error.S3Error, path: []const u8) void {
        const payload = S3Completions.OwnedS3Error.init(err, path) catch {
            this.outOfMemory();
            return;
        };
        this.complete(.{ .s3_error = payload });
    }

    pub fn completeSysError(this: *WriteAcceptor, value: bun.sys.Error) void {
        const payload = bun.bindgen.SystemError.fromSysError(value) catch {
            this.outOfMemory();
            return;
        };
        this.fail(.system, payload);
    }

    pub fn concurrencyUnavailable(this: *WriteAcceptor) void {
        this.fail(.concurrency_unavailable, {});
    }

    pub fn outOfMemory(this: *WriteAcceptor) void {
        var completion = this.takeCompletion();
        completion.outOfMemory();
    }

    pub fn deinit(this: *WriteAcceptor) void {
        var state = bun.take(&this.state) orelse return;
        state.payload.deinit();
        state.completion.release();
    }

    pub fn take(this: *WriteAcceptor) WriteAcceptor {
        return .{ .state = this.takeState() };
    }

    pub fn assertConsumed(this: *const WriteAcceptor) void {
        if (this.state != null) @panic("write returned without completing or transferring its result");
    }

    fn takeState(this: *WriteAcceptor) State {
        return bun.take(&this.state) orelse @panic("write completion owner was already consumed");
    }

    fn takeCompletion(this: *WriteAcceptor) WriteCompletions.Owned {
        var state = this.takeState();
        state.payload.deinit();
        return state.completion;
    }

    fn fail(this: *WriteAcceptor, comptime tag: anytype, payload: anytype) void {
        var completion = this.takeCompletion();
        completion.fail(tag, payload);
    }
};

const BlobWriteSchema = bun.bindgen.Module("Blob").class("Blob").member("write");

/// Completes a native file-write result into a boxed acceptor.
pub const WriteFileAcceptorHandler = struct {
    acceptor: WriteAcceptor,

    pub fn run(handler: *@This(), result: WriteFileResultType) void {
        handler.deliver(result);
    }

    pub fn runCopy(handler: *@This(), result: @import("copy_file.zig").CopyFileResult) void {
        handler.deliver(result);
    }

    fn deliver(handler: *@This(), result: anytype) void {
        var acceptor = handler.acceptor.take();
        bun.destroy(handler);
        switch (result) {
            .written => |wrote| acceptor.complete(.{ .written = wrote }),
            .system_error => |system_error| acceptor.fail(.system, system_error),
            .concurrency_unavailable => acceptor.concurrencyUnavailable(),
            .out_of_memory => acceptor.outOfMemory(),
            .cancelled => acceptor.deinit(),
        }
    }
};

const bun = @import("bun");
const bindgen = bun.bindgen;

const jsc = bun.jsc;
const Body = jsc.WebCore.Body;

const S3Completions = @import("../s3/completions.zig");
const WriteFunctionSchema = bun.bindgen.Module("BunObject").function("write");
