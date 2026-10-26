/// Enables analytics. This is used by:
/// - crash_handler.zig's `report` function to anonymously report crashes
///
/// Since this field can be .unknown, it makes more sense to call `isEnabled`
/// instead of processing this field directly.
pub var enabled: enum { yes, no, unknown } = .unknown;

pub fn isEnabled() bool {
    return switch (enabled) {
        .yes => true,
        .no => false,
        .unknown => {
            enabled = detect: {
                if (bun.env_var.DO_NOT_TRACK.get()) {
                    break :detect .no;
                }
                if (bun.env_var.HYPERFINE_RANDOMIZED_ENVIRONMENT_OFFSET.get() != null) {
                    break :detect .no;
                }
                break :detect .yes;
            };
            bun.assert(enabled == .yes or enabled == .no);
            return enabled == .yes;
        },
    };
}

/// This answers, "What parts of bun are people actually using?"
pub const Features = struct {
    pub var builtin_modules: std.enums.EnumSet(HardcodedModule) = .empty;

    pub var @"Bun.stderr": usize = 0;
    pub var @"Bun.stdin": usize = 0;
    pub var @"Bun.stdout": usize = 0;
    pub var WebSocket: usize = 0;
    pub var abort_signal: usize = 0;
    pub var binlinks: usize = 0;
    pub var bunfig: usize = 0;
    pub var define: usize = 0;
    pub var dotenv: usize = 0;
    pub var debugger: usize = 0;
    pub var external: usize = 0;
    pub var extracted_packages: usize = 0;
    pub var fetch: usize = 0;
    pub var git_dependencies: usize = 0;
    pub var html_rewriter: usize = 0;
    /// TCP server from `Bun.listen`
    pub var tcp_server: usize = 0;
    /// TLS server from `Bun.listen`
    pub var tls_server: usize = 0;
    pub var http_server: usize = 0;
    pub var https_server: usize = 0;
    pub var http_client_proxy: usize = 0;
    /// Set right before JSC::initialize is called
    pub var jsc: usize = 0;
    /// Set when bake.DevServer is initialized
    pub var dev_server: usize = 0;
    pub var lifecycle_scripts: usize = 0;
    pub var loaders: usize = 0;
    pub var lockfile_migration_from_package_lock: usize = 0;
    pub var text_lockfile: usize = 0;
    pub var isolated_bun_install: usize = 0;
    pub var hoisted_bun_install: usize = 0;
    pub var macros: usize = 0;
    pub var no_avx2: usize = 0;
    pub var no_avx: usize = 0;
    pub var shell: usize = 0;
    pub var spawn: usize = 0;
    pub var standalone_executable: usize = 0;
    pub var standalone_shell: usize = 0;
    /// Set when invoking a todo panic
    pub var todo_panic: usize = 0;
    pub var transpiler_cache: usize = 0;
    pub var tsconfig: usize = 0;
    pub var tsconfig_paths: usize = 0;
    pub var virtual_modules: usize = 0;
    pub var workers_spawned: usize = 0;
    pub var workers_terminated: usize = 0;
    pub var napi_module_register: usize = 0;
    pub var process_dlopen: usize = 0;
    pub var postgres_connections: usize = 0;
    pub var s3: usize = 0;
    pub var valkey: usize = 0;
    pub var csrf_verify: usize = 0;
    pub var csrf_generate: usize = 0;
    pub var unsupported_uv_function: usize = 0;
    pub var exited: usize = 0;
    pub var yarn_migration: usize = 0;
    pub var pnpm_migration: usize = 0;
    pub var yaml_parse: usize = 0;
    pub var cpu_profile: usize = 0;
    pub var heap_snapshot: usize = 0;
    pub var webview_chrome: usize = 0;
    pub var webview_webkit: usize = 0;

    pub fn formatter() Formatter {
        return Formatter{};
    }

    pub const Formatter = struct {
        pub fn format(_: Formatter, writer: *std.Io.Writer) !void {
            const fields = comptime brk: {
                const info: std.builtin.Type = @typeInfo(Features);
                var buffer: [info.@"struct".decl_names.len][]const u8 = @splat("");
                var count: usize = 0;
                for (info.@"struct".decl_names) |decl_name| {
                    var f = &@field(Features, decl_name);
                    _ = &f;
                    const Field = @TypeOf(f);
                    const FieldT: std.builtin.Type = @typeInfo(Field);
                    if (FieldT.pointer.child != usize) continue;
                    buffer[count] = decl_name;
                    count += 1;
                }

                break :brk buffer[0..count];
            };

            var is_first_feature = true;
            inline for (fields) |field| {
                const count = @field(Features, field);
                if (count > 0) {
                    if (is_first_feature) {
                        try writer.writeAll("Features: ");
                        is_first_feature = false;
                    }
                    try writer.writeAll(field);
                    if (count > 1) {
                        try writer.print("({d}) ", .{count});
                    } else {
                        try writer.writeAll(" ");
                    }
                }
            }
            if (!is_first_feature) {
                try writer.writeAll("\n");
            }

            var builtins = builtin_modules.iterator();
            if (builtins.next()) |first| {
                try writer.writeAll("Builtins: \"");
                try writer.writeAll(@tagName(first));
                try writer.writeAll("\" ");

                while (builtins.next()) |key| {
                    try writer.writeAll("\"");
                    try writer.writeAll(@tagName(key));
                    try writer.writeAll("\" ");
                }

                try writer.writeAll("\n");
            }
        }
    };
};

