const std = @import("std");
const ir = @import("bindgen_ir");

pub fn validate(comptime types: anytype, comptime Header: type) void {
    _ = Checked(types, Header);
}

fn Checked(comptime types: anytype, comptime Header: type) type {
    const Check = struct {
        comptime {
            @setEvalBranchQuota(1_000_000);
            for (0..types.len) |index| _ = CheckedType(index);
        }

        fn CheckedType(comptime index: usize) type {
            return struct {
                comptime {
                    @setEvalBranchQuota(10_000);
                    switch (types[index]) {
                        .scalar, .pointer => {},
                        .opaque_handle => |identifier| {
                            const name = identifier.comptimeName();
                            require(@typeInfo(@field(Header, name)) == .@"opaque", name);
                        },
                        .forward_structure => |identifier| {
                            const name = identifier.comptimeName();
                            const Actual = @field(Header, name);
                            require(@typeInfo(Actual) == .@"opaque" or @typeInfo(Actual) == .@"struct", name);
                        },
                        .alias => |alias| {
                            const name = alias.name.comptimeName();
                            require(matches(@field(Header, name), alias.child), name);
                            for (alias.constants) |constant| require(@field(Header, constant.name) == constant.value, constant.name);
                        },
                        .structure, .@"union" => |aggregate| {
                            const name = aggregate.name.comptimeName();
                            const Actual = @field(Header, name);
                            const is_struct = types[index] == .structure;
                            require(if (is_struct) @typeInfo(Actual) == .@"struct" else @typeInfo(Actual) == .@"union", name);
                            const info = if (is_struct) @typeInfo(Actual).@"struct" else @typeInfo(Actual).@"union";
                            require(info.layout == .@"extern" and info.field_names.len == aggregate.fields.len, name);
                            for (aggregate.fields, info.field_names, info.field_types) |field, actual_name, Field| {
                                require(std.mem.eql(u8, field.name, actual_name), name ++ "." ++ field.name);
                                require(matches(Field, field.type), name ++ "." ++ field.name);
                            }
                        },
                        inline .function_pointer, .function => |function, tag| {
                            const name = function.name.comptimeName();
                            const Function = if (tag == .function_pointer) pointer: {
                                const Actual = @field(Header, name);
                                const Pointer = if (@typeInfo(Actual) == .optional) @typeInfo(Actual).optional.child else Actual;
                                require(@typeInfo(Pointer) == .pointer, name);
                                break :pointer @typeInfo(Pointer).pointer.child;
                            } else @TypeOf(@field(Header, name));
                            require(@typeInfo(Function) == .@"fn", name);
                            const info = @typeInfo(Function).@"fn";
                            const allow_auto = tag == .function and function.inline_definition;
                            require(std.meta.eql(info.attrs.@"callconv", .c) or (allow_auto and std.meta.eql(info.attrs.@"callconv", .auto)), name);
                            require(!info.attrs.varargs and info.param_types.len == function.parameters.len, name);
                            const non_returning = tag == .function and function.non_returning;
                            require(if (non_returning) info.return_type.? == noreturn else matches(info.return_type.?, function.result), name);
                            for (info.param_types, function.parameters) |parameter, expected| {
                                const expected_type = if (tag == .function_pointer) expected else expected.type;
                                const parameter_name = if (tag == .function_pointer) name else name ++ "." ++ expected.name;
                                require(matches(parameter.?, expected_type), parameter_name);
                            }
                        },
                    }
                }
            };
        }

        fn matches(comptime Actual: type, comptime id: ir.WireTypeId) bool {
            return switch (types[id.index]) {
                .scalar => |scalar| Actual == scalar.zigType(),
                .pointer => |pointer| matchesPointer(Actual, pointer),
                .opaque_handle, .forward_structure => |name| Actual == @field(Header, name.comptimeName()),
                inline .alias, .structure, .@"union", .function_pointer => |declaration| Actual == @field(Header, declaration.name.comptimeName()),
                .function => |function| Actual == @TypeOf(@field(Header, function.name.comptimeName())),
            };
        }

        fn matchesPointer(comptime Actual: type, comptime pointer: ir.WirePointer) bool {
            const Pointer = if (@typeInfo(Actual) == .optional) @typeInfo(Actual).optional.child else Actual;
            const info = switch (@typeInfo(Pointer)) {
                .pointer => |info| info,
                else => return false,
            };
            if ((info.size != .one and info.size != .c) or info.attrs.@"const" != pointer.is_const) return false;
            const is_void = switch (types[pointer.child.index]) {
                .scalar => |scalar| scalar == .void,
                .pointer, .opaque_handle, .forward_structure, .alias, .structure, .@"union", .function_pointer, .function => false,
            };
            return if (is_void) info.child == anyopaque else matches(info.child, pointer.child);
        }
    };
    return Check;
}

fn require(comptime condition: bool, comptime name: []const u8) void {
    if (!condition) @compileError("translated binding wire type differs from the normalized IR: " ++ name);
}

