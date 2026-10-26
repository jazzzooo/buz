const Control = @This();

ref_count: RefCount = .init(),
registry: *jsc.NativeCompletionRegistry,
entry: jsc.NativeCompletionRegistry.Entry = undefined,
endpoint: ?*Endpoint = null,

const RefCount = bun.ptr.ThreadSafeRefCount(Control, "ref_count", destroy, .{});
const ref = RefCount.ref;
const deref = RefCount.deref;

const Endpoint = struct {
    control: *Control,
    bundle: *BundleV2,
    loop: *jsc.EventLoop,
    retired: bool = false,
    delivering: bool = false,
    detached: bool = false,

    fn deliver(raw: bun.bindgen.NativeCallbackContext(.vm)) void {
        const endpoint = raw.get(*Endpoint);
        const control = endpoint.control;
        const bundle = endpoint.bundle;
        control.ref();
        defer control.deref();
        if (endpoint.delivering) return;
        endpoint.delivering = true;
        defer {
            endpoint.delivering = false;
            if (endpoint.detached) {
                endpoint.finishDetach();
            } else if (bundle.results.hasPending()) {
                notify(.init(control));
            }
        }
        const message = bundle.results.pop() orelse return;
        var ast_scope: ?bun.ast.ASTMemoryAllocator.Scope = if (bundle.transpiler.options.dev_server) |dev| scope: {
            bun.assert(dev.current_bundle.?.bv2 == bundle);
            break :scope .{ .current = dev.current_bundle.?.ast_memory_allocator };
        } else null;
        if (ast_scope) |*scope| scope.enter();
        defer if (ast_scope) |*scope| scope.exit();
        message.deliver();
    }

    fn cancel(raw: bun.bindgen.NativeCallbackContext(.vm)) void {
        const endpoint = raw.get(*Endpoint);
        endpoint.bundle.requestCancel();
        if (endpoint.bundle.plugin_host) |host| host.cancelBuild(endpoint.bundle.cancellationToken());
    }

    fn detach(raw: bun.bindgen.NativeCallbackContext(.vm)) void {
        const endpoint = raw.get(*Endpoint);
        endpoint.control.endpoint = null;
        endpoint.detached = true;
        if (endpoint.delivering) {
            if (!endpoint.retired) cancel(raw);
            return;
        }
        endpoint.finishDetach();
    }

    fn finishDetach(endpoint: *Endpoint) void {
        const control = endpoint.control;
        const bundle = endpoint.bundle;
        const retired = endpoint.retired;
        defer control.deref();
        if (!retired) {
            cancel(.init(endpoint));
            const parsing = bundle.asynchronous;
            bundle.drainCancelledResults();
            if (parsing) bundle.transpiler.options.dev_server.?.cancelParsingBundle(bundle);
        }
        bun.destroy(endpoint);
    }
};

pub fn factory(loop: *jsc.EventLoop) ResultDispatcher.Factory {
    return .{ .context = .init(loop), .create_fn = create };
}

fn create(raw: ResultDispatcher.Context, bundle: *BundleV2) error{ OutOfMemory, Canceled }!ResultDispatcher {
    const loop = raw.get(*jsc.EventLoop);
    const vm = loop.virtual_machine;
    const registry = try (try vm.tryRareData()).nativeCompletionRegistryForLoop(vm, loop);
    const control = try bun.tryNew(Control, .{ .registry = registry });
    errdefer bun.destroy(control);
    const endpoint = try bun.tryNew(Endpoint, .{ .control = control, .bundle = bundle, .loop = loop });
    errdefer bun.destroy(endpoint);
    registry.retain();
    errdefer registry.release();
    control.endpoint = endpoint;
    control.entry = .{
        .context = .init(endpoint),
        .deliver = Endpoint.deliver,
        .cancel = Endpoint.cancel,
        .detach = Endpoint.detach,
        .delivery = .repeating,
    };
    if (!registry.register(&control.entry)) return error.Canceled;
    control.ref();
    return .{ .context = .init(control), .vtable = &vtable };
}

fn notify(raw: ResultDispatcher.Context) void {
    const control = raw.get(*Control);
    _ = control.registry.notify(&control.entry);
}

fn wait(raw: ResultDispatcher.Context, bundle: *BundleV2) void {
    const control = raw.get(*Control);
    control.ref();
    defer control.deref();
    const endpoint = control.endpoint orelse {
        bun.assert(bundle.graph.pending_items == 0);
        return;
    };
    const loop = endpoint.loop;
    while (!bundle.isDone()) {
        loop.tick();
        if (!bundle.isDone()) loop.autoTick();
    }
}

fn deinit(raw: ResultDispatcher.Context) void {
    const control = raw.get(*Control);
    if (control.endpoint) |endpoint| endpoint.retired = true;
    control.registry.detach(&control.entry);
    control.deref();
}

fn destroy(control: *Control) void {
    bun.assert(control.endpoint == null);
    control.registry.release();
    bun.destroy(control);
}

const vtable = ResultDispatcher.VTable{ .notify = notify, .wait = wait, .deinit = deinit };
const bun = @import("bun");
const jsc = bun.jsc;
const BundleV2 = bun.BundleV2;
const ResultDispatcher = @import("../bundler/ResultDispatcher.zig");
