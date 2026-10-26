const validation = @import("bindgen_class_field_validation");

const Invalid = struct {
    nested: struct {
        items: []const u8,
    },
};

comptime {
    validation.validateNativeData(Invalid, "Invalid", .{});
}
