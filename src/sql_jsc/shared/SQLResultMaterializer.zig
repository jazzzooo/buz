const std = @import("std");

const bun = @import("bun");
const SQLDataCell = @import("./SQLDataCell.zig").SQLDataCell;
const SQLQueryResultMode = @import("../../sql/shared/SQLQueryResultMode.zig").SQLQueryResultMode;
const SQLTypes = @import("./SQLTypes.zig");
const ResultColumnSlot = @import("../../sql/shared/ResultColumnSlot.zig");

pub const LayoutFlags = SQLTypes.ResultLayoutFlags;

pub const Layout = struct {
    structure: ?*const SQLTypes.ObjectStructure = null,
    slots: []const SQLTypes.ResultColumnSlot = &.{},
    flags: LayoutFlags = .{
        .has_indexed_columns = false,
        .has_named_columns = false,
        .has_duplicate_columns = false,
    },
};

fn stringNode(impl: ?bun.WTF.StringImpl) SQLTypes.DataCellNode {
    const value = impl orelse return .{ .string_latin1 = .{ .units = &.{} } };
    return if (value.is8Bit())
        .{ .string_latin1 = .{ .units = value.latin1Slice() } }
    else
        .{ .string_utf16 = .{ .units = value.utf16Slice() } };
}

fn jsonNode(impl: ?bun.WTF.StringImpl) SQLTypes.DataCellNode {
    const value = impl orelse return .{ .json_null = .null_value };
    return if (value.is8Bit())
        .{ .json_latin1 = .{ .units = value.latin1Slice() } }
    else
        .{ .json_utf16 = .{ .units = value.utf16Slice() } };
}

pub fn encodeColumnSlots(
    output: []SQLTypes.ResultColumnSlot,
    slots: []const ResultColumnSlot,
) void {
    if (output.len != slots.len) @panic("SQL column-slot carrier length mismatch");
    for (output, slots) |*destination, source| {
        destination.* = switch (source.value) {
            .duplicate => .{ .duplicate = .null_value },
            .indexed => |index| .{ .indexed = .{ .value = index } },
            .named => |name| switch (name.textView()) {
                .latin1 => |units| .{ .named_latin1 = units },
                .utf16 => |units| .{ .named_utf16 = units },
                .utf8 => unreachable,
            },
            .named_offset => |offset| .{ .named_offset = .{ .value = offset } },
        };
    }
}

pub fn createObjectStructure(
    values: *const SQLTypes.BindingValues,
    slots: []const SQLTypes.ResultColumnSlot,
) bun.JSError!?SQLTypes.ObjectStructure {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    values.initScope(&scope);
    defer scope.deinit();
    const result = (try scope.engine(SQLTypes.CreateObjectStructureSchema).call(.{
        .values = values.operand(&scope),
        .slots = slots,
    })) orelse return null;
    return try result.toOwned();
}

fn checkedAdd(total: *usize, amount: usize) bun.OOM!void {
    total.* = std.math.add(usize, total.*, amount) catch return error.OutOfMemory;
}

fn countCellNodes(cell: *const SQLDataCell) bun.OOM!usize {
    var count: usize = 1;
    if (cell.tag == .array) {
        for (cell.value.array.slice()) |*child| {
            try checkedAdd(&count, try countCellNodes(child));
        }
    }
    return count;
}

fn countNodes(cells: []const SQLDataCell) bun.OOM!usize {
    var count: usize = 0;
    for (cells) |*cell| try checkedAdd(&count, try countCellNodes(cell));
    return count;
}

fn appendNode(
    nodes: []SQLTypes.DataCellNode,
    index: *usize,
    node: SQLTypes.DataCellNode,
) void {
    nodes[index.*] = node;
    index.* += 1;
}

fn byteaBytes(cell: *const SQLDataCell) []const u8 {
    const address = cell.value.bytea[0];
    const length = cell.value.bytea[1];
    if (length == 0) return &.{};
    if (address == 0) @panic("SQL bytea cell has a null data pointer");
    return @as([*]const u8, @ptrFromInt(address))[0..length];
}

