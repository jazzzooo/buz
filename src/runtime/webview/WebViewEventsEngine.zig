pub const Finalizer = struct {
    node: bun.jsc.NativeFinalizerQueue.Node = .{},
    queue: *bun.jsc.NativeFinalizerQueue,
    view: ?@FieldType(bun.bindgen.Args(EnqueueFinalizerSchema), "view") = null,

    fn finalize(self: *Finalizer) void {
        var view = self.view.?.take();
        bun.bindgen.Engine(CloseNativeSchema).call(.{
            .view = &view,
            .shutting_down = self.queue.vm.isShuttingDown(),
        });
        view.deinit();
        bun.destroy(self);
    }
};

fn createFinalizer(args: bun.bindgen.Args(CreateFinalizerSchema)) bun.OOM!bun.bindgen.Return(CreateFinalizerSchema) {
    const vm: *bun.jsc.VirtualMachine = @ptrCast(@alignCast(args.vm));
    const queue = (try vm.tryRareData()).nativeFinalizerQueue();
    const finalizer = try bun.default_allocator.create(Finalizer);
    finalizer.* = .{ .queue = queue };
    return bun.bindgen.Return(CreateFinalizerSchema).initNative(finalizer);
}

fn enqueueFinalizer(args: *bun.bindgen.Args(EnqueueFinalizerSchema)) void {
    const finalizer = args.finalizer.takeNative();
    bun.assert(finalizer.view == null);
    finalizer.view = args.view.take();
    finalizer.queue.enqueue(&finalizer.node, finalizer, Finalizer.finalize);
}

fn discardFinalizer(args: *bun.bindgen.Args(DiscardFinalizerSchema)) void {
    const finalizer = args.finalizer.takeNative();
    bun.assert(finalizer.node.isUnused() and finalizer.view == null);
    bun.destroy(finalizer);
}

fn dispatch(comptime Schema: type, context: bun.bindgen.CallContext(Schema), args: bun.bindgen.Args(Schema)) void {
    if (comptime Schema == DispatchNavigatedSchema) {
        args.callback.dispatch(.{
            .url = args.url.operand(),
            .title = if (args.title) |value| value.operand() else null,
        });
    } else {
        args.callback.dispatch(.{
            .@"error" = args.@"error".operand(context),
        });
    }
}

fn bindDispatchNavigated(
    context: bun.bindgen.CallContext(DispatchNavigatedSchema),
    args: bun.bindgen.Args(DispatchNavigatedSchema),
) bun.bindgen.Return(DispatchNavigatedSchema) {
    dispatch(DispatchNavigatedSchema, context, args);
}

fn bindDispatchNavigationFailed(
    context: bun.bindgen.CallContext(DispatchNavigationFailedSchema),
    args: bun.bindgen.Args(DispatchNavigationFailedSchema),
) bun.bindgen.Return(DispatchNavigationFailedSchema) {
    dispatch(DispatchNavigationFailedSchema, context, args);
}

const bun = @import("bun");
const WebViewBindings = bun.bindgen.Module("webview");
const CreateFinalizerSchema = WebViewBindings.nativeExport("createWebViewFinalizer");
const EnqueueFinalizerSchema = WebViewBindings.nativeExport("enqueueWebViewFinalizer");
const DiscardFinalizerSchema = WebViewBindings.nativeExport("discardWebViewFinalizer");
const CloseNativeSchema = WebViewBindings.engineShim("closeWebViewNative");
const CreateFinalizerBinding = bun.bindgen.Fn(CreateFinalizerSchema, createFinalizer);
const EnqueueFinalizerBinding = bun.bindgen.Fn(EnqueueFinalizerSchema, enqueueFinalizer);
const DiscardFinalizerBinding = bun.bindgen.Fn(DiscardFinalizerSchema, discardFinalizer);
const DispatchNavigatedSchema = WebViewBindings.nativeExport("dispatchNavigated");
const DispatchNavigationFailedSchema = WebViewBindings.nativeExport("dispatchNavigationFailed");

const DispatchNavigatedBinding = bun.bindgen.Fn(DispatchNavigatedSchema, bindDispatchNavigated);
const DispatchNavigationFailedBinding = bun.bindgen.Fn(DispatchNavigationFailedSchema, bindDispatchNavigationFailed);

comptime {
    _ = CreateFinalizerBinding;
    _ = EnqueueFinalizerBinding;
    _ = DiscardFinalizerBinding;
    _ = DispatchNavigatedBinding;
    _ = DispatchNavigationFailedBinding;
}
