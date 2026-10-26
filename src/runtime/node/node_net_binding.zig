//
//

pub var autoSelectFamilyDefault: bool = true;

fn bindGetDefaultAutoSelectFamily(
    _: bun.bindgen.CallContext(GetDefaultAutoSelectFamilySchema),
    _: bun.bindgen.Args(GetDefaultAutoSelectFamilySchema),
) bun.JSError!bool {
    return autoSelectFamilyDefault;
}

fn bindSetDefaultAutoSelectFamily(
    _: bun.bindgen.CallContext(SetDefaultAutoSelectFamilySchema),
    args: bun.bindgen.Args(SetDefaultAutoSelectFamilySchema),
) bun.JSError!void {
    autoSelectFamilyDefault = args.value;
}

/// This is only used to provide the getDefaultAutoSelectFamilyAttemptTimeout and
/// setDefaultAutoSelectFamilyAttemptTimeout functions, not currently read by any other code. It's
/// `threadlocal` because Node.js expects each Worker to have its own copy of this, and currently
/// it can only be accessed by accessor functions which run on each Worker's main JavaScript thread.
///
/// If this becomes used in more places, and especially if it can be read by other threads, we may
/// need to store it as a field in the VirtualMachine instead of in a `threadlocal`.
pub threadlocal var autoSelectFamilyAttemptTimeoutDefault: u32 = 500;

fn bindGetDefaultAutoSelectFamilyAttemptTimeout(
    _: bun.bindgen.CallContext(GetDefaultAutoSelectFamilyAttemptTimeoutSchema),
    _: bun.bindgen.Args(GetDefaultAutoSelectFamilyAttemptTimeoutSchema),
) bun.JSError!u32 {
    return autoSelectFamilyAttemptTimeoutDefault;
}

fn bindSetDefaultAutoSelectFamilyAttemptTimeout(
    _: bun.bindgen.CallContext(SetDefaultAutoSelectFamilyAttemptTimeoutSchema),
    args: bun.bindgen.Args(SetDefaultAutoSelectFamilyAttemptTimeoutSchema),
) bun.JSError!void {
    var value = args.value;
    if (value < 10) value = 10;
    autoSelectFamilyAttemptTimeoutDefault = @intCast(value);
}

pub fn newDetachedSocket(
    context: bun.bindgen.CallContext(NewDetachedSocketSchema),
    args: bun.bindgen.Args(NewDetachedSocketSchema),
) bun.JSError!bun.bindgen.Return(NewDetachedSocketSchema) {
    return bun.api.NodeNetEngine.createDetached(context, args);
}

pub fn doConnect(
    context: bun.bindgen.CallContext(DoConnectSchema),
    args: bun.bindgen.Args(DoConnectSchema),
) bun.bindgen.CallError(DoConnectSchema)!void {
    try bun.api.NodeNetEngine.reconnect(context, args);
}

const bun = @import("bun");
const NodeSocketBindings = bun.bindgen.Module("NodeSocket");
const GetDefaultAutoSelectFamilySchema = NodeSocketBindings.function("getDefaultAutoSelectFamily");
const SetDefaultAutoSelectFamilySchema = NodeSocketBindings.function("setDefaultAutoSelectFamily");
const GetDefaultAutoSelectFamilyAttemptTimeoutSchema = NodeSocketBindings.function("getDefaultAutoSelectFamilyAttemptTimeout");
const SetDefaultAutoSelectFamilyAttemptTimeoutSchema = NodeSocketBindings.function("setDefaultAutoSelectFamilyAttemptTimeout");
const NewDetachedSocketSchema = NodeSocketBindings.function("newDetachedSocket");
const DoConnectSchema = NodeSocketBindings.function("doConnect");
const GetDefaultAutoSelectFamilyBinding = bun.bindgen.Fn(GetDefaultAutoSelectFamilySchema, bindGetDefaultAutoSelectFamily);
const SetDefaultAutoSelectFamilyBinding = bun.bindgen.Fn(SetDefaultAutoSelectFamilySchema, bindSetDefaultAutoSelectFamily);
const GetDefaultAutoSelectFamilyAttemptTimeoutBinding = bun.bindgen.Fn(GetDefaultAutoSelectFamilyAttemptTimeoutSchema, bindGetDefaultAutoSelectFamilyAttemptTimeout);
const SetDefaultAutoSelectFamilyAttemptTimeoutBinding = bun.bindgen.Fn(SetDefaultAutoSelectFamilyAttemptTimeoutSchema, bindSetDefaultAutoSelectFamilyAttemptTimeout);
const NewDetachedSocketBinding = bun.bindgen.Fn(NewDetachedSocketSchema, newDetachedSocket);
const DoConnectBinding = bun.bindgen.Fn(DoConnectSchema, doConnect);

comptime {
    _ = GetDefaultAutoSelectFamilyBinding;
    _ = SetDefaultAutoSelectFamilyBinding;
    _ = GetDefaultAutoSelectFamilyAttemptTimeoutBinding;
    _ = SetDefaultAutoSelectFamilyAttemptTimeoutBinding;
    _ = NewDetachedSocketBinding;
    _ = DoConnectBinding;
}
