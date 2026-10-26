const AdditionalOnAbortCallback = @This();
pub const Context = bun.bindgen.NativeCallbackContext(.vm);

cb: *const fn (this: Context) void,
data: Context,
deref_fn: *const fn (this: Context) void,

pub fn deref(this: AdditionalOnAbortCallback) void {
    this.deref_fn(this.data);
}

const bun = @import("bun");
