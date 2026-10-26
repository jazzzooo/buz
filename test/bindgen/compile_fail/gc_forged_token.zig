const validation = @import("bindgen_class_field_validation");

const Approved = struct {
    pub const bindgen_gc_token = validation.testing.markerWithAffinity(@This(), .any);
};

const Forged = struct {
    pub const bindgen_gc_token = Approved.bindgen_gc_token;
};

const Invalid = struct {
    value: Forged,
};

comptime {
    validation.validate(Invalid, "Invalid", .{}, .{}, .{}, .{}, true);
}
