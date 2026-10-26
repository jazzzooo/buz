const validation = @import("bindgen_class_field_validation");

const RawValue = struct {};
const Invalid = struct {
    value: RawValue,
};

comptime {
    validation.validate(Invalid, "Invalid", .{}, .{RawValue}, .{}, .{}, true);
}
