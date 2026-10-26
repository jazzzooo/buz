const Signature = @This();
fields: []Param = &.{},
query: []const u8 = "",

pub fn empty() Signature {
    return Signature{
        .fields = &.{},
        .query = "",
    };
}

pub fn deinit(this: *Signature) void {
    if (this.fields.len > 0) {
        bun.default_allocator.free(this.fields);
    }
    if (this.query.len > 0) {
        bun.default_allocator.free(this.query);
    }
}

pub fn hash(this: *const Signature) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, this.query.len);
    hasher.update(this.query);
    for (this.fields) |field| {
        std.hash.autoHash(&hasher, field.type);
        std.hash.autoHash(&hasher, field.flags.toInt());
    }
    return hasher.final();
}

pub fn eql(this: *const Signature, other: *const Signature) bool {
    if (!std.mem.eql(u8, this.query, other.query) or this.fields.len != other.fields.len) return false;
    for (this.fields, other.fields) |left, right| {
        if (left.type != right.type or left.flags.toInt() != right.flags.toInt()) return false;
    }
    return true;
}

pub const MapContext = struct {
    pub fn hash(_: @This(), key: *const Signature) u64 {
        return key.hash();
    }

    pub fn eql(_: @This(), left: *const Signature, right: *const Signature) bool {
        return left.eql(right);
    }
};

pub fn generate(
    query: []const u8,
    values: *const SQLTypes.BindingValues,
    columns: ?*const SQLTypes.BindingColumns,
) AnyMySQLError.Error!Signature {
    var fields = std.array_list.Managed(Param).init(bun.default_allocator);
    defer fields.deinit();

    if (SQLParameters.count(values, columns) > std.math.maxInt(u16)) return error.Overflow;
    var hints = try SQLParameters.inferMySQL(values, columns);
    defer hints.deinit();
    var iterator = hints.iterator();
    while (iterator.next()) |hint| {
        const field: Param = switch (hint.value) {
            .null_value => .{ .type = .MYSQL_TYPE_NULL, .flags = .{} },
            .string => .{ .type = .MYSQL_TYPE_STRING, .flags = .{} },
            .datetime => .{ .type = .MYSQL_TYPE_DATETIME, .flags = .{} },
            .blob => .{ .type = .MYSQL_TYPE_BLOB, .flags = .{} },
            .signed_longlong => .{ .type = .MYSQL_TYPE_LONGLONG, .flags = .{} },
            .unsigned_longlong => .{ .type = .MYSQL_TYPE_LONGLONG, .flags = .{ .UNSIGNED = true } },
            .signed_long => .{ .type = .MYSQL_TYPE_LONG, .flags = .{} },
            .unsigned_long => .{ .type = .MYSQL_TYPE_LONG, .flags = .{ .UNSIGNED = true } },
            .double_value => .{ .type = .MYSQL_TYPE_DOUBLE, .flags = .{} },
            .boolean => .{ .type = .MYSQL_TYPE_TINY, .flags = .{} },
            .json => .{ .type = .MYSQL_TYPE_JSON, .flags = .{} },
            .varchar => .{ .type = .MYSQL_TYPE_VARCHAR, .flags = .{} },
        };
        try fields.append(field);
    }

    const owned_query = try bun.default_allocator.dupe(u8, query);
    errdefer bun.default_allocator.free(owned_query);
    return Signature{
        .fields = try fields.toOwnedSlice(),
        .query = owned_query,
    };
}

const bun = @import("bun");
const std = @import("std");
const Param = @import("../MySQLStatement.zig").Param;
const SQLParameters = @import("../../shared/SQLParameters.zig");
const SQLTypes = @import("../../shared/SQLTypes.zig");

const AnyMySQLError = @import("../../../sql/mysql/protocol/AnyMySQLError.zig");
