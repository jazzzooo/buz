const IntrusiveTask = @This();
pub const Context = bun.bindgen.NativeCallbackContext(.vm);

context: Context,
callback: *const fn (Context) void,
on_cancel: *const fn (Context) void,

pub fn run(task: *IntrusiveTask) void {
    task.callback(task.context);
}

pub fn cancel(task: *IntrusiveTask) void {
    task.on_cancel(task.context);
}

const bun = @import("bun");
