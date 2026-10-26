const validation = @import("bindgen_class_field_validation");

const Invalid = struct {
    callback: *const fn () void,
};

comptime {
    validation.validate(Invalid, "Invalid", .{}, .{}, .{}, .{}, true);
}
