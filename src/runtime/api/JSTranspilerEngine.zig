pub fn construct(
    context: bindgen.CallContext(TranspilerConstructorSchema),
    args: bindgen.Args(TranspilerConstructorSchema),
) bindgen.CallError(TranspilerConstructorSchema)!*JSTranspiler.JSBinding {
    const vm = jsc.VirtualMachine.get();
    const binding = try bun.default_allocator.create(JSTranspiler.JSBinding);
    errdefer bun.default_allocator.destroy(binding);
    binding.* = .{
        .transpiler = .init(try JSTranspiler.create(.{
            .io = vm.io,
            .engine_capabilities = vm.transpiler.engine_capabilities,
            .env = vm.transpiler.env,
        }, context, args.options)),
    };
    return binding;
}

const JSTranspiler = @import("./JSTranspiler.zig");

const bun = @import("bun");
const bindgen = bun.bindgen;
const jsc = bun.jsc;

const TranspilerSchema = bindgen.Module("Transpiler").class("Transpiler");
const TranspilerConstructorSchema = TranspilerSchema.constructor();
