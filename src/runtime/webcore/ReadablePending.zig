const ReadablePending = @This();

const Bindings = bindgen.Module("ReadableStreamSource");
const CompletionSchema = Bindings.function("pullCompletion");
const PullSchema = Bindings.class("BytesInternalReadableStreamSource").member("pullNative");
const DeliverySchema = bindgen.DictionaryFieldType(PullSchema.ReturnType, "value");
const PromiseSchema = bindgen.UnionMemberType(DeliverySchema, "pending");

pub const PromiseResult = bindgen.BrandedValueResult(PromiseSchema);
pub const SettledResult = bindgen.Return(CompletionSchema);
pub const DirectResult = bindgen.Return(PullSchema);


const Payload = union(enum) {
    settled: SettledResult,
    system_error: bindgen.SystemError,
    abort_reason: CommonAbortReason,
    js_error: bindgen.Root,
    consumed: void,

    fn deinit(payload: *Payload) void {
        var pending = payload.*;
        payload.* = .{ .consumed = {} };
        switch (pending) {
            .settled => |*settled| bindgen.deinitReturn(CompletionSchema, settled),
            .js_error => |*root| root.deinit(),
            .system_error => |*err| err.deinit(),
            .abort_reason, .consumed => {},
        }
    }

    pub fn destroy(payload: *Payload) void {
        payload.deinit();
        bun.default_allocator.destroy(payload);
    }

    fn takeSettled(payload: *Payload) SettledResult {
        const settled = payload.settled;
        payload.* = .{ .consumed = {} };
        return settled;
    }
};

const CompletionOps = struct {
    pub const empty_payload: Payload = .{ .consumed = {} };
    pub const deinitPayload = Payload.deinit;

    pub fn materialize(
        comptime FunctionSchema: type,
        context: bindgen.MaterializationContext(FunctionSchema),
        payload: *Payload,
    ) bindgen.MaterializationError(FunctionSchema)!bindgen.Return(FunctionSchema) {
        return switch (payload.*) {
            .settled => payload.takeSettled(),
            .system_error => |err| blk: {
                payload.* = .{ .consumed = {} };
                break :blk context.fail(.system, err);
            },
            .abort_reason => |reason| {
                const operation = context.engineIn("abort_signals", "commonAbortReasonToJS");
                var error_value = try operation.call(.{
                    .value = reason.toBinding(@FieldType(@TypeOf(operation).Args, "value")),
                });
                defer error_value.deinit();
                var error_root = try error_value.toRoot();
                return context.reject(&error_root, .{ .attach_async_stack = true });
            },
            .js_error => |*root| {
                var error_root = root.take();
                payload.* = .{ .consumed = {} };
                return context.reject(&error_root, .{ .attach_async_stack = true });
            },
            .consumed => @panic("readable pull completion payload was consumed twice"),
        };
    }

    pub const destroyPayload = Payload.destroy;

};

const State = bindgen.PendingMaterializedCompletion(CompletionSchema, PromiseResult, Payload, CompletionOps);
state: State = .{},

pub fn has(pending: *const ReadablePending) bool {
    return pending.state.has();
}

pub fn promiseResult(pending: *ReadablePending, context: anytype) bun.JSError!PromiseResult {
    return pending.state.promiseResult(context);
}

pub fn resolve(pending: *ReadablePending, settled: SettledResult) void {
    pending.complete(.{ .settled = settled });
}

pub fn rejectSystem(pending: *ReadablePending, err: bun.sys.Error) void {
    if (!pending.has()) return;
    const owned_error = bindgen.SystemError.fromSysError(err) catch {
        pending.outOfMemory();
        return;
    };
    pending.rejectOwnedSystem(owned_error);
}

pub fn rejectOwnedSystem(pending: *ReadablePending, err: bindgen.SystemError) void {
    pending.complete(.{ .system_error = err });
}

pub fn rejectAbort(pending: *ReadablePending, reason: CommonAbortReason) void {
    pending.complete(.{ .abort_reason = reason });
}

pub fn rejectRoot(pending: *ReadablePending, root: *bindgen.Root) void {
    pending.complete(.{ .js_error = root.take() });
}

pub fn outOfMemory(pending: *ReadablePending) void {
    pending.state.outOfMemory();
}

pub fn directFromSettled(settled: *SettledResult) DirectResult {
    const Value = @FieldType(DirectResult, "value");
    const value: Value = switch (settled.value) {
        .bytes => |*bytes| .{ .bytes = bytes.take() },
        .count => |count| .{ .count = count },
        .closed => .{ .closed = false },
    };
    return .{ .value = value, .done = settled.done };
}

pub fn deinit(pending: *ReadablePending) void {
    pending.state.deinit();
}

fn complete(pending: *ReadablePending, payload_value: Payload) void {
    pending.state.complete(payload_value);
}



const bun = @import("bun");
const bindgen = bun.bindgen;
const CommonAbortReason = @import("../../http_types/CommonAbortReason.zig").CommonAbortReason;
