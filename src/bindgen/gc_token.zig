pub const Affinity = enum {
    any,
    vm,
};

fn Token(comptime Owner: type, comptime affinity: Affinity, comptime Pointee: ?type) type {
    return opaque {
        const owner = Owner;
        const pointee = Pointee;
        pub const bindgen_gc_affinity = affinity;
    };
}

fn Storage(comptime Owner: type, comptime affinity: Affinity) type {
    const Result_ = struct {
        var value: u8 = 0;

        comptime {
            _ = Owner;
            _ = affinity;
        }
    };
    return Result_;
}

pub fn markerWithAffinity(comptime Owner: type, comptime affinity: Affinity) *const Token(Owner, affinity, null) {
    return @ptrCast(&Storage(Owner, affinity).value);
}

pub fn nativePointerMarker(comptime Owner: type, comptime Pointee: type, comptime affinity: Affinity) *const Token(Owner, affinity, Pointee) {
    return @ptrCast(&Storage(Owner, affinity).value);
}

pub fn accepts(comptime Owner: type, comptime candidate: anytype) bool {
    const info = @typeInfo(@TypeOf(candidate));
    if (info != .pointer) return false;
    const Candidate = info.pointer.child;
    if (@typeInfo(Candidate) != .@"opaque" or
        !@hasDecl(Candidate, "pointee") or !@hasDecl(Candidate, "bindgen_gc_affinity")) return false;
    const affinity = Candidate.bindgen_gc_affinity;
    const expected = if (Candidate.pointee) |Pointee|
        nativePointerMarker(Owner, Pointee, affinity)
    else
        markerWithAffinity(Owner, affinity);
    return @TypeOf(candidate) == @TypeOf(expected) and candidate == expected;
}

pub fn requiresVM(comptime Owner: type, comptime candidate: anytype) bool {
    return accepts(Owner, candidate) and @typeInfo(@TypeOf(candidate)).pointer.child.bindgen_gc_affinity == .vm;
}

pub fn nativePointee(comptime Owner: type, comptime candidate: anytype) ?type {
    if (!accepts(Owner, candidate)) return null;
    return @typeInfo(@TypeOf(candidate)).pointer.child.pointee;
}
