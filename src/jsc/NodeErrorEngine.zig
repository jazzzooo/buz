const bun = @import("bun");
const bindgen = bun.bindgen;
const CreateSchema = bindgen.Module("ErrorCode").engineShim("create");
pub const Code = bindgen.EngineArgumentType(CreateSchema, "code");

pub fn create(context: anytype, code: Code, message: *const bindgen.DOMString) @TypeOf(context.engineIn("ErrorCode", "create")).Return {
    return context.engineIn("ErrorCode", "create").call(.{
        .code = code,
        .message = message.operand(),
    });
}
