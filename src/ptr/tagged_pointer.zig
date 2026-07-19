const AddressableSize = u49;

pub const TaggedPointer = packed struct(u64) {
    _ptr: AddressableSize,
    data: Tag,

    pub const Tag = u15;

    pub inline fn init(ptr: anytype, data: Tag) TaggedPointer {
        const Ptr = @TypeOf(ptr);
        if (comptime Ptr == @TypeOf(null)) {
            return .{ ._ptr = 0, .data = data };
        }

        if (comptime @typeInfo(Ptr) != .pointer and Ptr != ?*anyopaque) {
            @compileError(@typeName(Ptr) ++ " must be a ptr, received: " ++ @tagName(@typeInfo(Ptr)));
        }

        const address = @intFromPtr(ptr);

        return TaggedPointer{
            ._ptr = @as(AddressableSize, @truncate(address)),
            .data = data,
        };
    }

    pub inline fn get(this: TaggedPointer, comptime Type: type) *Type {
        return @as(*Type, @ptrFromInt(@as(usize, @intCast(this._ptr))));
    }

    pub inline fn from(val: anytype) TaggedPointer {
        const ValueType = @TypeOf(val);
        return switch (ValueType) {
            f64, i64, u64 => @bitCast(val),
            ?*anyopaque, *anyopaque => @bitCast(@intFromPtr(val)),
            else => @compileError("Unsupported type: " ++ @typeName(ValueType)),
        };
    }

    pub inline fn to(this: TaggedPointer) *anyopaque {
        return @ptrFromInt(@as(u64, @bitCast(this)));
    }
};

const TypeMapT = struct {
    value: TaggedPointer.Tag,
    ty: type,
    name: []const u8,
};
pub fn TypeMap(comptime Types: anytype) type {
    return [Types.len]TypeMapT;
}

pub fn TagTypeEnumWithTypeMap(comptime Types: anytype) struct {
    tag_type: type,
    ty_map: TypeMap(Types),
} {
    var type_map: TypeMap(Types) = undefined;
    var field_names: [Types.len][]const u8 = undefined;
    var field_values: [Types.len]TaggedPointer.Tag = undefined;

    inline for (Types, 0..) |field, i| {
        const name = comptime @typeName(field);
        field_names[i] = name;
        field_values[i] = 1024 - i;
        type_map[i] = .{ .value = 1024 - i, .ty = field, .name = name };
    }

    return .{
        .tag_type = @Enum(TaggedPointer.Tag, .nonexhaustive, &field_names, &field_values),
        .ty_map = type_map,
    };
}

pub fn TaggedPointerUnion(comptime Types: anytype) type {
    const result = TagTypeEnumWithTypeMap(Types);

    const TagType: type = result.tag_type;

    return struct {
        pub const Tag = TagType;
        pub const TagInt = TaggedPointer.Tag;
        pub const type_map: TypeMap(Types) = result.ty_map;
        repr: TaggedPointer,

        pub const Null: @This() = .{ .repr = .{ ._ptr = 0, .data = 0 } };

        pub fn clear(this: *@This()) void {
            this.* = Null;
        }

        pub fn typeFromTag(comptime the_tag: comptime_int) type {
            for (type_map) |entry| {
                if (entry.value == the_tag) return entry.ty;
            }
            @compileError("Unknown tag: " ++ the_tag);
        }

        pub fn typeNameFromTag(the_tag: TagInt) ?[]const u8 {
            inline for (type_map) |entry| {
                if (entry.value == the_tag) return entry.name;
            }
            return null;
        }

        pub fn typeName(this: This) ?[]const u8 {
            return @tagName(this.tag());
        }

        const This = @This();
        pub fn assert_type(comptime Type: type) void {
            const name = comptime @typeName(Type);
            if (!comptime @hasField(Tag, name)) {
                @compileError("TaggedPointerUnion does not have " ++ name ++ ".");
            }
        }
        pub inline fn get(this: This, comptime Type: type) ?*Type {
            comptime assert_type(Type);

            return if (this.is(Type)) this.as(Type) else null;
        }

        pub inline fn tag(this: This) TagType {
            return @as(TagType, @fromBackingInt(@intCast(this.repr.data)));
        }

        pub fn case(comptime Type: type) Tag {
            return @field(Tag, bun.meta.typeBaseName(@typeName(Type)));
        }

        /// unsafely cast a tagged pointer to a specific type, without checking that it's really that type
        pub inline fn as(this: This, comptime Type: type) *Type {
            comptime assert_type(Type);
            return this.repr.get(Type);
        }

        pub inline fn setUintptr(this: *This, value: AddressableSize) void {
            this.repr._ptr = value;
        }

        pub inline fn asUintptr(this: This) AddressableSize {
            return this.repr._ptr;
        }

        pub inline fn is(this: This, comptime Type: type) bool {
            comptime assert_type(Type);
            return this.repr.data == comptime @backingInt(@field(Tag, @typeName(Type)));
        }

        pub fn set(this: *@This(), _ptr: anytype) void {
            this.* = @This().init(_ptr);
        }

        pub inline fn isValidPtr(_ptr: ?*anyopaque) bool {
            return This.isValid(This.from(_ptr));
        }

        pub inline fn isValid(this: This) bool {
            return switch (this.repr.data) {
                @backingInt(
                    @field(Tag, @typeName(Types[Types.len - 1])),
                )...@backingInt(
                    @field(Tag, @typeName(Types[0])),
                ) => true,
                else => false,
            };
        }

        pub inline fn from(_ptr: ?*anyopaque) This {
            return This{ .repr = TaggedPointer.from(_ptr) };
        }

        pub inline fn ptr(this: This) *anyopaque {
            return this.repr.to();
        }

        pub inline fn ptrUnsafe(this: This) *anyopaque {
            @setRuntimeSafety(false);
            return this.repr.to();
        }

        pub inline fn init(_ptr: anytype) @This() {
            const tyinfo = @typeInfo(@TypeOf(_ptr));
            if (tyinfo != .pointer) @compileError("Only pass pointers to TaggedPointerUnion.init(), you gave us a: " ++ @typeName(@TypeOf(_ptr)));

            const Type = std.meta.Child(@TypeOf(_ptr));
            return initWithType(Type, _ptr);
        }

        pub inline fn initWithType(comptime Type: type, _ptr: anytype) @This() {
            const tyinfo = @typeInfo(@TypeOf(_ptr));
            if (tyinfo != .pointer) @compileError("Only pass pointers to TaggedPointerUnion.init(), you gave us a: " ++ @typeName(@TypeOf(_ptr)));
            const name = comptime @typeName(Type);

            // there will be a compiler error if the passed in type doesn't exist in the enum
            return This{ .repr = TaggedPointer.init(_ptr, @backingInt(@field(Tag, name))) };
        }

        pub inline fn isNull(this: This) bool {
            return this.repr._ptr == 0;
        }

        pub inline fn call(this: This, comptime fn_name: []const u8, args_without_this: anytype, comptime Ret: type) Ret {
            inline for (type_map) |entry| {
                if (this.repr.data == entry.value) {
                    const pointer = this.as(entry.ty);
                    const func = &@field(entry.ty, fn_name);
                    const args = brk: {
                        var args: std.meta.ArgsTuple(@TypeOf(@field(entry.ty, fn_name))) = undefined;
                        args[0] = pointer;

                        inline for (args_without_this, 1..) |a, i| {
                            args[i] = a;
                        }

                        break :brk args;
                    };
                    return @call(.auto, func, args);
                }
            }
            @panic("Invalid tag");
        }
    };
}

const bun = @import("bun");
const std = @import("std");
