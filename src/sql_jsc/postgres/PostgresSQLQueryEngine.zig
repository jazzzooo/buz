const PostgresSQLQuery = @This();
const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});

query: PostgresQuery,
thisValue: bindgen.WrapperReference(.{PostgresSQLQueryClassSchema}) = .empty(),
binding: SQLTypes.BindingValues,
pending_value: ?SQLTypes.ResultRows,
columns: ?SQLTypes.BindingColumns,
target: ?QueryTarget = null,
ref_count: RefCount = RefCount.init(),

pub const JSBinding = struct {
    bindgen_state: bindgen.ClassState = .{},
    query: bindgen.OwnedNative(PostgresSQLQuery, .vm),

    pub const destroy = @This().deinit;

    fn deinit(this: *JSBinding) void {
        this.query.deinit();
        bun.destroy(this);
    }

    pub fn memoryUsage(this: *const JSBinding, _: bun.bindgen.MemoryUsageContext(.any)) usize {
        return @sizeOf(JSBinding) + this.query.get().estimatedSize();
    }

    pub fn doCancel(
        _: *JSBinding,
        _: bindgen.CallContext(PostgresSQLQueryCancelSchema),
        _: bindgen.Args(PostgresSQLQueryCancelSchema),
    ) bun.JSError!void {}

    pub fn doDone(
        _: *JSBinding,
        _: bindgen.CallContext(PostgresSQLQueryDoneSchema),
        _: bindgen.Args(PostgresSQLQueryDoneSchema),
    ) bun.JSError!void {}

    pub fn doRun(
        this: *JSBinding,
        context: bindgen.CallContext(PostgresSQLQueryRunSchema),
        args: bindgen.Args(PostgresSQLQueryRunSchema),
    ) bindgen.CallError(PostgresSQLQueryRunSchema)!void {
        return this.runFromBinding(context, args);
    }

    pub fn runFromBinding(
        this: *JSBinding,
        context: bindgen.CallContext(PostgresSQLQueryRunSchema),
        args: bindgen.Args(PostgresSQLQueryRunSchema),
    ) bindgen.CallError(PostgresSQLQueryRunSchema)!void {
        const global = context.viewToken().globalObject();
        const connection = args.connection.get(PostgresSQLConnection.JSBinding).connection.get();
        const query = this.query.get();
        try query.setTargetView(args.target);
        const outcome = query.run(global, connection) catch |err| {
            query.markRunFailed();
            return err;
        };
        switch (outcome) {
            .started => {},
            .cached_statement_failed => {
                defer query.markRunFailed();
                const payload = try query.getStatement().?.error_response.?.toPayload();
                return context.fail(.postgres_failure, payload);
            },
            .failed => |failure| {
                defer query.markRunFailed();
                var message_buffer: [256]u8 = undefined;
                const description = AnyPostgresErrorModule.describe(failure.message, failure.err, &message_buffer);
                const payload = try PostgresErrorJSC.createPostgresErrorPayload(
                    description.message,
                    description.options,
                );
                return context.fail(.postgres_failure, payload);
            },
        }
    }

    pub fn setModeFromJS(
        this: *JSBinding,
        _: bindgen.CallContext(PostgresSQLQuerySetModeSchema),
        args: bindgen.Args(PostgresSQLQuerySetModeSchema),
    ) bun.JSError!void {
        this.query.get().query.setResultMode(@fromBackingInt(@intCast(args.mode)));
    }

    pub fn setPendingValueFromJS(
        this: *JSBinding,
        _: bindgen.CallContext(PostgresSQLQuerySetPendingValueSchema),
        args: bindgen.Args(PostgresSQLQuerySetPendingValueSchema),
    ) bun.JSError!void {
        if (args.value) |value| {
            if (value) |array| {
                try this.query.get().setPendingValueView(array);
                return;
            }
        }
        this.query.get().clearPendingValue();
    }
};

pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

