const b = @import("bindgen_schema");

const dynamic_library_handle = b.nominalHandle("DynamicLibrary", .{
    .cpp_type = .{ .pointer = &.{ .named = "BunBindgenDynamicLibraryHandle" } },
    .cpp_declarations = &.{.{ .structure = "BunBindgenDynamicLibraryHandle" }},
    .access_thread = .any,
});

const native_exports = .{
    b.nativeExportWithOptions(
        "windowsLoadLibrary",
        .{b.argument("path", b.dom_string, .{})},
        b.optional(dynamic_library_handle),
        .{ .throws = .never, .realm = .none, .exposure = .{ .os = "windows" } },
    ),
};

pub const schema = b.moduleWithNativeExports("windows_dynamic_library", .{}, native_exports);
