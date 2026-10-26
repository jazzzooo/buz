//! Bun's build. Downloaded inputs are pinned in build.zig.zon (the bootstrap
//! bun that runs codegen, Node.js headers, mold, ICU and dependency sources);
//! WebKit is vendored in-tree (vendor/webkit). The host provides git plus
//! ruby, python3, and perl for the WebKit codegen.
//!
//!   zig build                          debug binary → zig-out/bin/bun-debug
//!   zig build --watch -fincremental    the dev loop: edit → smoke-tested
//!                                      binary in a few seconds
//!   zig build run -- -e 'console.log(1)'
//!   zig build --release=fast           release → zig-out/bin/{bun-profile,bun}
//!   zig build check --watch -fincremental   type-check only, no binary
//!
//! Product compile steps leave `incremental` unset: -fincremental trades
//! content-based caching for in-process state, which only pays off under
//! --watch (where the CLI flag enables it). Host executables that the graph
//! immediately runs disable incremental compilation so their output is not
//! held open by a persistent compiler.
//!
//! Builds on x86_64-linux only; the check-* steps provide experimental
//! semantic checks for other targets.

const std = @import("std");
const builtin = @import("builtin");

const Build = std.Build;
const Step = Build.Step;
const Compile = Step.Compile;
const LazyPath = Build.LazyPath;
const Target = std.Target;
const ResolvedTarget = std.Build.ResolvedTarget;
const CrossTarget = std.zig.CrossTarget;
const Optimize = std.builtin.Optimize;
const Module = Build.Module;
const fs = std.fs;
const Version = std.SemanticVersion;
const Arch = std.Target.Cpu.Arch;

const OperatingSystem = @import("src/bun_core/env.zig").OperatingSystem;
const bun_exe = @import("src/build/exe.zig");
const bun_webkit = @import("src/build/webkit.zig");
const bun_icu = @import("src/build/icu.zig");
const bun_unicode_data = @import("src/build/unicode_data.zig");

const zero_sha = "0000000000000000000000000000000000000000";

const BunBuildOptions = struct {
    target: ResolvedTarget,
    optimize: Optimize,
    os: OperatingSystem,
    arch: Arch,

    version: Version,
    canary_revision: ?u32,
    sha: []const u8,
    /// enable debug logs in release builds
    enable_logs: bool = false,
    enable_valgrind: bool,
    enable_tinycc: bool,
    use_mimalloc: bool,
    nodejs_compatibility: bun_exe.NodejsCompatibility,
    /// To make iterating on some '@embedFile's faster, we load them at runtime
    /// instead of at compile time. This is disabled in release or if this flag
    /// is set (to allow CI to build a portable executable). Affected files:
    ///
    /// - src/bake/runtime.ts (bundled)
    ///
    /// A similar technique is used in C++ code for JavaScript builtins
    codegen_embed: bool = false,

    /// Directory holding the generated code (see Codegen.codegen_install_abs).
    codegen_path: []const u8,
    override_no_export_cpp_apis: bool,
    android_ndk_sysroot: ?[]const u8 = null,
    freebsd_sysroot_x86_64: ?[]const u8 = null,
    freebsd_sysroot_aarch64: ?[]const u8 = null,

    cached_options_module: ?*Module = null,
    windows_shim: ?WindowsShim = null,

    /// The codegen graph; codegen_path is its stable synced dir.
    codegen: *const bun_exe.Codegen,
    binding_codegen: *bun_exe.BindingCodegen,
    unicode_data: *Module,

    pub fn isBaseline(this: *const BunBuildOptions) bool {
        return this.arch.isX86() and
            !Target.x86.featureSetHas(this.target.result.cpu.features, .avx2);
    }

    pub fn shouldEmbedCode(opts: *const BunBuildOptions) bool {
        return opts.optimize != .debug or opts.codegen_embed;
    }

    pub fn freebsdSysroot(opts: *const BunBuildOptions) ?[]const u8 {
        return switch (opts.arch) {
            .x86_64 => opts.freebsd_sysroot_x86_64,
            .aarch64 => opts.freebsd_sysroot_aarch64,
            else => null,
        };
    }

    pub fn buildOptionsModule(this: *BunBuildOptions, b: *Build) *Module {
        if (this.cached_options_module) |mod| {
            return mod;
        }

        var opts = b.addOptions();
        const root_path = b.root.toString(b.allocator) catch @panic("OOM");
        opts.addOption([]const u8, "base_path", root_path);
        opts.addOption([]const u8, "codegen_path", if (std.fs.path.isAbsolute(this.codegen_path))
            this.codegen_path
        else
            std.fs.path.resolve(b.graph.arena, &.{ root_path, this.codegen_path }) catch @panic("OOM"));

        opts.addOption(bool, "codegen_embed", this.shouldEmbedCode());
        opts.addOption(u32, "canary_revision", this.canary_revision orelse 0);
        opts.addOption(bool, "is_canary", this.canary_revision != null);
        opts.addOption(Version, "version", this.version);
        opts.addOption([:0]const u8, "sha", b.allocator.dupeSentinel(u8, this.sha, 0) catch @panic("OOM"));
        opts.addOption(bool, "baseline", this.isBaseline());
        opts.addOption(bool, "enable_logs", this.enable_logs);
        opts.addOption(bool, "enable_valgrind", this.enable_valgrind);
        opts.addOption(bool, "enable_tinycc", this.enable_tinycc);
        opts.addOption(bool, "use_mimalloc", this.use_mimalloc);
        opts.addOption([]const u8, "reported_nodejs_version", b.fmt("{f}", .{this.nodejs_compatibility.version}));
        opts.addOption(bool, "override_no_export_cpp_apis", this.override_no_export_cpp_apis);

        const mod = opts.createModule();
        this.cached_options_module = mod;
        return mod;
    }

    pub fn windowsShim(this: *BunBuildOptions, b: *Build) WindowsShim {
        return this.windows_shim orelse {
            this.windows_shim = WindowsShim.create(b, this.arch);
            return this.windows_shim.?;
        };
    }
};

