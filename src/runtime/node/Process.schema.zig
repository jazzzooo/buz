const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const engine_types = @import("binding_schema_engine_types");
const node_ipc = @import("binding_schema_NodeIPC");

const stdio_fd_type = b.enumeration("StdioFdType", .{
    b.enumerationValue("file", "file"),
    b.enumerationValue("pipe", "pipe"),
    b.enumerationValue("socket", "socket"),
});

fn nativeExport(
    comptime name: []const u8,
    comptime arguments: anytype,
    comptime result: b.Type,
) b.NativeExport {
    return b.nativeExportWithOptions(name, arguments, result, .current_realm_throwing);
}

fn realmFreeEngineShim(
    comptime name: []const u8,
    comptime arguments: anytype,
) b.EngineShim {
    return b.engineShim(name, arguments, b.none, .realm_independent);
}

const functions = .{
    b.function(
        "send",
        node_ipc.send_arguments,
        b.boolean,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .node,
            .errors = node_ipc.send_errors,
            .missing_required_arguments = .convert_undefined,
        },
    ),
};

const system_errors = b.domainErrors(.{
    b.systemError("system"),
});

const set_cwd_errors = b.domainErrors(.{
    b.domainError("empty_path", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected path to be a non-empty string" },
    }),
    b.domainError("invalid_path", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Invalid path" },
    }),
    b.systemError("system"),
});

const native_exports = .{
    b.nativeExport(
        "processStdioFdType",
        .{
            b.argument("fd", b.int32, .{}),
        },
        stdio_fd_type,
    ),
    b.nativeExportWithOptions("getTitle", .{}, b.dom_string, .current_realm_throwing),
    b.nativeExportWithOptions("setTitle", .{b.argument("title", b.dom_string, .{})}, b.none, .current_realm_throwing),
    b.nativeExportWithOptions("createArgv", .{}, archetypes.dom_strings, .current_realm_throwing),
    b.nativeExportWithOptions("getCwd", .{}, b.dom_string, .{
        .throws = .js_exception,
        .realm = .current,
        .errors = system_errors,
    }),
    b.nativeExportWithOptions("setCwd", .{b.argument("path", b.dom_string, .{})}, b.dom_string, .{
        .throws = .js_exception,
        .realm = .current,
        .errors = set_cwd_errors,
    }),
    b.nativeExportWithOptions("exit", .{b.argument("code", b.uint8, .{})}, b.none, .current_realm_throwing),
    nativeExport("createArgv0", .{}, b.dom_string),
    nativeExport("getExecPath", .{}, b.dom_string),
    b.nativeExportWithOptions("createExecArgv", .{}, archetypes.dom_strings, .current_realm_throwing),
    b.nativeExportWithOptions("getEval", .{}, archetypes.optional_dom_string, .current_realm_throwing),
    b.nativeExport("nodeNoWarnings", .{}, b.boolean),
    b.nativeExport("suppressCrashOnProcessKillSelfIfDesired", .{}, b.none),
    b.nativeExport("version", .{}, b.dom_string),
    b.nativeExport("versionWithSha", .{}, b.dom_string),
    b.nativeExport("revision", .{}, b.dom_string),
    b.nativeExport("githubReleaseURL", .{}, b.dom_string),
    b.nativeExport("useSystemCA", .{}, b.boolean),
    b.nativeExport("editWindowsEnvVar", .{
        b.argument("key", b.dom_string, .{}),
        b.argument("value", b.optional(b.dom_string), .{}),
    }, b.none),
    b.nativeExport("setTLSRejectUnauthorizedValue", .{b.argument("value", b.int32, .{})}, b.none),
    b.nativeExport("getTLSRejectUnauthorizedValue", .{}, b.int32),
    b.nativeExport("setVerboseFetchValue", .{b.argument("value", b.int32, .{})}, b.none),
    b.nativeExport("getVerboseFetchValue", .{}, b.int32),
    b.nativeExport("isNoProxy", .{
        b.argument("hostname", b.buffer(.copy), .{}),
        b.argument("host", b.buffer(.copy), .{}),
    }, b.boolean),
};

const engine_shims = .{
    realmFreeEngineShim("setZeroFillBuffers", .{b.argument("value", b.boolean, .{})}),
    realmFreeEngineShim("setProcessNoDeprecation", .{b.argument("value", b.boolean, .{})}),
    realmFreeEngineShim("setProcessThrowDeprecation", .{b.argument("value", b.boolean, .{})}),
};

pub const schema = b.moduleWithDeclarations("Process", functions, .{}, engine_shims, native_exports);
