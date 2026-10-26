const validation = @import("bindgen_class_field_validation");

const FocusedValue = struct {
    value: u64,

    pub const bindgen_focused_value_access = {};
};

const Invalid = struct {
    value: FocusedValue,
};

comptime {
    validation.validateNativeData(Invalid, "Invalid", .{});
}
