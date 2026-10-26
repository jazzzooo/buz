const Hmac = @This();
const bun = @import("bun");
const bindgen = bun.bindgen;
const Module = bindgen.Module("NodeCryptoHmac");
const Class = Module.class("Hmac");
const Constructor = Class.constructor();
const Update = Class.member("update");
const Digest = Class.member("digest");
const Context = bindgen.Return(Module.engineShim("create"));

pub const Binding = bindgen.Class(Class, Hmac);

bindgen_state: bindgen.ClassState = .{},
active: ?Context,

pub fn construct(context: bindgen.CallContext(Constructor), args: bindgen.Args(Constructor)) bun.JSError!*Hmac {
    var encoding: bindgen.EngineArgumentType(Module.engineShim("create"), "encoding") = null;
    if (args.options) |lazy| {
        switch ((try lazy.convert(context)).value) {
            .options => |options| encoding = options.encoding,
            .ignored => {},
        }
    }
    const key = (try args.key.convert(context)).value;
    const operation = context.engineIn("NodeCryptoHmac", "create");
    const Key = @FieldType(@TypeOf(operation).Args, "key");
    const KeyObject = @FieldType(Key, "key_object");
    var active = try operation.call(.{ .algorithm = args.hmac.operand(), .key = switch (key) {
        .buffer => |bytes| .{ .buffer = bytes.operand() },
        .string => |text| .{ .string = text.operand() },
        .key_object => |key_object| .{ .key_object = switch (key_object) {
            inline else => |value, tag| @unionInit(KeyObject, @tagName(tag), value.operand(context)),
        } },
    }, .encoding = encoding });
    errdefer active.deinit();
    const this = try bun.default_allocator.create(Hmac);
    this.* = .{ .active = active.take() };
    return this;
}

pub fn update(this: *Hmac, context: bindgen.CallContext(Update), args: bindgen.Args(Update)) bindgen.CallError(Update)!void {
    if (this.active == null) return context.fail(.finalized, {});
    const data = args.data orelse return context.fail(.missing_input, {});
    const input = (try data.convert(context)).value;
    var encoding: bindgen.EngineArgumentType(Module.engineShim("update"), "encoding") = null;
    if (input == .string) {
        if (args.encoding) |lazy| encoding = (try lazy.convert(context)).value;
    }
    const active = if (this.active) |*value| value else return context.fail(.update_failed, {});
    try context.engineIn("NodeCryptoHmac", "update").call(.{ .hmac = active, .input = switch (input) {
        .buffer => |bytes| .{ .buffer = bytes.operand() },
        .string => |text| .{ .string = text.operand() },
    }, .encoding = encoding });
}

pub fn digest(this: *Hmac, context: bindgen.CallContext(Digest), args: bindgen.Args(Digest)) bun.JSError!bindgen.Return(Digest) {
    var active = this.active;
    this.active = null;
    defer if (active) |*value| value.deinit();
    return context.engineIn("NodeCryptoHmac", "digest").call(.{
        .hmac = if (active) |*value| value else null,
        .encoding = args.encoding orelse null,
    });
}

pub fn memoryUsage(this: *const Hmac, _: bindgen.MemoryUsageContext(.vm)) usize {
    const native_size = if (this.active != null) bindgen.Engine(Module.engineShim("contextSize")).call(.{}) else 0;
    return @sizeOf(Hmac) + @as(usize, @intCast(native_size));
}

pub fn destroy(this: *Hmac) void {
    if (this.active) |*active| active.deinit();
    bun.destroy(this);
}

comptime {
    _ = Binding;
}