pub fn getOSVersionMin(os: OperatingSystem) ?Target.Query.OsVersion {
    return switch (os) {
        .mac => .{
            .semver = .{ .major = 13, .minor = 0, .patch = 0 },
        },

        // FreeBSD 14.0 is the oldest supported major. 14.x guarantees forward
        // ABI compat, and 13.x is EOL by the time this lands.
        .freebsd => .{
            .semver = .{ .major = 14, .minor = 0, .patch = 0 },
        },

        // Windows 10 1809 is the minimum supported version
        // One case where this is specifically required is in `deleteOpenedFile`
        .windows => .{
            .windows = .win10_rs5,
        },

        else => null,
    };
}

pub fn getCpuModel(os: OperatingSystem, arch: Arch) ?Target.Query.CpuModel {
    // https://github.com/oven-sh/bun/issues/12076
    if (os == .linux and arch == .aarch64) {
        return .{ .explicit = &Target.aarch64.cpu.cortex_a35 };
    }

    // Be explicit and ensure we do not accidentally target a newer M-series chip
    if (os == .mac and arch == .aarch64) {
        return .{ .explicit = &Target.aarch64.cpu.apple_m1 };
    }

    // x86_64 stays null here: the executable graph picks its own CPU model.
    return null;
}

pub fn build(b: *Build) !void {
    // Configure observes untracked host state (source-directory scans,
    // toolchain probes, env vars), and the Maker's config-cache manifest does not yet
    // hash directory dependencies, so a cached configuration would miss new
    // source files. Keep the cache off.
    b.graph.poisonCache();

    std.log.info("zig compiler v{s}", .{builtin.zig_version_string});

    var target_query = b.standardTargetOptionsQueryOnly(.{});
    const optimize = b.standardOptimizeOption(.{});

    const os, const arch, const abi = brk: {
        // resolve the target query to pick up what operating system and cpu
        // architecture that is desired. this information is used to slightly
        // refine the query.
        const temp_resolved = b.resolveTargetQuery(target_query);
        const arch = temp_resolved.result.cpu.arch;
        const os: OperatingSystem = if (arch.isWasm())
            .wasm
        else switch (temp_resolved.result.os.tag) {
            .macos => .mac,
            .linux => .linux,
            .freebsd => .freebsd,
            .windows => .windows,
            else => |t| std.debug.panic("Unsupported OS tag {}", .{t}),
        };
        const abi = temp_resolved.result.abi;
        break :brk .{ os, arch, abi };
    };

    // Refine the target's CPU model where a platform has an explicit floor.
    if (getCpuModel(os, arch)) |cpu_model| {
        target_query.cpu_model = cpu_model;
    }

    target_query.os_version_min = getOSVersionMin(os);

    const target = b.resolveTargetQuery(target_query);

    // The full-executable graph: pinned inputs, codegen, C/C++, link, smoke
    // test. Every step (bun, check) consumes its generated code.
    const mode: bun_exe.Mode = if (optimize == .debug) .debug else .release;
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) {
        std.debug.panic("this build supports x86_64-linux hosts only", .{});
    }
    // Null = lazy fetches pending: end configuration cleanly so the runner
    // fetches the marked dependencies and re-runs it.
    const resolved = bun_exe.resolveDeps(b) orelse return;
    const pkgs = b.graph.arena.create(bun_exe.DepPkgs) catch @panic("OOM");
    pkgs.* = resolved;
    const cpp_deps = bun_exe.addCppDeps(b, pkgs, mode, optimize);
    const binding_codegen = bun_exe.addBindingCodegen(b);
    const cg = bun_exe.addCodegen(b, pkgs, mode, binding_codegen, cpp_deps.zstd);
    const emit_bindings = b.step("emit-bindings", "Generate JS/native bindings for the selected target");
    if (binding_codegen.forTarget(b, target)) |bindings| {
        emit_bindings.dependOn(bindings.step);
    } else {
        emit_bindings.dependOn(bindingTargetUnavailable(b, target));
    }
    addBindgenTests(b);
    const webkit_derived = bun_webkit.addStep(b, pkgs, mode, optimize);
    const webkit_ctx = b.graph.arena.create(bun_webkit.Ctx) catch @panic("OOM");
    webkit_ctx.* = bun_webkit.addLibs(b, pkgs, mode, optimize, webkit_derived, cg.schema_bindings_dirs);
    const icu_ctx = b.graph.arena.create(bun_icu.Ctx) catch @panic("OOM");
    icu_ctx.* = bun_icu.addLibs(b, pkgs, optimize);
    const unicode_data = bun_unicode_data.addModule(b, pkgs.icu);

    const codegen_embed = b.option(bool, "codegen_embed", "Embed generated runtime assets in Debug builds") orelse false;

    const bun_version = b.option([]const u8, "version", "Value of `Bun.version`") orelse
        packageJsonVersion(b) orelse "0.0.0";

    const override_no_export_cpp_apis = b.option(bool, "override-no-export-cpp-apis", "Override the default export_cpp_apis logic to disable exports") orelse false;
    // Zig does not bundle bionic headers, so translate-c needs the NDK
    // sysroot include paths explicitly. The obj's linkLibC() gets bionic
    // via `zig build --libc <file>` (b.libc_file), which the build script
    // also passes when targeting Android.
    const android_ndk_sysroot = b.option([]const u8, "android_ndk_sysroot", "Android NDK sysroot for translate-c headers");
    if (abi.isAndroid() and android_ndk_sysroot == null) {
        std.debug.panic("-Dandroid_ndk_sysroot is required when targeting Android (zig does not bundle bionic headers)", .{});
    }
    // Same story for FreeBSD: zig bundles only Linux/macOS/Windows libc
    // headers, so translate-c needs the FreeBSD sysroot. The obj's
    // linkLibC() gets FreeBSD libc via `zig build --libc <file>`. On a
    // native FreeBSD host the system root is the sysroot.
    const freebsd_sysroot = b.option([]const u8, "freebsd_sysroot", "FreeBSD sysroot (extracted base.txz) for the current target") orelse
        if (os == .freebsd and builtin.os.tag == .freebsd) "/" else null;
    const freebsd_sysroot_x86_64 = b.option([]const u8, "freebsd_sysroot_x86_64", "FreeBSD amd64 sysroot for multi-target checks") orelse freebsd_sysroot;
    const freebsd_sysroot_aarch64 = b.option([]const u8, "freebsd_sysroot_aarch64", "FreeBSD arm64 sysroot for multi-target checks") orelse freebsd_sysroot;
    const target_freebsd_sysroot = switch (arch) {
        .x86_64 => freebsd_sysroot_x86_64,
        .aarch64 => freebsd_sysroot_aarch64,
        else => null,
    };
    if (os == .freebsd and target_freebsd_sysroot == null) {
        std.debug.panic("a FreeBSD sysroot for the target architecture is required when cross-compiling", .{});
    }

    var build_options = BunBuildOptions{
        .target = target,
        .optimize = optimize,
        .os = os,
        .arch = arch,
        .codegen_path = cg.codegen_install_abs,
        .codegen_embed = codegen_embed,
        .override_no_export_cpp_apis = override_no_export_cpp_apis,
        .version = try Version.parse(bun_version),
        .canary_revision = canary: {
            const rev = b.option(u32, "canary", "Treat this as a canary build (0 = release)") orelse 1;
            break :canary if (rev == 0) null else rev;
        },
        .nodejs_compatibility = try bun_exe.nodejsCompatibility(b),
        // Dev builds bake the zero sha so commits never invalidate compiles;
        // CI passes the real revision.
        .sha = sha: {
            const sha = b.option([]const u8, "sha", "Force the git sha") orelse zero_sha;

            if (sha.len == 0) {
                std.log.warn("No git sha found, falling back to zero sha", .{});
                break :sha zero_sha;
            }
            if (sha.len != 40) {
                std.log.warn("Invalid git sha: {s}", .{sha});
                std.log.warn("Falling back to zero sha", .{});
                break :sha zero_sha;
            }

            break :sha sha;
        },
        .enable_logs = b.option(bool, "enable_logs", "Enable logs in release") orelse (optimize == .debug),
        .enable_valgrind = b.option(bool, "enable_valgrind", "Enable valgrind") orelse false,
        .enable_tinycc = b.option(bool, "enable_tinycc", "Enable TinyCC for FFI JIT compilation") orelse true,
        .use_mimalloc = b.option(bool, "use_mimalloc", "Use mimalloc as default allocator") orelse true,
        .android_ndk_sysroot = android_ndk_sysroot,
        .freebsd_sysroot_x86_64 = freebsd_sysroot_x86_64,
        .freebsd_sysroot_aarch64 = freebsd_sysroot_aarch64,
        .codegen = cg,
        .binding_codegen = binding_codegen,
        .unicode_data = unicode_data,
    };

    // The bun executable: codegen, C/C++, link, smoke test. Default step.
    {
        var o = build_options;
        // The executable and its C++ dependencies share the host target.
        o.target = b.graph.host;
        o.os = .linux;
        o.arch = .x86_64;
        o.cached_options_module = null;
        const obj = addBunObject(b, &o);

        const exe_opts: bun_exe.Options = .{
            .mode = mode,
            .optimize = optimize,
            .codegen_embed = o.shouldEmbedCode(),
            .version = bun_version,
            .sha = if (std.mem.eql(u8, build_options.sha, zero_sha)) null else build_options.sha,
            .nodejs = o.nodejs_compatibility,
            .target = o.target,
            .webkit = webkit_ctx,
            .icu = icu_ctx,
        };
        const archives = bun_exe.addCpp(b, pkgs, cg, cpp_deps, exe_opts);
        const built = bun_exe.addLink(b, pkgs, archives, obj.getEmittedBin(), cg, exe_opts);
        // The executable is pinned to this target; fail loudly rather than
        // silently overriding an explicit -Dtarget/-Dcpu.
        if (os != .linux or arch != .x86_64 or
            (target_query.abi != null and target_query.abi.? != .gnu) or
            target_query.cpu_model != .determined_by_arch_os)
        {
            const fail = b.addFail("the bun executable is pinned to x86_64-linux-gnu (native cpu); -Dtarget/-Dcpu apply only to the check steps");
            built.step.dependOn(&fail.step);
        }
        b.default_step.dependOn(built.step);

        const run_step = b.step("run", "Run the built bun (pass args after --)");
        const run_cmd = b.addRunFile(built.exe);
        run_cmd.addPassthruArgs();
        run_cmd.step.dependOn(built.step);
        run_step.dependOn(&run_cmd.step);
    }

    // zig build windows-shim
    {
        var step = b.step("windows-shim", "Build the Windows shim (bun_shim_impl.exe + bun_shim_debug.exe)");
        var windows_shim = build_options.windowsShim(b);
        step.dependOn(&b.addInstallFile(windows_shim.exe.getEmittedBin(), "bun_shim_impl.exe").step);
        step.dependOn(&b.addInstallFile(windows_shim.dbg.getEmittedBin(), "bun_shim_debug.exe").step);
    }

    // zig build check
    {
        var step = b.step("check", "Check for semantic analysis errors");
        var bun_check_obj = addBunObject(b, &build_options);
        bun_check_obj.generated_bin = .none;
        step.dependOn(&bun_check_obj.step);
    }

    // zig build check-debug
    {
        const step = b.step("check-debug", "Check for semantic analysis errors on some platforms");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .windows, .arch = .x86_64 },
            .{ .os = .windows, .arch = .aarch64 },
            .{ .os = .mac, .arch = .aarch64 },
            .{ .os = .linux, .arch = .x86_64 },
        }, &.{.debug});
    }

    // zig build check-all
    {
        const step = b.step("check-all", "Check for semantic analysis errors across the native target matrix");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .windows, .arch = .x86_64 },
            .{ .os = .windows, .arch = .aarch64 },
            .{ .os = .mac, .arch = .x86_64 },
            .{ .os = .mac, .arch = .aarch64 },
            .{ .os = .linux, .arch = .x86_64 },
            .{ .os = .linux, .arch = .aarch64 },
            .{ .os = .linux, .arch = .x86_64, .abi = .musl },
            .{ .os = .linux, .arch = .aarch64, .abi = .musl },
        }, &.{ .debug, .fast });
    }

    // zig build check-all-debug
    {
        const step = b.step("check-all-debug", "Check for semantic analysis errors across the native target matrix in debug mode");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .windows, .arch = .x86_64 },
            .{ .os = .windows, .arch = .aarch64 },
            .{ .os = .mac, .arch = .x86_64 },
            .{ .os = .mac, .arch = .aarch64 },
            .{ .os = .linux, .arch = .x86_64 },
            .{ .os = .linux, .arch = .aarch64 },
            .{ .os = .linux, .arch = .x86_64, .abi = .musl },
            .{ .os = .linux, .arch = .aarch64, .abi = .musl },
        }, &.{.debug});
    }

    // zig build check-windows
    {
        const step = b.step("check-windows", "Check for semantic analysis errors on Windows");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .windows, .arch = .x86_64 },
            .{ .os = .windows, .arch = .aarch64 },
        }, &.{ .debug, .fast });
    }
    {
        const step = b.step("check-windows-debug", "Check for semantic analysis errors on Windows");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .windows, .arch = .x86_64 },
            .{ .os = .windows, .arch = .aarch64 },
        }, &.{.debug});
    }
    {
        const step = b.step("check-macos", "Check for semantic analysis errors on macOS");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .mac, .arch = .x86_64 },
            .{ .os = .mac, .arch = .aarch64 },
        }, &.{ .debug, .fast });
    }
    {
        const step = b.step("check-macos-debug", "Check for semantic analysis errors on macOS in debug mode");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .mac, .arch = .x86_64 },
            .{ .os = .mac, .arch = .aarch64 },
        }, &.{.debug});
    }
    {
        const step = b.step("check-linux", "Check for semantic analysis errors on Linux");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .linux, .arch = .x86_64 },
            .{ .os = .linux, .arch = .aarch64 },
        }, &.{ .debug, .fast });
    }
    {
        const step = b.step("check-linux-debug", "Check for semantic analysis errors on Linux in debug mode");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .linux, .arch = .x86_64 },
            .{ .os = .linux, .arch = .aarch64 },
        }, &.{.debug});
    }
    // check-android needs the NDK sysroot for translate-c (zig doesn't
    // bundle bionic headers). Skip step creation entirely when none was
    // passed, so plain `zig build check` doesn't try to construct a
    // translate-c step that would panic.
    if (android_ndk_sysroot != null) {
        {
            const step = b.step("check-android", "Check for semantic analysis errors on Android");
            addMultiCheck(b, step, build_options, &.{
                .{ .os = .linux, .arch = .x86_64, .abi = .android },
                .{ .os = .linux, .arch = .aarch64, .abi = .android },
            }, &.{ .debug, .fast });
        }
        {
            const step = b.step("check-android-debug", "Check for semantic analysis errors on Android");
            addMultiCheck(b, step, build_options, &.{
                .{ .os = .linux, .arch = .x86_64, .abi = .android },
                .{ .os = .linux, .arch = .aarch64, .abi = .android },
            }, &.{.debug});
        }
    }
    // check-freebsd needs the sysroot for translate-c (zig doesn't bundle
    // FreeBSD libc headers). Skip step creation entirely when none was
    // passed, so plain `zig build check` doesn't try to construct a
    // translate-c step that would panic.
    if (freebsd_sysroot_x86_64 != null and freebsd_sysroot_aarch64 != null) {
        {
            const step = b.step("check-freebsd", "Check for semantic analysis errors on FreeBSD");
            addMultiCheck(b, step, build_options, &.{
                .{ .os = .freebsd, .arch = .x86_64 },
                .{ .os = .freebsd, .arch = .aarch64 },
            }, &.{ .debug, .fast });
        }
        {
            const step = b.step("check-freebsd-debug", "Check for semantic analysis errors on FreeBSD");
            addMultiCheck(b, step, build_options, &.{
                .{ .os = .freebsd, .arch = .x86_64 },
                .{ .os = .freebsd, .arch = .aarch64 },
            }, &.{.debug});
        }
    }
    {
        const step = b.step("check-wasm", "Check the WebAssembly transpiler subset for semantic analysis errors");
        const wasm_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .cpu_model = .baseline,
            .os_tag = .freestanding,
        });
        inline for (.{ std.builtin.Optimize.debug, std.builtin.Optimize.fast }) |wasm_mode| {
            var options: BunBuildOptions = .{
                .target = wasm_target,
                .optimize = wasm_mode,
                .os = .wasm,
                .arch = .wasm32,
                .version = build_options.version,
                .canary_revision = build_options.canary_revision,
                .sha = build_options.sha,
                .enable_logs = build_options.enable_logs,
                .enable_valgrind = false,
                .enable_tinycc = false,
                .use_mimalloc = build_options.use_mimalloc,
                .nodejs_compatibility = build_options.nodejs_compatibility,
                .codegen_embed = build_options.codegen_embed,
                .codegen_path = build_options.codegen_path,
                .codegen = build_options.codegen,
                .binding_codegen = build_options.binding_codegen,
                .unicode_data = build_options.unicode_data,
                .override_no_export_cpp_apis = true,
            };
            var obj = addBunWasmObject(b, &options);
            obj.generated_bin = .none;
            step.dependOn(&obj.step);
        }
    }
}

