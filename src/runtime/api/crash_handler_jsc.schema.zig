const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const crash_handler_scope = b.nominalHandle("CrashHandlerScope", .{
    .cpp_type = .{ .pointer = &.{ .named = "BindByteOwnerHandle" } },
    .cpp_declarations = &.{.{ .structure = "BindByteOwnerHandle" }},
    .ownership = .owned,
    .cpp_release = "releaseExternalBytesOwner",
    .access_thread = .current,
    .destroy_thread = .current,
    .zig_type = "bindgen.ExternalBytesOwnerHandle",
});

const crash_handler_feature_data = b.dictionary("CrashHandlerFeatureData", .{
    b.dictionaryField("features", archetypes.dom_strings, .{ .required = true }),
    b.dictionaryField("version", b.dom_string, .{ .required = true }),
    b.dictionaryField("is_canary", b.boolean, .{ .required = true }),
    b.dictionaryField("revision", b.dom_string, .{ .required = true }),
    b.dictionaryField("generated_at", b.int64, .{ .required = true }),
});

fn function(comptime name: []const u8, comptime result: b.Type) b.Function {
    return b.function(
        name,
        .{},
        result,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    );
}

const functions = .{
    function("getMachOImageZeroOffset", archetypes.optional_size),
    function("getFeaturesAsVLQ", b.dom_string),
    function("getFeatureData", crash_handler_feature_data),
    function("segfault", b.none),
    function("panic", b.none),
    function("rootError", b.none),
    function("outOfMemory", b.none),
    function("raiseIgnoringPanicHandler", b.none),
};

fn fatal(comptime name: []const u8, comptime argument: []const u8) b.NativeExport {
    return b.nativeExportWithOptions(name, .{b.argument(argument, b.nativeSlice(.uint8, .read_only), .{})}, b.none, .{
        .throws = .never,
        .realm = .none,
        .non_returning = true,
        .standalone_header = "CrashHandler",
    });
}

const native_exports = .{
    fatal("panic", "message"),
    fatal("crash", "message"),
    fatal("unsupportedUVFunction", "name"),
    b.nativeExportWithOptions("crashHandlerBeginNativePlugin", .{b.argument("name", b.nativeSlice(.uint8, .read_only), .{})}, crash_handler_scope, .allocating),
    b.nativeExportWithOptions("crashHandlerBeginDlopen", .{b.argument("action", b.nativeSlice(.uint8, .read_only), .{})}, crash_handler_scope, .allocating),
    b.nativeExport("globalObjectOnCrash", .{}, b.none),
    b.nativeExport("crashHandlerSetMachineMemorySize", .{b.argument("size", b.size, .{})}, b.none),
};

const engine_shims = .{
    b.engineShim("dumpStackTrace", .{b.argument("addresses", b.nativeSlice(.uint64, .read_only), .{})}, b.none, .realm_independent_allocating),
};

pub const schema = b.moduleWithDeclarations("CrashHandlerBindings", functions, .{}, engine_shims, native_exports);
