pub fn getBunServerAllClosedPromise(
    context: bun.bindgen.CallContext(GetBunServerAllClosedPromiseSchema),
    args: bun.bindgen.Args(GetBunServerAllClosedPromiseSchema),
) bun.JSError!bun.bindgen.Return(GetBunServerAllClosedPromiseSchema) {
    return bun.api.NodeHTTPEngine.getServerAllClosedPromise(context, args);
}

pub fn setServerIdleTimeout(
    context: bun.bindgen.CallContext(SetServerIdleTimeoutSchema),
    args: bun.bindgen.Args(SetServerIdleTimeoutSchema),
) bun.JSError!void {
    _ = context;
    bun.api.NodeHTTPEngine.setServerIdleTimeout(args);
}

pub fn setCustomOptions(
    context: bun.bindgen.CallContext(SetCustomOptionsSchema),
    args: bun.bindgen.Args(SetCustomOptionsSchema),
) bun.JSError!void {
    _ = context;
    try bun.api.NodeHTTPEngine.setCustomOptions(args);
}

pub fn getMaxHTTPHeaderSize(
    _: bun.bindgen.CallContext(GetMaxHTTPHeaderSizeSchema),
    _: bun.bindgen.Args(GetMaxHTTPHeaderSizeSchema),
) bun.JSError!usize {
    return bun.http.max_http_header_size;
}

pub fn setMaxHTTPHeaderSize(
    context: bun.bindgen.CallContext(SetMaxHTTPHeaderSizeSchema),
    args: bun.bindgen.Args(SetMaxHTTPHeaderSizeSchema),
) bun.bindgen.CallError(SetMaxHTTPHeaderSizeSchema)!usize {
    if (args.value <= 0) return context.fail(.invalid_size, {});
    bun.http.max_http_header_size = @intCast(args.value);
    return bun.http.max_http_header_size;
}

fn drainMicrotasks(
    context: bun.bindgen.CallContext(DrainMicrotasksSchema),
    _: bun.bindgen.Args(DrainMicrotasksSchema),
) bun.JSError!void {
    try context.engineIn("microtasks", "drainMicrotasks").call(.{});
}

fn defaultMaxHTTPHeaderSize(
    _: bun.bindgen.Args(DefaultMaxHTTPHeaderSizeSchema),
) bun.bindgen.Return(DefaultMaxHTTPHeaderSizeSchema) {
    return bun.http.max_http_header_size;
}

const bun = @import("bun");

const NodeHTTPBindings = bun.bindgen.Module("NodeHTTP");
const GetBunServerAllClosedPromiseSchema = NodeHTTPBindings.function("getServerAllClosedPromise");
const SetServerIdleTimeoutSchema = NodeHTTPBindings.function("setServerIdleTimeout");
const SetCustomOptionsSchema = NodeHTTPBindings.function("setCustomOptions");
const GetMaxHTTPHeaderSizeSchema = NodeHTTPBindings.function("getMaxHeaderSize");
const SetMaxHTTPHeaderSizeSchema = NodeHTTPBindings.function("setMaxHeaderSize");
const DrainMicrotasksSchema = NodeHTTPBindings.function("drainMicrotasks");
const DefaultMaxHTTPHeaderSizeSchema = NodeHTTPBindings.nativeExport("defaultMaxHTTPHeaderSize");
const GetBunServerAllClosedPromiseBinding = bun.bindgen.Fn(GetBunServerAllClosedPromiseSchema, getBunServerAllClosedPromise);
const SetServerIdleTimeoutBinding = bun.bindgen.Fn(SetServerIdleTimeoutSchema, setServerIdleTimeout);
const SetCustomOptionsBinding = bun.bindgen.Fn(SetCustomOptionsSchema, setCustomOptions);
const GetMaxHTTPHeaderSizeBinding = bun.bindgen.Fn(GetMaxHTTPHeaderSizeSchema, getMaxHTTPHeaderSize);
const SetMaxHTTPHeaderSizeBinding = bun.bindgen.Fn(SetMaxHTTPHeaderSizeSchema, setMaxHTTPHeaderSize);
const DrainMicrotasksBinding = bun.bindgen.Fn(DrainMicrotasksSchema, drainMicrotasks);
const DefaultMaxHTTPHeaderSizeBinding = bun.bindgen.Fn(DefaultMaxHTTPHeaderSizeSchema, defaultMaxHTTPHeaderSize);

comptime {
    _ = GetBunServerAllClosedPromiseBinding;
    _ = SetServerIdleTimeoutBinding;
    _ = SetCustomOptionsBinding;
    _ = GetMaxHTTPHeaderSizeBinding;
    _ = SetMaxHTTPHeaderSizeBinding;
    _ = DrainMicrotasksBinding;
    _ = DefaultMaxHTTPHeaderSizeBinding;
}
