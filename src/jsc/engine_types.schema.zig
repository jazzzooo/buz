const b = @import("bindgen_schema");

pub const host_function = b.nominalHandle("HostFunction", .{
    .cpp_type = .{ .named = "BunBindgenHostFunction" },
    .cpp_declarations = &.{.{ .alias = .{ .name = "BunBindgenHostFunction", .type = .{ .function_pointer = .{ .result = &.{ .named = "JSC::EncodedJSValue" }, .parameters = &.{ .{ .pointer = &.{ .named = "JSC::JSGlobalObject" } }, .{ .pointer = &.{ .named = "JSC::CallFrame" } } }, .convention = .host } } } }},
    .ownership = .borrowed,
    .access_thread = .vm,
});

pub const wtf_string_impl = b.nominalHandle("WTFStringImpl", .{
    .cpp_type = .{ .pointer = &.{ .named = "WTF::StringImpl" } },
    .cpp_declarations = &.{.{ .class = "WTF::StringImpl" }},
    .access_thread = .any,
});

pub const native_blob = b.nominalHandle("NativeBlob", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::BlobImpl" } },
    .cpp_declarations = &.{.{ .class = "WebCore::BlobImpl" }},
    .access_thread = .any,
});

pub const external_bytes_owner = b.external_bytes_owner;

pub const bun_vm = b.nominalHandle("BunVM", .{
    .cpp_type = .{ .pointer = &.{ .named = "VirtualMachine" } },
    .cpp_declarations = &.{.{ .structure = "VirtualMachine" }},
    .access_thread = .any,
});

pub const jsc_vm = b.nominalHandle("VM", .{
    .cpp_type = .{ .pointer = &.{ .named = "JSC::VM" } },
    .cpp_declarations = &.{.{ .class = "JSC::VM" }},
    .access_thread = .any,
});

pub const native_event_loop = b.nominalHandle("NativeEventLoop", .{
    .cpp_type = .{ .pointer = &.{ .named = "uv_loop_t" } },
    .cpp_declarations = &.{ .{ .structure = "uv_loop_s" }, .{ .alias = .{ .name = "uv_loop_t", .type = .{ .named = "uv_loop_s" } } } },
    .zig_type = "Async.Loop",
    .access_thread = .current,
});

pub const global_object = b.nominalHandle("GlobalObject", .{
    .cpp_type = .{ .pointer = &.{ .named = "JSC::JSGlobalObject" } },
    .cpp_declarations = &.{.{ .class = "JSC::JSGlobalObject" }},
    .access_thread = .vm,
});

pub const call_frame = b.nominalHandle("CallFrame", .{
    .cpp_type = .{ .pointer = &.{ .named = "JSC::CallFrame" } },
    .cpp_declarations = &.{.{ .class = "JSC::CallFrame" }},
    .access_thread = .vm,
});

pub const zig_global_object = b.nominalHandle("ZigGlobalObject", .{
    .cpp_type = .{ .pointer = &.{ .named = "Zig::GlobalObject" } },
    .cpp_declarations = &.{.{ .class = "Zig::GlobalObject" }},
    .access_thread = .any,
});

pub const callable_or_async_context_value = b.brandedValueWithBrand(b.cppBrand("CallableOrAsyncContextValue", .{
    .symbol = "Bun::Bindgen::TypePredicates::isCallableOrAsyncContext",
    .header = "AsyncContextFrame.h",
}, "(...args: unknown[]) => unknown"), .{});

pub const module_info_deserialized = b.nominalHandle("ModuleInfoDeserialized", .{
    .cpp_type = .{ .pointer = &.{ .named = "bun_ModuleInfoDeserialized" } },
    .cpp_declarations = &.{.{ .structure = "bun_ModuleInfoDeserialized" }},
    .ownership = .owned,
    .cpp_release = "releaseModuleInfoDeserialized",
    .access_thread = .any,
    .destroy_thread = .any,
    .zig_type = "transpiler.analyze_transpiled_module.ModuleInfoDeserialized",
});

pub const borrowed_module_info_deserialized = b.nominalHandle("BorrowedModuleInfoDeserialized", .{
    .cpp_type = .{ .pointer = &.{ .named = "bun_ModuleInfoDeserialized" } },
    .cpp_declarations = &.{.{ .structure = "bun_ModuleInfoDeserialized" }},
    .zig_type = "transpiler.analyze_transpiled_module.ModuleInfoDeserialized",
    .access_thread = .any,
});

pub const schema = b.module("engine_types", .{});