fn getTarget(this: *PostgresSQLQuery, clean_target: bool) ?QueryTarget {
    const target = if (this.target) |*value| value else return null;
    if (!clean_target) return target.clone();
    const result = target.take();
    this.target = null;
    return result;
}

fn setTargetView(this: *PostgresSQLQuery, value: anytype) bun.JSError!void {
    const retained = try value.toOwned();
    if (this.target) |*target| target.deinit();
    this.target = retained;
}

pub fn pendingRows(this: *const PostgresSQLQuery) ?*const SQLTypes.ResultRows {
    return if (this.pending_value) |*rows| rows else null;
}

pub fn adoptPendingRows(this: *PostgresSQLQuery, rows: SQLTypes.ResultRows) void {
    this.clearPendingValue();
    this.pending_value = rows;
}

pub fn setPendingValueView(this: *PostgresSQLQuery, value: anytype) bun.JSError!void {
    const retained = try value.toOwned();
    this.clearPendingValue();
    this.pending_value = retained;
}

pub fn clearPendingValue(this: *PostgresSQLQuery) void {
    if (this.pending_value) |*rows| rows.deinit();
    this.pending_value = null;
}

pub fn columnsValue(this: *const PostgresSQLQuery) ?*const SQLTypes.BindingColumns {
    return if (this.columns) |*columns| columns else null;
}

pub fn bindingValues(this: *const PostgresSQLQuery) *const SQLTypes.BindingValues {
    return &this.binding;
}

pub fn getStatus(this: *const PostgresSQLQuery) PostgresQuery.Status {
    return this.query.getStatus();
}

pub fn setStatus(this: *PostgresSQLQuery, status: PostgresQuery.Status) void {
    this.query.setStatus(status);
}

pub fn getStatement(this: *const PostgresSQLQuery) ?*PostgresSQLStatement {
    return this.query.getStatement();
}

pub fn queryText(this: *const PostgresSQLQuery) bun.String {
    return this.query.text();
}

pub fn isSimple(this: *const PostgresSQLQuery) bool {
    return this.query.isSimple();
}

pub fn isPipelined(this: *const PostgresSQLQuery) bool {
    return this.query.isPipelined();
}

pub fn setPipelined(this: *PostgresSQLQuery, value: bool) void {
    this.query.setPipelined(value);
}

pub fn setBinary(this: *PostgresSQLQuery, value: bool) void {
    this.query.setBinary(value);
}

pub fn isBinary(this: *const PostgresSQLQuery) bool {
    return this.query.isBinary();
}

pub fn isBigintSupported(this: *const PostgresSQLQuery) bool {
    return this.query.isBigintSupported();
}

pub fn getResultMode(this: *const PostgresSQLQuery) SQLQueryResultMode {
    return this.query.getResultMode();
}

pub fn isAlive(this: *const PostgresSQLQuery) bun.JSError!bool {
    return !(try this.thisValue.isEmpty());
}

pub fn deinit(this: *@This()) void {
    this.query.cleanup();
    this.binding.deinit();
    if (this.pending_value) |*value| value.deinit();
    if (this.columns) |*value| value.deinit();
    if (this.target) |*value| value.deinit();
    bun.default_allocator.destroy(this);
}

pub fn destroy(this: *@This()) void {
    debug("PostgresSQLQuery finalize", .{});
    this.thisValue.finalize();
    this.deref();
}

pub fn onWriteFail(
    this: *@This(),
    err: AnyPostgresError,
    globalObject: *jsc.JSGlobalObject,
) void {
    this.rejectPostgresError(null, err, globalObject);
}
fn rejectPostgresError(
    this: *@This(),
    message: ?[]const u8,
    err: AnyPostgresError,
    globalObject: *jsc.JSGlobalObject,
) void {
    if (CallbackError.pending(globalObject)) |failure| return this.rejectWithException(failure, globalObject);
    switch (err) {
        error.JSError, error.JSTerminated, error.OutOfMemory => |failure| this.rejectWithException(failure, globalObject),
        error.ShortRead => bun.unreachablePanic("Assertion failed: ShortRead should be handled by the caller in postgres", .{}),
        else => {
            var message_buffer: [256]u8 = undefined;
            const description = AnyPostgresErrorModule.describe(message, err, &message_buffer);
            this.rejectWithPayload(description.message, description.options, globalObject);
        },
    }
}

