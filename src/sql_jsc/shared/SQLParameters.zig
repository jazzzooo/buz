const bun = @import("bun");
const std = @import("std");
const bindgen = bun.bindgen;
const SQLTypes = @import("./SQLTypes.zig");
const Parameter = @import("../../sql/shared/Parameter.zig").Parameter;
const module = bindgen.Module("SQLParameters");
const InferMySQL = module.engineShim("inferMySQL");
const InferPostgres = module.engineShim("inferPostgres");
const MaterializeMySQL = module.engineShim("materializeMySQL");
const MaterializePostgres = module.engineShim("materializePostgres");
const Converted = bindgen.Return(MaterializeMySQL).Item;
const Count = module.engineShim("count");
pub const Kind = std.meta.Elem(bindgen.EngineArgumentType(MaterializeMySQL, "plan"));

pub const Batch = struct {
    items: []Converted,

    pub fn deinit(this: *Batch) void {
        for (this.items) |*item| item.deinit();
        bun.default_allocator.free(this.items);
        this.* = .{ .items = &.{} };
    }

    pub fn len(this: *const Batch) usize {
        return this.items.len;
    }

    pub fn at(this: *const Batch, index: usize) Parameter {
        return switch (this.items[index].value) {
            .null_value => .null_value,
            .float32 => |value| .{ .float32 = @floatCast(value) },
            inline .text, .bytes, .int32_array => |value, tag| @unionInit(Parameter, @tagName(tag), value.slice()),
            inline else => |value, tag| @unionInit(Parameter, @tagName(tag), value),
        };
    }
};

pub fn count(values: *const SQLTypes.BindingValues, columns: ?*const SQLTypes.BindingColumns) u64 {
    var scope: bindgen.FocusedEngineScope = undefined;
    values.initScope(&scope);
    defer scope.deinit();
    return scope.engine(Count).call(.{ .values = values.operand(&scope), .columns = if (columns) |present| present.operand(&scope) else null });
}

pub fn inferMySQL(values: *const SQLTypes.BindingValues, columns: ?*const SQLTypes.BindingColumns) bun.JSError!bindgen.Return(InferMySQL) {
    var scope: bindgen.FocusedEngineScope = undefined;
    values.initScope(&scope);
    defer scope.deinit();
    return scope.engine(InferMySQL).call(.{ .values = values.operand(&scope), .columns = if (columns) |present| present.operand(&scope) else null });
}

pub fn inferPostgres(values: *const SQLTypes.BindingValues, columns: ?*const SQLTypes.BindingColumns) bun.JSError!bindgen.Return(InferPostgres) {
    var scope: bindgen.FocusedEngineScope = undefined;
    values.initScope(&scope);
    defer scope.deinit();
    return scope.engine(InferPostgres).call(.{ .values = values.operand(&scope), .columns = if (columns) |present| present.operand(&scope) else null });
}

pub fn materializeMySQL(values: *const SQLTypes.BindingValues, columns: ?*const SQLTypes.BindingColumns, plan: []const Kind) bun.JSError!Batch {
    return materialize(MaterializeMySQL, values, columns, plan);
}

pub fn materializePostgres(values: *const SQLTypes.BindingValues, columns: ?*const SQLTypes.BindingColumns, plan: []const Kind) bun.JSError!Batch {
    return materialize(MaterializePostgres, values, columns, plan);
}

fn materialize(comptime Operation: type, values: *const SQLTypes.BindingValues, columns: ?*const SQLTypes.BindingColumns, plan: []const Kind) bun.JSError!Batch {
    var scope: bindgen.FocusedEngineScope = undefined;
    values.initScope(&scope);
    defer scope.deinit();
    var result = try scope.engine(Operation).call(.{ .values = values.operand(&scope), .columns = if (columns) |present| present.operand(&scope) else null, .plan = plan });
    defer result.deinit();
    const items = try bun.default_allocator.alloc(Converted, result.len());
    var iterator = result.iterator();
    for (items) |*item| item.* = iterator.next().?;
    return .{ .items = items };
}
