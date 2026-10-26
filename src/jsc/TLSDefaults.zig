fn get(
    _: bun.bindgen.CallContext(GetSchema),
    _: bun.bindgen.Args(GetSchema),
) bun.JSError!bun.bindgen.Return(GetSchema) {
    const ciphers = bun.jsc.VirtualMachine.get().rareData().tlsDefaultCiphers() orelse bun.uws.get_default_ciphers();
    return bun.bindgen.DOMString.fromUTF8(ciphers);
}

fn set(
    context: bun.bindgen.CallContext(SetSchema),
    args: bun.bindgen.Args(SetSchema),
) bun.JSError!bun.bindgen.Return(SetSchema) {
    _ = context;
    var ciphers = try args.ciphers.toUTF8(bun.default_allocator);
    defer ciphers.deinit();
    bun.jsc.VirtualMachine.get().rareData().setTLSDefaultCiphers(ciphers.slice());
}

const bun = @import("bun");

const Bindings = bun.bindgen.Module("TLSDefaults");
const GetSchema = Bindings.function("get");
const SetSchema = Bindings.function("set");
const GetBinding = bun.bindgen.Fn(GetSchema, get);
const SetBinding = bun.bindgen.Fn(SetSchema, set);

comptime {
    _ = GetBinding;
    _ = SetBinding;
}
