const SinkPending = @This();

const JSSinkBindings = bindgen.Module("JSSink");
const CompletionSchema = JSSinkBindings.function("countCompletion");
const WriteSchema = JSSinkBindings.class("FileSink").member("write");
const PromiseSchema = bindgen.UnionMemberType(WriteSchema.ReturnType, "pending");

pub const PromiseResult = bindgen.BrandedValueResult(PromiseSchema);
pub const OwnedPromise = bindgen.OwnedBrandedValue(PromiseSchema);

const Payload = union(enum) {
    count: usize,
    system_error: bindgen.SystemError,
    s3_error: S3Completions.OwnedS3Error,
    consumed: void,

    fn deinit(payload: *Payload) void {
        var pending = payload.*;
        payload.* = .{ .consumed = {} };
        switch (pending) {
            inline .system_error, .s3_error => |*err| err.deinit(),
            .count, .consumed => {},
        }
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
            .count => |count| count,
            .system_error => |err| blk: {
                payload.* = .{ .consumed = {} };
                break :blk context.fail(.system, err);
            },
            .s3_error => |*err| {
                return context.fail(.s3, err.takeFailure());
            },
            .consumed => @panic("sink completion payload was consumed twice"),
        };
    }

    pub fn destroyPayload(payload: *Payload) void {
        payload.deinit();
        bun.default_allocator.destroy(payload);
    }

};

const State = bindgen.PendingMaterializedCompletion(CompletionSchema, PromiseResult, Payload, CompletionOps);
state: State = .{},

pub fn has(pending: *const SinkPending) bool {
    return pending.state.has();
}

pub fn promiseResult(pending: *SinkPending, context: anytype) bun.JSError!PromiseResult {
    return pending.state.promiseResult(context);
}

pub fn existingPromiseResult(pending: *const SinkPending, context: anytype) PromiseResult {
    if (!pending.has()) @panic("pending sink promise does not exist");
    return pending.state.existingPromise().toResult(context);
}

pub fn existingPromiseOwned(pending: *const SinkPending) OwnedPromise {
    if (!pending.has()) @panic("pending sink promise does not exist");
    return pending.state.existingPromise().toOwned();
}

pub fn rejectedSystem(context: anytype, err: bun.sys.Error) bun.JSError!PromiseResult {
    var pending: SinkPending = .{};
    const result = try pending.promiseResult(context);
    pending.rejectSystem(err);
    return result;
}

pub fn resolve(pending: *SinkPending, count: usize) void {
    pending.complete(.{ .count = count });
}

pub fn rejectSystem(pending: *SinkPending, err: bun.sys.Error) void {
    if (!pending.has()) return;
    const owned_error = bindgen.SystemError.fromSysError(err) catch {
        pending.outOfMemory();
        return;
    };
    pending.complete(.{ .system_error = owned_error });
}

pub fn rejectS3(pending: *SinkPending, err: bun.S3.Error.S3Error, path: ?[]const u8) void {
    if (!pending.has()) return;
    const owned_error = S3Completions.OwnedS3Error.init(err, path) catch {
        pending.outOfMemory();
        return;
    };
    pending.complete(.{ .s3_error = owned_error });
}

pub fn rejectOwnedS3(pending: *SinkPending, err: *const S3Completions.OwnedS3Error) void {
    if (!pending.has()) return;
    pending.complete(.{ .s3_error = err.clone() });
}

pub fn outOfMemory(pending: *SinkPending) void {
    pending.state.outOfMemory();
}

pub fn deinit(pending: *SinkPending) void {
    pending.state.deinit();
}

fn complete(pending: *SinkPending, payload_value: Payload) void {
    pending.state.complete(payload_value);
}



const bun = @import("bun");
const bindgen = bun.bindgen;
const S3Completions = @import("./s3/completions.zig");
