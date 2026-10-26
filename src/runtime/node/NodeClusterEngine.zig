pub var child_singleton: InternalMsgHolder = .{};

pub fn onInternalMessageChild(
    args: bun.bindgen.Args(OnInternalMessageChildSchema),
) bun.JSError!void {
    child_singleton.setCallback(try args.callback.toOwned());
    try child_singleton.flush();
}

pub fn onInternalMessagePrimary(
    args: bun.bindgen.Args(OnInternalMessagePrimarySchema),
) bun.JSError!void {
    const subprocess = args.subprocess.get(bun.jsc.Subprocess.JSBinding).subprocess.get();
    const ipc_data = subprocess.ipc() orelse return;
    ipc_data.internal_msg_queue.setCallback(try args.callback.toOwned());
    try ipc_data.internal_msg_queue.flush();
}

pub fn handleInternalMessageChild(
    message: *const bun.bindgen.Root,
) bun.JSError!void {
    try child_singleton.dispatch(message);
}

pub fn handleInternalMessagePrimary(
    subprocess: *bun.jsc.Subprocess,
    message: *const bun.bindgen.Root,
) bun.JSError!void {
    const ipc_data = subprocess.ipc() orelse return;
    try ipc_data.internal_msg_queue.dispatch(message);
}

pub const InternalMsgHolder = struct {
    callback: ?InternalMessageCallback = null,
    messages: std.ArrayListUnmanaged(bun.bindgen.Root) = .empty,

    pub fn isReady(this: *const InternalMsgHolder) bool {
        return this.callback != null;
    }

    pub fn setCallback(this: *InternalMsgHolder, callback: InternalMessageCallback) void {
        if (this.callback) |*previous| previous.deinit();
        this.callback = callback;
    }

    fn enqueue(
        this: *InternalMsgHolder,
        message: *const bun.bindgen.Root,
    ) bun.JSError!void {
        var retained = message.clone();
        errdefer retained.deinit();
        try this.messages.append(bun.default_allocator, retained);
    }

    fn dispatch(
        this: *InternalMsgHolder,
        message: *const bun.bindgen.Root,
    ) bun.JSError!void {
        if (!this.isReady()) {
            try this.enqueue(message);
            return;
        }
        try this.dispatchRoot(message);
    }

    fn dispatchRoot(
        this: *InternalMsgHolder,
        message: *const bun.bindgen.Root,
    ) bun.JSError!void {
        const callback = if (this.callback) |*value| value else return;
        var invocation: InternalMessageCallback.Invocation = undefined;
        callback.beginInvocation(&invocation);
        defer invocation.deinit();
        try invocation.call(.{
            .message = message.operand(&invocation),
            .handle = false,
        });
    }

    fn flush(this: *InternalMsgHolder) bun.JSError!void {
        bun.assert(this.isReady());
        var messages = this.messages;
        this.messages = .empty;
        defer {
            for (messages.items) |*message| message.deinit();
            messages.deinit(bun.default_allocator);
        }
        for (messages.items) |*message| {
            if (!this.isReady()) break;
            try this.dispatchRoot(message);
        }
    }

    pub fn deinit(this: *InternalMsgHolder) void {
        if (this.callback) |*callback| callback.deinit();
        for (this.messages.items) |*message| message.deinit();
        this.messages.deinit(bun.default_allocator);
        this.* = .{};
    }
};

const std = @import("std");
const bun = @import("bun");

const NodeClusterBindings = bun.bindgen.Module("NodeCluster");
const OnInternalMessageChildSchema = NodeClusterBindings.function("onInternalMessageChild");
const OnInternalMessagePrimarySchema = NodeClusterBindings.function("onInternalMessagePrimary");
const InternalMessageCallback = bun.bindgen.Callback(OnInternalMessageChildSchema.args[0].ArgumentType);
