const bun = @import("bun");

const bindgen = bun.bindgen;
const CreateArgumentArraySchema = bindgen.Module("Expect").engineShim("createArgumentArray");

pub fn create(context: anytype, values: anytype) bun.JSError!bindgen.BrandedValueResult(CreateArgumentArraySchema.ReturnType) {
    const operation = context.engineIn("Expect", "createArgumentArray");
    const Value = @typeInfo(@FieldType(@TypeOf(operation).Args, "values")).pointer.child;
    const operands = try bun.default_allocator.alloc(Value, values.len());
    defer bun.default_allocator.free(operands);
    for (operands, 0..) |*operand, index| operand.* = values.at(index).?.operand(context).asEngine();
    return operation.call(.{ .values = operands });
}
