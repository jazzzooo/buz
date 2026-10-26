const JSMySQLQuery = @This();
const RefCount = bun.ptr.RefCount(@This(), "__ref_count", deinit, .{});

pub const JSBinding = struct {
    bindgen_state: bindgen.ClassState = .{},
    query: bindgen.OwnedNative(JSMySQLQuery, .vm),

    pub const destroy = @This().deinit;

    fn deinit(this: *JSBinding) void {
        this.query.deinit();
        bun.destroy(this);
    }

    pub fn memoryUsage(this: *const JSBinding, _: bun.bindgen.MemoryUsageContext(.any)) usize {
        return @sizeOf(JSBinding) + this.query.get().estimatedSize();
    }

    pub fn hasPendingActivity(this: *const JSBinding) bool {
        return this.query.get().wrapper_active.load(.acquire);
    }

    pub fn doCancel(
        _: *JSBinding,
        _: bindgen.CallContext(MySQLQueryCancelSchema),
        _: bindgen.Args(MySQLQueryCancelSchema),
    ) bun.JSError!void {}

    pub fn doDone(
        _: *JSBinding,
        _: bindgen.CallContext(MySQLQueryDoneSchema),
        _: bindgen.Args(MySQLQueryDoneSchema),
    ) bun.JSError!void {}

    pub fn doRun(
        this: *JSBinding,
        context: bindgen.CallContext(MySQLQueryRunSchema),
        args: bindgen.Args(MySQLQueryRunSchema),
    ) bindgen.CallError(MySQLQueryRunSchema)!void {
        return this.runFromBinding(context, args);
    }

    pub fn runFromBinding(
        this: *JSBinding,
        context: bindgen.CallContext(MySQLQueryRunSchema),
        args: bindgen.Args(MySQLQueryRunSchema),
    ) bindgen.CallError(MySQLQueryRunSchema)!void {
        const query = this.query.get();
        if (query.submitting or query.queued or query.isCompleted()) return;
        query.ref();
        defer query.deref();
        query.submitting = true;
        defer query.submitting = false;

        const connection = args.connection.get(MySQLConnection.JSBinding).connection.get();
        try query.setTargetView(args.target);
        const outcome = query.run(connection) catch |err| {
            query.markAsFailed();
            return err;
        };
        switch (outcome) {
            .started => connection.enqueueRequest(query),
            .cached_statement_failed => {
                defer query.markAsFailed();
                const description = query.getStatement().?.error_response.describe();
                const payload = try MySQLErrorJSC.createMySQLErrorPayload(
                    description.message,
                    description.options,
                );
                return context.fail(.mysql_failure, payload);
            },
            .failed => |failure| {
                defer query.markAsFailed();
                const description = AnyMySQLError.describe(failure.message, failure.err);
                const payload = try MySQLErrorJSC.createMySQLErrorPayload(
                    description.message,
                    .{ .code = description.code },
                );
                return context.fail(.mysql_failure, payload);
            },
        }
    }

    pub fn setModeFromJS(
        this: *JSBinding,
        _: bindgen.CallContext(MySQLQuerySetModeSchema),
        args: bindgen.Args(MySQLQuerySetModeSchema),
    ) bun.JSError!void {
        const mode: SQLQueryResultMode = @fromBackingInt(@intCast(args.mode));
        this.query.get().query.setResultMode(mode);
    }

    pub fn setPendingValueFromJS(
        this: *JSBinding,
        _: bindgen.CallContext(MySQLQuerySetPendingValueSchema),
        args: bindgen.Args(MySQLQuerySetPendingValueSchema),
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

js_wrapper: bindgen.ClassWrapperHandle(MySQLQueryClassSchema, .weak) = .empty,
wrapper_active: std.atomic.Value(bool) = .init(false),
// unfortunally we cannot use #ref_count here
__ref_count: RefCount = RefCount.init(),
queue_node: std.DoublyLinkedList.Node = .{},
queued: bool = false,
submitting: bool = false,
vm: *jsc.VirtualMachine,
globalObject: *jsc.JSGlobalObject,
query: MySQLQuery,
binding: SQLTypes.BindingValues,
pending_value: ?SQLTypes.ResultRows,
columns: ?SQLTypes.BindingColumns,
target: ?QueryTarget = null,

pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

pub fn estimatedSize(this: *@This()) usize {
    _ = this;
    return @sizeOf(@This());
}

fn deinit(this: *@This()) void {
    bun.assert(!this.queued and !this.submitting);
    this.binding.deinit();
    if (this.pending_value) |*value| value.deinit();
    if (this.columns) |*value| value.deinit();
    if (this.target) |*value| value.deinit();
    this.query.cleanup();
    bun.destroy(this);
}

pub fn destroy(this: *@This()) void {
    debug("MySQLQuery finalize", .{});
    this.js_wrapper.deinit();
    this.deref();
}

pub fn createInstance(
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
    const this = try bun.default_allocator.create(@This());
    var query = args.query.toOwned();
    this.* = .{
        .query = MySQLQuery.init(
            query.takeBunString(),
            bigint,
            simple,
        ),
        .globalObject = globalThis,
        .vm = globalThis.bunVM(),
        .binding = values.take(),
        .pending_value = pending.take(),
        .columns = if (columns) |*value| value.take() else null,
    };

    const binding = bun.new(JSBinding, .{ .query = .init(this) });
    var this_ref = try MySQLQueryClass.adoptNativeRef(binding, globalThis);
    errdefer this_ref.deinit();
    this.js_wrapper = try MySQLQueryClass.WeakWrapper.initRef(&this_ref);

    return this_ref;
}

pub fn resolve(
    this: *@This(),
    result: MySQLQueryResult,
) void {
    this.ref();
    const is_last_result = result.is_last_result;
    defer {
        if (is_last_result) {
            this.releaseRetainedValues();
            this.wrapper_active.store(false, .release);
        }
        this.deref();
    }

    if (!this.query.result(is_last_result)) {
        return;
    }
    if (this.vm.isShuttingDown()) {
        return;
    }

    var target = this.cloneTarget() orelse return;
    defer target.deinit();
    var wrapper = (this.js_wrapper.toOwned() catch |err| return this.globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer wrapper.deinit();
    const tag: CommandTag = .{ .SELECT = result.result_count };

    const callback = if (this.vm.rareData().mysql_context.onQueryResolveFn) |*value| value else return;

    const event_loop = this.vm.eventLoop();

    var pending = this.takePendingRows();
    defer if (pending) |*value| value.deinit();

    event_loop.enter();
    defer event_loop.exit();

    var invocation: MySQLContext.QueryResolveCallback.Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    var command_tag = QueryCommandTag.init(tag) catch {
        return this.globalObject.reportActiveExceptionAsUnhandled(this.globalObject.throwOutOfMemory());
    };
    defer QueryCommandTag.deinit(&command_tag);
    invocation.call(.{
        .query = target.operand(&invocation),
        .result = if (pending) |*value| value.operand(&invocation) else null,
        .commandTag = QueryCommandTag.operand(&command_tag),
        .count = QueryCommandTag.count(tag),
        .isLast = is_last_result,
        .lastInsertRowid = @floatFromInt(result.last_insert_id),
        .affectedRows = @floatFromInt(result.affected_rows),
    }) catch |err| invocation.reportActiveException(err);
}

pub fn markAsFailed(this: *@This()) void {
    this.ref();
    defer this.deref();
    this.wrapper_active.store(false, .release);
    _ = this.query.fail();
    this.releaseRetainedValues();
}

pub fn reject(this: *@This(), err: AnyMySQLError.Error) void {
    this.rejectWithMessage("Failed to bind query", err);
}

pub fn rejectWithMessage(this: *@This(), message: []const u8, err: AnyMySQLError.Error) void {
    if (this.vm.isShuttingDown()) {
        this.markAsFailed();
        return;
    }
    if (CallbackError.pending(this.globalObject)) |failure| {
        this.rejectWithException(failure);
    } else {
        switch (err) {
            error.JSError, error.JSTerminated, error.OutOfMemory => |failure| this.rejectWithException(failure),
            error.ShortRead => bun.unreachablePanic("Assertion failed: ShortRead should be handled by the caller in mysql", .{}),
            else => {
                const description = AnyMySQLError.describe(message, err);
                this.rejectWithPayload(description.message, .{ .code = description.code });
            },
        }
    }
}

pub fn rejectWithException(this: *@This(), failure: bun.JSError) void {
    this.ref();
    defer this.deref();
    if (this.vm.isShuttingDown()) {
        this.markAsFailed();
        return;
    }
    var original = CallbackError.takeRoot(this.globalObject, failure) catch |capture_error| {
        this.markAsFailed();
        return this.globalObject.reportActiveExceptionAsUnhandled(capture_error);
    };
    defer original.deinit();
    this.rejectWithRoot(&original);
}

pub fn rejectWithRoot(this: *@This(), original: *const bindgen.Root) void {
    this.rejectWithError(original, null);
}

pub fn rejectWithPayload(this: *@This(), message: []const u8, options: ErrorPacket.MySQLErrorOptions) void {
    var payload = MySQLErrorJSC.createMySQLErrorPayload(message, options) catch {
        this.rejectWithException(error.OutOfMemory);
        return;
    };
    defer MySQLErrorJSC.deinitMySQLErrorPayload(&payload);
    this.rejectWithError(null, payload);
}

fn rejectWithError(this: *@This(), original: ?*const bindgen.Root, payload: ?MySQLErrorPayload) void {
    this.ref();

    defer {
        this.releaseRetainedValues();
        this.wrapper_active.store(false, .release);
        this.deref();
    }
    if (!this.query.fail()) {
        return;
    }

    if (this.vm.isShuttingDown() or this.globalObject.pendingExceptionKind() == .termination) {
        return;
    }
    var target = this.cloneTarget() orelse return;
    defer target.deinit();

    const callback = if (this.vm.rareData().mysql_context.onQueryRejectFn) |*value| value else return;
    const event_loop = this.vm.eventLoop();
    var wrapper = (this.js_wrapper.toOwned() catch |err| return this.globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer wrapper.deinit();
    event_loop.enter();
    defer event_loop.exit();
    var invocation: MySQLContext.QueryRejectCallback.Invocation = undefined;
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

pub fn run(this: *@This(), connection: *MySQLConnection) MySQLQuery.RunError!MySQLQuery.RunOutcome {
    connection.ref();
    defer connection.deref();
    if (this.vm.isShuttingDown()) {
        debug("run cannot run a query if the VM is shutting down", .{});
        // cannot run a query if the VM is shutting down
        return .started;
    }
    if (!this.query.isPending() or this.query.isBeingPrepared()) {
        debug("run already running or being prepared", .{});
        // already running or completed
        return .started;
    }
    this.wrapper_active.store(true, .release);
    return this.query.runQuery(connection, this.columnsValue(), this.bindingValues());
}
pub inline fn isCompleted(this: *@This()) bool {
    return this.query.isCompleted();
}
pub inline fn isRunning(this: *@This()) bool {
    return this.query.isRunning();
}
pub inline fn isPending(this: *@This()) bool {
    return this.query.isPending();
}
pub inline fn isBeingPrepared(this: *@This()) bool {
    return this.query.isBeingPrepared();
}
pub inline fn isPipelined(this: *@This()) bool {
    return this.query.isPipelined();
}
pub inline fn isSimple(this: *@This()) bool {
    return this.query.isSimple();
}
pub inline fn isBigintSupported(this: *@This()) bool {
    return this.query.isBigintSupported();
}
pub inline fn getResultMode(this: *@This()) SQLQueryResultMode {
    return this.query.getResultMode();
}
// TODO: isolate statement modification away from the connection
pub fn getStatement(this: *@This()) ?*MySQLStatement {
    return this.query.getStatement();
}

pub fn markAsPrepared(this: *@This()) void {
    this.query.markAsPrepared();
}

pub inline fn setPendingValueView(this: *@This(), value: anytype) bun.JSError!void {
    if (this.vm.isShuttingDown()) return;
    const retained = try value.toOwned();
    this.clearPendingValue();
    this.pending_value = retained;
}
pub inline fn clearPendingValue(this: *@This()) void {
    if (this.vm.isShuttingDown()) return;
    if (this.pending_value) |*value| value.deinit();
    this.pending_value = null;
}
fn takePendingRows(this: *@This()) ?SQLTypes.ResultRows {
    if (this.vm.isShuttingDown()) return null;
    const rows = this.pending_value;
    this.pending_value = null;
    return rows;
}

pub inline fn pendingRows(this: *const @This()) ?*const SQLTypes.ResultRows {
    return if (this.pending_value) |*rows| rows else null;
}

pub inline fn adoptPendingRows(this: *@This(), rows: SQLTypes.ResultRows) void {
    this.clearPendingValue();
    this.pending_value = rows;
}

inline fn setTargetView(this: *@This(), value: anytype) bun.JSError!void {
    if (this.vm.isShuttingDown()) return;
    const retained = try value.toOwned();
    if (this.target) |*target| target.deinit();
    this.target = retained;
}
inline fn cloneTarget(this: *@This()) ?QueryTarget {
    if (this.vm.isShuttingDown()) return null;
    return if (this.target) |*target| target.clone() else null;
}

inline fn columnsValue(this: *const @This()) ?*const SQLTypes.BindingColumns {
    return if (this.columns) |*columns| columns else null;
}

pub inline fn bindingValues(this: *const @This()) *const SQLTypes.BindingValues {
    return &this.binding;
}

fn releaseRetainedValues(this: *@This()) void {
    this.binding.deinit();
    if (this.pending_value) |*value| value.deinit();
    this.pending_value = null;
    if (this.columns) |*value| value.deinit();
    this.columns = null;
    if (this.target) |*value| value.deinit();
    this.target = null;
}

const debug = bun.Output.scoped(.MySQLQuery, .visible);

const AnyMySQLError = @import("../../sql/mysql/protocol/AnyMySQLError.zig");
const ErrorPacket = @import("../../sql/mysql/protocol/ErrorPacket.zig");
const MySQLConnection = @import("./MySQLConnectionEngine.zig");
const MySQLContext = @import("./MySQLContextEngine.zig");
const MySQLErrorJSC = @import("./protocol/error_packet_jsc.zig");
const MySQLQuery = @import("./MySQLQuery.zig");
const MySQLQueryResult = @import("../../sql/mysql/MySQLQueryResult.zig");
const MySQLStatement = @import("./MySQLStatement.zig");
const bun = @import("bun");
const bindgen = bun.bindgen;
const std = @import("std");
const CommandTag = @import("../../sql/postgres/CommandTag.zig").CommandTag;
const QueryCommandTag = @import("../shared/QueryCommandTag.zig");
const SQLTypes = @import("../shared/SQLTypes.zig");
const SQLQueryResultMode = @import("../../sql/shared/SQLQueryResultMode.zig").SQLQueryResultMode;

const jsc = bun.jsc;
const CallbackError = @import("../shared/CallbackError.zig");

const MySQLQueryBindingModule = bindgen.Module("MySQLQuery");
const MySQLQueryClassSchema = MySQLQueryBindingModule.class("MySQLQuery");
const MySQLQueryClass = bindgen.Class(MySQLQueryClassSchema, JSBinding);
const MySQLQueryCancelSchema = MySQLQueryClassSchema.member("cancel");
const MySQLQueryDoneSchema = MySQLQueryClassSchema.member("done");
const MySQLQueryRunSchema = MySQLQueryClassSchema.member("run");
const MySQLQuerySetModeSchema = MySQLQueryClassSchema.member("setMode");
const MySQLQuerySetPendingValueSchema = MySQLQueryClassSchema.member("setPendingValue");
const QueryTarget = bindgen.OwnedBrandedValue(MySQLQueryRunSchema.args[1].ArgumentType);
const SQLBindings = bindgen.Module("SQLBinding");
const CreateQuerySchema = SQLBindings.function("mysqlCreateQuery");
const MySQLQueryResolveCallbackType = SQLBindings.function("mysqlInit").args[0].ArgumentType;
const MySQLQueryRejectCallbackType = SQLBindings.function("mysqlInit").args[1].ArgumentType;
const MySQLErrorPayload = MySQLErrorJSC.OwnedPayload;
pub const CreateQueryBinding = bindgen.Fn(CreateQuerySchema, createInstance);

comptime {
    _ = MySQLQueryClass;
    _ = CreateQueryBinding;
}
