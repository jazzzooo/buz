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
    @setEvalBranchQuota(100_000);
    var type_map: TypeMap(Types) = undefined;
    var field_names: [Types.len][]const u8 = undefined;
    var field_values: [Types.len]TaggedPointer.Tag = undefined;

    inline for (Types, 0..) |field, i| {
        const name = comptime @typeName(field);
        inline for (0..i) |previous_index| {
            const previous = Types[previous_index];
            if (field == previous) @compileError("duplicate tagged pointer type: " ++ name);
        }
        field_names[i] = name;
        inline for (0..i) |previous_index| {
            const previous = Types[previous_index];
            if (std.mem.eql(u8, @typeName(previous), name)) {
                field_names[i] = std.fmt.comptimePrint("{s} ({d})", .{ name, i });
                break;
            }
        }
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
            return typeNameFromTag(this.repr.data);
        }

        const This = @This();
        pub fn assert_type(comptime Type: type) void {
            _ = comptime case(Type);
        }
        pub inline fn get(this: This, comptime Type: type) ?*Type {
            comptime assert_type(Type);

            return if (this.is(Type)) this.as(Type) else null;
        }

        pub inline fn tag(this: This) TagType {
            return @as(TagType, @fromBackingInt(@intCast(this.repr.data)));
        }

        pub fn case(comptime Type: type) Tag {
            @setEvalBranchQuota(10_000);
            inline for (type_map) |entry| {
                if (entry.ty == Type) return @fromBackingInt(entry.value);
            }
            @compileError("TaggedPointerUnion does not have " ++ @typeName(Type) ++ ".");
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
            return this.repr.data == comptime @backingInt(case(Type));
        }

        pub fn set(this: *@This(), _ptr: anytype) void {
            this.* = @This().init(_ptr);
        }

        pub inline fn isValid(this: This) bool {
            return this.repr.data >= type_map[Types.len - 1].value and this.repr.data <= type_map[0].value;
        }

        pub inline fn from(_ptr: ?*anyopaque) This {
            return This{ .repr = TaggedPointer.from(_ptr) };
        }

        pub inline fn ptr(this: This) *anyopaque {
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
            return This{ .repr = TaggedPointer.init(_ptr, @backingInt(case(Type))) };
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

test "tagged pointers distinguish generic types with the same display name" {
    const Factory = struct {
        fn make(comptime identity: u8) type {
            const Item = struct {
                value: u8 = identity,
            };
            return Item;
        }
    };
    const First = Factory.make(1);
    const Second = Factory.make(2);
    const Pointer = TaggedPointerUnion(.{ First, Second });
    var first: First = .{};
    var second: Second = .{};
    const first_pointer = Pointer.init(&first);
    const second_pointer = Pointer.init(&second);
    try std.testing.expect(first_pointer.tag() != second_pointer.tag());
    try std.testing.expect(first_pointer.get(First).? == &first);
    try std.testing.expect(second_pointer.get(Second).? == &second);
    try std.testing.expect(first_pointer.get(Second) == null);
    try std.testing.expect(second_pointer.get(First) == null);
    try std.testing.expect(first_pointer.isValid() and second_pointer.isValid());
    try std.testing.expect(!Pointer.Null.isValid());
}

const std = @import("std");
