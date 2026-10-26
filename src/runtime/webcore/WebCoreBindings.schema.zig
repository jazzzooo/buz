const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

pub fn wrapperParent(comptime cpp_impl: []const u8) b.ClassParent {
    return b.engineParent(.{
        .cpp_class = .{ .specialization = .{ .name = "WebCore::JSDOMWrapper", .arguments = &.{.{ .named = cpp_impl }} } },
        .cpp_impl = cpp_impl,
        .header = "JSDOMWrapper.h",
        .prototype = .object,
        .constructor = .function,
    });
}

fn wrapperOptions(
    comptime engine_intrinsic: []const u8,
    comptime options: b.ClassOptions,
) b.ClassOptions {
    var resolved = options;
    resolved.backend = .cpp;
    resolved.representation = .engine;
    resolved.engine_intrinsic = engine_intrinsic;
    return resolved;
}

pub fn wrapperClass(
    comptime name: []const u8,
    comptime constructor: b.ClassMember,
    comptime members: anytype,
    comptime cached_slots: anytype,
    comptime engine_intrinsic: []const u8,
    comptime options: b.ClassOptions,
) b.Class {
    return b.class(name, constructor, members, cached_slots, wrapperOptions(engine_intrinsic, options));
}

pub fn wrapperClassWithDataProperties(
    comptime name: []const u8,
    comptime constructor: b.ClassMember,
    comptime members: anytype,
    comptime cached_slots: anytype,
    comptime data_properties: anytype,
    comptime engine_intrinsic: []const u8,
    comptime options: b.ClassOptions,
) b.Class {
    return b.classWithDataProperties(name, constructor, members, cached_slots, data_properties, wrapperOptions(engine_intrinsic, options));
}

pub fn eventHandlerGetter(comptime name: []const u8) b.ClassMember {
    return b.getter(name, archetypes.event_handler_value, .{ .configurable = true });
}

pub fn eventHandlerSetter(comptime name: []const u8) b.ClassMember {
    return b.setter(name, archetypes.event_handler_input, .{ .configurable = true });
}

pub const schema = b.module("WebCoreBindings", .{});
