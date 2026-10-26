//! This is a slower wrapper around a function pointer.
//! Prefer adding a task type directly to `Task` instead of using this.

const AnyTask = @This();

pub const Context = bun.bindgen.NativeCallbackContext(.vm);

ctx: ?Context,
callback: *const fn (Context) bun.JSError!void,

pub fn task(this: *AnyTask) Task {
    return Task.init(this);
}

pub fn run(this: *AnyTask) bun.JSError!void {
    const callback = this.callback;
    const ctx = this.ctx;
    try callback(ctx.?);
}

pub fn New(comptime Type: type, comptime Callback: anytype) type {
    return struct {
        pub fn init(ctx: *Type) AnyTask {
            return AnyTask{
                .callback = wrap,
                .ctx = .init(ctx),
            };
        }

        pub fn wrap(this: Context) bun.JSError!void {
            return @call(bun.callmod_inline, Callback, .{this.get(*Type)});
        }
    };
}

const bun = @import("bun");
const jsc = bun.jsc;

const Task = jsc.Task;
