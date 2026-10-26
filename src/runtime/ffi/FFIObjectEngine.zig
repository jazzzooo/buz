pub fn compile(
    context: bun.bindgen.CallContext(CompileSchema),
    args: bun.bindgen.Args(CompileSchema),
) bun.bindgen.CallError(CompileSchema)!bun.bindgen.Return(CompileSchema) {
    return FFI.compile(jsc.VirtualMachine.get().io, context, args);
}

pub fn dlopen(
    context: bun.bindgen.CallContext(DlopenSchema),
    args: bun.bindgen.Args(DlopenSchema),
) bun.bindgen.CallError(DlopenSchema)!bun.bindgen.Return(DlopenSchema) {
    const vm = jsc.VirtualMachine.get();
    const name = try FFI.copyFilePath(context, args.name);
    defer bun.default_allocator.free(name);
    const path_buffer = bun.path_buffer_pool.get();
    defer bun.path_buffer_pool.put(path_buffer);
    const resolved = jsc.ModuleLoader.resolveEmbeddedFile(vm, path_buffer, name, switch (bun.Environment.os) {
        .linux, .freebsd => "so",
        .mac => "dylib",
        .windows => "dll",
        .wasm => @compileError("FFI requires a native dynamic loader"),
    }) orelse name;
    return FFI.open(context, resolved, &args.symbols);
}

const bun = @import("bun");
const FFI = @import("./ffi.zig").FFI;
const jsc = bun.jsc;

const FFIBindings = bun.bindgen.Module("FFI");
const CompileSchema = FFIBindings.function("compile");
const DlopenSchema = FFIBindings.function("dlopen");
