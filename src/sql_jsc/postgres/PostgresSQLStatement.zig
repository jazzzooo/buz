const PostgresSQLStatement = @This();
const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
result_layout: ResultLayout = .{},
ref_count: RefCount = RefCount.init(),
fields: []protocol.FieldDescription = &[_]protocol.FieldDescription{},
parameters: []const int4 = &[_]int4{},
signature: Signature,
status: Status = Status.pending,
error_response: ?Error = null,
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

pub const Error = union(enum) {
    protocol: protocol.ErrorResponse,
    postgres_error: AnyPostgresError,

    pub fn deinit(this: *@This()) void {
        switch (this.*) {
            .protocol => |*err| err.deinit(),
            .postgres_error => {},
        }
    }

    pub fn toJS(this: *const @This(), globalObject: *jsc.JSGlobalObject) JSError!JSValue {
        return switch (this.*) {
            .protocol => |err| err.toJS(globalObject),
            .postgres_error => |err| postgresErrorToJS(globalObject, null, err),
        };
    }
};

pub const Status = enum {
    pending,
    parsing,
    prepared,
    failed,

    pub fn isRunning(this: @This()) bool {
        return this == .parsing;
    }
};

pub fn deinit(this: *PostgresSQLStatement) void {
    debug("PostgresSQLStatement deinit", .{});

    this.ref_count.assertNoRefs();

    for (this.fields) |*field| {
        field.deinit();
    }
    bun.default_allocator.free(this.fields);
    bun.default_allocator.free(this.parameters);
    this.result_layout.deinit();
    if (this.error_response) |err| {
        this.error_response = null;
        var _error = err;
        _error.deinit();
    }
    this.signature.deinit();
    bun.default_allocator.destroy(this);
}

pub fn layout(this: *PostgresSQLStatement, owner: JSValue, globalObject: *jsc.JSGlobalObject) *const ResultLayout {
    if (!this.result_layout.initialized) {
        this.result_layout.init(this.fields, owner, globalObject);
    }
    return &this.result_layout;
}

const debug = bun.Output.scoped(.Postgres, .visible);

const ResultLayout = @import("../../sql_jsc/shared/ResultLayout.zig");
const Signature = @import("../../sql_jsc/postgres/Signature.zig");
const protocol = @import("../../sql/postgres/PostgresProtocol.zig");

const AnyPostgresError = @import("../../sql/postgres/AnyPostgresError.zig").AnyPostgresError;
const postgresErrorToJS = @import("../../sql/postgres/AnyPostgresError.zig").postgresErrorToJS;

const types = @import("../../sql/postgres/PostgresTypes.zig");
const int4 = types.int4;

const bun = @import("bun");
const JSError = bun.JSError;

const jsc = bun.jsc;
const JSValue = jsc.JSValue;
