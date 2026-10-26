const validation = @import("bindgen_class_field_validation");

comptime {
    validation.validateNativeData(fn () void, "Callback", .{});
}
