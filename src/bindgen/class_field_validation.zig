const builtin = @import("builtin");
const std = @import("std");
const gc_token = @import("./gc_token.zig");

pub const testing = if (builtin.is_test) struct {
    pub const Affinity = gc_token.Affinity;

    pub fn markerWithAffinity(
        comptime Owner: type,
        comptime affinity: gc_token.Affinity,
    ) @TypeOf(gc_token.markerWithAffinity(Owner, affinity)) {
        return gc_token.markerWithAffinity(Owner, affinity);
    }

    pub const nativePointerMarker = gc_token.nativePointerMarker;
} else struct {};

test "native resource validation terminates for cycles and repeated types" {
    const Node = struct {
        next: ?Link,
        bytes: [16]u8,
        sibling: ?Link,

        const Self = @This();
        const Link = struct {
            pointer: *Self,
            pub const bindgen_gc_token = gc_token.nativePointerMarker(@This(), Self, .any);
        };
    };
    comptime validateNative(Node, "Node", .{}, .{}, .{}, false);
}

test "native ownership wrappers support scalar slice elements" {
    const Bytes = struct {
        values: []u8,
        pub const bindgen_gc_token = gc_token.nativePointerMarker(@This(), u8, .any);
    };
    comptime validateNative(Bytes, "Bytes", .{}, .{}, .{}, false);
    comptime validate(struct { bytes: Bytes }, "Owner", .{}, .{}, .{}, .{}, false);
}

test "native owners validate cyclic allocation graphs and native services" {
    const Resource = struct {
        bytes: []u8,
        next: ?*@This(),
        allocator: std.mem.Allocator,
        io: std.Io,
    };
    const Owner = struct {
        pointer: *Resource,
        pub const bindgen_gc_token = gc_token.nativePointerMarker(@This(), Resource, .any);
    };
    comptime validate(Owner, "Owner", .{}, .{}, .{}, .{}, false);
}

test "native C resources preserve their library callback representation" {
    const Resource = extern struct {
        userdata: ?*anyopaque,
        callback: ?*const fn (?*anyopaque) callconv(.c) void,
        bytes: [*c]u8,
    };
    comptime validateNative(Resource, "Resource", .{}, .{}, .{}, false);
}

pub fn validateNative(
    comptime T: type,
    comptime path: []const u8,
    comptime requires_root: anytype,
    comptime scoped_views: anytype,
    comptime vm_services: anytype,
    comptime allow_vm_affine: bool,
) void {
    @setEvalBranchQuota(10_000_000);
    validateNativePointee(T, path);
    const Rules = NativeRules(requires_root, scoped_views, vm_services);
    if (nativeValue(Rules, T, allow_vm_affine, .root, null).len != 0) {
        @compileError(joinLines(nativeValue(Rules, T, allow_vm_affine, .root, path)));
    }
}

fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

fn validateNativePointee(comptime T: type, comptime path: []const u8) void {
    const nominal = T != anyopaque and switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
    if (!nominal) {
        @compileError("native resource '" ++ path ++ "' requires a nominal pointee type");
    }
}

fn NativeRules(comptime requires_root: anytype, comptime scoped_views: anytype, comptime vm_services: anytype) type {
    return struct {
        const engine_values = requires_root;
        const views = scoped_views;
        const services = vm_services;
    };
}

/// Where a value sits relative to the validation root. The root, the pointee of
/// a root wrapper, and values stored inline are checked in place, so their
/// diagnostics keep the root path; aggregates behind any other pointer are
/// checked by their own `NativeNode`.
const Placement = enum { root, inline_value, pointee };

/// Validates an aggregate reached through a pointer. Types are interned, so each
/// type is checked once per compilation, and a pointer cycle ends at the node
/// that already exists.
fn NativeNode(comptime Rules: type, comptime T: type, comptime allow_vm_affine: bool) type {
    return struct {
        comptime {
            @setEvalBranchQuota(10_000_000);
            if (nativeFields(Rules, T, allow_vm_affine, null).len != 0) {
                const diagnostics = joinLines(nativeFields(Rules, T, allow_vm_affine, @typeName(T)));
                @compileError(if (allow_vm_affine)
                    diagnostics
                else
                    diagnostics ++ "'" ++ @typeName(T) ++ "' is reachable from any-thread native state\n");
            }
        }
    };
}

