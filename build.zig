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
//! Compile steps must leave `incremental` unset: -fincremental trades
//! content-based caching for in-process state, which only pays off under
//! --watch (where the CLI flag enables it).
//!
//! Builds on x86_64-linux only; the check-* steps type-check other targets.

const std = @import("std");
const builtin = @import("builtin");

const Build = std.Build;
const Step = Build.Step;
const Compile = Step.Compile;
const LazyPath = Build.LazyPath;
const Target = std.Target;
const ResolvedTarget = std.Build.ResolvedTarget;
const CrossTarget = std.zig.CrossTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const Module = Build.Module;
const fs = std.fs;
const Version = std.SemanticVersion;
const Arch = std.Target.Cpu.Arch;

const OperatingSystem = @import("src/bun_core/env.zig").OperatingSystem;
const bun_exe = @import("src/build/exe.zig");
const bun_webkit = @import("src/build/webkit.zig");
const bun_icu = @import("src/build/icu.zig");

const pathRel = fs.path.relative;

const zero_sha = "0000000000000000000000000000000000000000";

const BunBuildOptions = struct {
    target: ResolvedTarget,
    optimize: OptimizeMode,
    os: OperatingSystem,
    arch: Arch,

    version: Version,
    canary_revision: ?u32,
    sha: []const u8,
    /// enable debug logs in release builds
    enable_logs: bool = false,
    enable_fuzzilli: bool,
    enable_valgrind: bool,
    enable_tinycc: bool,
    use_mimalloc: bool,
    tracy_callstack_depth: u16,
    reported_nodejs_version: Version,
    /// To make iterating on some '@embedFile's faster, we load them at runtime
    /// instead of at compile time. This is disabled in release or if this flag
    /// is set (to allow CI to build a portable executable). Affected files:
    ///
    /// - src/bake/runtime.ts (bundled)
    /// - src/runtime/api/FFI.h
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

    pub fn isBaseline(this: *const BunBuildOptions) bool {
        return this.arch.isX86() and
            !Target.x86.featureSetHas(this.target.result.cpu.features, .avx2);
    }

    pub fn shouldEmbedCode(opts: *const BunBuildOptions) bool {
        return opts.optimize != .Debug or opts.codegen_embed;
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
        opts.addOption(bool, "enable_fuzzilli", this.enable_fuzzilli);
        opts.addOption(bool, "enable_valgrind", this.enable_valgrind);
        opts.addOption(bool, "enable_tinycc", this.enable_tinycc);
        opts.addOption(bool, "use_mimalloc", this.use_mimalloc);
        opts.addOption([]const u8, "reported_nodejs_version", b.fmt("{f}", .{this.reported_nodejs_version}));
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
    const mode: bun_exe.Mode = if (optimize == .Debug) .debug else .release;
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) {
        std.debug.panic("this build supports x86_64-linux hosts only", .{});
    }
    // Null = lazy fetches pending: end configuration cleanly so the runner
    // fetches the marked dependencies and re-runs it.
    const resolved = bun_exe.resolveDeps(b, mode) orelse return;
    const pkgs = b.graph.arena.create(bun_exe.DepPkgs) catch @panic("OOM");
    pkgs.* = resolved;
    const cg = bun_exe.addCodegen(b, pkgs, mode);
    const webkit_derived = bun_webkit.addStep(b, pkgs, mode);
    const webkit_ctx = b.graph.arena.create(bun_webkit.Ctx) catch @panic("OOM");
    webkit_ctx.* = bun_webkit.addLibs(b, pkgs, mode, webkit_derived);
    const icu_ctx = b.graph.arena.create(bun_icu.Ctx) catch @panic("OOM");
    icu_ctx.* = bun_icu.addLibs(b, pkgs);

    const codegen_embed = b.option(bool, "codegen_embed", "If codegen files should be embedded in the binary") orelse switch (b.graph.release_mode) {
        .off => false,
        else => true,
    };

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
        .reported_nodejs_version = try Version.parse(
            b.option([]const u8, "reported_nodejs_version", "Reported Node.js version") orelse
                bun_exe.nodejsVersionFromZon(b),
        ),
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
        .tracy_callstack_depth = b.option(u16, "tracy_callstack_depth", "") orelse 10,
        .enable_logs = b.option(bool, "enable_logs", "Enable logs in release") orelse (optimize == .Debug),
        .enable_fuzzilli = b.option(bool, "enable_fuzzilli", "Enable fuzzilli instrumentation") orelse false,
        .enable_valgrind = b.option(bool, "enable_valgrind", "Enable valgrind") orelse false,
        .enable_tinycc = b.option(bool, "enable_tinycc", "Enable TinyCC for FFI JIT compilation") orelse true,
        .use_mimalloc = b.option(bool, "use_mimalloc", "Use mimalloc as default allocator") orelse true,
        .android_ndk_sysroot = android_ndk_sysroot,
        .freebsd_sysroot_x86_64 = freebsd_sysroot_x86_64,
        .freebsd_sysroot_aarch64 = freebsd_sysroot_aarch64,
        .codegen = cg,
    };

    // The bun executable: codegen, C/C++, link, smoke test. Default step.
    {
        var o = build_options;
        // The executable and its C++ dependencies share the host target.
        o.target = b.graph.host;
        o.codegen_embed = mode == .release;
        o.cached_options_module = null;
        const obj = addBunObject(b, &o);

        const exe_opts: bun_exe.Options = .{
            .mode = mode,
            .version = bun_version,
            .sha = if (std.mem.eql(u8, build_options.sha, zero_sha)) null else build_options.sha,
            .target = o.target,
            .webkit = webkit_ctx,
            .icu = icu_ctx,
        };
        const archives = bun_exe.addCpp(b, pkgs, cg, exe_opts);
        const built = bun_exe.addLink(b, pkgs, archives, obj.getEmittedBin(), cg, exe_opts);
        // The executable is pinned to this target; fail loudly rather than
        // silently overriding an explicit -Dtarget/-Dcpu.
        if ((target_query.abi != null and target_query.abi.? != .gnu) or
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
        }, &.{.Debug});
    }

    // zig build check-all
    {
        const step = b.step("check-all", "Check for semantic analysis errors on all supported platforms");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .windows, .arch = .x86_64 },
            .{ .os = .windows, .arch = .aarch64 },
            .{ .os = .mac, .arch = .x86_64 },
            .{ .os = .mac, .arch = .aarch64 },
            .{ .os = .linux, .arch = .x86_64 },
            .{ .os = .linux, .arch = .aarch64 },
            .{ .os = .linux, .arch = .x86_64, .musl = true },
            .{ .os = .linux, .arch = .aarch64, .musl = true },
        }, &.{ .Debug, .ReleaseFast });
    }

    // zig build check-all-debug
    {
        const step = b.step("check-all-debug", "Check for semantic analysis errors on all supported platforms in debug mode");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .windows, .arch = .x86_64 },
            .{ .os = .windows, .arch = .aarch64 },
            .{ .os = .mac, .arch = .x86_64 },
            .{ .os = .mac, .arch = .aarch64 },
            .{ .os = .linux, .arch = .x86_64 },
            .{ .os = .linux, .arch = .aarch64 },
            .{ .os = .linux, .arch = .x86_64, .musl = true },
            .{ .os = .linux, .arch = .aarch64, .musl = true },
        }, &.{.Debug});
    }

    // zig build check-windows
    {
        const step = b.step("check-windows", "Check for semantic analysis errors on Windows");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .windows, .arch = .x86_64 },
            .{ .os = .windows, .arch = .aarch64 },
        }, &.{ .Debug, .ReleaseFast });
    }
    {
        const step = b.step("check-windows-debug", "Check for semantic analysis errors on Windows");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .windows, .arch = .x86_64 },
            .{ .os = .windows, .arch = .aarch64 },
        }, &.{.Debug});
    }
    {
        const step = b.step("check-macos", "Check for semantic analysis errors on macOS");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .mac, .arch = .x86_64 },
            .{ .os = .mac, .arch = .aarch64 },
        }, &.{ .Debug, .ReleaseFast });
    }
    {
        const step = b.step("check-macos-debug", "Check for semantic analysis errors on macOS in debug mode");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .mac, .arch = .x86_64 },
            .{ .os = .mac, .arch = .aarch64 },
        }, &.{.Debug});
    }
    {
        const step = b.step("check-linux", "Check for semantic analysis errors on Linux");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .linux, .arch = .x86_64 },
            .{ .os = .linux, .arch = .aarch64 },
        }, &.{ .Debug, .ReleaseFast });
    }
    {
        const step = b.step("check-linux-debug", "Check for semantic analysis errors on Linux in debug mode");
        addMultiCheck(b, step, build_options, &.{
            .{ .os = .linux, .arch = .x86_64 },
            .{ .os = .linux, .arch = .aarch64 },
        }, &.{.Debug});
    }
    // check-android needs the NDK sysroot for translate-c (zig doesn't
    // bundle bionic headers). Skip step creation entirely when none was
    // passed, so plain `zig build check` doesn't try to construct a
    // translate-c step that would panic.
    if (android_ndk_sysroot != null) {
        {
            const step = b.step("check-android", "Check for semantic analysis errors on Android");
            addMultiCheck(b, step, build_options, &.{
                .{ .os = .linux, .arch = .x86_64, .android = true },
                .{ .os = .linux, .arch = .aarch64, .android = true },
            }, &.{ .Debug, .ReleaseFast });
        }
        {
            const step = b.step("check-android-debug", "Check for semantic analysis errors on Android");
            addMultiCheck(b, step, build_options, &.{
                .{ .os = .linux, .arch = .x86_64, .android = true },
                .{ .os = .linux, .arch = .aarch64, .android = true },
            }, &.{.Debug});
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
            }, &.{ .Debug, .ReleaseFast });
        }
        {
            const step = b.step("check-freebsd-debug", "Check for semantic analysis errors on FreeBSD");
            addMultiCheck(b, step, build_options, &.{
                .{ .os = .freebsd, .arch = .x86_64 },
                .{ .os = .freebsd, .arch = .aarch64 },
            }, &.{.Debug});
        }
    }
    {
        const step = b.step("check-wasm", "Check the WebAssembly transpiler subset for semantic analysis errors");
        const wasm_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .cpu_model = .baseline,
            .os_tag = .freestanding,
        });
        inline for (.{ std.builtin.OptimizeMode.Debug, std.builtin.OptimizeMode.ReleaseFast }) |wasm_mode| {
            var options: BunBuildOptions = .{
                .target = wasm_target,
                .optimize = wasm_mode,
                .os = .wasm,
                .arch = .wasm32,
                .version = build_options.version,
                .canary_revision = build_options.canary_revision,
                .sha = build_options.sha,
                .enable_logs = build_options.enable_logs,
                .enable_fuzzilli = false,
                .enable_valgrind = false,
                .enable_tinycc = false,
                .use_mimalloc = build_options.use_mimalloc,
                .tracy_callstack_depth = build_options.tracy_callstack_depth,
                .reported_nodejs_version = build_options.reported_nodejs_version,
                .codegen_embed = build_options.codegen_embed,
                .codegen_path = build_options.codegen_path,
                .codegen = build_options.codegen,
                .override_no_export_cpp_apis = true,
            };
            var obj = addBunWasmObject(b, &options);
            obj.generated_bin = .none;
            step.dependOn(&obj.step);
        }
    }

    // zig build enum-extractor
    {
        // const step = b.step("enum-extractor", "Extract enum definitions (invoked by a code generator)");
        // const exe = b.addExecutable(.{
        //     .name = "enum_extractor",
        //     .root_source_file = b.path("./src/generated_enum_extractor.zig"),
        //     .target = b.graph.host,
        //     .optimize = .Debug,
        // });
        // const run = b.addRunArtifact(exe);
        // step.dependOn(&run.step);
    }

    // zig build generate-grapheme-tables
    // Regenerates src/string/immutable/grapheme_tables.zig from the vendored uucode.
    // Run this when updating src/unicode/uucode_lib. Normal builds use the committed file.
    {
        const step = b.step("generate-grapheme-tables", "Regenerate grapheme property tables from vendored uucode");

        // --- Phase 1: Build uucode tables (separate module graph, no tables dependency) ---
        const bt_config_mod = b.createModule(.{
            .root_source_file = b.path("src/unicode/uucode_lib/src/config.zig"),
            .target = b.graph.host,
        });
        const bt_types_mod = b.createModule(.{
            .root_source_file = b.path("src/unicode/uucode_lib/src/types.zig"),
            .target = b.graph.host,
        });
        bt_types_mod.addImport("config.zig", bt_config_mod);
        bt_config_mod.addImport("types.zig", bt_types_mod);

        const bt_config_x_mod = b.createModule(.{
            .root_source_file = b.path("src/unicode/uucode_lib/src/x/config.x.zig"),
            .target = b.graph.host,
        });
        const bt_types_x_mod = b.createModule(.{
            .root_source_file = b.path("src/unicode/uucode_lib/src/x/types.x.zig"),
            .target = b.graph.host,
        });
        bt_types_x_mod.addImport("config.x.zig", bt_config_x_mod);
        bt_config_x_mod.addImport("types.x.zig", bt_types_x_mod);
        bt_config_x_mod.addImport("types.zig", bt_types_mod);
        bt_config_x_mod.addImport("config.zig", bt_config_mod);

        const bt_build_config_mod = b.createModule(.{
            .root_source_file = b.path("src/unicode/uucode/uucode_config.zig"),
            .target = b.graph.host,
        });
        bt_build_config_mod.addImport("types.zig", bt_types_mod);
        bt_build_config_mod.addImport("config.zig", bt_config_mod);
        bt_build_config_mod.addImport("types.x.zig", bt_types_x_mod);
        bt_build_config_mod.addImport("config.x.zig", bt_config_x_mod);

        const build_tables_mod = b.createModule(.{
            .root_source_file = b.path("src/unicode/uucode_lib/src/build/tables.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        });
        build_tables_mod.addImport("config.zig", bt_config_mod);
        build_tables_mod.addImport("build_config", bt_build_config_mod);
        build_tables_mod.addImport("types.zig", bt_types_mod);

        const build_tables_exe = b.addExecutable(.{
            .name = "uucode_build_tables",
            .root_module = build_tables_mod,
            .use_llvm = true,
        });
        const run_build_tables = b.addRunArtifact(build_tables_exe);
        run_build_tables.setCwd(b.path("src/unicode/uucode_lib"));
        const tables_path = run_build_tables.addOutputFileArg("tables.zig");

        // --- Phase 2: Build grapheme-gen with full uucode (separate module graph) ---
        const rt_config_mod = b.createModule(.{
            .root_source_file = b.path("src/unicode/uucode_lib/src/config.zig"),
            .target = b.graph.host,
        });
        const rt_types_mod = b.createModule(.{
            .root_source_file = b.path("src/unicode/uucode_lib/src/types.zig"),
            .target = b.graph.host,
        });
        rt_types_mod.addImport("config.zig", rt_config_mod);
        rt_config_mod.addImport("types.zig", rt_types_mod);

        const rt_config_x_mod = b.createModule(.{
            .root_source_file = b.path("src/unicode/uucode_lib/src/x/config.x.zig"),
            .target = b.graph.host,
        });
        const rt_types_x_mod = b.createModule(.{
            .root_source_file = b.path("src/unicode/uucode_lib/src/x/types.x.zig"),
            .target = b.graph.host,
        });
        rt_types_x_mod.addImport("config.x.zig", rt_config_x_mod);
        rt_config_x_mod.addImport("types.x.zig", rt_types_x_mod);
        rt_config_x_mod.addImport("types.zig", rt_types_mod);
        rt_config_x_mod.addImport("config.zig", rt_config_mod);

        const rt_build_config_mod = b.createModule(.{
            .root_source_file = b.path("src/unicode/uucode/uucode_config.zig"),
            .target = b.graph.host,
        });
        rt_build_config_mod.addImport("types.zig", rt_types_mod);
        rt_build_config_mod.addImport("config.zig", rt_config_mod);
        rt_build_config_mod.addImport("types.x.zig", rt_types_x_mod);
        rt_build_config_mod.addImport("config.x.zig", rt_config_x_mod);

        const rt_tables_mod = b.createModule(.{
            .root_source_file = tables_path,
            .target = b.graph.host,
        });
        rt_tables_mod.addImport("types.zig", rt_types_mod);
        rt_tables_mod.addImport("types.x.zig", rt_types_x_mod);
        rt_tables_mod.addImport("config.zig", rt_config_mod);
        rt_tables_mod.addImport("build_config", rt_build_config_mod);

        const rt_get_mod = b.createModule(.{
            .root_source_file = b.path("src/unicode/uucode_lib/src/get.zig"),
            .target = b.graph.host,
        });
        rt_get_mod.addImport("types.zig", rt_types_mod);
        rt_get_mod.addImport("tables", rt_tables_mod);
        rt_types_mod.addImport("get.zig", rt_get_mod);

        const uucode_mod = b.createModule(.{
            .root_source_file = b.path("src/unicode/uucode_lib/src/root.zig"),
            .target = b.graph.host,
        });
        uucode_mod.addImport("types.zig", rt_types_mod);
        uucode_mod.addImport("config.zig", rt_config_mod);
        uucode_mod.addImport("types.x.zig", rt_types_x_mod);
        uucode_mod.addImport("tables", rt_tables_mod);
        uucode_mod.addImport("get.zig", rt_get_mod);

        // grapheme_gen executable
        const gen_exe = b.addExecutable(.{
            .name = "grapheme-gen",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/unicode/uucode/grapheme_gen.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
                .imports = &.{
                    .{ .name = "uucode", .module = uucode_mod },
                },
            }),
            .use_llvm = true,
        });

        const run_gen = b.addRunArtifact(gen_exe);
        const gen_output = run_gen.captureStdOut(.{});

        const install = b.addInstallFile(gen_output, "../src/string/immutable/grapheme_tables.zig");
        step.dependOn(&install.step);
    }
}

