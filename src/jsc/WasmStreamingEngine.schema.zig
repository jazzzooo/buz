const b = @import("bindgen_schema");
const response = @import("binding_schema_Response");

const wasm_streaming_compiler_handle = b.nominalHandle("WasmStreamingCompiler", .{
    .cpp_type = .{ .pointer = &.{ .named = "JSC::Wasm::StreamingCompiler" } },
    .cpp_declarations = &.{.{ .class = "JSC::Wasm::StreamingCompiler" }},
    .zig_type = "jsc.WasmStreamingCompilerHandle",
    .access_thread = .vm,
});

const engine_shims = .{
    b.engineShim("wasmStreamingCompilerAddBytes", .{
        b.argument("compiler", wasm_streaming_compiler_handle, .{}),
        b.argument("bytes", b.buffer(.copy), .{}),
    }, b.none, .vm_thread_nonthrowing),
};

const native_exports = .{
    b.nativeExportWithOptions("getBodyStreamOrBytesForWasmStreaming", .{
        b.argument("source", b.classRefWithOptions(response.response, .{
            .node_expected_instances = "Response or an Promise resolving to Response",
        }), .{}),
        b.argument("compiler", wasm_streaming_compiler_handle, .{}),
    }, b.optional(b.readable_stream), .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("WasmStreamingEngine", .{}, .{}, engine_shims, native_exports);
