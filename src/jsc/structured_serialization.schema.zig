const b = @import("bindgen_schema");

pub const serialized_script_value_handle = b.nominalHandle("SerializedScriptValue", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::SerializedScriptValue" } },
    .cpp_declarations = &.{.{ .class = "WebCore::SerializedScriptValue" }},
    .cpp_read_bytes = "serializedScriptValueBytes",
    .ownership = .owned,
    .cpp_release = "releaseSerializedScriptValue",
    .access_thread = .any,
    .destroy_thread = .any,
});

const engine_shims = .{
    b.engineShim(
        "serializeJSValue",
        .{
            b.argument("value", b.engine_value, .{}),
            b.argument("for_cross_process_transfer", b.boolean, .{}),
        },
        serialized_script_value_handle,
        .current_realm_throwing,
    ),
    b.engineShim(
        "deserializeJSValue",
        .{b.argument("data", b.buffer(.copy), .{})},
        b.engine_value,
        .current_realm_throwing,
    ),
};

pub const schema = b.moduleWithDeclarations("structured_serialization", .{}, .{}, engine_shims, .{});
