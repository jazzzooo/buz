const ThreadSafeStreamBuffer = @This();

buffer: bun.io.StreamBuffer = .{},
io: std.Io,
mutex: std.Io.Mutex = .init,
ref_count: StreamBufferRefCount = .init(),
// callback will be called passing the context for the http callback
// this is used to report when the buffer is drained and only if end chunk was not sent/reported
callback: ?Callback = null,

const Callback = struct {
    const Context = bun.bindgen.NativeCallbackContext(.vm);
    callback: *const fn (Context) void,
    context: Context,

    pub fn init(comptime T: type, comptime callback: *const fn (*T) void, context: *T) @This() {
        const Adapter = struct {
            fn call(capture: Context) void {
                callback(capture.get(*T));
            }
        };
        return .{ .callback = Adapter.call, .context = .init(context) };
    }

    pub fn call(this: @This()) void {
        this.callback(this.context);
    }
};

const StreamBufferRefCount = bun.ptr.ThreadSafeRefCount(@This(), "ref_count", ThreadSafeStreamBuffer.deinit, .{});
pub const ref = StreamBufferRefCount.ref;
pub const deref = StreamBufferRefCount.deref;

pub fn acquire(this: *ThreadSafeStreamBuffer) *bun.io.StreamBuffer {
    this.mutex.lockUncancelable(this.io);
    return &this.buffer;
}

pub fn release(this: *ThreadSafeStreamBuffer) void {
    this.mutex.unlock(this.io);
}

/// Should only be called in the main thread and before schedule the it to the http thread
pub fn setDrainCallback(this: *ThreadSafeStreamBuffer, comptime T: type, comptime callback: *const fn (*T) void, context: *T) void {
    this.callback = Callback.init(T, callback, context);
}

pub fn clearDrainCallback(this: *ThreadSafeStreamBuffer) void {
    this.mutex.lockUncancelable(this.io);
    defer this.mutex.unlock(this.io);
    this.callback = null;
}

/// This is exclusively called from the http thread
/// Buffer should be acquired before calling this
pub fn reportDrain(this: *ThreadSafeStreamBuffer) void {
    if (this.buffer.isEmpty()) {
        if (this.callback) |callback| {
            callback.call();
        }
    }
}

pub fn deinit(this: *ThreadSafeStreamBuffer) void {
    this.buffer.deinit();
    bun.destroy(this);
}

const std = @import("std");
const bun = @import("bun");