fn flattenCell(
    cell: *const SQLDataCell,
    nodes: []SQLTypes.DataCellNode,
    index: *usize,
) void {
    switch (cell.tag) {
        .null => appendNode(nodes, index, .{ .null_value = .null_value }),
        .string => appendNode(nodes, index, stringNode(cell.value.string)),
        .float8 => appendNode(nodes, index, .{ .double_value = cell.value.float8 }),
        .int4 => appendNode(nodes, index, .{ .int32 = cell.value.int4 }),
        .int8 => appendNode(nodes, index, .{ .int64 = cell.value.int8 }),
        .bool => appendNode(nodes, index, .{ .boolean = cell.value.bool != 0 }),
        .date => appendNode(nodes, index, .{ .date = .{ .milliseconds = cell.value.date } }),
        .date_with_time_zone => appendNode(nodes, index, .{ .date_with_timezone = .{ .milliseconds = cell.value.date_with_time_zone } }),
        .bytea => appendNode(nodes, index, .{ .bytea = .{ .bytes = byteaBytes(cell) } }),
        .json => appendNode(nodes, index, jsonNode(cell.value.json)),
        .array => {
            const children = cell.value.array.slice();
            appendNode(nodes, index, .{ .array = .{ .length = @intCast(children.len) } });
            for (children) |*child| flattenCell(child, nodes, index);
        },
        .typed_array => appendNode(nodes, index, .{ .typed_array = .{
            .kind = switch (cell.value.typed_array.kind) {
                .int32 => .int32,
                .float32 => .float32,
            },
            .bytes = cell.value.typed_array.elementBytes(),
            .length = cell.value.typed_array.len,
        } }),
        .raw => appendNode(nodes, index, .{ .raw = .{ .bytes = cell.value.raw.slice() } }),
        .uint4 => appendNode(nodes, index, .{ .uint32 = cell.value.uint4 }),
        .uint8 => appendNode(nodes, index, .{ .uint64 = cell.value.uint8 }),
    }
}

fn resultMode(mode: SQLQueryResultMode) SQLTypes.ResultMode {
    return switch (mode) {
        .objects => .objects,
        .values => .values,
        .raw => .raw,
    };
}

pub fn appendResultRow(
    values: *const SQLTypes.BindingValues,
    rows: ?*const SQLTypes.ResultRows,
    cells: []const SQLDataCell,
    mode: SQLQueryResultMode,
    layout: ?Layout,
) bun.JSError!?SQLTypes.ResultRows {
    const node_count = bun.handleOom(countNodes(cells));
    const nodes = bun.handleOom(bun.default_allocator.alloc(SQLTypes.DataCellNode, node_count));
    defer bun.default_allocator.free(nodes);

    var node_index: usize = 0;
    for (cells) |*cell| flattenCell(cell, nodes, &node_index);
    if (node_index != nodes.len) @panic("SQL data-cell carrier length mismatch");

    const top_level_count = std.math.cast(u32, cells.len) orelse
        @panic("SQL result row exceeds the generated carrier limit");
    const selected_layout: Layout = layout orelse .{};

    var scope: bun.bindgen.FocusedEngineScope = undefined;
    if (rows) |existing| existing.initScope(&scope) else values.initScope(&scope);
    defer scope.deinit();
    if (rows) |existing| {
        try scope.engine(SQLTypes.AppendResultRowSchema).call(.{
            .rows = existing.operand(&scope),
            .structure = if (selected_layout.structure) |structure| structure.operand(&scope) else null,
            .nodes = nodes,
            .count = top_level_count,
            .flags = selected_layout.flags,
            .resultMode = resultMode(mode),
            .slots = selected_layout.slots,
        });
        return null;
    }

    const result = try scope.engine(SQLTypes.CreateResultRowsSchema).call(.{
        .values = values.operand(&scope),
        .structure = if (selected_layout.structure) |structure| structure.operand(&scope) else null,
        .nodes = nodes,
        .count = top_level_count,
        .flags = selected_layout.flags,
        .resultMode = resultMode(mode),
        .slots = selected_layout.slots,
    });
    return try result.toOwned();
}
