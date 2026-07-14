//! Private utilities used in smart pointer implementations.

pub const PointerInfo = struct {
    const Self = @This();

    /// A possibly optional slice or single-item pointer type.
    /// E.g., `*u8`, `[]u8`, `?*u8`, `?[]u8`.
    Pointer: type,

    /// If `Pointer` is an optional pointer, this is the non-optional equivalent. Otherwise, this
    /// is the same as `Pointer`.
    ///
    /// For example, if `Pointer` is `?[]u8`, this is `[]u8`.
    NonOptionalPointer: type,

    /// The type of data stored by the pointer, i.e., the type obtained by dereferencing a
    /// single-item pointer or accessing an element of a slice.
    ///
    /// For example, if `Pointer` is `?[]u8`, this is `u8`.
    Child: type,

    pub fn kind(self: Self) enum { single, slice } {
        return switch (@typeInfo(self.NonOptionalPointer).pointer.size) {
            .one => .single,
            .slice => .slice,
            else => @compileError("unreachable"),
        };
    }

    pub fn isOptional(self: Self) bool {
        return @typeInfo(self.Pointer) == .optional;
    }

    pub fn isConst(self: Self) bool {
        return @typeInfo(self.NonOptionalPointer).pointer.attrs.@"const";
    }

    pub const ParseOptions = struct {
        allow_const: bool = true,
        allow_slices: bool = true,
    };

    pub fn parse(comptime Pointer: type, comptime options: ParseOptions) Self {
        const NonOptionalPointer = switch (@typeInfo(Pointer)) {
            .optional => |opt| opt.child,
            else => Pointer,
        };

        const pointer_info = switch (@typeInfo(NonOptionalPointer)) {
            .pointer => |ptr| ptr,
            else => @compileError("type must be a (possibly optional) pointer"),
        };
        const Child = pointer_info.child;

        switch (pointer_info.size) {
            .one => {},
            .slice => if (!options.allow_slices) @compileError("slices not supported"),
            .many => @compileError("many-item pointers not supported"),
            .c => @compileError("C pointers not supported"),
        }

        if (pointer_info.attrs.@"const" and !options.allow_const) {
            @compileError("const pointers not supported");
        }
        if (pointer_info.attrs.@"volatile") {
            @compileError("volatile pointers not supported");
        }
        if (pointer_info.attrs.@"align") |alignment| {
            if (alignment != @alignOf(Child)) {
                @compileError("non-default alignment not supported");
            }
        }
        if (pointer_info.attrs.@"allowzero") {
            @compileError("allowzero not supported");
        }
        if (pointer_info.sentinel_ptr != null) {
            @compileError("sentinel-terminated pointers not supported");
        }

        return .{
            .Pointer = Pointer,
            .NonOptionalPointer = NonOptionalPointer,
            .Child = Child,
        };
    }
};

pub fn AddConst(Pointer: type) type {
    return switch (@typeInfo(Pointer)) {
        .pointer => |ptr| blk: {
            var attrs = ptr.attrs;
            attrs.@"const" = true;
            break :blk @Pointer(ptr.size, attrs, ptr.child, ptr.sentinel());
        },
        .optional => |opt| ?AddConst(opt.child),
        // Technically this function accepts things like `?????[]u8`, but `PointerInfo.parse`
        // verifies that's not the case.
        else => @compileError("`Pointer` must be a (possibly optional) pointer or slice"),
    };
}
