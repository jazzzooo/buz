const validation = @import("bindgen_class_field_validation");

const Owner = struct {
    pointer: *anyopaque,
    pub const bindgen_gc_token = validation.testing.nativePointerMarker(@This(), anyopaque, .vm);
};

comptime {
    validation.validate(Owner, "Owner", .{}, .{}, .{}, .{}, true);
}
