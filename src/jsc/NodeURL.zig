const bun = @import("bun");
const bindgen = bun.bindgen;
const Module = bindgen.Module("NodeURL");
const ASCIISchema = Module.function("domainToASCII");
const UnicodeSchema = Module.function("domainToUnicode");

fn convertDomain(comptime Function: type, context: bindgen.CallContext(Function), args: bindgen.Args(Function), to_ascii: bool) bun.JSError!bindgen.Return(Function) {
    return switch (args.domain) {
        .null_value => .{ .null_value = false },
        .undefined_value => .{ .undefined_value = false },
        .string => |domain| .{ .string = (try context.engineIn("NodeURL", "convertDomain").call(.{
            .domain = domain.operand(),
            .toASCII = to_ascii,
        })) orelse bindgen.DOMString.empty() },
    };
}

fn domainToASCII(context: bindgen.CallContext(ASCIISchema), args: bindgen.Args(ASCIISchema)) bun.JSError!bindgen.Return(ASCIISchema) {
    return convertDomain(ASCIISchema, context, args, true);
}

fn domainToUnicode(context: bindgen.CallContext(UnicodeSchema), args: bindgen.Args(UnicodeSchema)) bun.JSError!bindgen.Return(UnicodeSchema) {
    return convertDomain(UnicodeSchema, context, args, false);
}

comptime {
    _ = bindgen.Fn(ASCIISchema, domainToASCII);
    _ = bindgen.Fn(UnicodeSchema, domainToUnicode);
}
