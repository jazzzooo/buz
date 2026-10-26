const validation = @import("bindgen_class_field_validation");

const Root = struct {
    pub const bindgen_gc_token = validation.testing.markerWithAffinity(@This(), .vm);
};
const Resource = struct {
    root: Root,
};
fn Owner(comptime affinity: validation.testing.Affinity) type {
    return struct {
        pointer: *Resource,
        pub const bindgen_gc_token = validation.testing.nativePointerMarker(@This(), Resource, affinity);
    };
}
const Parent = struct {
    vm: Owner(.vm),
    any: Owner(.any),
};
const ParentOwner = struct {
    pointer: *Parent,
    pub const bindgen_gc_token = validation.testing.nativePointerMarker(@This(), Parent, .vm);
};

comptime {
    @setEvalBranchQuota(100_000);
    validation.validate(ParentOwner, "Owner", .{}, .{}, .{}, .{}, true);
}
