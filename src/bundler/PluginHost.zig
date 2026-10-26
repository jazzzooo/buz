const PluginHost = @This();
pub const Context = bun.bindgen.NativeCallbackContext(.vm);

context: Context,
vtable: *const VTable,

pub const Request = struct {
    next: ?*Request = null,
    state: enum { idle, queued, consumed } = .idle,
    operation: union(enum) {
        load: *bun.bundle_v2.PluginLoad,
        resolve: *bun.bundle_v2.PluginResolve,
    },

    pub fn take(this: *Request) @FieldType(Request, "operation") {
        bun.assert(this.state == .queued);
        this.state = .consumed;
        return this.operation;
    }

    pub fn build(this: *const Request) *bun.BundleV2 {
        return switch (this.operation) {
            inline else => |operation| operation.bv2,
        };
    }

    pub fn cancel(this: *Request) void {
        switch (this.take()) {
            inline else => |operation| {
                operation.bv2.requestCancel();
                operation.failCallback(error.Canceled);
            },
        }
    }
};

pub const VTable = struct {
    has_any_matches: *const fn (Context, *const Fs.Path, bool) bun.OOM!bool,
    has_on_before_parse_plugins: *const fn (Context) bool,
    call_on_before_parse_plugins: *const fn (Context, *anyopaque, []const u8, []const u8, ?*anyopaque, ?*anyopaque) bun.OOM!u32,
    dispatch: *const fn (Context, *Request) void,
    cancel_build: *const fn (Context, *bun.BundleV2.Cancellation) void,
};

pub fn hasAnyMatches(this: PluginHost, path: *const Fs.Path, is_on_load: bool) bun.OOM!bool {
    return this.vtable.has_any_matches(this.context, path, is_on_load);
}

pub fn hasOnBeforeParsePlugins(this: PluginHost) bool {
    return this.vtable.has_on_before_parse_plugins(this.context);
}

pub fn callOnBeforeParsePlugins(
    this: PluginHost,
    plugin_context: anytype,
    namespace: []const u8,
    path: []const u8,
    arguments: anytype,
    result: anytype,
) bun.OOM!u32 {
    return this.vtable.call_on_before_parse_plugins(
        this.context,
        plugin_context,
        namespace,
        path,
        arguments,
        result,
    );
}

pub fn dispatch(this: PluginHost, request: *Request) void {
    this.vtable.dispatch(this.context, request);
}

pub fn cancelBuild(this: PluginHost, cancellation: *bun.BundleV2.Cancellation) void {
    this.vtable.cancel_build(this.context, cancellation);
}

const bun = @import("bun");
const Fs = @import("../resolver/fs.zig");
