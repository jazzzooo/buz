const AbortRegistration = struct {
    signal: *bun.webcore.AbortSignal,
    listener: bun.webcore.AbortSignal.Listener = undefined,
    state: bun.ptr.RefPtr(NodeFSAbort.State),

    fn onAbort(registration: *AbortRegistration, _: bun.bindgen.EngineValueView) void {
        registration.state.data.aborted.store(true, .release);
    }

    fn destroy(registration: *AbortRegistration) void {
        registration.signal.removeListener(&registration.listener);
        registration.signal.pendingActivityUnref();
        registration.signal.unref();
        registration.state.deref();
        bun.destroy(registration);
    }
};

pub const AbortAttachment = bun.bindgen.OwnedNativeWithDestructor(
    AbortRegistration,
    AbortRegistration.destroy,
    .vm,
);

pub const PreparedAbort = struct {
    token: NodeFSAbort.Token,
    attachment: AbortAttachment,
};

pub fn abortSignalAborted(signal: anytype) bool {
    return signal.get().aborted();
}

pub fn prepareAbort(
    context: anytype,
    signal_view: anytype,
) bun.JSError!PreparedAbort {
    const view = signal_view orelse return .{
        .token = .initSnapshot(false),
        .attachment = .empty,
    };
    const state_ptr = try bun.default_allocator.create(NodeFSAbort.State);
    state_ptr.* = .{};
    const state = bun.ptr.RefPtr(NodeFSAbort.State).adoptRef(state_ptr);
    errdefer state.deref();
    const registration = try bun.default_allocator.create(AbortRegistration);
    errdefer bun.destroy(registration);
    const signal = view.get().ref();
    errdefer signal.unref();
    signal.pendingActivityRef();
    errdefer signal.pendingActivityUnref();
    registration.* = .{
        .signal = signal,
        .state = state,
    };
    registration.signal = try signal.listen(context.viewToken().globalObject(), &registration.listener, registration, AbortRegistration.onAbort);
    return .{
        .token = .initShared(state.dupeRef()),
        .attachment = .init(registration),
    };
}

fn AbortErrorReturn(comptime Context: type) type {
    const Operation = @TypeOf(@as(Context, undefined).engineIn(
        "abort_signals",
        "abortSignalNodeAbortError",
    ));
    return Operation.Return;
}

pub fn abortError(
    context: anytype,
    attachment: *const AbortAttachment,
) AbortErrorReturn(@TypeOf(context)) {
    const registration = attachment.getOptional() orelse return null;
    return context.engineIn("abort_signals", "abortSignalNodeAbortError").call(.{
        .signal = registration.signal,
    });
}

pub fn abortErrorFromView(
    context: anytype,
    signal: anytype,
) AbortErrorReturn(@TypeOf(context)) {
    return context.engineIn("abort_signals", "abortSignalNodeAbortError").call(.{
        .signal = signal.get(),
    });
}

pub fn destroyAbortAttachment(attachment: *AbortAttachment) void {
    attachment.deinit();
}

const std = @import("std");
const bun = @import("bun");
const bindgen = bun.bindgen;
pub const FS = bun.api.node.fs;
pub const BindingAdapter = @import("./node_fs_binding.zig");
const fs_binding = BindingAdapter.WithFS(FS, @This());
pub const Bindings = fs_binding;
const NodeFSAbort = @import("../node/NodeFSAbort.zig");

const NodeJSFSSchema = bindgen.Module("NodeJSFS").class("NodeJSFS");
