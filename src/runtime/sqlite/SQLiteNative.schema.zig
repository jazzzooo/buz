const b = @import("bindgen_schema");
const types = @import("binding_schema_SQLiteTypes");

const cpp_member = b.ClassMemberOptions{
    .backend = .cpp,
    .this_value_type = b.js_object,
    .missing_required_arguments = .convert_undefined,
};

fn bindingMethod(comptime name: []const u8, comptime result: b.Type) b.ClassMember {
    return b.method(name, .{
        b.argument("bindings", types.bindings, .{ .presence = .optional, .missing = .omitted }),
    }, result, .{
        .backend = .cpp,
        .this_value_type = b.js_object,
        .missing_required_arguments = .convert_undefined,
        .length = 1,
    });
}

const database_class = b.class("Database", b.illegalConstructor(), .{
    b.getter("id", b.int32, .{ .implementation = "getId" }),
}, .{}, .{
    .ownership = .unique,
    .profile = .exact,
    .identity = .fresh,
    .memory_usage = .vm,
});

const statement_class = b.class("Statement", b.illegalConstructor(), .{
    b.method("run", .{
        b.argument("diff", b.optionalMatch(b.js_internal_field_tuple), .{}),
        b.argument("bindings", types.bindings, .{ .presence = .optional, .missing = .omitted }),
    }, b.none, .{
        .backend = .cpp,
        .this_value_type = b.js_object,
        .missing_required_arguments = .convert_undefined,
        .length = 1,
    }),
    bindingMethod("get", types.object_or_null),
    bindingMethod("all", types.array_or_number_or_undefined),
    bindingMethod("iterate", types.object_or_null),
    bindingMethod("values", types.array_or_number_or_null),
    bindingMethod("raw", types.array_or_number_or_null),
    b.method("as", .{b.argument("prototype", types.prototype, .{})}, b.none, cpp_member),
    b.method("finalize", .{}, b.none, cpp_member),
    b.getter("isFinalized", b.boolean, cpp_member),
    b.method("toString", .{}, b.dom_string, cpp_member),
    b.getter("columns", b.js_array, cpp_member),
    b.getter("columnsCount", b.int32, cpp_member),
    b.getter("paramsCount", b.int32, cpp_member),
    b.getter("columnTypes", b.js_array, cpp_member),
    b.getter("declaredTypes", b.js_array, cpp_member),
    b.getter("safeIntegers", b.boolean, .{
        .backend = .cpp,
        .profile = .webidl,
        .this_value_type = b.js_object,
        .missing_required_arguments = .convert_undefined,
    }),
    b.setter("safeIntegers", b.boolean, .{
        .backend = .cpp,
        .profile = .webidl,
        .this_value_type = b.js_object,
        .missing_required_arguments = .convert_undefined,
    }),
}, .{
    b.cachedSlot("userPrototype", b.js_object, .{ .writable = true, .exposed = false }),
}, .{
    .ownership = .unique,
    .profile = .exact,
    .identity = .fresh,
    .memory_usage = .vm,
});

const control_handle = b.class("ControlHandle", b.illegalConstructor(), .{
    b.getter("kind", types.control_handle_kind, .{ .implementation = "getKind" }),
    b.method("withUnsafePointer", .{
        b.argument("callback", types.pointer_callback, .{}),
    }, b.optionalUndefined(b.any), cpp_member),
}, .{}, .{
    .ownership = .unique,
    .profile = .exact,
    .identity = .fresh,
    .memory_usage = .vm,
});

const native_exports = .{
    b.nativeExportWithOptions("adoptControlHandle", .{
        b.argument("data", types.owned_control_handle_data, .{ .ownership = .transfer }),
        b.argument("kind", types.control_handle_kind, .{}),
        b.argument("memory", b.size, .{}),
    }, types.control_handle, .current_realm_throwing),
    b.nativeExportWithOptions("controlHandleData", .{
        b.argument("handle", types.control_handle, .{}),
    }, types.control_handle_data, .current_realm_throwing),
    b.nativeExportWithOptions("invokePointerCallback", .{
        b.argument("callback", types.pointer_callback, .{}),
        b.argument("pointer", b.uint64, .{}),
    }, b.any, .current_realm_throwing),
    b.nativeExportWithOptions("adoptDatabase", .{
        b.argument("data", types.owned_database_data, .{ .ownership = .transfer }),
        b.argument("identifier", b.int32, .{}),
        b.argument("memory", b.size, .{}),
    }, types.database, .current_realm_throwing),
    b.nativeExportWithOptions("adoptStatement", .{
        b.argument("data", types.owned_statement_data, .{ .ownership = .transfer }),
        b.argument("memory", b.size, .{}),
    }, types.statement, .current_realm_throwing),
    b.nativeExport("databaseData", .{
        b.argument("database", types.database_owner, .{}),
    }, types.database_data),
    b.nativeExportWithOptions("statementData", .{
        b.argument("statement", types.statement, .{}),
    }, types.statement_data, .current_realm_throwing),
    b.nativeExportWithOptions("getPrototype", .{
        b.argument("statement", types.statement, .{}),
    }, b.optionalUndefined(b.js_object), .current_realm_throwing),
    b.nativeExportWithOptions("setPrototype", .{
        b.argument("statement", types.statement, .{}),
        b.argument("prototype", b.optionalUndefined(b.js_object), .{}),
    }, b.none, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("SQLiteNative", .{}, .{ database_class, statement_class, control_handle }, .{}, native_exports);
pub const database = schema.class("Database");
pub const statement = schema.class("Statement");
