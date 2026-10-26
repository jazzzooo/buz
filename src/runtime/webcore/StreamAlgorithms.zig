const bun = @import("bun");
const bindgen = bun.bindgen;
const InvokeSizeSchema = bindgen.Module("StreamAlgorithms").function("invokeSize");
const InvokeSizeBinding = bindgen.Fn(InvokeSizeSchema, invokeSize);

fn invokeSize(context: bindgen.CallContext(InvokeSizeSchema), args: bindgen.Args(InvokeSizeSchema)) bun.JSError!bindgen.Return(InvokeSizeSchema) {
    return args.callback.call(.{ .chunk = args.chunk.operand(context) });
}

comptime {
    _ = &InvokeSizeBinding;
}
