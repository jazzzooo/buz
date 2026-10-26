const bun = @import("bun");
const std = @import("std");
const bindgen = bun.bindgen;

const SQLTypesModule = bindgen.Module("SQLTypes");
const SQLBindingModule = bindgen.Module("SQLBinding");

pub const CreateObjectStructureSchema = SQLTypesModule.engineShim("createObjectStructure");
pub const AppendResultRowSchema = SQLTypesModule.engineShim("appendResultRow");
pub const CreateResultRowsSchema = SQLTypesModule.engineShim("createResultRows");
pub const BindingValuesLengthSchema = SQLTypesModule.engineShim("bindingValuesLength");

pub const BindingValuesSchema = CreateObjectStructureSchema.args[0].ArgumentType;
pub const ResultRowsSchema = CreateResultRowsSchema.ReturnType;
pub const BindingColumnsSchema = SQLBindingModule.function("mysqlCreateQuery").args[3].ArgumentType.child;
pub const ObjectStructureSchema = CreateObjectStructureSchema.ReturnType.child;

pub const DataCellNode = std.meta.Elem(bindgen.EngineArgumentType(AppendResultRowSchema, "nodes"));
pub const ResultColumnSlot = std.meta.Elem(bindgen.EngineArgumentType(CreateObjectStructureSchema, "slots"));
pub const ResultLayoutFlags = bindgen.EngineArgumentType(AppendResultRowSchema, "flags");
pub const ResultMode = bindgen.EngineArgumentType(AppendResultRowSchema, "resultMode");

pub const BindingValues = bindgen.OwnedBrandedValue(BindingValuesSchema);
pub const ResultRows = bindgen.OwnedBrandedValue(ResultRowsSchema);
pub const BindingColumns = bindgen.OwnedBrandedValue(BindingColumnsSchema);
pub const ObjectStructure = bindgen.OwnedBrandedValue(ObjectStructureSchema);

pub const ConnectionStrings = struct {
    buffer: ?[]u8,
    username: []const u8,
    password: []const u8,
    database: []const u8,
    options: []const u8,
    path: []const u8,

    pub fn init(context: anytype, args: anytype) bindgen.CallError(@TypeOf(context))!ConnectionStrings {
        const fields = .{ "username", "password", "database", "options", "path" };
        var encoded: [fields.len]bun.String.Slice = @splat(.empty);
        defer for (encoded) |value| value.deinit();
        var size: usize = 0;
        inline for (fields, &encoded) |field, *value| {
            value.* = try @field(args, field).toUTF8(bun.default_allocator);
            size = std.math.add(usize, size, value.slice().len) catch return error.OutOfMemory;
        }
        const buffer = try bun.default_allocator.alloc(u8, size);
        var result: ConnectionStrings = undefined;
        result.buffer = buffer;
        errdefer result.deinit();
        var offset: usize = 0;
        inline for (fields, encoded) |field, value| {
            const bytes = value.slice();
            const output = buffer[offset..][0..bytes.len];
            @memcpy(output, bytes);
            @field(result, field) = output;
            offset += bytes.len;
        }
        // These parameters occupy null-terminated fields in the SQL wire protocols.
        inline for (.{ "username", "password", "database", "path" }) |field| {
            if (std.mem.indexOfScalar(u8, @field(result, field), 0) != null)
                return context.fail(.invalid_parameter, try bindgen.DOMString.fromUTF8(field ++ " must not contain null bytes"));
        }
        return result;
    }

    pub fn takeBuffer(this: *ConnectionStrings) []u8 {
        return bun.take(&this.buffer) orelse @panic("SQL connection strings were already transferred");
    }

    pub fn deinit(this: *ConnectionStrings) void {
        if (bun.take(&this.buffer)) |buffer| bun.freeSensitive(bun.default_allocator, buffer);
    }
};
