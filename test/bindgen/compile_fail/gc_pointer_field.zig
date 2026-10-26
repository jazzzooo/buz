const validation = @import("bindgen_class_field_validation");

const Invalid = struct {
    pointer: *u8,
};

comptime {
    validation.validate(Invalid, "Invalid", .{}, .{}, .{}, .{}, true);
}