/// Returns the violations of a `T` stored at `path`. A null path skips building
/// messages; the result is then only checked for emptiness.
fn nativeValue(
    comptime Rules: type,
    comptime T: type,
    comptime allow_vm_affine: bool,
    comptime placement: Placement,
    comptime path: ?[]const u8,
) []const []const u8 {
    if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.child == anyopaque)
        return &.{violation(path, "has an untyped native pointer; use a nominal resource type")};
    inline for (Rules.engine_values) |EngineValue| {
        if (T == EngineValue) return &.{violation(path, "must use a bindgen root or typed weak handle")};
    }
    inline for (Rules.views) |View| {
        if (T == View) return &.{violation(path, "contains a call-scoped view")};
    }
    inline for (Rules.services) |Service| {
        if (T == Service) {
            return if (allow_vm_affine) &.{} else &.{violation(path, "requires VM-affine service access")};
        }
    }
    if (T == std.mem.Allocator or T == std.Io) return &.{};
    const type_info = @typeInfo(T);
    if (hasDecl(T, "bindgen_focused_value_access")) {
        return &.{violation(path, "contains a focused engine value; use a root for storage")};
    }
    inline for (.{
        "bindgen_function_call_context",
        "bindgen_native_call_context",
        "bindgen_callback_invocation_context",
        "bindgen_materialization_context",
        "bindgen_structured_clone_context",
        "bindgen_focused_engine_scope",
    }) |marker| {
        if (hasDecl(T, marker)) return &.{violation(path, "contains a call-scoped context")};
    }
    if (hasDecl(T, "bindgen_gc_token")) {
        if (!gc_token.accepts(T, T.bindgen_gc_token)) {
            return &.{violation(path, "has an invalid bindgen GC token")};
        }
        if (!allow_vm_affine and gc_token.requiresVM(T, T.bindgen_gc_token)) {
            return &.{violation(path, "requires VM-affine reference handling")};
        }
        const Pointee = gc_token.nativePointee(T, T.bindgen_gc_token) orelse return &.{};
        const pointee_path = extend(path, ".*");
        if (Pointee == anyopaque) return &.{violation(pointee_path, "requires a typed pointee")};
        return nativeValue(
            Rules,
            Pointee,
            gc_token.requiresVM(T, T.bindgen_gc_token),
            if (placement == .root) .inline_value else .pointee,
            pointee_path,
        );
    }
    return switch (type_info) {
        .void, .null, .bool, .int, .float, .error_set, .@"enum", .@"opaque" => &.{},
        .pointer => |info| if (@typeInfo(info.child) == .@"fn")
            &.{}
        else
            nativeValue(Rules, info.child, allow_vm_affine, .pointee, extend(path, ".*")),
        .optional, .array, .vector, .error_union => nativeValue(Rules, container(T).child, allow_vm_affine, placement, extend(path, container(T).suffix)),
        .@"struct", .@"union" => switch (placement) {
            .root, .inline_value => nativeFields(Rules, T, allow_vm_affine, path),
            .pointee => pointee: {
                _ = NativeNode(Rules, T, allow_vm_affine);
                break :pointee &.{};
            },
        },
        else => &.{violation(path, "has unsupported runtime type '" ++ @typeName(T) ++ "'")},
    };
}

fn nativeFields(
    comptime Rules: type,
    comptime T: type,
    comptime allow_vm_affine: bool,
    comptime path: ?[]const u8,
) []const []const u8 {
    var diagnostics: []const []const u8 = &.{};
    switch (@typeInfo(T)) {
        inline .@"struct", .@"union" => |info| inline for (info.field_names, info.field_types) |field_name, FieldType| {
            if (info.layout == .@"extern" and isForeignOpaquePointer(FieldType)) continue;
            const field_path = if (path) |owner| owner ++ "." ++ field_name else null;
            const found = nativeValue(Rules, FieldType, allow_vm_affine, .inline_value, field_path);
            if (found.len != 0) diagnostics = diagnostics ++ found;
        },
        else => unreachable,
    }
    return diagnostics;
}

fn violation(comptime path: ?[]const u8, comptime problem: []const u8) []const u8 {
    return if (path) |resource| "native resource '" ++ resource ++ "' " ++ problem else "";
}

fn extend(comptime path: ?[]const u8, comptime suffix: []const u8) ?[]const u8 {
    return if (path) |resource| resource ++ suffix else null;
}

