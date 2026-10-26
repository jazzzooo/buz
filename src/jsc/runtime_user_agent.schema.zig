const b = @import("bindgen_schema");

const native_exports = .{
    b.nativeExport("runtimeUserAgent", .{}, b.dom_string),
};

pub const schema = b.moduleWithNativeExports("runtime_user_agent", .{}, native_exports);
