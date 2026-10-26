const b = @import("bindgen_schema");
const process = @import("binding_schema_ProcessHost");
const process_native = @import("binding_schema_Process");

const configurable = b.SurfaceMemberOptions{ .attributes = .{} };
const direct_configurable = b.SurfaceMemberOptions{ .attributes = .{}, .placement = .direct };
const non_configurable = b.SurfaceMemberOptions{ .attributes = .{ .configurable = false } };

fn exposed(comptime exposure: b.Exposure) b.SurfaceMemberOptions {
    var options = configurable;
    options.exposure = exposure;
    return options;
}

fn function(comptime property_name: []const u8, comptime declaration_name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(property_name, process.schema.function(declaration_name), configurable);
}

fn exposedFunction(
    comptime property_name: []const u8,
    comptime declaration_name: []const u8,
    comptime exposure: b.Exposure,
) b.SurfaceMember {
    var options = configurable;
    options.exposure = exposure;
    return b.surfaceFunction(property_name, process.schema.function(declaration_name), options);
}

fn lazy(comptime name: []const u8, comptime callback: []const u8) b.SurfaceMember {
    return b.surfaceLazyProperty(name, process.schema.function(callback), configurable);
}

fn accessor(comptime name: []const u8, comptime getter: []const u8, comptime setter: []const u8) b.SurfaceMember {
    return b.surfaceFunctionAccessor(name, process.schema.function(getter), process.schema.function(setter), configurable);
}

const hrtime_function = b.objectSurface("ProcessHrtimeFunction", .{
    b.surfaceFunction("bigint", process.schema.function("hrtimeBigInt"), configurable),
}, .{ .installation = .direct });

const memory_usage_function = b.objectSurface("ProcessMemoryUsageFunction", .{
    b.surfaceFunction("rss", process.schema.function("memoryUsageRSS"), configurable),
}, .{ .installation = .direct });

const process_features = b.objectSurface("ProcessFeatures", .{
    b.surfaceBoolean("inspector", true, configurable),
    b.surfaceExternalBoolean("debug", "processDebugFeature", configurable),
    b.surfaceBoolean("uv", true, configurable),
    b.surfaceBoolean("ipv6", true, configurable),
    b.surfaceBoolean("tls_alpn", true, configurable),
    b.surfaceBoolean("tls_sni", true, configurable),
    b.surfaceBoolean("tls_ocsp", true, configurable),
    b.surfaceBoolean("tls", true, configurable),
    b.surfaceBoolean("cached_builtins", true, configurable),
    b.surfaceBoolean("openssl_is_boringssl", true, configurable),
    b.surfaceBoolean("require_module", true, configurable),
    b.surfaceString("typescript", "transform", configurable),
}, .{ .installation = .direct });

const process_release = b.objectSurface("ProcessRelease", .{
    b.surfaceString("name", "node", configurable),
    b.surfaceLazyProperty("sourceUrl", process_native.schema.nativeExport("githubReleaseURL"), configurable),
    b.surfaceExternalString("headersUrl", "processHeadersURL", configurable),
}, .{ .installation = .direct });

const process_report = b.objectSurface("ProcessReport", .{
    b.surfaceBoolean("compact", false, configurable),
    b.surfaceString("directory", "", configurable),
    b.surfaceString("filename", "", configurable),
    b.surfaceFunction("getReport", process.schema.function("getReport"), configurable),
    b.surfaceBoolean("reportOnFatalError", false, configurable),
    b.surfaceBoolean("reportOnSignal", false, configurable),
    b.surfaceLazyProperty("reportOnUncaughtException", process.schema.function("processReportOnUncaughtException"), configurable),
    b.surfaceBoolean("excludeEnv", false, configurable),
    b.surfaceString("signal", "SIGUSR2", configurable),
    b.surfaceFunction("writeReport", process.schema.function("writeReport"), configurable),
}, .{ .installation = .direct });

