const b = @import("bindgen_schema");
const engine_types = @import("binding_schema_engine_types");

const engine_shims = .{
    b.engineShim("webViewHostProcessDied", .{
        b.argument("signo", b.int32, .{}),
        b.argument("generation", b.uint64, .{}),
    }, b.none, .current_realm_unchecked),
};

const native_exports = .{
    b.nativeExport("webViewHostProcessKill", .{b.argument("vm", engine_types.bun_vm, .{})}, b.none),
    b.nativeExportWithOptions("webViewHostProcessEnsure", .{
        b.argument("generation", b.uint64, .{}),
        b.argument("stdoutInherit", b.boolean, .{}),
        b.argument("stderrInherit", b.boolean, .{}),
    }, b.int32, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("WebViewHostProcess", .{}, .{}, engine_shims, native_exports);