pub fn rejectWithPayload(
    this: *@This(),
    message: []const u8,
    options: PostgresErrorOptions,
    globalObject: *jsc.JSGlobalObject,
) void {
    var payload = PostgresErrorJSC.createPostgresErrorPayload(message, options) catch {
        this.rejectWithException(error.OutOfMemory, globalObject);
        return;
    };
    defer PostgresErrorJSC.deinitPostgresErrorPayload(&payload);
    this.rejectWithError(null, payload, globalObject);
}

pub fn rejectWithException(this: *@This(), failure: bun.JSError, globalObject: *jsc.JSGlobalObject) void {
    this.ref();
    defer this.deref();
    if (globalObject.bunVM().isShuttingDown()) return this.markRunFailed();
    var original = CallbackError.takeRoot(globalObject, failure) catch |capture_error| {
        this.markRunFailed();
        return globalObject.reportActiveExceptionAsUnhandled(capture_error);
    };
    defer original.deinit();
    this.rejectWithRoot(&original, globalObject);
}

pub fn rejectWithRoot(this: *@This(), original: *const bindgen.Root, globalObject: *jsc.JSGlobalObject) void {
    this.rejectWithError(original, null, globalObject);
}

fn rejectWithError(
    this: *@This(),
    original: ?*const bindgen.Root,
    payload: ?PostgresQueryErrorPayload,
    globalObject: *jsc.JSGlobalObject,
) void {
    this.ref();
    defer this.deref();
    if (!this.query.fail()) return;
    defer this.thisValue.downgrade();
    defer this.allowGC();
    const vm = globalObject.bunVM();
    if (vm.isShuttingDown() or globalObject.pendingExceptionKind() == .termination) return;
    if (this.thisValue.isEmpty() catch |err| return globalObject.reportActiveExceptionAsUnhandled(err)) return;
    var target = this.getTarget(true) orelse return;
    defer target.deinit();

    const callback = if (vm.rareData().postgresql_context.onQueryRejectFn) |*value| value else return;
    const event_loop = vm.eventLoop();
    event_loop.enter();
    defer event_loop.exit();
    var invocation: PostgresSQLContext.QueryRejectCallback.Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    var original_value = if (original) |value| bindgen.AnyResult.fromRoot(value, &invocation) else bindgen.AnyResult.initUndefined(&invocation);
    defer original_value.deinit();
    invocation.call(.{
        .query = target.operand(&invocation),
        .original = original_value.operand(&invocation),
        .payload = invocation.argument("payload", payload),
    }) catch |error_value| invocation.reportActiveException(error_value);
}
pub fn onError(this: *@This(), err: PostgresSQLStatement.Error, globalObject: *jsc.JSGlobalObject) void {
    switch (err) {
        .protocol => |protocol_error| {
            var payload = ErrorResponseJSC.toPayload(protocol_error) catch {
                this.rejectWithException(error.OutOfMemory, globalObject);
                return;
            };
            defer PostgresErrorJSC.deinitPostgresErrorPayload(&payload);
            this.rejectWithError(null, payload, globalObject);
        },
        .postgres_error => |postgres_error| this.rejectPostgresError(null, postgres_error, globalObject),
    }
}

pub fn allowGC(this: *PostgresSQLQuery) void {
    this.binding.deinit();
    this.clearPendingValue();
    if (this.columns) |*value| value.deinit();
    this.columns = null;
    if (this.target) |*value| value.deinit();
    this.target = null;
}

