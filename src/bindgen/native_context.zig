const gc_token = @import("./gc_token.zig");

pub const testing = if (@import("builtin").is_test) struct {
    pub const validation = @import("./class_field_validation.zig");
} else struct {};

pub fn NativeContext(comptime affinity: gc_token.Affinity, comptime Policy: type) type {
    return struct {
        pointer: *Handle,
        type_identity: *const Identity,

        const Self = @This();
        const Handle = opaque {};
        const Identity = opaque {};

        // Capture validates the resource graph before erasure; recovery checks the original pointer type.
        pub const bindgen_gc_token = gc_token.markerWithAffinity(Self, affinity);

        fn identity(comptime Pointer: type) *const Identity {
            if (@typeInfo(Pointer) != .pointer or @typeInfo(Pointer).pointer.size != .one)
                @compileError("native callback contexts require a typed single-item pointer");
            const Tag = struct {
                pub const PointerType = Pointer;
                var byte: u8 = 0;
            };
            return @ptrCast(&Tag.byte);
        }

        pub fn init(pointer: anytype) Self {
            const Pointer = @TypeOf(pointer);
            const type_identity = identity(Pointer);
            comptime Policy.validate(@typeInfo(Pointer).pointer.child, affinity);
            return .{
                .pointer = @ptrCast(@constCast(pointer)),
                .type_identity = type_identity,
            };
        }

        pub fn get(self: Self, comptime Pointer: type) Pointer {
            if (self.type_identity != identity(Pointer))
                @panic("native callback context type mismatch");
            return @ptrCast(@alignCast(self.pointer));
        }

        pub fn eql(self: Self, other: Self) bool {
            return self.pointer == other.pointer and self.type_identity == other.type_identity;
        }
    };
}

test "native callback contexts recover the original pointer type" {
    const std = @import("std");
    const Policy = struct {
        pub fn validate(comptime T: type, comptime affinity: gc_token.Affinity) void {
            testing.validation.validateNative(T, @typeName(T), .{}, .{}, .{}, affinity == .vm);
        }
    };
    const Context = NativeContext(.any, Policy);
    const Resource = struct { value: u32 };
    const Other = struct { value: u32 };
    var resource: Resource = .{ .value = 4 };
    const context = Context.init(&resource);
    context.get(*Resource).value = 9;
    try std.testing.expectEqual(@as(u32, 9), resource.value);
    const aliased = Context.init(@as(*Other, @ptrCast(&resource)));
    try std.testing.expect(!context.eql(aliased));
    const constant = Context.init(@as(*const Resource, &resource));
    try std.testing.expect(!context.eql(constant));
    try std.testing.expectEqual(@as(u32, 9), constant.get(*const Resource).value);
}