const TargetDescription = struct {
    os: OperatingSystem,
    arch: Arch,
    musl: bool = false,
    android: bool = false,

    fn resolveTarget(desc: TargetDescription, b: *Build) std.Build.ResolvedTarget {
        return b.resolveTargetQuery(.{
            .os_tag = OperatingSystem.stdOSTag(desc.os),
            .cpu_arch = desc.arch,
            .cpu_model = getCpuModel(desc.os, desc.arch) orelse .determined_by_arch_os,
            .os_version_min = getOSVersionMin(desc.os),
            .abi = if (desc.android) .android else if (desc.musl) .musl else null,
        });
    }
};

fn addMultiCheck(
    b: *Build,
    parent_step: *Step,
    root_build_options: BunBuildOptions,
    to_check: []const TargetDescription,
    optimize: []const std.builtin.OptimizeMode,
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
                .tracy_callstack_depth = root_build_options.tracy_callstack_depth,
                .version = root_build_options.version,
                .reported_nodejs_version = root_build_options.reported_nodejs_version,
                .codegen_path = root_build_options.codegen_path,
                .enable_valgrind = root_build_options.enable_valgrind,
                .enable_tinycc = root_build_options.enable_tinycc,
                .enable_fuzzilli = root_build_options.enable_fuzzilli,
                .use_mimalloc = root_build_options.use_mimalloc,
                .override_no_export_cpp_apis = root_build_options.override_no_export_cpp_apis,
                .android_ndk_sysroot = root_build_options.android_ndk_sysroot,
                .freebsd_sysroot_x86_64 = root_build_options.freebsd_sysroot_x86_64,
                .freebsd_sysroot_aarch64 = root_build_options.freebsd_sysroot_aarch64,
                .codegen = root_build_options.codegen,
            };

            var obj = addBunObject(b, &options);
            obj.generated_bin = .none;
            parent_step.dependOn(&obj.step);
        }
    }
}

