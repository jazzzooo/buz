const ResultDispatcher = @This();
pub const Context = bun.bindgen.NativeCallbackContext(.vm);

context: Context,
vtable: *const VTable,

pub const VTable = struct {
    notify: *const fn (Context) void,
    wait: *const fn (Context, *BundleV2) void,
    deinit: *const fn (Context) void,
};

pub const Factory = struct {
    context: Context,
    create_fn: *const fn (Context, *BundleV2) error{ OutOfMemory, Canceled }!ResultDispatcher,

    pub fn create(this: Factory, bundle: *BundleV2) error{ OutOfMemory, Canceled }!ResultDispatcher {
        return this.create_fn(this.context, bundle);
    }
};

pub fn notification(this: ResultDispatcher) ResultQueue.Notification {
    return .{ .context = this.context, .notify = this.vtable.notify };
}

pub fn wait(this: ResultDispatcher, bundle: *BundleV2) void {
    this.vtable.wait(this.context, bundle);
}

pub fn deinit(this: ResultDispatcher) void {
    this.vtable.deinit(this.context);
}

const BundleV2 = @import("./bundle_v2.zig").BundleV2;
const ResultQueue = @import("./ResultQueue.zig");

const bun = @import("bun");
