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

    pub fn toPayload(this: *const @This()) bun.OOM!PostgresErrorJSC.OwnedPayload {
        return switch (this.*) {
            .protocol => |err| ErrorResponseJSC.toPayload(err),
            .postgres_error => |err| {
                var message_buffer: [256]u8 = undefined;
                const description = AnyPostgresErrorModule.describe(null, err, &message_buffer);
                return PostgresErrorJSC.createPostgresErrorPayload(description.message, description.options);
            },
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

pub fn layout(this: *PostgresSQLStatement, values: *const SQLTypes.BindingValues) bun.JSError!*const ResultLayout {
    if (!this.result_layout.initialized) {
        try this.result_layout.init(this.fields, values);
    }
    return &this.result_layout;
}

const debug = bun.Output.scoped(.Postgres, .visible);

const ResultLayout = @import("../../sql_jsc/shared/ResultLayout.zig");
const SQLTypes = @import("../../sql_jsc/shared/SQLTypes.zig");
const Signature = @import("../../sql_jsc/postgres/Signature.zig");
const protocol = @import("../../sql/postgres/PostgresProtocol.zig");

const AnyPostgresErrorModule = @import("../../sql/postgres/AnyPostgresError.zig");
const AnyPostgresError = AnyPostgresErrorModule.AnyPostgresError;
const PostgresErrorJSC = @import("./error_jsc.zig");
const ErrorResponseJSC = @import("./protocol/error_response_jsc.zig");

const types = @import("../../sql/postgres/PostgresTypes.zig");
const int4 = types.int4;

const bun = @import("bun");
