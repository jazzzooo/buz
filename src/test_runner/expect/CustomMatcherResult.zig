const bun = @import("bun");
const bindgen = bun.bindgen;
const ExpectBindings = bindgen.Module("Expect");
const MessageSchema = ExpectBindings.engineShim("customMatcherMessage");
pub const Message = @FieldType(bindgen.ResultType(MessageSchema.ReturnType), "message");

pub const Result = struct {
    pass: bool,
    message: Message,

    pub fn deinit(this: *Result) void {
        if (this.message) |*message| switch (message.*) {
            .text => |*text| text.deinit(),
            .callback => |*callback| callback.deinit(),
            .invalid => {},
        };
        this.* = undefined;
    }
};

pub fn parse(context: anytype, value: bindgen.EngineValueResult) bun.JSError!?Result {
    const pass_record = try context.engineIn("Expect", "customMatcherPass").call(.{ .value = value.operand(context).asEngine() });
    const pass = switch (pass_record) {
        .object => |object| object.pass orelse return null,
        .invalid => return null,
    };
    const message_record = try context.engineIn("Expect", "customMatcherMessage").call(.{ .value = value.operand(context).asEngine() });
    if (message_record.message) |message| if (message == .invalid) return null;
    return .{ .pass = pass, .message = message_record.message };
}

pub fn messageText(context: anytype, message: *Message) bun.JSError!bindgen.DOMString {
    const value = if (message.*) |*present| present else return bindgen.DOMString.fromUTF8("No message was specified for this matcher.");
    return switch (value.*) {
        .text => |*text| text.take(),
        .callback => |callback| blk: {
            const global = context.engineIn("global_objects", "globalObjectValue").call(.{});
            const result = try context.engineIn("js_functions", "jsValueCall").call(.{
                .function = callback.operand(context).asEngine(),
                .this_value = global.operand(context).asEngine(),
                .arguments = &.{},
            });
            break :blk context.engineIn("js_strings", "stringFromJS").call(.{ .value = result.operand(context).asEngine() });
        },
        .invalid => unreachable,
    };
}