pub fn markRunFailed(this: *PostgresSQLQuery) void {
    _ = this.query.fail();
    this.thisValue.downgrade();
    this.allowGC();
}

fn consumePendingRows(this: *PostgresSQLQuery) ?SQLTypes.ResultRows {
    const result = this.pending_value;
    this.pending_value = null;
    return result;
}

pub fn onResult(this: *@This(), command_tag_str: []const u8, globalObject: *jsc.JSGlobalObject, is_last: bool) void {
    this.ref();
    defer this.deref();
    if (!this.query.result(is_last)) return;
    const tag = CommandTag.init(command_tag_str);
    defer if (is_last) {
        this.allowGC();
        this.thisValue.downgrade();
    };
    if (this.thisValue.isEmpty() catch |err| return globalObject.reportActiveExceptionAsUnhandled(err)) return;
    var target = this.getTarget(is_last) orelse return;
    defer target.deinit();

    const vm = jsc.VirtualMachine.get();
    const callback = if (vm.rareData().postgresql_context.onQueryResolveFn) |*value| value else return;
    const event_loop = vm.eventLoop();
    var pending = this.consumePendingRows();
    defer if (pending) |*value| value.deinit();

    event_loop.enter();
    defer event_loop.exit();

    var invocation: PostgresSQLContext.QueryResolveCallback.Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    var command_tag = QueryCommandTag.init(tag) catch {
        return globalObject.reportActiveExceptionAsUnhandled(globalObject.throwOutOfMemory());
    };
    defer QueryCommandTag.deinit(&command_tag);
    invocation.call(.{
        .query = target.operand(&invocation),
        .result = if (pending) |*value| value.operand(&invocation) else null,
        .commandTag = QueryCommandTag.operand(&command_tag),
        .count = QueryCommandTag.count(tag),
        .isLast = is_last,
    }) catch |err| invocation.reportActiveException(err);
}

pub fn estimatedSize(this: *PostgresSQLQuery) usize {
    _ = this;
    return @sizeOf(PostgresSQLQuery);
}

pub fn call(
    context: bindgen.CallContext(CreateQuerySchema),
    args: bindgen.Args(CreateQuerySchema),
) bindgen.CallError(CreateQuerySchema)!bindgen.Return(CreateQuerySchema) {
    const globalThis = context.viewToken().globalObject();
    const bigint = args.bigint orelse false;
    const simple = args.simple orelse false;
    if (simple) {
        if (context.engineIn("SQLTypes", "bindingValuesLength").call(.{ .values = args.values.operand(context) }) > 0) {
            return context.fail(.simple_with_parameters, {});
        }
        if (args.query.length() >= std.math.maxInt(i32)) {
            return context.fail(.query_too_long, {});
        }
    }

    var values = try args.values.toOwned();
    defer values.deinit();
    var pending = try args.pendingValue.toOwned();
    defer pending.deinit();
    var columns = if (args.columns) |value| try value.toOwned() else null;
    defer if (columns) |*value| value.deinit();
    const ptr = try bun.default_allocator.create(PostgresSQLQuery);
    var query = args.query.toOwned();
    ptr.* = .{
        .query = PostgresQuery.init(query.takeBunString(), bigint, simple),
        .binding = values.take(),
        .pending_value = pending.take(),
        .columns = if (columns) |*value| value.take() else null,
    };

    const binding = bun.new(JSBinding, .{ .query = .init(ptr) });
    var this_ref = try PostgresSQLQueryClass.adoptNativeRef(binding, globalThis);
    errdefer this_ref.deinit();
    ptr.thisValue = try .initWeakRef(&this_ref);

    return this_ref;
}

