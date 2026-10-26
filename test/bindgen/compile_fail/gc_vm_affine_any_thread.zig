const validation = @import("bindgen_class_field_validation");

const VMAffine = struct {
    pub const bindgen_gc_token = validation.testing.markerWithAffinity(@This(), .vm);
};

const Invalid = struct {
    value: VMAffine,
};

comptime {
    validation.validate(Invalid, "Invalid", .{}, .{}, .{}, .{}, false);
}