fn getTranslateC(b: *Build, initial_target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, android_ndk_sysroot: ?[]const u8, freebsd_sysroot: ?[]const u8) LazyPath {
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
        .{ "MUSL", target.query.abi != null and target.query.abi.?.isMusl() },
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
                .optimize = .Debug,
            }),
        });
        const in = translate_c.getOutput();
        const run = b.addRunArtifact(helper_exe);
        run.addFileArg(in);
        const out = run.addOutputFileArg("c-headers-for-zig.zig");
        return out;
    }
    return translate_c.getOutput();
}

pub fn addBunObject(b: *Build, opts: *BunBuildOptions) *Compile {
    // Create `@import("bun")`, containing most of Bun's code.
    const bun = b.createModule(.{
        .root_source_file = b.path("src/bun.zig"),
    });
    bun.addImport("bun", bun); // allow circular "bun" import
    addInternalImports(b, bun, opts);

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),

        // Root module gets compilation flags. Forwarded as default to dependencies.
        .target = opts.target,
        .optimize = opts.optimize,
    });
    root.addImport("bun", bun);

    const obj = b.addObject(.{
        .name = if (opts.optimize == .Debug) "bun-debug" else "bun",
        .root_module = root,
    });
    configureObj(b, opts, obj);
    // Generated imports come from the stable synced dir.
    obj.step.dependOn(opts.codegen.sync_step);
    return obj;
}

