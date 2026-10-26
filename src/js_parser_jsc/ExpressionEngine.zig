//! Converts parsed AST literals into runtime values for macro execution.

const BindingEscape = bun.bindgen.Escape(@This());
pub fn toOwnedValue(expression: Expr, allocator: std.mem.Allocator, global: *jsc.JSGlobalObject) ToJSError!bun.bindgen.EngineRoot {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    const value = try dataToOperand(expression.data, allocator, &scope);
    return value.toRoot();
}

fn dataToOperand(data: Expr.Data, allocator: std.mem.Allocator, scope: *bun.bindgen.FocusedEngineScope) ToJSError!bun.bindgen.EngineOperand {
    return switch (data) {
        .e_array => |array| arrayToOperand(array.*, allocator, scope),
        .e_object => |object| objectToOperand(object, allocator, scope),
        .e_string => |string| stringToOperand(string, allocator, scope),
        .e_null => BindingEscape.borrowEngineValue(scope, .null),
        .e_undefined => BindingEscape.borrowEngineValue(scope, .js_undefined),
        .e_boolean, .e_branch_boolean => |boolean| BindingEscape.borrowEngineValue(scope, if (boolean.value) .true else .false),
        .e_number => |number| BindingEscape.borrowEngineValue(scope, jsc.JSValue.jsNumber(number.value)),
        .e_inlined_enum => |inlined| dataToOperand(inlined.value.data, allocator, scope),
        .e_identifier, .e_import_identifier, .e_private_identifier, .e_commonjs_export_identifier => error.@"Cannot convert identifier to JS. Try a statically-known value",
        else => error.@"Cannot convert argument type to JS",
    };
}

fn arrayToOperand(array: E.Array, allocator: std.mem.Allocator, scope: *bun.bindgen.FocusedEngineScope) ToJSError!bun.bindgen.EngineOperand {
    const items = array.items.slice();
    const result = try scope.engine(CreateArrayLiteralSchema).call(.{ .length = items.len });
    for (items, 0..) |expression, index| {
        const value = try dataToOperand(expression.data, allocator, scope);
        try scope.engine(DefineNextArrayLiteralElementSchema).call(.{
            .array = result.operand(scope),
            .index = @intCast(index),
            .value = value,
        });
    }
    return result.operand(scope).asEngine();
}

fn objectToOperand(object: *E.Object, allocator: std.mem.Allocator, scope: *bun.bindgen.FocusedEngineScope) ToJSError!bun.bindgen.EngineOperand {
    const result = try scope.engine(CreateObjectLiteralSchema).call(.{ .capacity = object.properties.len });
    for (object.properties.slice()) |property| {
        if (property.kind != .normal or property.class_static_block != null or property.key == null or property.value == null)
            return error.@"Cannot convert argument type to JS";
        const key = try dataToOperand(property.key.?.data, allocator, scope);
        const value = try dataToOperand(property.value.?.data, allocator, scope);
        try scope.engine(DefineObjectLiteralPropertySchema).call(.{
            .object = result.operand(scope),
            .key = key,
            .value = value,
        });
    }
    return result.operand(scope).asEngine();
}

fn stringToOperand(value: *E.String, allocator: std.mem.Allocator, scope: *bun.bindgen.FocusedEngineScope) ToJSError!bun.bindgen.EngineOperand {
    value.resolveRopeIfNeeded(allocator);
    var string = string: {
        if (!value.isPresent()) break :string bun.bindgen.DOMString.empty();
        if (value.isUTF8()) {
            if (try bun.strings.toUTF16Alloc(allocator, value.slice8(), false, false)) |utf16| {
                defer allocator.free(utf16);
                break :string try bun.bindgen.DOMString.fromUTF16(utf16);
            }
            break :string try bun.bindgen.DOMString.fromLatin1(value.slice8());
        }
        break :string try bun.bindgen.DOMString.fromUTF16(value.slice16());
    };
    defer string.deinit();
    const result = try scope.engine(StringToJSSchema).call(.{ .value = string.operand() });
    return result.operand(scope).asEngine();
}

const std = @import("std");

const bun = @import("bun");
const jsc = bun.jsc;

const js_ast = bun.ast;
const E = js_ast.E;
const Expr = js_ast.Expr;
const ToJSError = js_ast.ToJSError;

const ExprJSCBindings = bun.bindgen.Module("ExprJSC");
const CreateArrayLiteralSchema = ExprJSCBindings.engineShim("createArrayLiteral");
const DefineNextArrayLiteralElementSchema = ExprJSCBindings.engineShim("defineNextArrayLiteralElement");
const CreateObjectLiteralSchema = ExprJSCBindings.engineShim("createObjectLiteral");
const DefineObjectLiteralPropertySchema = ExprJSCBindings.engineShim("defineObjectLiteralProperty");
const StringToJSSchema = bun.bindgen.Module("js_strings").engineShim("stringToJS");
