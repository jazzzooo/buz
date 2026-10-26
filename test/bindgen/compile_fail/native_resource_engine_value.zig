const validation = @import("bindgen_class_field_validation");

const RawValue = enum(u64) { _ };
const Nested = struct { values: [2]RawValue };
const NestedOwner = struct {
    pointer: *Nested,
    pub const bindgen_gc_token = validation.testing.nativePointerMarker(@This(), Nested, .vm);
};
const Resource = struct { nested: ?NestedOwner };
const Owner = struct {
    pointer: *Resource,
    pub const bindgen_gc_token = validation.testing.nativePointerMarker(@This(), Resource, .vm);
};

comptime {
    @setEvalBranchQuota(100_000);
    validation.validate(Owner, "Owner", .{}, .{RawValue}, .{}, .{}, true);
}
