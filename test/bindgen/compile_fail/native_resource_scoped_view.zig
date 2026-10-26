const validation = @import("bindgen_class_field_validation");

const ViewToken = struct { generation: u64 };
const Resource = struct { view: struct { token: ViewToken } };
const Owner = struct {
    pointer: *Resource,
    pub const bindgen_gc_token = validation.testing.nativePointerMarker(@This(), Resource, .vm);
};

comptime {
    @setEvalBranchQuota(100_000);
    validation.validate(Owner, "Owner", .{}, .{}, .{ViewToken}, .{}, true);
}
