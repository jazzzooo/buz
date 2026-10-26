pub fn DoneCallback(comptime RefData: type) type {
    return struct {
        ref: ?bindgen.RefNative(RefData, .vm) = null,
        called: bool = false,
        bindgen_state: bindgen.ClassState = .{},

        pub fn destroy(this: *@This()) void {
            if (this.ref) |*ref| ref.deinit();
            bun.destroy(this);
        }
    };
}

const bun = @import("bun");
const bindgen = bun.bindgen;
