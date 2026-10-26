//! Native outcomes for S3 operations, materialized into their declared
//! fulfillment types on the VM thread.

pub const OwnedS3Error = struct {
    payload: ?Failure,

    pub fn init(err: S3Error, path: ?[]const u8) bun.OOM!OwnedS3Error {
        return .{ .payload = try serviceFailure(err, path) };
    }

    pub fn deinit(this: *OwnedS3Error) void {
        var payload = bun.take(&this.payload) orelse return;
        bun.bindgen.deinitDomainErrorPayload(FailureSchema, .s3, &payload);
    }

    pub fn takeFailure(this: *OwnedS3Error) Failure {
        return bun.take(&this.payload) orelse @panic("S3 error payload was already consumed");
    }

    pub fn clone(this: *const OwnedS3Error) OwnedS3Error {
        const payload = this.payload orelse @panic("S3 error payload was already consumed");
        return .{ .payload = .{
            .code = if (payload.code) |code| code.clone() else null,
            .message = payload.message.clone(),
            .path = if (payload.path) |path| path.clone() else null,
        } };
    }

    pub fn memoryCost(this: *const OwnedS3Error) usize {
        const payload = this.payload orelse return 0;
        return (if (payload.code) |code| code.byteLength() else @as(usize, 0)) + payload.message.byteLength() +
            (if (payload.path) |path| path.byteLength() else @as(usize, 0));
    }
};

pub fn serviceFailure(err: S3Error, path: ?[]const u8) bun.OOM!Failure {
    var result: Failure = .{ .code = .empty(), .message = .empty(), .path = null };
    errdefer bun.bindgen.deinitDomainErrorPayload(FailureSchema, .s3, &result);
    result.code = try bun.bindgen.ThreadSafeDOMString.fromUTF8(err.code);
    result.message = try bun.bindgen.ThreadSafeDOMString.fromUTF8(err.message);
    if (path) |value| result.path = try bun.bindgen.ThreadSafeDOMString.fromUTF8(value);
    return result;
}

pub const OwnedS3Stat = S3Stat.Data;

fn CompletionPayload(comptime Success: type) type {
    switch (Success) {
        void, bool, u64, OwnedS3Stat => {},
        else => @compileError("S3 completion payload requires an explicit ownership policy"),
    }
    return struct {
        success: Success,

        fn deinit(this: *@This()) void {
            if (Success == OwnedS3Stat) this.success.deinit();
        }
    };
}

fn CompletionOps(comptime Success: type) type {
    const Payload = CompletionPayload(Success);
    return struct {
        pub fn materialize(
            comptime FunctionSchema: type,
            context: bun.bindgen.MaterializationContext(FunctionSchema),
            payload: *Payload,
        ) bun.bindgen.MaterializationError(FunctionSchema)!bun.bindgen.Return(FunctionSchema) {
            _ = context.viewToken();
            if (Success == OwnedS3Stat) return payload.success.toBindingRef(context);
            return payload.success;
        }

        pub fn destroyPayload(payload: *Payload) void {
            payload.deinit();
            bun.destroy(payload);
        }

    };
}

const S3ClientClassSchema = bun.bindgen.Module("S3Client").class("S3Client");
const BlobBindingModule = bun.bindgen.Module("Blob");
const BlobClassSchema = BlobBindingModule.class("Blob");
const S3FileClassSchema = BlobBindingModule.class("S3File");

pub const VoidCompletions = bun.bindgen.MaterializedCompletionSet(.{
    S3ClientClassSchema.memberKind("delete", .method),
    S3ClientClassSchema.memberKind("unlink", .method),
    S3ClientClassSchema.memberKind("delete", .static_method),
    S3ClientClassSchema.memberKind("unlink", .static_method),
    BlobClassSchema.member("delete"),
    BlobClassSchema.member("unlink"),
}, CompletionPayload(void), CompletionOps(void));

pub const ExistsCompletions = bun.bindgen.MaterializedCompletionSet(.{
    S3ClientClassSchema.memberKind("exists", .method),
    S3ClientClassSchema.memberKind("exists", .static_method),
    BlobClassSchema.member("exists"),
}, CompletionPayload(bool), CompletionOps(bool));

pub const SizeCompletions = bun.bindgen.MaterializedCompletionSet(.{
    S3ClientClassSchema.memberKind("size", .method),
    S3ClientClassSchema.memberKind("size", .static_method),
}, CompletionPayload(u64), CompletionOps(u64));

pub const StatCompletions = bun.bindgen.MaterializedCompletionSet(.{
    S3ClientClassSchema.memberKind("stat", .method),
    S3ClientClassSchema.memberKind("stat", .static_method),
    BlobClassSchema.member("statS3Native"),
    S3FileClassSchema.member("stat"),
}, CompletionPayload(OwnedS3Stat), CompletionOps(OwnedS3Stat));

pub fn ResultAcceptor(comptime Payload: type, comptime Completions: type) type {
    const Value = @FieldType(Payload, "success");
    const Result = struct {
        completion: ?Completions.Owned,

        pub fn fromCompletion(completion: Completions.Owned) @This() {
            return .{ .completion = completion };
        }

        pub fn takeForContext(context: anytype) @This() {
            var view = context.completion();
            return .fromCompletion(Completions.takeForContext(context, &view));
        }

        pub fn take(this: *@This()) @This() {
            return .fromCompletion(this.takeCompletion());
        }

        pub fn resolve(this: *@This(), value: Value) void {
            var completion = this.takeCompletion();
            completeOwned(&completion, Payload{ .success = value });
        }

        pub fn rejectError(this: *@This(), err: S3Error, path: ?[]const u8) void {
            const payload = serviceFailure(err, path) catch {
                this.outOfMemory();
                return;
            };
            var completion = this.takeCompletion();
            completion.fail(.s3, payload);
        }

        pub fn outOfMemory(this: *@This()) void {
            var completion = this.takeCompletion();
            completion.outOfMemory();
        }

        pub fn release(this: *@This()) void {
            if (bun.take(&this.completion)) |value| {
                var completion = value;
                completion.release();
            }
        }

        fn takeCompletion(this: *@This()) Completions.Owned {
            return bun.take(&this.completion) orelse @panic("S3 completion was already consumed");
        }
    };
    return Result;
}

pub const VoidAcceptor = ResultAcceptor(CompletionPayload(void), VoidCompletions);
pub const ExistsAcceptor = ResultAcceptor(CompletionPayload(bool), ExistsCompletions);
pub const SizeAcceptor = ResultAcceptor(CompletionPayload(u64), SizeCompletions);
pub const StatAcceptor = ResultAcceptor(CompletionPayload(OwnedS3Stat), StatCompletions);

fn completeOwned(completion: anytype, value: anytype) void {
    var payload = value;
    const owned = bun.default_allocator.create(@TypeOf(payload)) catch {
        payload.deinit();
        completion.outOfMemory();
        return;
    };
    owned.* = payload;
    completion.complete(owned);
}

const bun = @import("bun");
const S3Error = bun.S3.Error.S3Error;
const S3Stat = @import("../S3Stat.zig").S3Stat;

const FailureSchema = S3ClientClassSchema.memberKind("list", .method);
const Failure = bun.bindgen.DomainErrorPayload(FailureSchema, .s3);