fn addBindgenTests(b: *Build) void {
    const step = b.step("test-bindgen", "Run binding normalizer, IR, and compile-failure tests");
    const ir = b.createModule(.{
        .root_source_file = b.path("src/bindgen/ir.zig"),
    });
    const schema = b.createModule(.{
        .root_source_file = b.path("src/bindgen/schema.zig"),
    });
    schema.addImport("bindgen_ir", ir);
    const class_field_validation = b.createModule(.{
        .root_source_file = b.path("src/bindgen/class_field_validation.zig"),
    });
    const shared_schema = b.createModule(.{
        .root_source_file = b.path("src/jsc/bindgen_shared.schema.zig"),
    });
    shared_schema.addImport("bindgen_schema", schema);
    const archetypes_schema = b.createModule(.{
        .root_source_file = b.path("src/bindgen/archetypes.schema.zig"),
    });
    archetypes_schema.addImport("bindgen_schema", schema);
    const hash_types_schema = b.createModule(.{
        .root_source_file = b.path("src/runtime/crypto/HashTypes.schema.zig"),
    });
    hash_types_schema.addImport("bindgen_schema", schema);
    hash_types_schema.addImport("binding_schema_archetypes", archetypes_schema);
    const structured_clone_schema = b.createModule(.{
        .root_source_file = b.path("src/runtime/webcore/StructuredClone.schema.zig"),
    });
    structured_clone_schema.addImport("bindgen_schema", schema);
    const test_schema = b.createModule(.{
        .root_source_file = b.path("src/jsc/bindgen_test.schema.zig"),
    });
    test_schema.addImport("bindgen_schema", schema);
    test_schema.addImport("binding_schema_bindgen_shared", shared_schema);
    test_schema.addImport("binding_schema_archetypes", archetypes_schema);
    test_schema.addImport("binding_schema_HashTypes", hash_types_schema);
    test_schema.addImport("binding_schema_StructuredClone", structured_clone_schema);

    inline for (.{
        .{ "bindgen-normalize", "src/bindgen/normalize_test.zig" },
        .{ "bindgen-ir", "src/bindgen/ir_test.zig" },
    }) |entry| {
        const name, const source = entry;
        const root = b.createModule(.{
            .root_source_file = b.path(source),
            .target = b.graph.host,
            .optimize = .debug,
        });
        root.addImport("bindgen_ir", ir);
        root.addImport("bindgen_schema", schema);
        root.addImport("rapidhash", b.createModule(.{ .root_source_file = b.path("src/hash/rapidhash.zig") }));
        root.addImport("bindgen_test_schema", test_schema);
        root.addImport("binding_schema_archetypes", archetypes_schema);
        const tests = b.addTest(.{ .name = name, .root_module = root });
        tests.incremental = false;
        step.dependOn(&b.addRunArtifact(tests).step);
    }

    const field_validation_tests = b.addTest(.{
        .name = "bindgen-class-fields",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bindgen/class_field_validation.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    field_validation_tests.incremental = false;
    step.dependOn(&b.addRunArtifact(field_validation_tests).step);

    inline for (.{
        .{ "gc_raw_value_field", "bound class field 'Invalid.value' must use a bindgen root or typed weak handle" },
        .{ "gc_pointer_field", "bound class field 'Invalid.pointer' has unapproved pointer type '*u8'; use an explicit owned, referenced, or borrowed native wrapper" },
        .{ "gc_function_pointer_field", "bound class field 'Invalid.callback' has unapproved pointer type '*const fn () void'; use an explicit owned, referenced, or borrowed native wrapper" },
        .{ "native_data_nested_pointer", "NativeData payload 'Invalid.nested.items' contains pointer type '[]const u8'; use an explicit owned, referenced, or borrowed native wrapper" },
        .{ "native_data_unsupported_type", "NativeData payload 'Callback' has unsupported runtime type 'fn () void'" },
        .{ "native_data_engine_value", "NativeData payload 'Invalid.value' contains an engine value; use a root or typed handle" },
        .{ "native_data_focused_value", "NativeData payload 'Invalid.value' contains a focused engine value; use a root for storage" },
        .{ "gc_forged_token", "bound class field 'Invalid.value' has an invalid bindgen GC token" },
        .{ "gc_vm_affine_any_thread", "bound class field 'Invalid.value' requires VM-affine reference handling" },
        .{ "native_resource_engine_value", "native resource 'native_resource_engine_value.Nested.values[]' must use a bindgen root or typed weak handle" },
        .{ "native_resource_scoped_view", "native resource 'Owner.*.view.token' contains a call-scoped view" },
        .{ "native_resource_nested_affinity", "native resource 'native_resource_nested_affinity.Resource.root' requires VM-affine reference handling" },
        .{ "native_resource_raw_pointer", "native resource 'Owner.*.pointer' has an untyped native pointer; use a nominal resource type" },
        .{ "native_resource_unnamed", "native resource 'Owner.*' requires a typed pointee" },
    }) |case| {
        const name, const expected = case;
        const root = b.createModule(.{
            .root_source_file = b.path("test/bindgen/compile_fail/" ++ name ++ ".zig"),
            .target = b.graph.host,
            .optimize = .debug,
        });
        root.addImport("bindgen_class_field_validation", class_field_validation);
        const compile_fail = b.addTest(.{
            .name = "bindgen-compile-fail-" ++ name,
            .root_module = root,
            .emit_object = true,
        });
        compile_fail.incremental = false;
        compile_fail.expect_errors = .{ .contains = expected };
        step.dependOn(&compile_fail.step);
    }
}

const TargetDescription = struct {
    os: OperatingSystem,
    arch: Arch,
    abi: ?Target.Abi = null,

    fn resolveTarget(desc: TargetDescription, b: *Build) std.Build.ResolvedTarget {
        return b.resolveTargetQuery(.{
            .os_tag = OperatingSystem.stdOSTag(desc.os),
            .cpu_arch = desc.arch,
            .cpu_model = getCpuModel(desc.os, desc.arch) orelse .determined_by_arch_os,
            .os_version_min = getOSVersionMin(desc.os),
            .abi = desc.abi orelse if (desc.os == .linux) .gnu else null,
        });
    }
};

fn addMultiCheck(
    b: *Build,
    parent_step: *Step,
    root_build_options: BunBuildOptions,
    to_check: []const TargetDescription,
    optimize: []const std.builtin.Optimize,
) void {
    for (to_check) |check| {
        for (optimize) |mode| {
            const check_target = check.resolveTarget(b);
            var options: BunBuildOptions = .{
                .target = check_target,
                .os = check.os,
                .arch = check_target.result.cpu.arch,
                .optimize = mode,

                .canary_revision = root_build_options.canary_revision,
                .sha = root_build_options.sha,
                .version = root_build_options.version,
                .nodejs_compatibility = root_build_options.nodejs_compatibility,
                .codegen_path = root_build_options.codegen_path,
                .enable_valgrind = root_build_options.enable_valgrind,
                .enable_tinycc = root_build_options.enable_tinycc,
                .use_mimalloc = root_build_options.use_mimalloc,
                .override_no_export_cpp_apis = root_build_options.override_no_export_cpp_apis,
                .android_ndk_sysroot = root_build_options.android_ndk_sysroot,
                .freebsd_sysroot_x86_64 = root_build_options.freebsd_sysroot_x86_64,
                .freebsd_sysroot_aarch64 = root_build_options.freebsd_sysroot_aarch64,
                .codegen = root_build_options.codegen,
                .binding_codegen = root_build_options.binding_codegen,
                .unicode_data = root_build_options.unicode_data,
            };

            var obj = addBunObject(b, &options);
            obj.generated_bin = .none;
            parent_step.dependOn(&obj.step);
        }
    }
}

fn getTranslateC(b: *Build, initial_target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, android_ndk_sysroot: ?[]const u8, freebsd_sysroot: ?[]const u8) LazyPath {
    const target = b.resolveTargetQuery(q: {
        var query = initial_target.query;
        if (query.os_tag == .windows)
            query.abi = .gnu;
        break :q query;
    });
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c-headers-for-zig.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    inline for ([_](struct { []const u8, bool }){
        .{ "WINDOWS", translate_c.target.result.os.tag == .windows },
        .{ "POSIX", translate_c.target.result.os.tag != .windows },
        .{ "LINUX", translate_c.target.result.os.tag == .linux },
        .{ "MUSL", target.result.abi.isMusl() },
        .{ "DARWIN", translate_c.target.result.os.tag.isDarwin() },
        .{ "FREEBSD", translate_c.target.result.os.tag == .freebsd },
    }) |entry| {
        const str, const value = entry;
        translate_c.defineCMacroRaw(b.fmt("{s}={d}", .{ str, @intFromBool(value) }));
    }

    if (target.result.os.tag == .windows and target.result.cpu.arch == .x86_64) {
        // winnt.h includes these intrinsic headers even though none of their
        // inline functions are needed by the translated declarations.
        translate_c.defineCMacro("__X86INTRIN_H", "1");
        translate_c.defineCMacro("__EMMINTRIN_H", "1");
    }

    // zstd headers for @cImport come from the pinned zon package.
    if (b.lazyDependency("zstd", .{})) |zstd_pkg| {
        translate_c.addIncludePath(zstd_pkg.path("lib"));
    }

    if (target.result.abi.isAndroid()) {
        const sysroot = android_ndk_sysroot orelse
            std.debug.panic("translate-c for Android requires -Dandroid_ndk_sysroot", .{});
        // Bionic annotates array parameters with Clang nullability keywords,
        // which translate-c rejects even though the annotations do not affect
        // the declarations' ABI. Its signedness overload for ioctl is likewise
        // unnecessary for translated declarations.
        translate_c.defineCMacroRaw("_Nonnull=");
        translate_c.defineCMacroRaw("_Nullable=");
        translate_c.defineCMacroRaw("_Null_unspecified=");
        translate_c.defineCMacro("BIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD", "1");
        const arch_triple = switch (target.result.cpu.arch) {
            .aarch64 => "aarch64-linux-android",
            .x86_64 => "x86_64-linux-android",
            else => |a| std.debug.panic("unsupported Android arch: {s}", .{@tagName(a)}),
        };
        translate_c.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}) });
        translate_c.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ sysroot, arch_triple }) });
    }

    if (target.result.os.tag == .freebsd) {
        const sysroot = freebsd_sysroot orelse
            std.debug.panic("translate-c for FreeBSD requires -Dfreebsd_sysroot", .{});
        // Prefer the requested release's headers over Zig's generic FreeBSD
        // header set so translated ABI layouts come from the actual sysroot.
        translate_c.addIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}) });
    }

    if (target.result.os.tag == .windows) {
        // translate-c is unable to translate the unsuffixed windows functions
        // like `SetCurrentDirectory` since they are defined with an odd macro
        // that translate-c doesn't handle.
        //
        //     #define SetCurrentDirectory __MINGW_NAME_AW(SetCurrentDirectory)
        //
        // In these cases, it's better to just reference the underlying function
        // directly: SetCurrentDirectoryW. To make the error better, a post
        // processing step is applied to the translate-c file.
        //
        // Additionally, this step makes it so that decls like NTSTATUS and
        // HANDLE point to the standard library structures.
        const helper_exe = b.addExecutable(.{
            .name = "process_windows_translate_c",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/codegen/process_windows_translate_c.zig"),
                .target = b.graph.host,
                .optimize = .debug,
            }),
        });
        helper_exe.incremental = false;
        const in = translate_c.getOutput();
        const run = b.addRunArtifact(helper_exe);
        run.addFileArg(in);
        const out = run.addOutputFileArg("c-headers-for-zig.zig");
        return out;
    }
    return translate_c.getOutput();
}