fn addBunWasmObject(b: *Build, opts: *BunBuildOptions) *Compile {
    const bun = b.createModule(.{
        .root_source_file = b.path("src/bun.zig"),
    });
    bun.addImport("bun", bun);
    addInternalImports(b, bun, opts);

    const root = b.createModule(.{
        .root_source_file = b.path("src/main_wasm.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .single_threaded = true,
    });
    root.addImport("bun", bun);

    const obj = b.addObject(.{
        .name = if (opts.optimize == .Debug) "bun-wasm-debug" else "bun-wasm",
        .root_module = root,
    });
    configureObj(b, opts, obj);
    obj.step.dependOn(opts.codegen.sync_step);
    return obj;
}

fn configureObj(b: *Build, opts: *BunBuildOptions, obj: *Compile) void {
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

    if (opts.enable_fuzzilli) {
        const fail_step = b.addFail("fuzzilli requires an ASan build, which is not currently supported");
        obj.step.dependOn(&fail_step.step);
    }
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

        if (opts.optimize == .Debug and opts.enable_valgrind) {
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

fn addInternalImports(b: *Build, mod: *Module, opts: *BunBuildOptions) void {
    const os = opts.os;

    mod.addImport("build_options", opts.buildOptionsModule(b));

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
        .{ .file = "ZigGeneratedClasses.zig", .import = "ZigGeneratedClasses" },
        .{ .file = "bindgen_generated.zig", .import = "bindgen_generated" },
        .{ .file = "ResolvedSourceTag.zig", .import = "ResolvedSourceTag" },
        .{ .file = "ErrorCode.zig", .import = "ErrorCode" },
        .{ .file = "runtime.out.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "bake.client.js", .import = "bake-codegen/bake.client.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "bake.error.js", .import = "bake-codegen/bake.error.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "bake.server.js", .import = "bake-codegen/bake.server.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "bun-error/index.js", .enable = opts.shouldEmbedCode() },
        .{ .file = "bun-error/bun-error.css", .enable = opts.shouldEmbedCode() },
        .{ .file = "fallback-decoder.js", .enable = opts.shouldEmbedCode() },
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
        const cppImport = b.createModule(.{
            .root_source_file = (std.Build.LazyPath{ .cwd_relative = opts.codegen_path }).path(b, "cpp.zig"),
        });
        mod.addImport("cpp", cppImport);
        cppImport.addImport("bun", mod);
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
    propagateImports(mod) catch @panic("OOM");
}

/// Makes all imports of `source_mod` visible to all of its dependencies.
/// Does not replace existing imports.
fn propagateImports(source_mod: *Module) !void {
    var seen = std.AutoHashMap(*Module, void).init(source_mod.owner.graph.arena);
    defer seen.deinit();
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
                .optimize = .ReleaseFast,
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
                .optimize = .Debug,
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