const process_versions = b.objectSurface("ProcessVersions", .{
    b.surfaceExternalString("node", "processVersionNode", configurable),
    b.surfaceLazyProperty("bun", process.schema.function("processVersionsBun"), configurable),
    b.surfaceExternalString("boringssl", "processVersionBoringSSL", configurable),
    b.surfaceString("openssl", "1.1.0", configurable),
    b.surfaceString("llhttp", "9.3.0", configurable),
    b.surfaceExternalString("libarchive", "processVersionLibarchive", configurable),
    b.surfaceExternalString("mimalloc", "processVersionMimalloc", configurable),
    b.surfaceExternalString("picohttpparser", "processVersionPicoHTTPParser", configurable),
    b.surfaceExternalString("uwebsockets", "processVersionUWebSockets", configurable),
    b.surfaceExternalString("webkit", "processVersionWebKit", configurable),
    b.surfaceExternalString("zig", "processVersionZig", configurable),
    b.surfaceExternalString("zlib", "processVersionZlib", configurable),
    b.surfaceExternalString("tinycc", "processVersionTinyCC", configurable),
    b.surfaceExternalString("lolhtml", "processVersionLOLHTML", configurable),
    b.surfaceExternalString("ares", "processVersionCAres", configurable),
    b.surfaceExternalString("libdeflate", "processVersionLibdeflate", configurable),
    b.surfaceExternalString("usockets", "processVersionUSockets", configurable),
    b.surfaceExternalString("lshpack", "processVersionLSHPack", configurable),
    b.surfaceExternalString("zstd", "processVersionZstd", configurable),
    b.surfaceExternalString("v8", "processVersionV8", configurable),
    b.surfaceLazyProperty("uv", process.schema.function("processVersionsUV"), configurable),
    b.surfaceString("napi", "10", configurable),
    b.surfaceExternalString("icu", "processVersionICU", configurable),
    b.surfaceExternalString("unicode", "processVersionUnicode", configurable),
    b.surfaceExternalString("modules", "processVersionModules", configurable),
}, .{ .installation = .direct });

const process_config_target_defaults = b.objectSurface(
    "ProcessConfigTargetDefaults",
    .{},
    .{ .installation = .direct },
);

const process_config_variables = b.objectSurface("ProcessConfigVariables", .{
    b.surfaceInteger("v8_enable_i8n_support", 1, configurable),
    b.surfaceBoolean("enable_lto", false, configurable),
    b.surfaceBoolean("enable_thin_lto", false, configurable),
    b.surfaceString("lto_jobs", "", configurable),
    b.surfaceExternalNumber("node_module_version", "processConfigNodeModuleVersion", configurable),
    b.surfaceExternalNumber("napi_build_version", "processConfigNapiBuildVersion", configurable),
    b.surfaceEmptyArray("node_builtin_shareable_builtins", b.dom_string, configurable),
    b.surfaceString("node_byteorder", "little", configurable),
    b.surfaceExternalNumber("clang", "processConfigClang", configurable),
    b.surfaceBoolean("control_flow_guard", false, configurable),
    b.surfaceBoolean("coverage", false, configurable),
    b.surfaceInteger("dcheck_always_on", 0, configurable),
    b.surfaceBoolean("debug_nghttp2", false, configurable),
    b.surfaceBoolean("debug_node", false, configurable),
    b.surfaceBoolean("enable_pgo_generate", false, configurable),
    b.surfaceBoolean("enable_pgo_use", false, configurable),
    b.surfaceBoolean("error_on_warn", false, configurable),
    b.surfaceInteger("force_dynamic_crt", 0, configurable),
    b.surfaceInteger("nasm_version", 2, exposed(.{ .os = "windows" })),
    b.surfaceString("arm_fpu", "neon", exposed(.{ .target = "aarch64-macos" })),
    b.surfaceString("napi_build", "0.0", exposed(.{ .os = "linux" })),
    b.surfaceExternalString("host_arch", "processConfigArchitecture", configurable),
    b.surfaceExternalString("target_arch", "processConfigArchitecture", configurable),
    b.surfaceInteger("asan", 0, configurable),
}, .{ .installation = .direct });

const process_config = b.objectSurface("ProcessConfig", .{
    b.surfaceObjectValue("target_defaults", process_config_target_defaults, configurable),
    b.surfaceObjectValue("variables", process_config_variables, configurable),
}, .{ .installation = .direct, .integrity = .frozen });

