const bun = @import("bun");
const bindgen = bun.bindgen;
const Module = bindgen.Module("NodeCryptoSign");

pub const NativeSignature = opaque {};
pub const Sign = Handle("Sign");
pub const Verify = Handle("Verify");

fn Handle(comptime name: []const u8) type {
    return struct {
        const Self = @This();
        const Class = Module.class(name);
        const Constructor = Class.constructor();
        const Native = Module.nativeExport("get" ++ name);

        bindgen_state: bindgen.ClassState = .{},
        signature: bindgen.Return(Module.engineShim("create")),

        pub const Binding = bindgen.Class(Class, Self);

        fn create(context: anytype) bun.JSError!*Self {
            const this = try bun.default_allocator.create(Self);
            errdefer bun.destroy(this);
            this.* = .{ .signature = try context.engineIn("NodeCryptoSign", "create").call(.{}) };
            return this;
        }

        pub fn construct(context: bindgen.CallContext(Constructor), _: bindgen.Args(Constructor)) bun.JSError!*Self {
            return create(context);
        }

        pub fn call(context: bindgen.CallContext(Class.constructorCall()), _: bindgen.Args(Class.constructorCall())) bun.JSError!bindgen.Return(Class.constructorCall()) {
            return Binding.adoptResult(try create(context), context);
        }

        pub fn destroy(this: *Self) void {
            this.signature.deinit();
            bun.destroy(this);
        }

        fn nativeSignature(args: bindgen.Args(Native)) *NativeSignature {
            return args.owner.signature.get();
        }

        comptime {
            _ = Binding;
            _ = bindgen.Fn(Native, nativeSignature);
        }
    };
}

comptime {
    _ = Sign;
    _ = Verify;
}
