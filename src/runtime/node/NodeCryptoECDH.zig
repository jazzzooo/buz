const ECDH = @This();
const bun = @import("bun");
const bindgen = bun.bindgen;
const Module = bindgen.Module("NodeCryptoECDH");
const Class = Module.class("ECDH");
const Constructor = Class.constructor();
const Call = Class.constructorCall();
const Native = Module.nativeExport("nativeKey");

pub const NativeKey = opaque {};
pub const Binding = bindgen.Class(Class, ECDH);

bindgen_state: bindgen.ClassState = .{},
key: bindgen.Return(Module.engineShim("create")),

fn create(context: anytype, curve: bindgen.DOMStringView) bun.JSError!*ECDH {
    const this = try bun.default_allocator.create(ECDH);
    errdefer bun.destroy(this);
    this.* = .{ .key = try context.engineIn("NodeCryptoECDH", "create").call(.{ .curve = curve.operand() }) };
    return this;
}

pub fn construct(context: bindgen.CallContext(Constructor), args: bindgen.Args(Constructor)) bun.JSError!*ECDH {
    return create(context, args.curve);
}

pub fn call(context: bindgen.CallContext(Call), args: bindgen.Args(Call)) bun.JSError!bindgen.Return(Call) {
    return Binding.adoptResult(try create(context, args.curve), context);
}

pub fn destroy(this: *ECDH) void {
    this.key.deinit();
    bun.destroy(this);
}

fn setKey(this: *ECDH, comptime name: []const u8, context: bindgen.CallContext(Class.member(name)), args: bindgen.Args(Class.member(name))) bindgen.CallError(Class.member(name))!bindgen.Return(Class.member(name)) {
    const input = args.key orelse return context.fail(.missing_key, {});
    var encoding: @FieldType(bindgen.Args(Module.engineShim(name)), "encoding") = null;
    if (args.encoding) |lazy| {
        if (input == .string) {
            encoding = (try lazy.convert(context)).value;
        }
    }
    var result = try args.bindingThis.toOwned();
    errdefer result.deinit();
    try context.engineIn("NodeCryptoECDH", name).call(.{ .key = &this.key, .input = switch (input) {
        .buffer => |bytes| .{ .buffer = bytes.operand() },
        .string => |text| .{ .string = text.operand() },
    }, .encoding = encoding });
    return result;
}

pub fn setPublicKey(this: *ECDH, context: bindgen.CallContext(Class.member("setPublicKey")), args: bindgen.Args(Class.member("setPublicKey"))) bindgen.CallError(Class.member("setPublicKey"))!bindgen.Return(Class.member("setPublicKey")) {
    return this.setKey("setPublicKey", context, args);
}

pub fn setPrivateKey(this: *ECDH, context: bindgen.CallContext(Class.member("setPrivateKey")), args: bindgen.Args(Class.member("setPrivateKey"))) bindgen.CallError(Class.member("setPrivateKey"))!bindgen.Return(Class.member("setPrivateKey")) {
    return this.setKey("setPrivateKey", context, args);
}

fn nativeKey(args: bindgen.Args(Native)) *NativeKey {
    return args.owner.key.get();
}

comptime {
    _ = Binding;
    _ = bindgen.Fn(Native, nativeKey);
}
