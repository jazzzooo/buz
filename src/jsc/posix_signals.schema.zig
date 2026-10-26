const b = @import("bindgen_schema");

const native_exports = .{
    b.nativeExport("ensureSignalHandler", .{}, b.none),
    b.nativeExport("onPosixSignal", .{b.argument("signal", b.int32, .{})}, b.none),
};

pub const schema = b.moduleWithNativeExports("posix_signals", .{}, native_exports);
