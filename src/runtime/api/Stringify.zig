const bun = @import("bun");
const CreateError = bun.bindgen.Module("Stringify").function("createError");

pub fn createError(
    context: bun.bindgen.CallContext(CreateError),
    args: bun.bindgen.Args(CreateError),
) bun.JSError!bun.bindgen.Return(CreateError) {
    return context.engineIn("errors", "createError").call(.{ .message = args.message.operand() });
}

comptime {
    _ = bun.bindgen.Fn(CreateError, createError);
}