pub fn run(this: *PostgresSQLQuery, globalObject: *jsc.JSGlobalObject, connection: *PostgresSQLConnection) RunError!RunOutcome {
    connection.ref();
    defer connection.deref();
    const poll_was_active = connection.poll_ref.isActive();
    connection.poll_ref.ref(globalObject.bunVM());
    var request_committed = false;
    defer if (!request_committed and !poll_was_active) connection.poll_ref.unref(globalObject.bunVM());

    this.ref();
    defer if (!request_committed) this.deref();
    const was_strong = this.thisValue.isStrong();
    try this.thisValue.upgrade();
    defer if (!request_committed and !was_strong) this.thisValue.downgrade();
    const outcome = try this.query.run(
        this,
        &connection.connection,
        this.bindingValues(),
        this.columnsValue(),
    );
    switch (outcome) {
        .started => |did_write| {
            if (did_write) {
                connection.flushDataAndResetTimeout();
            } else {
                connection.resetConnectionTimeout();
                if (!this.query.isSimple()) connection.connection.advanceAndFlush();
            }
            request_committed = true;
        },
        .cached_statement_failed, .failed => {},
    }
    return outcome;
}
const debug = bun.Output.scoped(.Postgres, .visible);

const PostgresQuery = @import("./PostgresQuery.zig");
const PostgresSQLConnection = @import("./PostgresSQLConnectionEngine.zig");
const PostgresSQLContext = @import("./PostgresSQLContextEngine.zig");
const PostgresSQLStatement = @import("./PostgresSQLStatement.zig");
const bun = @import("bun");
const bindgen = bun.bindgen;
const std = @import("std");
const CommandTag = @import("../../sql/postgres/CommandTag.zig").CommandTag;
const QueryCommandTag = @import("../shared/QueryCommandTag.zig");
const SQLTypes = @import("../shared/SQLTypes.zig");
const SQLQueryResultMode = @import("../../sql/shared/SQLQueryResultMode.zig").SQLQueryResultMode;

const AnyPostgresErrorModule = @import("../../sql/postgres/AnyPostgresError.zig");
const AnyPostgresError = AnyPostgresErrorModule.AnyPostgresError;
const PostgresErrorOptions = AnyPostgresErrorModule.PostgresErrorOptions;
const PostgresErrorJSC = @import("./error_jsc.zig");
const ErrorResponseJSC = @import("./protocol/error_response_jsc.zig");

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const CallbackError = @import("../shared/CallbackError.zig");

pub const RunError = PostgresQuery.RunError;
pub const RunOutcome = PostgresQuery.RunOutcome;

const PostgresSQLQueryBindingModule = bindgen.Module("PostgresSQLQuery");
const PostgresSQLQueryClassSchema = PostgresSQLQueryBindingModule.class("PostgresSQLQuery");
const PostgresSQLQueryClass = bindgen.Class(PostgresSQLQueryClassSchema, JSBinding);
const PostgresSQLQueryCancelSchema = PostgresSQLQueryClassSchema.member("cancel");
const PostgresSQLQueryDoneSchema = PostgresSQLQueryClassSchema.member("done");
const PostgresSQLQueryRunSchema = PostgresSQLQueryClassSchema.member("run");
const PostgresSQLQuerySetModeSchema = PostgresSQLQueryClassSchema.member("setMode");
const PostgresSQLQuerySetPendingValueSchema = PostgresSQLQueryClassSchema.member("setPendingValue");
const QueryTarget = bindgen.OwnedBrandedValue(PostgresSQLQueryRunSchema.args[1].ArgumentType);
const SQLBindings = bindgen.Module("SQLBinding");
const CreateQuerySchema = SQLBindings.function("postgresCreateQuery");
const PostgresQueryResolveCallbackType = SQLBindings.function("postgresInit").args[0].ArgumentType;
const PostgresQueryRejectCallbackType = SQLBindings.function("postgresInit").args[1].ArgumentType;
const PostgresQueryErrorPayload = PostgresErrorJSC.OwnedPayload;
pub const CreateQueryBinding = bindgen.Fn(CreateQuerySchema, call);

comptime {
    _ = PostgresSQLQueryClass;
    _ = CreateQueryBinding;
}
