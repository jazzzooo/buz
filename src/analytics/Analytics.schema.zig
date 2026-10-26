const b = @import("bindgen_schema");

fn recordFeature(comptime name: []const u8) b.NativeExport {
    return b.nativeExport(name, .{}, b.none);
}

const native_exports = .{
    recordFeature("recordNapiModuleRegister"),
    recordFeature("recordProcessDlopen"),
    recordFeature("recordHeapSnapshot"),
    recordFeature("recordWebViewChrome"),
    recordFeature("recordWebViewWebKit"),
};

pub const schema = b.moduleWithNativeExports("Analytics", .{}, native_exports);
