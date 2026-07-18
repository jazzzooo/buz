const MySQLStatement = @This();
const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});

result_layout: ResultLayout = .{},
ref_count: RefCount = RefCount.init(),
statement_id: u32 = 0,
params: []Param = &[_]Param{},
params_received: u32 = 0,

columns: []ColumnDefinition41 = &[_]ColumnDefinition41{},
columns_received: u32 = 0,

signature: Signature,
status: Status = Status.parsing,
error_response: ErrorPacket = .{ .error_code = 0 },
execution_flags: ExecutionFlags = .{},
result_count: u64 = 0,

pub const ExecutionFlags = packed struct(u8) {
    header_received: bool = false,
    need_to_send_params: bool = true,
    /// In legacy protocol (CLIENT_DEPRECATE_EOF not negotiated), tracks whether
    /// the intermediate EOF packet between column definitions and row data has
    /// been consumed. This prevents the intermediate EOF from being mistakenly
    /// treated as end-of-result-set.
    columns_eof_received: bool = false,
    _: u5 = 0,
};

pub const Status = enum {
    pending,
    parsing,
    prepared,
    failed,
};

pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

pub fn reset(this: *MySQLStatement) void {
    this.result_count = 0;
    this.columns_received = 0;
    this.execution_flags = .{};
}

pub fn beginColumns(this: *MySQLStatement, count: usize) !void {
    this.columns_received = 0;
    if (this.columns.len == count) return;

    this.result_layout.deinit();
    for (this.columns) |*column| column.deinit();
    if (this.columns.len > 0) bun.default_allocator.free(this.columns);

    this.columns = &.{};
    this.columns = try bun.default_allocator.alloc(ColumnDefinition41, count);
    for (this.columns) |*column| column.* = .{};
}

pub fn decodeColumn(this: *MySQLStatement, reader: anytype) !void {
    bun.debugAssert(this.columns_received < this.columns.len);

    var column: ColumnDefinition41 = .{};
    errdefer column.deinit();
    try column.decode(reader);

    const existing = &this.columns[this.columns_received];
    if (this.result_layout.initialized and !existing.name_or_index.eql(column.name_or_index)) {
        this.result_layout.deinit();
    }
    existing.deinit();
    existing.* = column;
    this.columns_received += 1;
}

pub fn deinit(this: *MySQLStatement) void {
    debug("MySQLStatement deinit", .{});

    for (this.columns) |*column| {
        column.deinit();
    }
    if (this.columns.len > 0) {
        bun.default_allocator.free(this.columns);
    }
    if (this.params.len > 0) {
        bun.default_allocator.free(this.params);
    }
    this.result_layout.deinit();
    this.error_response.deinit();
    this.signature.deinit();
    bun.destroy(this);
}

pub fn layout(this: *MySQLStatement, owner: ?JSValue, globalObject: *jsc.JSGlobalObject) *const ResultLayout {
    if (!this.result_layout.initialized) {
        this.result_layout.init(this.columns, owner, globalObject);
    }
    return &this.result_layout;
}
pub const Param = @import("../../sql/mysql/MySQLParam.zig").Param;
const _ParamUnused = struct {
    type: types.FieldType,
    flags: ColumnDefinition41.ColumnFlags,
};
const debug = bun.Output.scoped(.MySQLStatement, .hidden);

const ResultLayout = @import("../shared/ResultLayout.zig");
const ColumnDefinition41 = @import("../../sql/mysql/protocol/ColumnDefinition41.zig");
const ErrorPacket = @import("../../sql/mysql/protocol/ErrorPacket.zig");
const Signature = @import("./protocol/Signature.zig");
const types = @import("../../sql/mysql/MySQLTypes.zig");

const bun = @import("bun");

const jsc = bun.jsc;
const JSValue = jsc.JSValue;