fn bindingTargetUnavailable(b: *Build, target: ResolvedTarget) *Step {
    const triple = target.result.zigTriple(b.graph.arena) catch @panic("OOM");
    return &b.addFail(b.fmt("JS/native bindings are not available for {s}", .{triple})).step;
}

pub fn addBunObject(b: *Build, opts: *BunBuildOptions) *Compile {
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),

        // Root module gets compilation flags. Forwarded as default to dependencies.
        .target = opts.target,
        .optimize = opts.optimize,
    });
    const obj = b.addObject(.{
        .name = if (opts.optimize == .debug) "bun-debug" else "bun",
        .root_module = root,
    });
    const bindings = opts.binding_codegen.forTarget(b, opts.target) orelse {
        obj.step.dependOn(bindingTargetUnavailable(b, opts.target));
        return obj;
    };

    // Create `@import("bun")`, containing most of Bun's code.
    const bun = b.createModule(.{
        .root_source_file = b.path("src/bun.zig"),
    });
    bun.addImport("bun", bun); // allow circular "bun" import
    addInternalImports(b, bun, opts, bindings);
    root.addImport("bun", bun);

    configureObj(opts, obj);
    // Runtime assets are imported from the stable synced dir.
    obj.step.dependOn(opts.codegen.sync_step);
    obj.step.dependOn(opts.binding_codegen.checkWireTypes(b, opts.target));
    return obj;
}