fn joinLines(comptime lines: []const []const u8) []const u8 {
    var message: []const u8 = "";
    for (lines) |line| message = message ++ line ++ "\n";
    return message;
}

fn container(comptime T: type) struct { child: type, suffix: []const u8 } {
    return switch (@typeInfo(T)) {
        .optional => |info| .{ .child = info.child, .suffix = "?" },
        .array => |info| .{ .child = info.child, .suffix = "[]" },
        .vector => |info| .{ .child = info.child, .suffix = "<>" },
        .error_union => |info| .{ .child = info.payload, .suffix = "!" },
        else => @compileError("expected a stored-value container"),
    };
}

fn isForeignOpaquePointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |info| info.child == anyopaque,
        inline .optional, .array => |info| isForeignOpaquePointer(info.child),
        else => false,
    };
}

pub fn validateNativeData(
    comptime T: type,
    comptime path: []const u8,
    comptime engine_values: anytype,
) void {
    inline for (engine_values) |EngineValue| {
        if (T == EngineValue) {
            @compileError(
                "NativeData payload '" ++ path ++
                    "' contains an engine value; use a root or typed handle",
            );
        }
    }

    const type_info = @typeInfo(T);
    if (hasDecl(T, "bindgen_focused_value_access")) {
        @compileError(
            "NativeData payload '" ++ path ++
                "' contains a focused engine value; use a root for storage",
        );
    }

    switch (type_info) {
        .void,
        .bool,
        .int,
        .float,
        .error_set,
        .@"enum",
        => {},
        .pointer => @compileError(
            "NativeData payload '" ++ path ++ "' contains pointer type '" ++ @typeName(T) ++
                "'; use an explicit owned, referenced, or borrowed native wrapper",
        ),
        .optional, .array, .vector, .error_union => validateNativeData(container(T).child, path ++ container(T).suffix, engine_values),
        inline .@"struct", .@"union" => |info| inline for (info.field_names, info.field_types) |field_name, FieldType| {
            validateNativeData(FieldType, path ++ "." ++ field_name, engine_values);
        },
        else => @compileError(
            "NativeData payload '" ++ path ++ "' has unsupported runtime type '" ++ @typeName(T) ++ "'",
        ),
    }
}

pub fn validate(
    comptime T: type,
    comptime path: []const u8,
    comptime approved: anytype,
    comptime requires_root: anytype,
    comptime scoped_views: anytype,
    comptime vm_services: anytype,
    comptime allow_vm_affine: bool,
) void {
    const type_info = @typeInfo(T);
    if (hasDecl(T, "bindgen_gc_token")) {
        if (!gc_token.accepts(T, T.bindgen_gc_token)) {
            @compileError("bound class field '" ++ path ++ "' has an invalid bindgen GC token");
        }
        if (!allow_vm_affine and gc_token.requiresVM(T, T.bindgen_gc_token)) {
            @compileError("bound class field '" ++ path ++ "' requires VM-affine reference handling");
        }
        if (gc_token.nativePointee(T, T.bindgen_gc_token) != null) {
            validateNative(T, path, requires_root, scoped_views, vm_services, allow_vm_affine);
        }
        return;
    }
    inline for (approved) |Approved| {
        if (T == Approved) return;
    }
    inline for (requires_root) |EngineValue| {
        if (T == EngineValue) {
            @compileError("bound class field '" ++ path ++ "' must use a bindgen root or typed weak handle");
        }
    }

    switch (type_info) {
        .void,
        .bool,
        .int,
        .float,
        .comptime_int,
        .comptime_float,
        .@"enum",
        .error_set,
        => {},
        .optional, .array, .vector, .error_union => validate(container(T).child, path ++ container(T).suffix, approved, requires_root, scoped_views, vm_services, allow_vm_affine),
        inline .@"struct", .@"union" => |info| inline for (info.field_names, info.field_types) |field_name, FieldType| {
            validate(FieldType, path ++ "." ++ field_name, approved, requires_root, scoped_views, vm_services, allow_vm_affine);
        },
        .pointer => @compileError(
            "bound class field '" ++ path ++ "' has unapproved pointer type '" ++ @typeName(T) ++
                "'; use an explicit owned, referenced, or borrowed native wrapper",
        ),
        else => @compileError(
            "bound class field '" ++ path ++ "' has unsupported type '" ++ @typeName(T) ++ "'",
        ),
    }
}