fn bindRecordNapiModuleRegister(
    _: bun.bindgen.Args(RecordNapiModuleRegisterSchema),
) bun.bindgen.Return(RecordNapiModuleRegisterSchema) {
    Features.napi_module_register += 1;
}

fn bindRecordProcessDlopen(
    _: bun.bindgen.Args(RecordProcessDlopenSchema),
) bun.bindgen.Return(RecordProcessDlopenSchema) {
    Features.process_dlopen += 1;
}

fn bindRecordHeapSnapshot(
    _: bun.bindgen.Args(RecordHeapSnapshotSchema),
) bun.bindgen.Return(RecordHeapSnapshotSchema) {
    Features.heap_snapshot += 1;
}

fn bindRecordWebViewChrome(
    _: bun.bindgen.Args(RecordWebViewChromeSchema),
) bun.bindgen.Return(RecordWebViewChromeSchema) {
    Features.webview_chrome += 1;
}

fn bindRecordWebViewWebKit(
    _: bun.bindgen.Args(RecordWebViewWebKitSchema),
) bun.bindgen.Return(RecordWebViewWebKitSchema) {
    Features.webview_webkit += 1;
}

pub fn validateFeatureName(name: []const u8) void {
    if (name.len > 64) @compileError("Invalid feature name: " ++ name);
    for (name) |char| {
        switch (char) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '.', ':', '-' => {},
            else => @compileError("Invalid feature name: " ++ name),
        }
    }
}

pub const packed_features_list = brk: {
    const decls = std.meta.declarations(Features);
    var names: [decls.len][:0]const u8 = undefined;
    var i = 0;
    for (decls) |name| {
        if (@TypeOf(@field(Features, name)) == usize) {
            validateFeatureName(name);
            names[i] = name;
            i += 1;
        }
    }
    break :brk names[0..i].*;
};

pub const PackedFeatures = blk: {
    var field_names: [64][]const u8 = undefined;
    for (packed_features_list, 0..) |name, i| field_names[i] = name;
    for (packed_features_list.len..field_names.len) |i| {
        field_names[i] = std.fmt.comptimePrint("_{d}", .{i});
    }

    const default_bit = false;
    break :blk @Struct(
        .@"packed",
        u64,
        &field_names,
        &@splat(bool),
        &@splat(.{ .default_value_ptr = &default_bit }),
    );
};

pub fn packedFeatures() PackedFeatures {
    var bits = PackedFeatures{};
    inline for (packed_features_list) |name| {
        if (@field(Features, name) > 0) {
            @field(bits, name) = true;
        }
    }
    return bits;
}

const std = @import("std");

const bun = @import("bun");
const HardcodedModule = @import("../resolve_builtins/HardcodedModule.zig").HardcodedModule;
const AnalyticsBindings = bun.bindgen.Module("Analytics");
const RecordNapiModuleRegisterSchema = AnalyticsBindings.nativeExport("recordNapiModuleRegister");
const RecordProcessDlopenSchema = AnalyticsBindings.nativeExport("recordProcessDlopen");
const RecordHeapSnapshotSchema = AnalyticsBindings.nativeExport("recordHeapSnapshot");
const RecordWebViewChromeSchema = AnalyticsBindings.nativeExport("recordWebViewChrome");
const RecordWebViewWebKitSchema = AnalyticsBindings.nativeExport("recordWebViewWebKit");
const RecordNapiModuleRegisterBinding = bun.bindgen.Fn(RecordNapiModuleRegisterSchema, bindRecordNapiModuleRegister);
const RecordProcessDlopenBinding = bun.bindgen.Fn(RecordProcessDlopenSchema, bindRecordProcessDlopen);
const RecordHeapSnapshotBinding = bun.bindgen.Fn(RecordHeapSnapshotSchema, bindRecordHeapSnapshot);
const RecordWebViewChromeBinding = bun.bindgen.Fn(RecordWebViewChromeSchema, bindRecordWebViewChrome);
const RecordWebViewWebKitBinding = bun.bindgen.Fn(RecordWebViewWebKitSchema, bindRecordWebViewWebKit);

comptime {
    _ = RecordNapiModuleRegisterBinding;
    _ = RecordProcessDlopenBinding;
    _ = RecordHeapSnapshotBinding;
    _ = RecordWebViewChromeBinding;
    _ = RecordWebViewWebKitBinding;
}
