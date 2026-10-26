onQueryResolveFn: ?QueryResolveCallback = null,
onQueryRejectFn: ?QueryRejectCallback = null,

pub fn init(
    context: bun.bindgen.CallContext(InitSchema),
    args: bun.bindgen.Args(InitSchema),
) bun.JSError!void {
    return initFromBinding(context, args);
}

fn initFromBinding(context: anytype, args: anytype) bun.JSError!void {
    const globalThis = context.viewToken().globalObject();
    const ctx = &globalThis.bunVM().rareData().mysql_context;
    var resolve_callback = if (args.onQueryResolve) |value| try value.toOwned() else null;
    errdefer if (resolve_callback) |*callback| callback.deinit();
    const reject_callback = if (args.onQueryReject) |value| try value.toOwned() else null;
    if (ctx.onQueryResolveFn) |*previous| previous.deinit();
    ctx.onQueryResolveFn = resolve_callback;
    if (ctx.onQueryRejectFn) |*previous| previous.deinit();
    ctx.onQueryRejectFn = reject_callback;
}

const bun = @import("bun");

const JSC = bun.jsc;
const SQLBindings = bun.bindgen.Module("SQLBinding");
const InitSchema = SQLBindings.function("mysqlInit");
pub const QueryResolveCallback = bun.bindgen.Callback(InitSchema.args[0].ArgumentType);
pub const QueryRejectCallback = bun.bindgen.Callback(InitSchema.args[1].ArgumentType);
pub const InitBinding = bun.bindgen.Fn(InitSchema, init);

comptime {
    _ = InitBinding;
}
