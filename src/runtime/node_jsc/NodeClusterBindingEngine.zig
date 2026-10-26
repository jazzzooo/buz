const log = Output.scoped(.IPC, .visible);

pub fn sendHelperChild(
    context: bun.bindgen.CallContext(SendHelperChildSchema),
    args: bun.bindgen.Args(SendHelperChildSchema),
) bun.bindgen.CallError(SendHelperChildSchema)!bun.bindgen.Return(SendHelperChildSchema) {
    log("sendHelperChild", .{});
    return bun.jsc.IPC.sendHelperChild(context, args);
}

pub fn onInternalMessageChild(
    _: bun.bindgen.CallContext(OnInternalMessageChildSchema),
    args: bun.bindgen.Args(OnInternalMessageChildSchema),
) bun.JSError!void {
    log("onInternalMessageChild", .{});
    try NodeClusterEngine.onInternalMessageChild(args);
}

pub fn sendHelperPrimary(
    context: bun.bindgen.CallContext(SendHelperPrimarySchema),
    args: bun.bindgen.Args(SendHelperPrimarySchema),
) bun.JSError!bun.bindgen.Return(SendHelperPrimarySchema) {
    log("sendHelperPrimary", .{});
    return bun.jsc.IPC.sendHelperPrimary(context, args);
}

pub fn onInternalMessagePrimary(
    _: bun.bindgen.CallContext(OnInternalMessagePrimarySchema),
    args: bun.bindgen.Args(OnInternalMessagePrimarySchema),
) bun.JSError!void {
    try NodeClusterEngine.onInternalMessagePrimary(args);
}

//
//
//

pub fn setRef(
    _: bun.bindgen.CallContext(SetRefSchema),
    args: bun.bindgen.Args(SetRefSchema),
) bun.JSError!void {
    bun.jsc.IPC.setChannelRef(args.enabled);
}
pub fn channelIgnoreOneDisconnectEventListener(
    _: bun.bindgen.CallContext(ChannelIgnoreOneDisconnectEventListenerSchema),
    _: bun.bindgen.Args(ChannelIgnoreOneDisconnectEventListenerSchema),
) bun.JSError!bool {
    return bun.jsc.IPC.markChannelIgnoreOneDisconnectEventListener();
}

pub fn emitProcessErrorEvent(
    context: bun.bindgen.CallContext(EmitProcessErrorEventSchema),
    args: bun.bindgen.Args(EmitProcessErrorEventSchema),
) bun.JSError!void {
    try context.engineIn("NodeCluster", "processEmitErrorEvent").call(.{ .value = args.error_value.operand(context).asEngine() });
}
fn bindRefChannelUnlessOverridden(
    context: bun.bindgen.CallContext(RefChannelUnlessOverriddenSchema),
    _: bun.bindgen.Args(RefChannelUnlessOverriddenSchema),
) bun.bindgen.Return(RefChannelUnlessOverriddenSchema) {
    bun.jsc.IPC.refChannelUnlessOverridden(context.viewToken().globalObject());
}

fn bindUnrefChannelUnlessOverridden(
    context: bun.bindgen.CallContext(UnrefChannelUnlessOverriddenSchema),
    _: bun.bindgen.Args(UnrefChannelUnlessOverriddenSchema),
) bun.bindgen.Return(UnrefChannelUnlessOverriddenSchema) {
    bun.jsc.IPC.unrefChannelUnlessOverridden(context.viewToken().globalObject());
}

fn bindShouldIgnoreOneDisconnectEventListener(
    context: bun.bindgen.CallContext(ShouldIgnoreOneDisconnectEventListenerSchema),
    _: bun.bindgen.Args(ShouldIgnoreOneDisconnectEventListenerSchema),
) bun.bindgen.Return(ShouldIgnoreOneDisconnectEventListenerSchema) {
    return bun.jsc.IPC.shouldIgnoreOneDisconnectEventListener(context.viewToken().globalObject());
}

const bun = @import("bun");
const Output = bun.Output;
const NodeClusterEngine = @import("../node/NodeClusterEngine.zig");

const NodeClusterBindings = bun.bindgen.Module("NodeCluster");
const SendHelperChildSchema = NodeClusterBindings.function("sendHelperChild");
const OnInternalMessageChildSchema = NodeClusterBindings.function("onInternalMessageChild");
const SendHelperPrimarySchema = NodeClusterBindings.function("sendHelperPrimary");
const OnInternalMessagePrimarySchema = NodeClusterBindings.function("onInternalMessagePrimary");
const SetRefSchema = NodeClusterBindings.function("setRef");
const ChannelIgnoreOneDisconnectEventListenerSchema = NodeClusterBindings.function("channelIgnoreOneDisconnectEventListener");
const EmitProcessErrorEventSchema = NodeClusterBindings.function("emitProcessErrorEvent");
const SendHelperChildBinding = bun.bindgen.Fn(SendHelperChildSchema, sendHelperChild);
const OnInternalMessageChildBinding = bun.bindgen.Fn(OnInternalMessageChildSchema, onInternalMessageChild);
const SendHelperPrimaryBinding = bun.bindgen.Fn(SendHelperPrimarySchema, sendHelperPrimary);
const OnInternalMessagePrimaryBinding = bun.bindgen.Fn(OnInternalMessagePrimarySchema, onInternalMessagePrimary);
const SetRefBinding = bun.bindgen.Fn(SetRefSchema, setRef);
const ChannelIgnoreOneDisconnectEventListenerBinding = bun.bindgen.Fn(ChannelIgnoreOneDisconnectEventListenerSchema, channelIgnoreOneDisconnectEventListener);
pub const EmitProcessErrorEventBinding = bun.bindgen.Fn(EmitProcessErrorEventSchema, emitProcessErrorEvent);
const RefChannelUnlessOverriddenSchema = NodeClusterBindings.nativeExport("refChannelUnlessOverridden");
const UnrefChannelUnlessOverriddenSchema = NodeClusterBindings.nativeExport("unrefChannelUnlessOverridden");
const ShouldIgnoreOneDisconnectEventListenerSchema = NodeClusterBindings.nativeExport("shouldIgnoreOneDisconnectEventListener");
const RefChannelUnlessOverriddenBinding = bun.bindgen.Fn(RefChannelUnlessOverriddenSchema, bindRefChannelUnlessOverridden);
const UnrefChannelUnlessOverriddenBinding = bun.bindgen.Fn(UnrefChannelUnlessOverriddenSchema, bindUnrefChannelUnlessOverridden);
const ShouldIgnoreOneDisconnectEventListenerBinding = bun.bindgen.Fn(
    ShouldIgnoreOneDisconnectEventListenerSchema,
    bindShouldIgnoreOneDisconnectEventListener,
);

comptime {
    _ = SendHelperChildBinding;
    _ = OnInternalMessageChildBinding;
    _ = SendHelperPrimaryBinding;
    _ = OnInternalMessagePrimaryBinding;
    _ = SetRefBinding;
    _ = ChannelIgnoreOneDisconnectEventListenerBinding;
    _ = EmitProcessErrorEventBinding;
    _ = RefChannelUnlessOverriddenBinding;
    _ = UnrefChannelUnlessOverriddenBinding;
    _ = ShouldIgnoreOneDisconnectEventListenerBinding;
}
