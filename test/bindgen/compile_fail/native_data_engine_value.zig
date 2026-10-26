const validation = @import("bindgen_class_field_validation");

const EngineValue = enum(u64) { _ };

const Invalid = struct {
    value: EngineValue,
};

comptime {
    validation.validateNativeData(Invalid, "Invalid", .{EngineValue});
}
