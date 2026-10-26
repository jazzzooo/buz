//! Windows-only `uv_signal_t` lifecycle used by process signal listeners.

fn bindUVSignalHandleInit(
    args: bun.bindgen.Args(UVSignalHandleInitSchema),
) bun.bindgen.Return(UVSignalHandleInitSchema) {
    const callback: *const fn (sig: *libuv.uv_signal_t, num: c_int) callconv(.c) void = @ptrCast(args.callback);
    const signal = bun.new(libuv.uv_signal_t, undefined);

    var rc = libuv.uv_signal_init(args.loop, signal);
    if (rc.errno()) |_| {
        bun.destroy(signal);
        return null;
    }

    rc = libuv.uv_signal_start(signal, callback, args.signal);
    if (rc.errno()) |_| {
        libuv.uv_close(@ptrCast(signal), &freeWithDefaultAllocator);
        return null;
    }

    libuv.uv_unref(@ptrCast(signal));

    return @ptrCast(signal);
}

fn freeWithDefaultAllocator(signal: *anyopaque) callconv(.c) void {
    bun.destroy(@as(*libuv.uv_signal_t, @ptrCast(@alignCast(signal))));
}

fn bindUVSignalHandleClose(
    args: bun.bindgen.Args(UVSignalHandleCloseSchema),
) bun.bindgen.Return(UVSignalHandleCloseSchema) {
    const signal: *libuv.uv_signal_t = @ptrCast(@alignCast(args.handle));
    _ = libuv.uv_signal_stop(signal);
    libuv.uv_close(@ptrCast(signal), &freeWithDefaultAllocator);
}

const UVSignalHandleBindings = bun.bindgen.Module("uv_signal_handles");
const UVSignalHandleInitSchema = UVSignalHandleBindings.nativeExport("uvSignalHandleInit");
const UVSignalHandleCloseSchema = UVSignalHandleBindings.nativeExport("uvSignalHandleClose");
const UVSignalHandleInitBinding = bun.bindgen.Fn(UVSignalHandleInitSchema, bindUVSignalHandleInit);
const UVSignalHandleCloseBinding = bun.bindgen.Fn(UVSignalHandleCloseSchema, bindUVSignalHandleClose);

comptime {
    if (bun.Environment.isWindows) {
        _ = UVSignalHandleInitBinding;
        _ = UVSignalHandleCloseBinding;
    }
}

const bun = @import("bun");
const libuv = bun.windows.libuv;
