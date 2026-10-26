const b = @import("bindgen_schema");
const engine_types = @import("binding_schema_engine_types");

const uv_signal_handle = b.nominalHandle("UVSignal", .{
    .cpp_type = .{ .pointer = &.{ .named = "uv_signal_s" } },
    .cpp_declarations = &.{.{ .structure = "uv_signal_s" }},
    .access_thread = .current,
});
const uv_signal_callback_handle = b.nominalHandle("UVSignalCallback", .{
    .cpp_type = .{ .named = "BunBindgenUVSignalCallback" },
    .cpp_declarations = &.{ .{ .structure = "uv_signal_s" }, .{ .alias = .{ .name = "BunBindgenUVSignalCallback", .type = .{ .function_pointer = .{ .result = &.void, .parameters = &.{ .{ .pointer = &.{ .named = "uv_signal_s" } }, .int }, .convention = .c } } } } },
    .access_thread = .current,
});

const native_exports = .{
    b.nativeExportWithOptions(
        "uvSignalHandleInit",
        .{
            b.argument("loop", engine_types.native_event_loop, .{}),
            b.argument("signal", b.int32, .{}),
            b.argument("callback", uv_signal_callback_handle, .{}),
        },
        b.optional(uv_signal_handle),
        .{ .throws = .never, .realm = .none, .exposure = .{ .os = "windows" } },
    ),
    b.nativeExportWithOptions(
        "uvSignalHandleClose",
        .{b.argument("handle", uv_signal_handle, .{})},
        b.none,
        .{ .throws = .never, .realm = .none, .exposure = .{ .os = "windows" } },
    ),
};

pub const schema = b.moduleWithNativeExports("uv_signal_handles", .{}, native_exports);
