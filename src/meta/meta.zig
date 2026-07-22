pub fn EnumInfo(comptime T: type) std.builtin.Type.Enum {
    const tyinfo = @typeInfo(T);
    return switch (tyinfo) {
        .@"union" => @typeInfo(tyinfo.@"union".tag_type.?).@"enum",
        .@"enum" => tyinfo.@"enum",
        else => {
            @compileError("Used `EnumInfo(T)` on a type that is not an `enum` or a `union(enum)`");
        },
    };
}

pub fn ReturnOf(comptime function: anytype) type {
    return ReturnOfType(@TypeOf(function));
}

pub fn ReturnOfType(comptime Type: type) type {
    const typeinfo: std.builtin.Type.Fn = @typeInfo(Type).@"fn";
    return typeinfo.return_type orelse void;
}

pub fn typeName(comptime Type: type) []const u8 {
    const name = @typeName(Type);
    return typeBaseName(name);
}

/// partially emulates behaviour of @typeName in previous Zig versions,
/// converting "some.namespace.MyType" to "MyType"
pub inline fn typeBaseName(comptime fullname: [:0]const u8) [:0]const u8 {
    @setEvalBranchQuota(1_000_000);
    // leave type name like "namespace.WrapperType(namespace.MyType)" as it is
    const baseidx = comptime std.mem.indexOf(u8, fullname, "(");
    if (baseidx != null) return comptime fullname;

    const idx = comptime std.mem.lastIndexOf(u8, fullname, ".");

    const name = if (idx == null) fullname else fullname[(idx.? + 1)..];
    return comptime name;
}

pub fn enumFieldNames(comptime Type: type) []const []const u8 {
    var names: [std.meta.fieldNames(Type).len][]const u8 = undefined;
    var i: usize = 0;
    for (std.meta.fieldNames(Type)) |name| {
        // zig seems to include "_" or an empty string in the list of enum field names
        // it makes sense, but humans don't want that
        if (bun.strings.eqlAnyComptime(name, &.{ "_none", "", "_" })) {
            continue;
        }
        names[i] = name;
        i += 1;
    }
    return names[0..i];
}

pub fn banFieldType(comptime Container: type, comptime T: type) void {
    comptime {
        const field_names, const field_types = switch (@typeInfo(Container)) {
            .@"struct" => |info| .{ info.field_names, info.field_types },
            .@"union" => |info| .{ info.field_names, info.field_types },
            else => @compileError("Expected struct or union type, found '" ++ @typeName(Container) ++ "'"),
        };
        for (field_names, field_types) |field_name, FieldType| {
            if (FieldType == T) {
                @compileError(std.fmt.comptimePrint(typeName(T) ++ " field \"" ++ field_name ++ "\" not allowed in " ++ typeName(Container), .{}));
            }
        }
    }
}

// []T -> T
// *const T -> T
// *[n]T -> T
pub fn Item(comptime T: type) type {
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .one) {
                switch (@typeInfo(ptr.child)) {
                    .array => |array| {
                        return array.child;
                    },
                    else => {},
                }
            }
            return ptr.child;
        },
        else => return std.meta.Child(T),
    }
}

/// Returns .{a, b, ...args_}
pub inline fn ConcatArgs2(
    comptime func: anytype,
    a: anytype,
    b: anytype,
    args_: anytype,
) std.meta.ArgsTuple(@TypeOf(func)) {
    var args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
    args[0] = a;
    args[1] = b;

    inline for (args_, 2..) |arg, i| {
        args[i] = arg;
    }

    return args;
}

pub const TaggedUnion = @import("./tagged_union.zig").TaggedUnion;

pub fn isSimpleCopyType(comptime T: type) bool {
    @setEvalBranchQuota(1_000_000);
    const tyinfo = @typeInfo(T);
    return switch (tyinfo) {
        .void => true,
        .bool => true,
        .int => true,
        .float => true,
        .@"enum" => true,
        .@"struct" => {
            inline for (tyinfo.@"struct".field_types) |FieldType| {
                if (!isSimpleCopyType(FieldType)) return false;
            }
            return true;
        },
        .@"union" => {
            inline for (tyinfo.@"union".field_types) |FieldType| {
                if (!isSimpleCopyType(FieldType)) return false;
            }
            return true;
        },
        .optional => return isSimpleCopyType(tyinfo.optional.child),
        else => false,
    };
}

pub fn isSimpleEqlType(comptime T: type) bool {
    const tyinfo = @typeInfo(T);
    return switch (tyinfo) {
        .type => true,
        .void => true,
        .bool => true,
        .int => true,
        .float => true,
        .@"enum" => true,
        .@"struct" => |struct_info| struct_info.layout == .@"packed",
        else => false,
    };
}

pub const ListContainerType = enum {
    array_list,
    baby_list,
    small_list,
};
pub fn looksLikeListContainerType(comptime T: type) ?struct { list: ListContainerType, child: type } {
    const tyinfo = @typeInfo(T);
    if (tyinfo == .@"struct") {
        const field_names = tyinfo.@"struct".field_names;
        const field_types = tyinfo.@"struct".field_types;

        // Looks like array list
        if (field_names.len == 2 and
            std.mem.eql(u8, field_names[0], "items") and
            std.mem.eql(u8, field_names[1], "capacity"))
            return .{ .list = .array_list, .child = std.meta.Child(field_types[0]) };

        // Looks like babylist
        if (@hasDecl(T, "looksLikeContainerTypeBabyList")) {
            return .{ .list = .baby_list, .child = T.looksLikeContainerTypeBabyList };
        }

        // Looks like SmallList
        if (@hasDecl(T, "looksLikeContainerTypeSmallList")) {
            return .{ .list = .small_list, .child = T.looksLikeContainerTypeSmallList };
        }
    }

    return null;
}

pub fn Tagged(comptime U: type, comptime T: type) type {
    const info = @typeInfo(U).@"union";
    return @Union(.auto, T, info.field_names, info.field_types[0..], info.field_attrs[0..]);
}

/// userland implementation of https://github.com/ziglang/zig/issues/21879
pub fn useAllFields(comptime T: type, _: VoidFields(T)) void {}

fn VoidFields(comptime T: type) type {
    const field_names = @typeInfo(T).@"struct".field_names;
    return @Struct(.auto, null, field_names, &@splat(void), &@splat(.{}));
}

pub fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

pub fn hasField(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasField(T, name),
        else => false,
    };
}

const bun = @import("bun");
const std = @import("std");
