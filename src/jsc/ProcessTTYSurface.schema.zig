const b = @import("bindgen_schema");
const tty = @import("binding_schema_ProcessTTY");

const permanent = b.SurfaceMemberOptions{
    .attributes = .{ .configurable = false },
};

const namespace_member = b.SurfaceMemberOptions{ .attributes = .{} };

const constructor_member = b.SurfaceMemberOptions{
    .attributes = .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
    },
};

const prototype = b.objectSurface("TTYWrapPrototype", .{
    b.surfaceFunction("getWindowSize", tty.schema.function("wrapGetWindowSize"), permanent),
    b.surfaceFunction("setRawMode", tty.schema.function("wrapSetMode"), permanent),
    b.surfaceSymbolString(.to_string_tag, "LibuvStreamWrap", .{
        .attributes = .{ .writable = false, .enumerable = false },
    }),
}, .{ .installation = .reified });

const namespace = b.objectSurface("ProcessTTYBinding", .{
    b.surfaceFunction("isTTY", tty.schema.function("isatty"), namespace_member),
    b.surfaceLazyProperty("TTY", tty.schema.function("constructTTYWrapConstructor"), constructor_member),
}, .{ .installation = .direct });

pub const schema = b.moduleWithSurfaces("ProcessTTYSurface", .{ prototype, namespace });
