const validation = @import("bindgen_class_field_validation");

const Resource = struct { pointer: *anyopaque };
const Owner = struct {
    pointer: *Resource,
    pub const bindgen_gc_token = validation.testing.nativePointerMarker(@This(), Resource, .vm);
};

comptime {
    validation.validate(Owner, "Owner", .{}, .{}, .{}, .{}, true);
}