fn addBunWasmObject(b: *Build, opts: *BunBuildOptions) *Compile {
    const bun = b.createModule(.{
        .root_source_file = b.path("src/bun.zig"),
    });
    bun.addImport("bun", bun);
    addInternalImports(b, bun, opts, null);

    const root = b.createModule(.{
        .root_source_file = b.path("src/main_wasm.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .single_threaded = true,
    });
    root.addImport("bun", bun);

    const obj = b.addObject(.{
        .name = if (opts.optimize == .debug) "bun-wasm-debug" else "bun-wasm",
        .root_module = root,
    });
    configureObj(opts, obj);
    obj.step.dependOn(opts.codegen.sync_step);
    return obj;
}

fn configureObj(opts: *BunBuildOptions, obj: *Compile) void {
    // Flags on root module get used for the compilation
    obj.root_module.omit_frame_pointer = false;
    obj.root_module.strip = false; // stripped at the end
    // https://github.com/ziglang/zig/issues/17430
    obj.root_module.pic = true;

    // Incremental compilation is deliberately NOT forced here: -fincremental
    // switches the compiler to a cache mode without content-based caching, so
    // forcing it makes every one-shot build a full recompile. Pass
    // `--watch -fincremental` for the resident dev loop; one-shot builds get
    // the content-addressed whole-cache.

    obj.bundle_compiler_rt = false;
    obj.bundle_ubsan_rt = false;

    // Link libc
    if (opts.os != .wasm) {
        obj.root_module.link_libc = true;
        obj.root_module.link_libcpp = true;
    }

    // Disable stack probing on x86 so we don't need to include compiler_rt
    if (opts.arch.isX86()) {
        // TODO: enable on debug please.
        obj.root_module.stack_check = false;
        obj.root_module.stack_protector = false;
    }

    if (opts.os == .linux) {
        obj.link_emit_relocs = false;
        obj.link_eh_frame_hdr = false;
        obj.link_function_sections = true;
        obj.link_data_sections = true;

        if (opts.optimize == .debug and opts.enable_valgrind) {
            obj.root_module.valgrind = true;
        }
    }
}

/// Default `Bun.version`, read from package.json.
fn packageJsonVersion(b: *Build) ?[]const u8 {
    const arena = b.graph.arena;
    b.dependOnFileContents(b.path("package.json"));
    const root = b.root.toString(arena) catch return null;
    const dir = std.Io.Dir.openDirAbsolute(b.graph.io, root, .{}) catch return null;
    const content = dir.readFileAlloc(b.graph.io, "package.json", arena, .limited(1024 * 1024)) catch return null;
    const key = "\"version\": \"";
    const start = (std.mem.indexOf(u8, content, key) orelse return null) + key.len;
    const end = std.mem.indexOfScalarPos(u8, content, start, '"') orelse return null;
    return content[start..end];
}

fn addInternalImports(b: *Build, mod: *Module, opts: *BunBuildOptions, bindings: ?*const bun_exe.BindingArtifacts) void {
    const os = opts.os;
    var shared_modules: std.ArrayList(*Module) = .empty;
    shared_modules.appendSlice(b.graph.arena, &.{
        opts.unicode_data,
        opts.binding_codegen.ir_module,
        opts.codegen.mysql_domain,
    }) catch @panic("OOM");

    const build_options = opts.buildOptionsModule(b);
    mod.addImport("build_options", build_options);
    mod.addImport("unicode_data", opts.unicode_data);
    mod.addImport("bindgen_ir", opts.binding_codegen.ir_module);
    mod.addImport("mysql_domain", opts.codegen.mysql_domain);
    mod.addImport("network_core", b.createModule(.{
        .root_source_file = b.path("src/runtime/network_core/root.zig"),
    }));
    if (bindings) |artifacts| {
        const binding_ir = b.createModule(.{ .root_source_file = artifacts.ir });
        mod.addImport("binding_ir", binding_ir);
        const binding_fingerprint = b.createModule(.{ .root_source_file = artifacts.fingerprint });
        mod.addImport("binding_fingerprint", binding_fingerprint);
        shared_modules.appendSlice(b.graph.arena, &.{ binding_ir, binding_fingerprint }) catch @panic("OOM");

        const binding_implementations = b.createModule(.{
            .root_source_file = artifacts.implementations,
        });
        binding_implementations.addImport("bun", mod);
        mod.addImport("binding_implementations", binding_implementations);

        const binding_wire_translate = b.addTranslateC(.{
            .root_source_file = artifacts.wire_header,
            .target = opts.target,
            .optimize = opts.optimize,
            .link_libc = true,
        });
        const binding_wire = b.createModule(.{
            .root_source_file = binding_wire_translate.getOutput(),
        });
        mod.addImport("binding_wire", binding_wire);
    }

    const lshpack_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/lshpack_sys/BunHpack.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    mod.addImport("lshpack-ffi", b.createModule(.{
        .root_source_file = lshpack_translate.getOutput(),
    }));

    const highway_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/highway_sys/BunHighway.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    mod.addImport("highway-ffi", b.createModule(.{
        .root_source_file = highway_translate.getOutput(),
    }));

    const webview_host_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/webview_sys/BunWebViewHost.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    mod.addImport("webview-host-ffi", b.createModule(.{
        .root_source_file = webview_host_translate.getOutput(),
    }));

    const rescle_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/rescle_sys/BunResources.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    mod.addImport("rescle-ffi", b.createModule(.{
        .root_source_file = rescle_translate.getOutput(),
    }));

    const image_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/image_sys/BunImage.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    mod.addImport("image-ffi", b.createModule(.{
        .root_source_file = image_translate.getOutput(),
    }));

    const perf_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/perf_sys/BunPerf.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    mod.addImport("perf-ffi", b.createModule(.{
        .root_source_file = perf_translate.getOutput(),
    }));

    const tcc_stdio_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/tcc_sys/TccStdio.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    mod.addImport("tcc-stdio", b.createModule(.{
        .root_source_file = tcc_stdio_translate.getOutput(),
    }));

    const libc_stdio_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/libc_sys/BunStdio.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    mod.addImport("libc-stdio", b.createModule(.{
        .root_source_file = libc_stdio_translate.getOutput(),
    }));

    const libc_process_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/libc_sys/BunProcessMemory.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    mod.addImport("libc-process", b.createModule(.{
        .root_source_file = libc_process_translate.getOutput(),
    }));

    const libc_spawn_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/libc_sys/BunSpawn.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    mod.addImport("libc-spawn", b.createModule(.{
        .root_source_file = libc_spawn_translate.getOutput(),
    }));

    const dns_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/dns/BunDNS.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    mod.addImport("dns-native", b.createModule(.{
        .root_source_file = dns_translate.getOutput(),
    }));

    const native_stack_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/debugger_sys/BunNativeStack.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    mod.addImport("debugger-native-stack", b.createModule(.{
        .root_source_file = native_stack_translate.getOutput(),
    }));

    const embedded_data_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/exe_format/EmbeddedData.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    mod.addImport("embedded-data", b.createModule(.{
        .root_source_file = embedded_data_translate.getOutput(),
    }));

    const usockets_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/uws_sys/UwsNative.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    usockets_translate.defineCMacro("BUN_DEBUG", "1");
    mod.addImport("usockets-native", b.createModule(.{
        .root_source_file = usockets_translate.getOutput(),
    }));

    const translated_c = if (os == .wasm)
        b.path("src/codegen/translated_c_stub.zig")
    else
        getTranslateC(b, opts.target, opts.optimize, opts.android_ndk_sysroot, opts.freebsdSysroot());
    mod.addImport("translated-c-headers", b.createModule(.{ .root_source_file = translated_c }));

    const zlib_internal_path = switch (os) {
        .windows => "src/zlib_sys/win32.zig",
        .linux, .mac, .freebsd => "src/zlib_sys/posix.zig",
        else => null,
    };
    if (zlib_internal_path) |path| {
        mod.addAnonymousImport("zlib-internal", .{
            .root_source_file = b.path(path),
        });
    }

    const async_path = switch (os) {
        .linux, .mac, .freebsd => "src/aio/posix_event_loop.zig",
        .windows => "src/aio/windows_event_loop.zig",
        else => "src/aio/stub_event_loop.zig",
    };
    mod.addAnonymousImport("async", .{
        .root_source_file = b.path(async_path),
    });

    // Generated code exposed as individual modules.
    inline for (.{
        .{ .file = "runtime.out.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "bake.client.js", .import = "bake-codegen/bake.client.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "bake.error.js", .import = "bake-codegen/bake.error.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "bake.server.js", .import = "bake-codegen/bake.server.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "bun-error/index.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "bun-error/bun-error.css", .enable = opts.shouldEmbedCode() },
        .{ .file = "fallback-decoder.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "add-completions.txt.zst" },
        .{ .file = "node-fallbacks/react-refresh.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/assert.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/buffer.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/console.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/constants.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/crypto.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/domain.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/events.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/http.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/https.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/net.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/os.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/path.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/process.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/punycode.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/querystring.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/stream.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/string_decoder.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/sys.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/timers.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/tty.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/url.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/util.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "node-fallbacks/zlib.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "eval/feedback.ts", .enable = opts.shouldEmbedCode() },
    }) |entry| {
        if (!@hasField(@TypeOf(entry), "enable") or entry.enable) {
            const import_path = if (@hasField(@TypeOf(entry), "import"))
                entry.import
            else
                entry.file;
            const path = b.pathJoin(&.{ opts.codegen_path, entry.file });
            mod.addAnonymousImport(import_path, .{
                .root_source_file = .{ .cwd_relative = path },
            });
        }
    }
    {
        const ciInfoImport = b.createModule(.{
            .root_source_file = (std.Build.LazyPath{ .cwd_relative = opts.codegen_path }).path(b, "ci_info.zig"),
        });
        mod.addImport("ci_info", ciInfoImport);
        ciInfoImport.addImport("bun", mod);
    }
    inline for (.{
        .{ .import = "completions-bash", .file = b.path("completions/bun.bash") },
        .{ .import = "completions-zsh", .file = b.path("completions/bun.zsh") },
        .{ .import = "completions-fish", .file = b.path("completions/bun.fish") },
    }) |entry| {
        mod.addAnonymousImport(entry.import, .{
            .root_source_file = entry.file,
        });
    }

    if (os == .windows) {
        mod.addAnonymousImport("bun_shim_impl.exe", .{
            .root_source_file = opts.windowsShim(b).exe.getEmittedBin(),
        });
    }

    // Finally, make it so all modules share the same import table.
    propagateImports(mod, shared_modules.items) catch @panic("OOM");
}

/// Makes all imports of `source_mod` visible to all of its dependencies.
/// Shared modules retain their own import graphs to avoid mixing target-specific imports.
/// Does not replace existing imports.
fn propagateImports(source_mod: *Module, shared_modules: []const *Module) !void {
    var seen = std.AutoHashMap(*Module, void).init(source_mod.owner.graph.arena);
    defer seen.deinit();
    for (shared_modules) |mod| try seen.put(mod, {});
    var queue = std.array_list.Managed(*Module).init(source_mod.owner.graph.arena);
    defer queue.deinit();
    try queue.appendSlice(source_mod.import_table.values());
    while (queue.pop()) |mod| {
        if ((try seen.getOrPut(mod)).found_existing) continue;
        try queue.appendSlice(mod.import_table.values());

        for (source_mod.import_table.keys(), source_mod.import_table.values()) |k, v|
            if (mod.import_table.get(k) == null)
                mod.addImport(k, v);
    }
}

const WindowsShim = struct {
    exe: *Compile,
    dbg: *Compile,

    fn create(b: *Build, arch: Arch) WindowsShim {
        const target = b.resolveTargetQuery(.{
            .cpu_model = switch (arch) {
                .aarch64 => .baseline,
                else => .{ .explicit = &std.Target.x86.cpu.nehalem },
            },
            .cpu_arch = switch (arch) {
                .aarch64 => .aarch64,
                else => .x86_64,
            },
            .os_tag = .windows,
            .os_version_min = getOSVersionMin(.windows),
        });

        const path = b.path("src/install/windows-shim/bun_shim_impl.zig");

        const exe = b.addExecutable(.{
            .name = "bun_shim_impl",
            .root_module = b.createModule(.{
                .root_source_file = path,
                .target = target,
                .optimize = .fast,
                .unwind_tables = .none,
                .omit_frame_pointer = true,
                .strip = true,
                .sanitize_thread = false,
                .single_threaded = true,
                .link_libc = false,
            }),
            .linkage = .static,
            .use_llvm = true,
            .use_lld = true,
        });

        const dbg = b.addExecutable(.{
            .name = "bun_shim_debug",
            .root_module = b.createModule(.{
                .root_source_file = path,
                .target = target,
                .optimize = .debug,
                .single_threaded = true,
                .link_libc = false,
            }),
            .linkage = .static,
            .use_llvm = true,
            .use_lld = true,
        });

        return .{ .exe = exe, .dbg = dbg };
    }
};