pub const bun_process_surface = b.objectSurface("BunProcess", .{
    b.surfaceBoolean("_exiting", false, direct_configurable),
    function("_debugEnd", "empty"),
    function("_debugProcess", "empty"),
    accessor("_eval", "processGetEval", "setProcessGetEval"),
    function("_fatalException", "fatalException"),
    function("_getActiveHandles", "emptyArray"),
    function("_getActiveRequests", "emptyArray"),
    function("_kill", "reallyKill"),
    function("_linkedBinding", "empty"),
    b.surfaceEmptyArray("_preload_modules", b.dom_string, configurable),
    function("_rawDebug", "empty"),
    function("_startProfilerIdleNotifier", "empty"),
    function("_stopProfilerIdleNotifier", "empty"),
    function("_tickCallback", "empty"),
    function("abort", "abort"),
    b.surfaceEmptySet("allowedNodeEnvironmentFlags", b.dom_string, configurable),
    lazy("arch", "constructArch"),
    b.surfaceLazyProperty("argv", process_native.schema.nativeExport("createArgv"), configurable),
    lazy("argv0", "constructArgv0"),
    function("assert", "assert"),
    function("availableMemory", "availableMemory"),
    function("binding", "binding"),
    b.surfaceBoolean("browser", false, configurable),
    lazy("channel", "constructProcessChannel"),
    function("chdir", "chdir"),
    b.surfaceObjectValue("config", process_config, configurable),
    accessor("connected", "processConnected", "setProcessConnected"),
    function("constrainedMemory", "constrainedMemory"),
    function("cpuUsage", "cpuUsage"),
    function("cwd", "cwd"),
    accessor("debugPort", "processDebugPort", "setProcessDebugPort"),
    lazy("disconnect", "constructProcessDisconnect"),
    function("dlopen", "dlopen"),
    function("emitWarning", "emitWarning"),
    lazy("env", "constructEnv"),
    b.surfaceLazyProperty("execArgv", process_native.schema.nativeExport("createExecArgv"), configurable),
    lazy("execPath", "constructExecPath"),
    function("execve", "execve"),
    function("exit", "exit"),
    b.surfaceFunctionAccessor("exitCode", process.schema.function("processExitCode"), process.schema.function("setProcessExitCode"), non_configurable),
    b.surfaceObjectValue("features", process_features, configurable),
    function("getActiveResourcesInfo", "emptyStringArray"),
    function("getBuiltinModule", "loadBuiltinModule"),
    function("hasUncaughtExceptionCaptureCallback", "hasUncaughtExceptionCaptureCallback"),
    b.surfaceCallableValue("hrtime", process.schema.function("hrtime"), hrtime_function, configurable),
    b.surfaceBoolean("isBun", true, configurable),
    function("kill", "kill"),
    lazy("mainModule", "constructMainModuleProperty"),
    b.surfaceCallableValue("memoryUsage", process.schema.function("memoryUsage"), memory_usage_function, configurable),
    b.surfaceEmptyArray("moduleLoadList", b.dom_string, configurable),
    lazy("nextTick", "constructProcessNextTickFn"),
    accessor("noDeprecation", "processNoDeprecation", "setProcessNoDeprecation"),
    function("openStdin", "openStdin"),
    lazy("pid", "constructPid"),
    lazy("platform", "constructPlatform"),
    accessor("ppid", "processPpid", "setProcessPpid"),
    function("reallyExit", "reallyExit"),
    function("ref", "ref"),
    b.surfaceObjectValue("release", process_release, configurable),
    b.surfaceObjectValue("report", process_report, configurable),
    function("resourceUsage", "resourceUsage"),
    lazy("revision", "constructRevision"),
    lazy("send", "constructProcessSend"),
    function("setSourceMapsEnabled", "setSourceMapsEnabled"),
    function("setUncaughtExceptionCaptureCallback", "setUncaughtExceptionCaptureCallback"),
    lazy("stderr", "constructStderr"),
    lazy("stdin", "constructStdin"),
    lazy("stdout", "constructStdout"),
    accessor("throwDeprecation", "processThrowDeprecation", "setProcessThrowDeprecation"),
    accessor("title", "processTitle", "setProcessTitle"),
    function("umask", "umask"),
    function("unref", "unref"),
    function("uptime", "uptime"),
    lazy("version", "constructVersion"),
    b.surfaceObjectValue("versions", process_versions, configurable),
    exposedFunction("getegid", "getegid", .{ .not_os = "windows" }),
    exposedFunction("geteuid", "geteuid", .{ .not_os = "windows" }),
    exposedFunction("getgid", "getgid", .{ .not_os = "windows" }),
    exposedFunction("getgroups", "getgroups", .{ .not_os = "windows" }),
    exposedFunction("getuid", "getuid", .{ .not_os = "windows" }),
    exposedFunction("setegid", "setegid", .{ .not_os = "windows" }),
    exposedFunction("seteuid", "seteuid", .{ .not_os = "windows" }),
    exposedFunction("setgid", "setgid", .{ .not_os = "windows" }),
    exposedFunction("setgroups", "setgroups", .{ .not_os = "windows" }),
    exposedFunction("setuid", "setuid", .{ .not_os = "windows" }),
    b.surfaceSymbolString(.to_string_tag, "process", direct_configurable),
}, .{});

pub const schema = b.moduleWithSurfaces("BunProcessSurface", .{
    hrtime_function,
    memory_usage_function,
    process_features,
    process_release,
    process_report,
    process_versions,
    process_config_target_defaults,
    process_config_variables,
    process_config,
    bun_process_surface,
});
