const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const engine_types = @import("binding_schema_engine_types");

const engine_shims = .{
    b.engineShim("chromeProcessDied", .{
        b.argument("signo", b.int32, .{}),
        b.argument("generation", b.uint64, .{}),
    }, b.none, .current_realm_unchecked),
};

const native_exports = .{
    b.nativeExport("chromeProcessKill", .{b.argument("vm", engine_types.bun_vm, .{})}, b.none),
    b.nativeExportWithOptions("chromeProcessEnsure", .{
        b.argument("generation", b.uint64, .{}),
        b.argument("userDataDir", b.optional(b.dom_string), .{}),
        b.argument("path", b.optional(b.dom_string), .{}),
        b.argument("extraArgv", archetypes.dom_strings, .{}),
        b.argument("stdoutInherit", b.boolean, .{}),
        b.argument("stderrInherit", b.boolean, .{}),
    }, b.int32, .current_realm_throwing),
    b.nativeExport("chromeProcessAutoDetect", .{b.argument("output", b.nativeSlice(.uint8, .read_write), .{})}, b.size),
};

pub const schema = b.moduleWithDeclarations("ChromeProcess", .{}, .{}, engine_shims, native_exports);
