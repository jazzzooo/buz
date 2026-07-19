//! The `zig build` graph for the bun executable: codegen (pinned bootstrap
//! bun) → C/C++ (zig cc) → link (pinned mold) → smoke test. x86_64-linux.
//!
//! Downloaded inputs are pinned in build.zig.zon: the bootstrap bun, Node.js
//! headers, mold, and the ICU and dep source archives; WebKit is vendored
//! in-tree. C++ compiles against zig's bundled libc++, and the C++ runtime
//! in the link comes from zig's cache (discoverZigCxxRuntime). The host is
//! assumed to be a native FHS glibc Linux: headers come from /usr/include,
//! the dynamic linker is /lib64/ld-linux-x86-64.so.2, and git applies dep
//! patches. Per-dep compile recipes live in src/build/deps/; this file owns
//! policy (per-mode base flags, include chains, the link line, output
//! layout).
//!
//! Outputs land in zig-out/bin. Codegen is consumed through stable
//! directories under build/zig/<mode>/, mirrored copy-if-changed from the
//! cached step outputs by a sync step: a step's cache-output directory path
//! changes whenever its inputs change, even when the output content didn't,
//! so compiles key on the stable files' content instead. Debug binaries also
//! load JS builtins and the bake runtime from these directories at runtime.

const std = @import("std");
const builtin = @import("builtin");
const recipes = @import("deps/deps.zig");

const Build = std.Build;
const Step = Build.Step;
const LazyPath = Build.LazyPath;

pub const Mode = enum { debug, release };

/// Patches applied to vendored dep sources before compiling. Entries that are
/// not .patch files are overlays copied into the source root.
const dep_patches = [_]struct { dep: []const u8, files: []const []const u8 }{
    .{ .dep = "zlib", .files = &.{"patches/zlib/clang-cl-arm64.patch"} },
    .{ .dep = "libarchive", .files = &.{
        "patches/libarchive/archive_write_add_filter_gzip.c.patch",
        "patches/libarchive/nonblocking-read.patch",
    } },
    .{ .dep = "libjpeg-turbo", .files = &.{
        "patches/libjpeg-turbo/8bit-only.patch",
        "patches/libjpeg-turbo/jbun_stubs.c",
    } },
    .{ .dep = "hdrhistogram", .files = &.{"patches/hdrhistogram/bitscan-type.patch"} },
    .{ .dep = "highway", .files = &.{"patches/highway/silence-warnings.patch"} },
    .{ .dep = "lshpack", .files = &.{"patches/lshpack/bss-huff-tables.patch"} },
    .{ .dep = "lsqpack", .files = &.{"patches/lsqpack/bss-huff-tables.patch"} },
    .{ .dep = "lsquic", .files = &.{
        "patches/lsquic/versions-to-string.patch",
        "patches/lsquic/allow-no-sni.patch",
        "patches/lsquic/skip-priority-walk.patch",
        "patches/lsquic/disable-gquic.patch",
    } },
    .{ .dep = "tinycc", .files = &.{"patches/tinycc/tcc.h.patch"} },
};

/// Files that must compile standalone instead of joining a unified bundle:
/// heavy TUs that saturate a core alone, files with file-static name
/// collisions, and files whose conditional compilation is corrupted by
/// macros leaking from bundle siblings.
const no_unify = [_][]const u8{
    "src/jsc/bindings/ZigGlobalObject.cpp",
    "src/jsc/bindings/BunObject.cpp",
    "src/jsc/bindings/bindings.cpp",
    "src/jsc/bindings/BunProcess.cpp",
    "src/jsc/bindings/JSBuffer.cpp",
    "src/jsc/bindings/napi.cpp",
    "src/jsc/bindings/webcore/SerializedScriptValue.cpp",
    "src/jsc/bindings/webcore/HTTPParsers.cpp",
    "src/jsc/bindings/webcore/JSMIMEType.cpp",
    "src/jsc/bindings/webcore/JSWasmStreamingCompiler.cpp",
    "src/jsc/bindings/webcore/JSDOMPromiseDeferred.cpp",
    "src/jsc/bindings/webcore/JSMessageEventCustom.cpp",
    "src/jsc/bindings/sqlite/JSSQLStatement.cpp",
    "src/jsc/bindings/webcrypto/CryptoAlgorithmAES_CBC.cpp",
    "src/jsc/bindings/webcrypto/CryptoAlgorithmAES_CBCOpenSSL.cpp",
    "src/jsc/bindings/webcrypto/CryptoAlgorithmAES_CFB.cpp",
    "src/jsc/bindings/webcrypto/CryptoAlgorithmAES_CFBOpenSSL.cpp",
    "src/jsc/bindings/webcrypto/CryptoAlgorithmAES_CTR.cpp",
    "src/jsc/bindings/webcrypto/CryptoAlgorithmAES_CTROpenSSL.cpp",
    "src/jsc/bindings/webcrypto/CryptoAlgorithmAES_GCM.cpp",
    "src/jsc/bindings/webcrypto/CryptoAlgorithmAES_GCMOpenSSL.cpp",
    "src/jsc/bindings/webcrypto/CryptoAlgorithmAES_KW.cpp",
    "src/jsc/bindings/webcrypto/CryptoAlgorithmECDSA.cpp",
    "src/jsc/bindings/webcrypto/CryptoAlgorithmHMAC.cpp",
    "src/jsc/bindings/webcrypto/CryptoAlgorithmRSAES_PKCS1_v1_5.cpp",
    "src/jsc/bindings/webcrypto/CryptoAlgorithmRSASSA_PKCS1_v1_5.cpp",
    "src/jsc/bindings/webcrypto/CryptoAlgorithmRSA_OAEP.cpp",
    "src/jsc/bindings/webcrypto/CryptoAlgorithmRSA_PSS.cpp",
    "src/jsc/bindings/webcrypto/SubtleCrypto.cpp",
    "src/jsc/bindings/ProcessBindingUV.cpp",
    "src/jsc/bindings/ProcessBindingConstants.cpp",
    "src/jsc/bindings/workaround-missing-symbols.cpp",
    "packages/bun-usockets/src/crypto/root_certs_windows.cpp",
    "packages/bun-usockets/src/crypto/root_certs_darwin.cpp",
    "src/jsc/bindings/image_resize.cpp",
    "src/jsc/bindings/image_coregraphics_shim.cpp",
    "src/jsc/bindings/image_wic_shim.cpp",
};

/// Directories scanned (non-recursively) for bun's own C++ sources.
const cxx_dirs = [_][]const u8{
    "src/io",
    "src/jsc/modules",
    "src/jsc/bindings",
    "src/jsc/bindings/webcore",
    "src/jsc/bindings/sqlite",
    "src/jsc/bindings/webcrypto",
    "src/jsc/bindings/node",
    "src/jsc/bindings/node/crypto",
    "src/jsc/bindings/node/http",
    "src/jsc/bindings/v8",
    "src/jsc/bindings/v8/shim",
    "src/runtime/webview",
    "src/bake",
    "src/uws_sys",
    "src/simdutf_sys",
    "src/jsc/bindings/vm",
    "packages/bun-usockets/src/crypto",
};

/// Directories scanned (non-recursively) for bun's own C sources.
const c_dirs = [_][]const u8{
    "packages/bun-usockets/src",
    "packages/bun-usockets/src/eventing",
    "packages/bun-usockets/src/internal",
    "packages/bun-usockets/src/crypto",
    "src",
    "src/jsc/bindings/node/http/llhttp",
};

/// Individually listed C sources outside the directory scans.
const c_files = [_][]const u8{
    "src/jsc/bindings/uv-posix-polyfills.c",
    "src/jsc/bindings/uv-posix-stubs.c",
};

pub const Options = struct {
    /// Debug/release feature configuration, independent of optimization.
    mode: Mode,
    optimize: std.builtin.OptimizeMode,
    codegen_embed: bool,
    /// `Bun.version`, from package.json unless overridden.
    version: []const u8,
    /// 40-hex git sha or null. Baked into bun_dependency_versions.h for
    /// process.versions.uws/usockets; CI passes it, dev builds stay null so
    /// commits don't invalidate compiles.
    sha: ?[]const u8,
    target: Build.ResolvedTarget,
    /// WTF/bmalloc/JSC compiled from vendor/webkit plus the vendored header
    /// set.
    webkit: *const @import("webkit.zig").Ctx,
    /// ICU compiled from the pinned source tarball.
    icu: *const @import("icu.zig").Ctx,
};

/// What downstream consumers need from codegen.
pub const Codegen = struct {
    /// Generated .cpp files, compiled straight from their generating steps.
    cpp_sources: []const LazyPath,
    /// Absolute path of the stable codegen dir; baked as
    /// build_options.codegen_path and used as -I for C/C++.
    codegen_install_abs: []const u8,
    /// Absolute path baked as BUN_DYNAMIC_JS_LOAD_PATH (debug builtin JS).
    js_install_abs: []const u8,
    /// Absolute path of the stable dir holding the precompiled header.
    pch_install_abs: []const u8,
    /// Mirrors step outputs into the stable dirs. Everything that reads the
    /// stable dirs must depend on it.
    sync_step: *Step,
};

pub const DepPkgs = struct {
    bun: LazyPath, // bootstrap bun executable
    bun_dir_abs: []const u8, // its directory (prepended to PATH for scripts)
    mold: LazyPath, // pinned linker
    icu: *Build.Dependency, // ICU sources (see src/build/icu.zig)
    /// Node.js headers with the bundled openssl/uv headers deleted (they
    /// would shadow BoringSSL's and bun's own uv shims).
    nodejs: LazyPath,
    /// dep name → source root to compile from (patched copy when needed).
    srcs: std.StringArrayHashMapUnmanaged(LazyPath),
    /// dep name → absolute path of the pristine zon package, for
    /// configure-time reads of files patches don't touch (*.h.in templates).
    srcs_abs: std.StringArrayHashMapUnmanaged([]const u8),
};

pub const BunExe = struct {
    /// The linked executable (bun-debug / bun-profile).
    exe: LazyPath,
    /// Built + installed + smoke-tested.
    step: *Step,
};

// ───────────────────────────────────────────────────────────────────────────
// Entry points called from build.zig
// ───────────────────────────────────────────────────────────────────────────

/// Resolve all zon dependencies. Returns null while lazy fetches are pending;
/// every missing dependency is marked before returning, so the runner fetches
/// them in one round and re-runs configure.
pub fn resolveDeps(b: *Build, mode: Mode) ?DepPkgs {
    const arena = b.graph.arena;
    var ok = true;
    const bootstrap = lazyDep(b, "bun_bootstrap", &ok);
    _ = mode;
    const icu = lazyDep(b, "icu", &ok);
    const nodejs = lazyDep(b, "nodejs_headers", &ok);
    const mold = lazyDep(b, "mold", &ok);
    var pkgs: std.StringArrayHashMapUnmanaged(*Build.Dependency) = .empty;
    for (recipes.all) |dep| {
        if (dep.in_tree) continue;
        const pkg = lazyDep(b, zonName(b, dep.name), &ok) orelse continue;
        pkgs.put(arena, dep.name, pkg) catch @panic("OOM");
    }
    if (!ok) return null;

    // The fetcher strips each archive's single root directory.
    const bun_exe = bootstrap.?.path("bun");
    var srcs: std.StringArrayHashMapUnmanaged(LazyPath) = .empty;
    var srcs_abs: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (pkgs.keys(), pkgs.values()) |name, pkg| {
        srcs.put(arena, name, patchedRoot(b, name, bun_exe, pkg.path(""))) catch @panic("OOM");
        srcs_abs.put(arena, name, depRootAbs(b, pkg)) catch @panic("OOM");
    }

    const nodejs_headers = blk: {
        const run = b.addRunFile(bun_exe);
        run.addFileArg(b.path("src/build/apply-patches.ts"));
        run.addDirectoryArg(nodejs.?.path(""));
        const out = run.addOutputDirectoryArg("nodejs-headers");
        run.addArgs(&.{ "--delete=include/node/openssl", "--delete=include/node/uv", "--delete=include/node/uv.h" });
        run.step.name = "strip nodejs bundled headers";
        break :blk out;
    };

    const bun_dir_abs = depRootAbs(b, bootstrap.?);
    return .{
        .bun = bun_exe,
        .bun_dir_abs = bun_dir_abs,
        .mold = mold.?.path("bin/mold"),
        .icu = icu.?,
        .nodejs = nodejs_headers,
        .srcs = srcs,
        .srcs_abs = srcs_abs,
    };
}

fn depRootAbs(b: *Build, dep: *Build.Dependency) []const u8 {
    // Package roots (zig-pkg/<hash>) render relative to the build root.
    const root = dep.builder.root.toString(b.graph.arena) catch @panic("OOM");
    if (std.fs.path.isAbsolute(root)) return root;
    return rootJoin(b, root);
}

fn rootJoin(b: *Build, rel: []const u8) []const u8 {
    const root = b.root.toString(b.graph.arena) catch @panic("OOM");
    return std.fs.path.join(b.graph.arena, &.{ root, rel }) catch @panic("OOM");
}

fn lazyDep(b: *Build, name: []const u8, ok: *bool) ?*Build.Dependency {
    const dep = b.lazyDependency(name, .{}) orelse {
        ok.* = false;
        return null;
    };
    return dep;
}

fn zonName(b: *Build, dep_name: []const u8) []const u8 {
    // zon identifiers use underscores (libjpeg-turbo → libjpeg_turbo).
    const buf = b.graph.arena.dupe(u8, dep_name) catch @panic("OOM");
    for (buf) |*c| {
        if (c.* == '-') c.* = '_';
    }
    return buf;
}

/// For patched deps, a copied+patched source tree in a fresh cached output
/// dir (the zon package itself is immutable); otherwise the package root.
fn patchedRoot(b: *Build, dep_name: []const u8, bun: LazyPath, pkg_root: LazyPath) LazyPath {
    const patches: []const []const u8 = for (dep_patches) |p| {
        if (std.mem.eql(u8, p.dep, dep_name)) break p.files;
    } else return pkg_root;

    const run = b.addRunFile(bun);
    run.addFileArg(b.path("src/build/apply-patches.ts"));
    run.addDirectoryArg(pkg_root);
    const out = run.addOutputDirectoryArg(dep_name);
    for (patches) |p| run.addFileArg(b.path(p));
    run.step.name = b.fmt("patch {s}", .{dep_name});
    return out;
}

/// Version strings surfaced through bun_dependency_versions.h
/// (process.versions.*), derived from the pinned URLs in build.zig.zon.
/// key → { header name, zon dependency }; the value is extracted from the
/// dependency's URL.
const version_sources = [_][2][]const u8{
    .{ "PICOHTTPPARSER", "picohttpparser" },
    .{ "ZLIB_HASH", "zlib" },
    .{ "ZSTD_HASH", "zstd" },
    .{ "LIBDEFLATE_HASH", "libdeflate" },
    .{ "LIBARCHIVE", "libarchive" },
    .{ "LIBJPEG_TURBO", "libjpeg_turbo" },
    .{ "LIBSPNG", "libspng" },
    .{ "LIBWEBP", "libwebp" },
    .{ "C_ARES", "cares" },
    .{ "LOLHTML", "lolhtml" },
    .{ "LSHPACK", "lshpack" },
    .{ "LSQPACK", "lsqpack" },
    .{ "MIMALLOC", "mimalloc" },
    .{ "TINYCC", "tinycc" },
    .{ "BORINGSSL", "boringssl" },
    .{ "LSQUIC", "lsquic" },
};

/// The pinned URL of a build.zig.zon dependency. Textual scan rather than a
/// typed ZON import: the import would need the manifest's full struct shape
/// spelled out and break on unrelated additions.
fn zonUrl(b: *Build, dep_name: []const u8) []const u8 {
    const S = struct {
        var content: ?[]const u8 = null;
    };
    const content = S.content orelse blk: {
        const c = readRootFile(b, "build.zig.zon");
        b.dependOnFileContents(b.path("build.zig.zon"));
        S.content = c;
        break :blk c;
    };
    const key = b.fmt(".{s} = .{{", .{dep_name});
    const start = std.mem.indexOf(u8, content, key) orelse
        std.debug.panic("build.zig.zon: missing dependency {s}", .{dep_name});
    const url_key = ".url = \"";
    const url_start = (std.mem.indexOfPos(u8, content, start, url_key) orelse
        std.debug.panic("build.zig.zon: {s} has no url", .{dep_name})) + url_key.len;
    const url_end = std.mem.indexOfScalarPos(u8, content, url_start, '"').?;
    return content[url_start..url_end];
}

/// The ref a pinned source-archive URL points at: the path segment before
/// ".tar.gz"/".zip" for /archive/<ref> URLs, the "autobuild-<hash>" tag for
/// WebKit, "vX.Y.Z" for the Node headers.
/// The oven-sh/WebKit commit recorded in vendor/webkit/VENDOR.
fn webkitVendorCommit(b: *Build) []const u8 {
    const arena = b.graph.arena;
    const io = b.graph.io;
    var dir = std.Io.Dir.openDirAbsolute(io, rootJoin(b, "vendor/webkit"), .{}) catch @panic("open vendor/webkit");
    defer dir.close(io);
    const text = dir.readFileAlloc(io, "VENDOR", arena, .limited(64 * 1024)) catch @panic("read vendor/webkit/VENDOR");
    const marker = "commit: ";
    const start = (std.mem.indexOf(u8, text, marker) orelse @panic("no commit in VENDOR")) + marker.len;
    const end = std.mem.indexOfAnyPos(u8, text, start, " \n") orelse text.len;
    return text[start..end];
}

fn zonRef(b: *Build, dep_name: []const u8) []const u8 {
    const url = zonUrl(b, dep_name);
    if (std.mem.indexOf(u8, url, "autobuild-")) |i| {
        const start = i + "autobuild-".len;
        return url[start..std.mem.indexOfScalarPos(u8, url, start, '/').?];
    }
    if (std.mem.indexOf(u8, url, "/node-v")) |i| {
        const start = i + "/node-v".len;
        return url[start..std.mem.indexOf(u8, url, "-headers").?];
    }
    const last_slash = std.mem.lastIndexOfScalar(u8, url, '/').?;
    var ref = url[last_slash + 1 ..];
    for ([_][]const u8{ ".tar.gz", ".tar.xz", ".tgz", ".zip" }) |suffix| {
        if (std.mem.endsWith(u8, ref, suffix)) ref = ref[0 .. ref.len - suffix.len];
    }
    return ref;
}

/// Default Node.js compatibility version, from the pinned headers URL.
pub fn nodejsVersionFromZon(b: *Build) []const u8 {
    return zonRef(b, "nodejs_headers");
}

// ───────────────────────────────────────────────────────────────────────────
// Codegen
// ───────────────────────────────────────────────────────────────────────────

const SyncPairs = struct {
    run: *Step.Run,

    fn add(sp: *SyncPairs, src: LazyPath, dest_rel: []const u8) void {
        sp.run.addDirectoryArg(src);
        sp.run.addArg(dest_rel);
    }
    fn addFile(sp: *SyncPairs, src: LazyPath, dest_rel: []const u8) void {
        sp.run.addFileArg(src);
        sp.run.addArg(dest_rel);
    }
};

pub fn addCodegen(b: *Build, deps: *const DepPkgs, mode: Mode) *Codegen {
    const arena = b.graph.arena;
    const cg = arena.create(Codegen) catch @panic("OOM");

    const stable_root = rootJoin(b, b.fmt("build/zig/{s}", .{@tagName(mode)}));
    const sync = b.addRunFile(deps.bun);
    sync.addFileArg(b.path("src/build/sync-dirs.ts"));
    sync.addArg(stable_root);
    sync.has_side_effects = true;
    sync.step.name = "sync codegen";
    var sp: SyncPairs = .{ .run = sync };

    cg.* = .{
        .cpp_sources = &.{},
        .codegen_install_abs = std.fs.path.join(arena, &.{ stable_root, "codegen" }) catch @panic("OOM"),
        .js_install_abs = std.fs.path.join(arena, &.{ stable_root, "js" }) catch @panic("OOM"),
        .pch_install_abs = std.fs.path.join(arena, &.{ stable_root, "pch" }) catch @panic("OOM"),
        .sync_step = &sync.step,
    };

    var cpp_sources: std.ArrayList(LazyPath) = .empty;

    const install_root = bunInstall(b, deps, "");
    const install_bun_error = bunInstall(b, deps, "packages/bun-error");
    const install_node_fallbacks = bunInstall(b, deps, "src/node-fallbacks");

    const esbuild = b.path("node_modules/.bin/esbuild");
    const debug_flag = if (mode == .debug) "--debug=ON" else "--debug=OFF";

    // ─── generate-node-errors.ts <outdir> ───
    const node_errors_dir = blk: {
        const run = script(b, deps, "src/codegen/generate-node-errors.ts", .{ .use_run = true });
        run.addFileInput(b.path("src/jsc/bindings/ErrorCode.ts"));
        run.addFileInput(b.path("src/jsc/bindings/ErrorCode.cpp"));
        run.addFileInput(b.path("src/jsc/bindings/ErrorCode.h"));
        break :blk run.addOutputDirectoryArg("codegen");
    };
    sp.add(node_errors_dir, "codegen");

    // ─── generate-classes.ts <classes...> <outdir> ───
    const classes_dir = blk: {
        const run = script(b, deps, "src/codegen/generate-classes.ts", .{ .use_run = true });
        run.addFileInput(b.path("src/jsc/bindings/js_classes.ts"));
        for (listFiles(b, "src", ".classes.ts", true)) |f| run.addFileArg(b.path(f));
        break :blk run.addOutputDirectoryArg("codegen");
    };
    cpp_sources.append(arena, classes_dir.path(b, "ZigGeneratedClasses.cpp")) catch @panic("OOM");
    sp.add(classes_dir, "codegen");

    // ─── bundle-modules.ts --debug=X <BUILD_PATH> ───
    const bundle_dir = blk: {
        const run = script(b, deps, "src/codegen/bundle-modules.ts", .{ .use_run = true });
        run.addArg(debug_flag);
        const out = run.addOutputDirectoryArg("bundle-modules");
        for (listFiles(b, "src/js", ".ts", true)) |f| run.addFileInput(b.path(f));
        for (listFiles(b, "src/js", ".js", true)) |f| run.addFileInput(b.path(f));
        run.addFileInput(b.path("src/install/PackageManager/scanner-entry.ts"));
        run.addFileInput(b.path("src/jsc/bindings/js_classes.ts"));
        run.addFileInput(b.path("src/jsc/bindings/InternalModuleRegistry.cpp"));
        break :blk out;
    };
    const bundle_codegen = bundle_dir.path(b, "codegen");
    cpp_sources.append(arena, bundle_codegen.path(b, "WebCoreJSBuiltins.cpp")) catch @panic("OOM");
    sp.add(bundle_codegen, "codegen");
    if (mode == .debug) sp.add(bundle_dir.path(b, "js"), "js");

    // GeneratedJS2Native.zig lives in the source tree (relative imports).
    // Copying from the step output keeps it present even when the step is
    // skipped by a cache hit.
    const usf = b.addUpdateSourceFiles();
    usf.addCopyFileToSource(bundle_codegen.path(b, "GeneratedJS2Native.zig"), "src/jsc/bindings/GeneratedJS2Native.zig");
    sync.step.dependOn(&usf.step);

    // ─── generate-jssink.ts <outdir> ───
    const jssink_dir = blk: {
        const run = script(b, deps, "src/codegen/generate-jssink.ts", .{ .use_run = true });
        run.addFileInput(b.path("src/codegen/create-hash-table.ts"));
        run.addFileInput(b.path("src/codegen/create_hash_table"));
        break :blk run.addOutputDirectoryArg("codegen");
    };
    cpp_sources.append(arena, jssink_dir.path(b, "JSSink.cpp")) catch @panic("OOM");
    sp.add(jssink_dir, "codegen");

    // ─── create-hash-table.ts <src> <out> (object LUTs) ───
    const luts_dir = blk: {
        const wf = b.addWriteFiles();
        const lut_pairs = [_][2][]const u8{
            .{ "src/jsc/bindings/BunObject.cpp", "BunObject.lut.h" },
            .{ "src/jsc/bindings/ZigGlobalObject.lut.txt", "ZigGlobalObject.lut.h" },
            .{ "src/jsc/bindings/JSBuffer.cpp", "JSBuffer.lut.h" },
            .{ "src/jsc/bindings/BunProcess.cpp", "BunProcess.lut.h" },
            .{ "src/jsc/bindings/ProcessBindingBuffer.cpp", "ProcessBindingBuffer.lut.h" },
            .{ "src/jsc/bindings/ProcessBindingConstants.cpp", "ProcessBindingConstants.lut.h" },
            .{ "src/jsc/bindings/ProcessBindingFs.cpp", "ProcessBindingFs.lut.h" },
            .{ "src/jsc/bindings/ProcessBindingNatives.cpp", "ProcessBindingNatives.lut.h" },
            .{ "src/jsc/bindings/ProcessBindingHTTPParser.cpp", "ProcessBindingHTTPParser.lut.h" },
            .{ "src/jsc/modules/NodeModuleModule.cpp", "NodeModuleModule.lut.h" },
            .{ "src/jsc/bindings/webcore/JSEvent.cpp", "JSEvent.lut.h" },
        };
        for (lut_pairs) |pair| {
            const run = script(b, deps, "src/codegen/create-hash-table.ts", .{ .use_run = true });
            run.addFileInput(b.path("src/codegen/create_hash_table"));
            run.addFileArg(b.path(pair[0]));
            _ = wf.addCopyFile(run.addOutputFileArg(pair[1]), pair[1]);
        }
        const run = script(b, deps, "src/codegen/create-hash-table.ts", .{ .use_run = true });
        run.addFileInput(b.path("src/codegen/create_hash_table"));
        run.addFileArg(classes_dir.path(b, "ZigGeneratedClasses.lut.txt"));
        _ = wf.addCopyFile(run.addOutputFileArg("ZigGeneratedClasses.lut.h"), "ZigGeneratedClasses.lut.h");
        break :blk wf.getDirectory();
    };
    sp.add(luts_dir, "codegen");

    // ─── bindgen.ts ───
    const bindgen_dir = blk: {
        const run = script(b, deps, "src/codegen/bindgen.ts", .{ .use_run = true });
        run.addArg(debug_flag);
        const out = run.addOutputDirectoryArg2("codegen", .{ .prefix = "--codegen-root=", .make_absolute = true });
        for (listFiles(b, "src", ".bind.ts", true)) |f| run.addFileInput(b.path(f));
        break :blk out;
    };
    cpp_sources.append(arena, bindgen_dir.path(b, "GeneratedBindings.cpp")) catch @panic("OOM");
    sp.add(bindgen_dir, "codegen");
    usf.addCopyFileToSource(bindgen_dir.path(b, "GeneratedBindings.zig"), "src/jsc/bindings/GeneratedBindings.zig");

    // ─── bindgenv2 ───
    const bindv2_sources = listFiles(b, "src", ".bindv2.ts", true);
    const bindv2_dir = blk: {
        const run = script(b, deps, "src/codegen/bindgenv2/script.ts", .{ .use_run = true });
        run.addArg("--command=generate");
        const out = run.addOutputDirectoryArg2("codegen", .{ .prefix = "--codegen-path=", .make_absolute = true });
        var list: std.ArrayList(u8) = .empty;
        list.appendSlice(arena, "--sources=") catch @panic("OOM");
        for (bindv2_sources, 0..) |f, i| {
            if (i > 0) list.append(arena, ',') catch @panic("OOM");
            list.appendSlice(arena, rootJoin(b, f)) catch @panic("OOM");
            run.addFileInput(b.path(f));
        }
        run.addArg(list.items);
        for (listFiles(b, "src/codegen/bindgenv2", ".ts", true)) |f| run.addFileInput(b.path(f));
        break :blk out;
    };
    sp.add(bindv2_dir, "codegen");
    // Fixed-name aggregate that #includes the per-type .cpp outputs. Compiled
    // from the stable dir: its quoted includes must resolve to the same
    // header paths as the -I'd stable codegen dir, or #pragma once sees two
    // copies of each generated header in one TU.
    cpp_sources.append(arena, .{
        .cwd_relative = std.fs.path.join(arena, &.{ cg.codegen_install_abs, "bindgen_generated.cpp" }) catch @panic("OOM"),
    }) catch @panic("OOM");

    // ─── cppbind.ts <srcdir> <outdir> <cxx-sources.txt> ───
    const cppbind_dir = blk: {
        const run = script(b, deps, "src/codegen/cppbind.ts", .{ .use_run = false });
        run.addArg(rootJoin(b, "src"));
        const out = run.addOutputDirectoryArg("codegen");
        const wf = b.addWriteFiles();
        var list: std.ArrayList(u8) = .empty;
        for (allCxxSources(b)) |f| {
            list.appendSlice(arena, f) catch @panic("OOM");
            list.append(arena, '\n') catch @panic("OOM");
            run.addFileInput(b.path(f));
        }
        run.addFileArg(wf.add("cxx-sources.txt", list.items));
        usesInstall(run, install_root); // lezer-cpp from root node_modules
        break :blk out;
    };
    sp.add(cppbind_dir, "codegen");

    // ─── ci_info.ts <out> ───
    {
        const run = script(b, deps, "src/codegen/ci_info.ts", .{ .use_run = false });
        sp.addFile(run.addOutputFileArg("ci_info.zig"), "codegen/ci_info.zig");
    }

    // ─── bake-codegen.ts ───
    const bake_dir = blk: {
        const run = script(b, deps, "src/codegen/bake-codegen.ts", .{ .use_run = true });
        run.addArg(debug_flag);
        // make_absolute: bake-codegen resolves the path from a different cwd.
        const out = run.addOutputDirectoryArg2("codegen", .{ .prefix = "--codegen-root=", .make_absolute = true });
        for (listFiles(b, "src/bake", ".ts", true)) |f| {
            if (std.mem.endsWith(u8, f, "src/bake/generated.ts")) continue;
            run.addFileInput(b.path(f));
        }
        for (listFiles(b, "src/bake", ".css", true)) |f| run.addFileInput(b.path(f));
        break :blk out;
    };
    sp.add(bake_dir, "codegen");

    // ─── esbuild bundles: bun-error, fallback-decoder, runtime.out.js ───
    {
        const run = b.addRunFile(esbuild);
        run.setCwd(b.path("packages/bun-error"));
        run.addArgs(&.{ "index.tsx", "bun-error.css" });
        const out = run.addPrefixedOutputDirectoryArg("--outdir=", "bun-error");
        run.addArgs(&.{
            "--define:process.env.NODE_ENV=\"production\"",
            "--minify",
            "--bundle",
            "--platform=browser",
            "--format=esm",
        });
        for (listFiles(b, "packages/bun-error", ".tsx", false)) |f| run.addFileInput(b.path(f));
        for (listFiles(b, "packages/bun-error", ".ts", false)) |f| run.addFileInput(b.path(f));
        for (listFiles(b, "packages/bun-error", ".css", false)) |f| run.addFileInput(b.path(f));
        usesInstall(run, install_root);
        usesInstall(run, install_bun_error);
        sp.add(out, "codegen/bun-error");
    }
    {
        const run = b.addRunFile(esbuild);
        run.setCwd(b.path("."));
        run.addFileArg(b.path("src/fallback.ts"));
        const out = run.addPrefixedOutputFileArg("--outfile=", "fallback-decoder.js");
        run.addArgs(&.{ "--target=esnext", "--bundle", "--format=iife", "--platform=browser", "--minify" });
        usesInstall(run, install_root);
        sp.addFile(out, "codegen/fallback-decoder.js");
    }
    {
        const run = b.addRunFile(esbuild);
        run.setCwd(b.path("."));
        run.addFileArg(b.path("src/runtime.bun.js"));
        const out = run.addPrefixedOutputFileArg("--outfile=", "runtime.out.js");
        run.addArgs(&.{
            "--define:process.env.NODE_ENV=\"production\"",
            "--target=esnext",
            "--bundle",
            "--format=esm",
            "--platform=node",
            "--minify",
            "--external:/bun:*",
        });
        usesInstall(run, install_root);
        sp.addFile(out, "codegen/runtime.out.js");
    }

    // ─── node-fallbacks ───
    {
        const run = script(b, deps, "src/node-fallbacks/build-fallbacks.ts", .{ .use_run = false });
        run.setCwd(b.path("src/node-fallbacks"));
        const out = run.addOutputDirectoryArg("node-fallbacks");
        for (listFiles(b, "src/node-fallbacks", ".js", false)) |f| run.addFileArg(b.path(f));
        usesInstall(run, install_node_fallbacks);

        const rr = b.addRunFile(deps.bun);
        rr.addArg("build");
        rr.setCwd(b.path("src/node-fallbacks"));
        rr.addFileArg(b.path("src/node-fallbacks/node_modules/react-refresh/cjs/react-refresh-runtime.development.js"));
        const rr_out = rr.addPrefixedOutputFileArg("--outfile=", "react-refresh.js");
        rr.addArgs(&.{ "--target=browser", "--format=cjs", "--minify", "--define:process.env.NODE_ENV=\"development\"" });
        usesInstall(rr, install_node_fallbacks);

        const wf = b.addWriteFiles();
        _ = wf.addCopyDirectory(out, "", .{});
        _ = wf.addCopyFile(rr_out, "react-refresh.js");
        sp.add(wf.getDirectory(), "codegen/node-fallbacks");
    }

    cg.cpp_sources = cpp_sources.items;
    return cg;
}

const ScriptOpts = struct { use_run: bool };

/// A codegen script under the pinned bootstrap bun, cwd = repo root.
fn script(b: *Build, deps: *const DepPkgs, path: []const u8, opts: ScriptOpts) *Step.Run {
    const run = b.addRunFile(deps.bun);
    if (opts.use_run) run.addArg("run");
    run.addFileArg(b.path(path));
    // Run steps do not discover imports; the scripts import src/codegen
    // helpers freely, so declare the whole top level.
    for (listFiles(b, "src/codegen", ".ts", false)) |f| run.addFileInput(b.path(f));
    run.setCwd(b.path("."));
    run.setEnvironmentVariable("TARGET_PLATFORM", "linux");
    run.setEnvironmentVariable("TARGET_ARCH", "x64");
    // Constant PATH: the pinned bun must win for scripts that spawn `bun`,
    // and the env is hashed into the step manifest, so inheriting the host
    // PATH would invalidate all codegen whenever it changes.
    run.setEnvironmentVariable("PATH", b.fmt("{s}:/usr/bin:/bin", .{deps.bun_dir_abs}));
    return run;
}

const Install = struct {
    step: *Step,
    lock: LazyPath,
    pkg_json: LazyPath,
};

/// bun install --frozen-lockfile in a package dir. Always runs; it is its
/// own no-op check (~tens of ms).
fn bunInstall(b: *Build, deps: *const DepPkgs, dir: []const u8) Install {
    const run = b.addRunFile(deps.bun);
    run.addArgs(&.{ "install", "--frozen-lockfile" });
    run.setCwd(if (dir.len == 0) b.path(".") else b.path(dir));
    run.has_side_effects = true;
    run.step.name = b.fmt("bun install {s}", .{if (dir.len == 0) "." else dir});
    return .{
        .step = &run.step,
        .lock = b.path(b.pathJoin(&.{ dir, "bun.lock" })),
        .pkg_json = b.path(b.pathJoin(&.{ dir, "package.json" })),
    };
}

/// Order after the install and key on the lockfile: node_modules content is
/// not otherwise visible to the consumer's cache manifest.
fn usesInstall(run: *Step.Run, inst: Install) void {
    run.step.dependOn(inst.step);
    run.addFileInput(inst.lock);
    run.addFileInput(inst.pkg_json);
}

// ───────────────────────────────────────────────────────────────────────────
// C/C++ compilation
// ───────────────────────────────────────────────────────────────────────────

/// Static archives in link order (whole-archive).
pub fn addCpp(b: *Build, deps: *const DepPkgs, cg: *const Codegen, opts: Options) []const *Step.Compile {
    const arena = b.graph.arena;
    var archives: std.ArrayList(*Step.Compile) = .empty;

    const base_flags: []const []const u8 = blk: {
        const mode_flags: []const []const u8 = switch (opts.mode) {
            .debug => recipes.base_flags_debug,
            .release => recipes.base_flags_release,
        };
        var list: std.ArrayList([]const u8) = .empty;
        // Zig uses -O2 for C/C++; Bun's performance-oriented modes use -O3.
        if (opts.optimize == .ReleaseSafe or opts.optimize == .ReleaseFast) {
            list.append(arena, "-O3") catch @panic("OOM");
        }
        list.appendSlice(arena, mode_flags) catch @panic("OOM");
        // zig injects -Werror=date-time; mimalloc's release config uses __DATE__.
        list.append(arena, "-Wno-date-time") catch @panic("OOM");
        break :blk list.items;
    };
    const gen_dirs = makeGenDirs(b, deps);
    const versions_dir = makeDepVersionsHeader(b, opts);

    // ─── bun's own C++ and C ───
    {
        const bun_cxx_flags: []const []const u8 = switch (opts.mode) {
            .debug => recipes.bun_cxx_flags_debug,
            .release => recipes.bun_cxx_flags_release,
        };
        const bun_c_flags: []const []const u8 = switch (opts.mode) {
            .debug => recipes.bun_c_flags_debug,
            .release => recipes.bun_c_flags_release,
        };

        const lib_cxx = newCppLib(b, "bun-cxx", opts, true, &.{});
        const lib_c = newCppLib(b, "bun-c", opts, false, &.{});
        for (recipes.bun_includes) |inc| addInclude(b, lib_cxx, inc, deps, cg, opts.webkit, &gen_dirs, versions_dir);
        for (recipes.bun_c_includes) |inc| addInclude(b, lib_c, inc, deps, cg, opts.webkit, &gen_dirs, versions_dir);

        var cxx_flags: std.ArrayList([]const u8) = .empty;
        cxx_flags.appendSlice(arena, base_flags) catch @panic("OOM");
        cxx_flags.appendSlice(arena, bun_cxx_flags) catch @panic("OOM");
        // Extern-template s_info instantiations whose definitions live in
        // the JSC library (JSBuffer.cpp).
        cxx_flags.append(arena, "-Wno-undefined-var-template") catch @panic("OOM");
        if (opts.mode == .debug and !opts.codegen_embed) {
            cxx_flags.append(arena, b.fmt("-DBUN_DYNAMIC_JS_LOAD_PATH=\"{s}\"", .{cg.js_install_abs})) catch @panic("OOM");
        }
        // Debug builds force-include a precompiled root-pch.h (clang picks up
        // the adjacent .pch); the release TU pipeline reports a different
        // cc1 OptimizationLevel than the zig cc driver, which fails PCH
        // validation, and one-shot release builds gain little from one.
        if (opts.mode == .debug) {
            cxx_flags.append(arena, "-include") catch @panic("OOM");
            cxx_flags.append(arena, std.fs.path.join(arena, &.{ cg.pch_install_abs, "root-pch.h" }) catch @panic("OOM")) catch @panic("OOM");
            const pch_step = addPch(b, deps, cg, opts.webkit, cxx_flags.items, &gen_dirs, versions_dir);
            lib_cxx.step.dependOn(pch_step);
        }

        const split = unifiedSplit(b, opts.mode);
        for (split.standalone) |f| {
            lib_cxx.root_module.addCSourceFile(.{ .file = b.path(f), .flags = cxx_flags.items, .language = .cpp });
        }
        for (split.bundles) |bundle| {
            lib_cxx.root_module.addCSourceFile(.{ .file = bundle, .flags = cxx_flags.items, .language = .cpp });
        }
        lib_cxx.root_module.addCSourceFile(.{
            .file = cxxInputStamp(b, deps),
            .flags = &.{},
            .language = .cpp,
        });
        for (cg.cpp_sources) |f| {
            lib_cxx.root_module.addCSourceFile(.{ .file = f, .flags = cxx_flags.items, .language = .cpp });
        }

        var c_flags: std.ArrayList([]const u8) = .empty;
        c_flags.appendSlice(arena, base_flags) catch @panic("OOM");
        c_flags.appendSlice(arena, bun_c_flags) catch @panic("OOM");
        if (opts.mode == .debug and !opts.codegen_embed) {
            c_flags.append(arena, b.fmt("-DBUN_DYNAMIC_JS_LOAD_PATH=\"{s}\"", .{cg.js_install_abs})) catch @panic("OOM");
        }
        for (allCSources(b)) |f| {
            lib_c.root_module.addCSourceFile(.{ .file = b.path(f), .flags = c_flags.items, .language = .c });
        }

        archives.append(arena, lib_cxx) catch @panic("OOM");
        archives.append(arena, lib_c) catch @panic("OOM");
    }

    // ─── vendored deps ───
    // One static lib per compile group: zig models CPU features per module,
    // so SIMD variant groups (zlib, libwebp) need their own module targets.
    for (recipes.all) |dep| {
        const root: ?LazyPath = if (dep.in_tree) null else deps.srcs.get(dep.name).?;
        for (dep.groups, 0..) |group, gi| {
            const group_flags = if (opts.mode == .release and group.flags_release != null)
                group.flags_release.?
            else
                group.flags;
            const cxx_lang = group.cxx or hasLangOverride(group_flags);
            const name = if (dep.groups.len == 1) dep.name else b.fmt("{s}-{d}", .{ dep.name, gi });
            const lib = newCppLib(b, name, opts, cxx_lang, groupFeatures(b, group_flags));

            var flags: std.ArrayList([]const u8) = .empty;
            if (!group.no_base) flags.appendSlice(arena, base_flags) catch @panic("OOM");
            {
                // `-x <lang>` pairs are expressed via the `language` field:
                // zig places source files before user flags, where a trailing
                // -x has no effect.
                var i: usize = 0;
                while (i < group_flags.len) : (i += 1) {
                    if (std.mem.eql(u8, group_flags[i], "-x")) {
                        i += 1;
                        continue;
                    }
                    flags.append(arena, group_flags[i]) catch @panic("OOM");
                }
            }
            for (group.includes) |inc| addInclude(b, lib, inc, deps, cg, opts.webkit, &gen_dirs, versions_dir);
            for (group.files) |f| {
                const file: LazyPath = if (root) |r| r.path(b, f) else b.path(f);
                const language: Build.Module.CSourceLanguage = if (std.mem.endsWith(u8, f, ".S"))
                    .assembly_with_preprocessor
                else if (cxx_lang)
                    .cpp
                else
                    .c;
                lib.root_module.addCSourceFile(.{ .file = file, .flags = flags.items, .language = language });
            }
            archives.append(arena, lib) catch @panic("OOM");
        }
    }

    return archives.items;
}

/// Precompile root-pch.h with flags identical to the C++ TUs' and mirror
/// {root-pch.h, root-pch.h.pch} into the stable pch dir the TUs -include
/// from. Compiled against the codegen steps' cache dirs (same content as the
/// synced dir), so the PCH's cache key covers codegen changes.
fn addPch(
    b: *Build,
    deps: *const DepPkgs,
    cg: *const Codegen,
    wk: *const @import("webkit.zig").Ctx,
    cxx_flags: []const []const u8,
    gen_dirs: *const std.StringArrayHashMapUnmanaged(LazyPath),
    versions_dir: LazyPath,
) *Step {
    const arena = b.graph.arena;
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "c++" });
    run.step.name = "precompile root-pch.h";

    // clang validates PCH/TU identity on target triple, __PIC__ level, and
    // include environment. -target: the versioned triple the TU modules
    // resolve to; the default zig c++ include set matches the modules'
    // link_libc + link_libcpp environment.
    const triple = cppTarget(b, &.{}).result.zigTriple(arena) catch @panic("OOM");
    run.addArgs(&.{ "-target", triple, "-march=native" });

    // The TU flags, minus the -include of the header being precompiled.
    var i: usize = 0;
    while (i < cxx_flags.len) : (i += 1) {
        if (std.mem.eql(u8, cxx_flags[i], "-include")) {
            i += 1;
            continue;
        }
        // The CLI treats these as a module-level pic=false, which zig
        // rejects for glibc targets; the cc1 relocation model below produces
        // the same __PIC__ == 0 the TU compiles get from them.
        if (std.mem.eql(u8, cxx_flags[i], "-fno-pic") or std.mem.eql(u8, cxx_flags[i], "-fno-pie")) continue;
        run.addArg(cxx_flags[i]);
    }
    // The relocation model rides in via the shared base flags; the pic-level
    // override additionally clears the __PIC__ macro the way the TUs'
    // -fno-pic (filtered above) does.
    run.addArgs(&.{ "-Xclang", "-pic-level", "-Xclang", "0" });
    run.addArgs(&.{ "-fpch-instantiate-templates", "-Xclang", "-fno-pch-timestamp" });

    for (recipes.bun_includes) |inc| {
        switch (inc) {
            .dep => |d| {
                const root = deps.srcs.get(d[0]).?;
                run.addPrefixedDirectoryArg("-I", if (d[1].len == 0) root else root.path(b, d[1]));
            },
            .gen => |g| {
                const dir = gen_dirs.get(g[0]).?;
                run.addPrefixedDirectoryArg("-I", if (g[1].len == 0) dir else dir.path(b, g[1]));
            },
            .repo => |p| run.addPrefixedDirectoryArg("-I", b.path(p)),
            .webkit => {
                for (wk.includes) |dir| run.addPrefixedDirectoryArg("-I", dir);
                run.step.dependOn(wk.sync);
            },
            .nodejs => |p| run.addPrefixedDirectoryArg("-I", deps.nodejs.path(b, p)),
            // Stable dir, so the depfile keys on generated-header content
            // rather than on codegen step dirs whose paths churn.
            .codegen => run.addArg(b.fmt("-I{s}", .{cg.codegen_install_abs})),
            .builddir => run.addPrefixedDirectoryArg("-I", versions_dir),
        }
    }

    run.addArgs(&.{ "-x", "c++-header" });
    run.addFileArg(b.path("src/jsc/bindings/root-pch.h"));
    // The depfile tracks the exact transitive headers; the sync dependency
    // only orders the generated headers into existence.
    run.step.dependOn(cg.sync_step);
    run.addArgs(&.{ "-MD", "-MF" });
    _ = run.addDepFileOutputArg("root-pch.d");
    run.addArg("-o");
    const pch = run.addOutputFileArg("root-pch.h.pch");

    // Mirror {header, .pch} into the stable dir; clang probes for the .pch
    // adjacent to the -include'd header. Separate from the main sync step,
    // which is this step's dependency.
    const stable_root = std.fs.path.dirname(cg.pch_install_abs).?;
    const mirror = b.addRunFile(deps.bun);
    mirror.addFileArg(b.path("src/build/sync-dirs.ts"));
    mirror.addArg(stable_root);
    mirror.has_side_effects = true;
    mirror.step.name = "sync pch";
    var sp: SyncPairs = .{ .run = mirror };
    sp.addFile(b.path("src/jsc/bindings/root-pch.h"), "pch/root-pch.h");
    sp.addFile(pch, "pch/root-pch.h.pch");
    return &mirror.step;
}

fn hasLangOverride(flags: []const []const u8) bool {
    var i: usize = 0;
    while (i + 1 < flags.len) : (i += 1) {
        if (std.mem.eql(u8, flags[i], "-x") and std.mem.eql(u8, flags[i + 1], "c++")) return true;
    }
    return false;
}

fn newCppLib(b: *Build, name: []const u8, opts: Options, is_cxx: bool, extra_features: []const []const u8) *Step.Compile {
    const mod = b.createModule(.{
        .target = cppTarget(b, extra_features),
        .optimize = opts.optimize,
        // The whole C++ world (WebKit, ICU, deps, bun-cxx) compiles against
        // zig's bundled libc++; the C++ ABI must stay uniform across it.
        // link_libcpp does not imply the libc headers.
        .link_libc = true,
        .link_libcpp = is_cxx,
        // Sanitizers are opt-in; zig defaults debug C/C++ to `undefined`.
        .sanitize_c = .off,
    });
    const lib = b.addLibrary(.{
        .name = name,
        .root_module = mod,
        .linkage = .static,
    });
    // These libs have no Zig compilation unit; under a CLI -fincremental
    // (the watch loop) the incremental cache mode emits broken archives for
    // them and disables content caching.
    lib.incremental = false;
    return lib;
}

/// Target for C/C++ translation units: the native host, plus per-group SIMD
/// features.
///
/// Per-file -m flags alone do not work under zig's compile step: it emits the
/// module CPU's complete feature list as cc1-level -target-feature flags,
/// which override anything the clang driver derives from -m options. SIMD
/// variant groups therefore get their features baked into the module target.
pub fn cppTarget(b: *Build, extra_features: []const []const u8) Build.ResolvedTarget {
    var query = b.graph.host.query;
    query.cpu_arch = .x86_64;
    query.cpu_model = .native;
    var add = std.Target.Cpu.Feature.Set.empty;
    for (extra_features) |name| {
        const feature = std.meta.stringToEnum(std.Target.x86.Feature, name) orelse
            std.debug.panic("unknown x86 feature: {s}", .{name});
        add.addFeature(@backingInt(feature));
    }
    query.cpu_features_add = add;
    return b.resolveTargetQuery(query);
}

/// Map a compile group's -m<feature> flags to zig target feature names.
fn groupFeatures(b: *Build, flags: []const []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (flags) |f| {
        if (!std.mem.startsWith(u8, f, "-m")) continue;
        const name = f[2..];
        const mapped: ?[]const u8 = if (std.mem.eql(u8, name, "sse4.1"))
            "sse4_1"
        else if (std.mem.eql(u8, name, "sse4.2"))
            "sse4_2"
        else if (std.meta.stringToEnum(std.Target.x86.Feature, name) != null)
            name
        else
            null;
        if (mapped) |m| out.append(b.graph.arena, m) catch @panic("OOM");
    }
    return out.items;
}

pub const ZigCxxRuntime = struct {
    crt1: []const u8,
    libcxxabi: []const u8,
    libcxx: []const u8,
    libunwind: []const u8,
    compiler_rt: []const u8,
};

/// The static C++ runtime pieces zig links for -lc++, discovered by parsing
/// a --verbose-link of a trivial program (they live at content-hashed global
/// cache paths).
pub fn discoverZigCxxRuntime(b: *Build, optimize: std.builtin.OptimizeMode) ZigCxxRuntime {
    const arena = b.graph.arena;
    if (zig_cxx_runtime_cache) |c| return c;
    const io = b.graph.io;
    const dir_abs = rootJoin(b, ".zig-cache");
    var dir = std.Io.Dir.openDirAbsolute(io, dir_abs, .{}) catch @panic("open .zig-cache");
    defer dir.close(io);
    dir.writeFile(io, .{ .sub_path = "cxx-runtime-probe.cpp", .data = "int main(){return 0;}\n" }) catch @panic("write cxx probe");
    // --verbose-link prints to stderr.
    const runtime_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseFast else optimize;
    const out = b.run(&.{
        "sh",
        "-c",
        b.fmt(
            // native: crt1.o must match the host glibc the binary links
            // against (the generic target's crt1 references the pre-2.34
            // __libc_csu_* symbols).
            "exec \"$0\" build-exe -target native -O {s} -lc++ --verbose-link -femit-bin={s}/cxx-runtime-probe {s}/cxx-runtime-probe.cpp 2>&1",
            .{ @tagName(runtime_optimize), dir_abs, dir_abs },
        ),
        b.graph.zig_exe,
    });
    var crt1: ?[]const u8 = null;
    var libcxxabi: ?[]const u8 = null;
    var libcxx: ?[]const u8 = null;
    var libunwind: ?[]const u8 = null;
    var compiler_rt: ?[]const u8 = null;
    var it = std.mem.tokenizeAny(u8, out, " \n\r");
    while (it.next()) |tok| {
        inline for (.{
            .{ "crt1.o", &crt1 },
            .{ "libc++abi.a", &libcxxabi },
            .{ "libc++.a", &libcxx },
            .{ "libunwind.a", &libunwind },
            .{ "libcompiler_rt.a", &compiler_rt },
        }) |pair| {
            if (std.mem.endsWith(u8, tok, "/" ++ pair[0])) {
                pair[1].* = arena.dupe(u8, tok) catch @panic("OOM");
            }
        }
    }
    const rt: ZigCxxRuntime = .{
        .crt1 = crt1 orelse @panic("cxx runtime discovery: no crt1.o in link line"),
        .libcxxabi = libcxxabi orelse @panic("cxx runtime discovery: no libc++abi.a in link line"),
        .libcxx = libcxx orelse @panic("cxx runtime discovery: no libc++.a in link line"),
        .libunwind = libunwind orelse @panic("cxx runtime discovery: no libunwind.a in link line"),
        .compiler_rt = compiler_rt orelse @panic("cxx runtime discovery: no libcompiler_rt.a in link line"),
    };
    zig_cxx_runtime_cache = rt;
    return rt;
}

var zig_cxx_runtime_cache: ?ZigCxxRuntime = null;

/// Generated per-dep config headers (the `gen` include kind): substituted
/// .in templates, snapshotted configs, tinycc's tccdefs_.h.
fn makeGenDirs(b: *Build, deps: *const DepPkgs) std.StringArrayHashMapUnmanaged(LazyPath) {
    const arena = b.graph.arena;
    var dirs: std.StringArrayHashMapUnmanaged(LazyPath) = .empty;

    // zlib: configure-file templates (read from the pristine package; the
    // zlib patch doesn't touch them).
    {
        const root_abs = deps.srcs_abs.get("zlib").?;
        const wf = b.addWriteFiles();
        _ = wf.add("zlib.h", substFile(b, root_abs, "zlib.h.in", &.{.{ "@ZLIB_SYMBOL_PREFIX@", "" }}));
        _ = wf.add("zconf.h", substFile(b, root_abs, "zconf.h.in", &.{
            .{ "#ifdef HAVE_UNISTD_H ", "#if 1 " },
            .{ "#ifdef NEED_PTRDIFF_T ", "#if 0 " },
        }));
        _ = wf.add("zlib_name_mangling.h", "#ifndef ZLIB_NAME_MANGLING_H\n#define ZLIB_NAME_MANGLING_H\n#endif\n");
        _ = wf.add("gzread_mangle.h", "#undef gzgetc\n#undef zng_gzgetc\n");
        dirs.put(arena, "zlib", wf.getDirectory()) catch @panic("OOM");
    }

    // libjpeg-turbo: configure-file templates.
    {
        const root_abs = deps.srcs_abs.get("libjpeg-turbo").?;
        const wf = b.addWriteFiles();
        _ = wf.add("jconfig.h", substFile(b, root_abs, "src/jconfig.h.in", &.{
            .{ "@JPEG_LIB_VERSION@", "80" },
            .{ "@VERSION@", "3.1.4" },
            .{ "@LIBJPEG_TURBO_VERSION_NUMBER@", "3001004" },
            .{ "#cmakedefine WITH_SIMD 1", "/* #undef WITH_SIMD */" },
            .{ "#cmakedefine RIGHT_SHIFT_IS_UNSIGNED 1", "/* #undef RIGHT_SHIFT_IS_UNSIGNED */" },
            .{ "#cmakedefine", "#define" },
        }));
        _ = wf.add("jconfigint.h", substFile(b, root_abs, "src/jconfigint.h.in", &.{
            .{ "@BUILD@", "bun" },
            .{ "@HIDDEN@", "__attribute__((visibility(\"hidden\")))" },
            .{ "@INLINE@", "inline __attribute__((always_inline))" },
            .{ "@THREAD_LOCAL@", "__thread" },
            .{ "@CMAKE_PROJECT_NAME@", "libjpeg-turbo" },
            .{ "@VERSION@", "3.1.4" },
            .{ "@SIZE_T@", "8" },
            .{ "#cmakedefine WITH_SIMD 1", "/* #undef WITH_SIMD */" },
            .{ "#cmakedefine HAVE_BUILTIN_CTZL", "#define HAVE_BUILTIN_CTZL" },
            .{ "#cmakedefine HAVE_INTRIN_H", "/* */" },
            .{ "#cmakedefine", "#define" },
        }));
        _ = wf.add("jversion.h", substFile(b, root_abs, "src/jversion.h.in", &.{
            .{ "@COPYRIGHT_YEAR@", "2025" },
        }));
        dirs.put(arena, "libjpeg-turbo", wf.getDirectory()) catch @panic("OOM");
    }

    // cares + libarchive: static per-target configs (see src/build/assets).
    {
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(b.path("src/build/assets/cares/ares_config.h"), "ares_config.h");
        _ = wf.addCopyFile(b.path("src/build/assets/cares/ares_build.h"), "ares_build.h");
        dirs.put(arena, "cares", wf.getDirectory()) catch @panic("OOM");
    }
    {
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(b.path("src/build/assets/libarchive/config.h"), "config.h");
        dirs.put(arena, "libarchive", wf.getDirectory()) catch @panic("OOM");
    }

    // tinycc: tccdefs_.h generated by its conftest tool.
    {
        const root = deps.srcs.get("tinycc").?;
        const tool_mod = b.createModule(.{ .target = b.graph.host, .optimize = .ReleaseFast, .link_libc = true });
        tool_mod.addCSourceFile(.{
            .file = root.path(b, "conftest.c"),
            .flags = &.{ "-w", "-DC2STR" },
            .language = .c,
        });
        const tool = b.addExecutable(.{ .name = "tinycc-conftest", .root_module = tool_mod });
        const run = b.addRunArtifact(tool);
        run.setCwd(root);
        run.addFileArg(root.path(b, "include/tccdefs.h"));
        const out = run.addOutputFileArg("tccdefs_.h");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(out, "tccdefs_.h");
        dirs.put(arena, "tinycc", wf.getDirectory()) catch @panic("OOM");
    }

    return dirs;
}

/// Configure-time template substitution. The .in files live in immutable zon
/// packages, so reading them during configure is deterministic.
fn substFile(b: *Build, root_abs: []const u8, sub_path: []const u8, replacements: []const [2][]const u8) []const u8 {
    const arena = b.graph.arena;
    const abs = std.fs.path.join(arena, &.{ root_abs, sub_path }) catch @panic("OOM");
    var content = readAbsFile(b, abs);
    for (replacements) |r| {
        const count = std.mem.replacementSize(u8, content, r[0], r[1]);
        const buf = arena.alloc(u8, count) catch @panic("OOM");
        _ = std.mem.replace(u8, content, r[0], r[1], buf);
        content = buf;
    }
    return content;
}

fn makeDepVersionsHeader(b: *Build, opts: Options) LazyPath {
    const arena = b.graph.arena;
    const sha = opts.sha orelse "dev";
    // The zig commit is only surfaced as the short hash embedded in the
    // compiler's version string.
    const zig_version = builtin.zig_version_string;
    const zig_ref = if (std.mem.lastIndexOfScalar(u8, zig_version, '+')) |i| zig_version[i + 1 ..] else zig_version;

    var entries: std.ArrayList([2][]const u8) = .empty;
    for (version_sources) |kv| {
        entries.append(arena, .{ kv[0], zonRef(b, kv[1]) }) catch @panic("OOM");
    }
    entries.appendSlice(arena, &.{
        .{ "WEBKIT", webkitVendorCommit(b) },
        .{ "ICU", zonRef(b, "icu") },
        .{ "BUN_VERSION", opts.version },
        .{ "NODEJS_COMPAT_VERSION", nodejsVersionFromZon(b) },
        .{ "UWS", sha },
        .{ "USOCKETS", sha },
        .{ "ZIG", zig_ref },
    }) catch @panic("OOM");

    var text: std.ArrayList(u8) = .empty;
    text.appendSlice(arena,
        \\// Generated by src/build/exe.zig from build.zig.zon. Do not edit.
        \\#ifndef BUN_DEPENDENCY_VERSIONS_H
        \\#define BUN_DEPENDENCY_VERSIONS_H
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    ) catch @panic("OOM");
    for (entries.items) |kv| {
        text.print(arena, "#define BUN_DEP_{s} \"{s}\"\n", .{ kv[0], kv[1] }) catch @panic("OOM");
    }
    text.appendSlice(arena, "\n// C string constants for easy access\n") catch @panic("OOM");
    for (entries.items) |kv| {
        text.print(arena, "static const char* const BUN_VERSION_{s} = \"{s}\";\n", .{ kv[0], kv[1] }) catch @panic("OOM");
    }
    text.appendSlice(arena,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\#endif
        \\
    ) catch @panic("OOM");
    const wf = b.addWriteFiles();
    _ = wf.add("bun_dependency_versions.h", text.items);
    return wf.getDirectory();
}

fn addInclude(
    b: *Build,
    lib: *Step.Compile,
    inc: recipes.Include,
    deps: *const DepPkgs,
    cg: *const Codegen,
    wk: *const @import("webkit.zig").Ctx,
    gen_dirs: *const std.StringArrayHashMapUnmanaged(LazyPath),
    versions_dir: LazyPath,
) void {
    switch (inc) {
        .dep => |d| {
            const root = deps.srcs.get(d[0]) orelse std.debug.panic("unknown dep include: {s}", .{d[0]});
            lib.root_module.addIncludePath(if (d[1].len == 0) root else root.path(b, d[1]));
        },
        .gen => |g| {
            const dir = gen_dirs.get(g[0]) orelse std.debug.panic("no gen dir for dep: {s}", .{g[0]});
            lib.root_module.addIncludePath(if (g[1].len == 0) dir else dir.path(b, g[1]));
        },
        .repo => |p| lib.root_module.addIncludePath(b.path(p)),
        .webkit => {
            for (wk.includes) |dir| lib.root_module.addIncludePath(dir);
            lib.step.dependOn(wk.sync);
        },
        .nodejs => |p| lib.root_module.addIncludePath(deps.nodejs.path(b, p)),
        // The stable synced dir, so compile caches key on generated-file
        // content rather than on cache-dir paths that churn per codegen run.
        .codegen => {
            lib.root_module.addIncludePath(.{ .cwd_relative = cg.codegen_install_abs });
            lib.step.dependOn(cg.sync_step);
        },
        .builddir => lib.root_module.addIncludePath(versions_dir),
    }
}

// ───────────────────────────────────────────────────────────────────────────
// Unified sources
// ───────────────────────────────────────────────────────────────────────────

/// Makes mutable C++ inputs part of bun-cxx's direct input identity so its
/// whole-cache entry cannot hide changes omitted from its parent manifest.
fn cxxInputStamp(b: *Build, deps: *const DepPkgs) LazyPath {
    const run = b.addRunFile(deps.bun);
    run.addFileArg(b.path("src/build/write-input-stamp.ts"));
    const stamp = run.addOutputFileArg("cxx-input-stamp.cpp");
    for (allCxxWatchInputs(b)) |f| run.addFileInput(b.path(f));
    run.step.name = "C++ input stamp";
    return stamp;
}

const UnifiedSplit = struct {
    standalone: []const []const u8, // repo-relative
    bundles: []const LazyPath,
};

/// WebKit-style unified source bundling: group by directory, sort by
/// basename, chunk (8 debug / 32 release). no_unify files and single-file
/// directories compile standalone. Grouping per directory keeps
/// `using namespace` at file scope from leaking across subsystems.
fn unifiedSplit(b: *Build, mode: Mode) UnifiedSplit {
    const arena = b.graph.arena;
    const bundle_size: usize = if (mode == .debug) 8 else 32;

    var skip: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (no_unify) |f| skip.put(arena, f, {}) catch @panic("OOM");

    var by_dir: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    var standalone: std.ArrayList([]const u8) = .empty;

    for (allCxxSources(b)) |f| {
        if (skip.contains(f)) {
            standalone.append(arena, f) catch @panic("OOM");
            continue;
        }
        const dir = std.fs.path.dirname(f).?;
        const entry = by_dir.getOrPut(arena, dir) catch @panic("OOM");
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        entry.value_ptr.append(arena, f) catch @panic("OOM");
    }

    var bundles: std.ArrayList(LazyPath) = .empty;
    const wf = b.addWriteFiles();

    const dirs = arena.dupe([]const u8, by_dir.keys()) catch @panic("OOM");
    std.mem.sort([]const u8, dirs, {}, lessThanString);
    for (dirs) |dir| {
        const files = by_dir.get(dir).?.items;
        std.mem.sort([]const u8, files, {}, lessThanBasename);
        if (files.len == 1) {
            standalone.append(arena, files[0]) catch @panic("OOM");
            continue;
        }
        const tag = tagFor(arena, dir);
        var i: usize = 0;
        var n: usize = 0;
        while (i < files.len) : (n += 1) {
            const end = @min(i + bundle_size, files.len);
            var body: std.ArrayList(u8) = .empty;
            for (files[i..end]) |f| {
                body.print(arena, "#include \"{s}\"\n", .{rootJoin(b, f)}) catch @panic("OOM");
            }
            const name = b.fmt("UnifiedSource-{s}-{d}.cpp", .{ tag, n });
            bundles.append(arena, wf.add(name, body.items)) catch @panic("OOM");
            i = end;
        }
    }

    return .{ .standalone = standalone.items, .bundles = bundles.items };
}

fn tagFor(arena: std.mem.Allocator, dir: []const u8) []const u8 {
    const buf = arena.dupe(u8, dir) catch @panic("OOM");
    for (buf) |*c| {
        if (!std.ascii.isAlphanumeric(c.*)) c.* = '_';
    }
    return buf;
}

fn lessThanString(_: void, a: []const u8, bb: []const u8) bool {
    return std.mem.order(u8, a, bb) == .lt;
}

fn lessThanBasename(_: void, a: []const u8, bb: []const u8) bool {
    return std.mem.order(u8, std.fs.path.basename(a), std.fs.path.basename(bb)) == .lt;
}

// ───────────────────────────────────────────────────────────────────────────
// Source scanning (configure time)
// ───────────────────────────────────────────────────────────────────────────

var cxx_sources_cache: ?[]const []const u8 = null;
var c_sources_cache: ?[]const []const u8 = null;
var cxx_watch_inputs_cache: ?[]const []const u8 = null;

fn allCxxWatchInputs(b: *Build) []const []const u8 {
    if (cxx_watch_inputs_cache) |c| return c;
    const arena = b.graph.arena;
    var out: std.ArrayList([]const u8) = .empty;
    out.appendSlice(arena, allCxxSources(b)) catch @panic("OOM");
    const header_suffixes = [_][]const u8{ ".h", ".hh", ".hpp", ".hxx", ".inc", ".inl", ".ipp", ".def" };
    for ([_][]const u8{ "src", "packages" }) |dir| {
        out.appendSlice(arena, listFilesAny(b, dir, &header_suffixes, true)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, out.items, {}, lessThanString);
    cxx_watch_inputs_cache = out.items;
    return out.items;
}

fn allCxxSources(b: *Build) []const []const u8 {
    if (cxx_sources_cache) |c| return c;
    const arena = b.graph.arena;
    var out: std.ArrayList([]const u8) = .empty;
    for (cxx_dirs) |dir| {
        for (listFiles(b, dir, ".cpp", false)) |f| out.append(arena, f) catch @panic("OOM");
    }
    // webcrypto/*/*.cpp (one extra level).
    for (listDirs(b, "src/jsc/bindings/webcrypto")) |sub| {
        for (listFiles(b, sub, ".cpp", false)) |f| out.append(arena, f) catch @panic("OOM");
    }
    std.mem.sort([]const u8, out.items, {}, lessThanString);
    cxx_sources_cache = out.items;
    return out.items;
}

fn allCSources(b: *Build) []const []const u8 {
    if (c_sources_cache) |c| return c;
    const arena = b.graph.arena;
    var out: std.ArrayList([]const u8) = .empty;
    for (c_dirs) |dir| {
        for (listFiles(b, dir, ".c", false)) |f| {
            // sqlite3.c is its own recipe (src/build/deps/sqlite.zig).
            if (std.mem.endsWith(u8, f, "sqlite3.c")) continue;
            out.append(arena, f) catch @panic("OOM");
        }
    }
    for (c_files) |f| out.append(arena, f) catch @panic("OOM");
    std.mem.sort([]const u8, out.items, {}, lessThanString);
    c_sources_cache = out.items;
    return out.items;
}

/// Repo-relative files under `dir` with the given suffix. One-shot builds
/// pick up created/deleted files because configure re-runs every invocation
/// (build.zig keeps the config cache poisoned); --watch does not re-run
/// configure, so new files there need a watch restart. The directory
/// registration is what a future config cache would key on.
fn listFiles(b: *Build, dir: []const u8, suffix: []const u8, recursive: bool) []const []const u8 {
    return listFilesAny(b, dir, &.{suffix}, recursive);
}

fn listFilesAny(b: *Build, dir: []const u8, suffixes: []const []const u8, recursive: bool) []const []const u8 {
    const arena = b.graph.arena;
    const io = b.graph.io;
    b.dependOnDirectory(b.path(dir));
    var out: std.ArrayList([]const u8) = .empty;
    var handle = std.Io.Dir.openDirAbsolute(io, rootJoin(b, dir), .{ .iterate = true }) catch
        std.debug.panic("cannot open source dir: {s}", .{dir});
    defer handle.close(io);
    if (recursive) {
        var walker = handle.walk(arena) catch @panic("OOM");
        defer walker.deinit();
        while (walker.next(io) catch @panic("walk failed")) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.indexOf(u8, entry.path, "node_modules") != null) continue;
            if (!hasAnySuffix(entry.path, suffixes)) continue;
            out.append(arena, b.fmt("{s}/{s}", .{ dir, entry.path })) catch @panic("OOM");
        }
    } else {
        var it = handle.iterate();
        while (it.next(io) catch @panic("iterate failed")) |entry| {
            if (entry.kind != .file) continue;
            if (!hasAnySuffix(entry.name, suffixes)) continue;
            out.append(arena, b.fmt("{s}/{s}", .{ dir, entry.name })) catch @panic("OOM");
        }
    }
    std.mem.sort([]const u8, out.items, {}, lessThanString);
    return out.items;
}

fn hasAnySuffix(path: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, path, suffix)) return true;
    }
    return false;
}

fn listDirs(b: *Build, dir: []const u8) []const []const u8 {
    const arena = b.graph.arena;
    const io = b.graph.io;
    b.dependOnDirectory(b.path(dir));
    var out: std.ArrayList([]const u8) = .empty;
    var handle = std.Io.Dir.openDirAbsolute(io, rootJoin(b, dir), .{ .iterate = true }) catch return &.{};
    defer handle.close(io);
    var it = handle.iterate();
    while (it.next(io) catch @panic("iterate failed")) |entry| {
        if (entry.kind != .directory) continue;
        out.append(arena, b.fmt("{s}/{s}", .{ dir, entry.name })) catch @panic("OOM");
    }
    std.mem.sort([]const u8, out.items, {}, lessThanString);
    return out.items;
}

fn readRootFile(b: *Build, rel: []const u8) []u8 {
    return readAbsFile(b, rootJoin(b, rel));
}

fn readAbsFile(b: *Build, abs: []const u8) []u8 {
    const dir = std.Io.Dir.openDirAbsolute(b.graph.io, std.fs.path.dirname(abs).?, .{}) catch
        std.debug.panic("cannot open dir of: {s}", .{abs});
    return dir.readFileAlloc(b.graph.io, std.fs.path.basename(abs), b.graph.arena, .limited(16 * 1024 * 1024)) catch
        std.debug.panic("cannot read: {s}", .{abs});
}

fn addDynamicExports(b: *Build, run: *Step.Run) void {
    const path = "src/symbols.dyn";
    const text = readRootFile(b, path);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var opened = false;
    var closed = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "{")) {
            if (opened or closed) @panic("invalid dynamic export list");
            opened = true;
            continue;
        }
        if (std.mem.eql(u8, line, "};")) {
            if (!opened or closed) @panic("invalid dynamic export list");
            closed = true;
            continue;
        }
        if (!opened or closed or !std.mem.endsWith(u8, line, ";")) @panic("invalid dynamic export list");
        const symbol = line[0 .. line.len - 1];
        // Mold otherwise ignores stale entries, so keep this file an exact ABI manifest.
        run.addArg(b.fmt("--require-defined={s}", .{symbol}));
    }
    if (!opened or !closed) @panic("invalid dynamic export list");
    run.addPrefixedFileArg("--export-dynamic-symbol-list=", b.path(path));
}

// ───────────────────────────────────────────────────────────────────────────
// Link + smoke test
// ───────────────────────────────────────────────────────────────────────────

pub fn addLink(
    b: *Build,
    deps: *const DepPkgs,
    archives: []const *Step.Compile,
    zig_obj_bin: LazyPath,
    cg: *const Codegen,
    opts: Options,
) BunExe {
    const cxxrt = discoverZigCxxRuntime(b, opts.optimize);

    // Direct mold invocation: every input is explicit, so no compiler driver
    // is involved in the link at all.
    const run = b.addRunFile(deps.mold);
    const exe_name = if (opts.mode == .debug) "bun-debug" else "bun-profile";
    run.step.name = b.fmt("link {s}", .{exe_name});

    run.addArgs(&.{"-o"});
    const exe = run.addOutputFileArg(exe_name);

    // Debug: mold splits DWARF and the symbol table into a sibling .dbg,
    // written in the background by a detached child and found through the
    // embedded .gnu_debuglink. The step must not capture stdio: the writer
    // inherits the pipes, and a captured step would wait for their EOF. As
    // a side-effect step the link also reuses one output directory rather
    // than accreting a gigabyte-sized one per --watch cycle.
    const dbg_name = b.fmt("{s}.dbg", .{exe_name});
    const debug_file: ?LazyPath = if (opts.mode == .debug) dbg: {
        const dbg_file = run.addPrefixedOutputFileArg("--separate-debug-file=", dbg_name);
        run.stdio = .inherit;
        break :dbg dbg_file;
    } else null;

    run.addArgs(&.{ "--dynamic-linker", "/lib64/ld-linux-x86-64.so.2" });
    // Only crt1: init_array needs no crti/crtbegin bookends (zig's own links
    // prove this out on modern glibc).
    run.addFileArg(.{ .cwd_relative = cxxrt.crt1 });

    // Whole-archive: every object participates, exactly as if the .o files
    // were on the link line individually.
    run.addArg("--whole-archive");
    for (archives) |lib| run.addArtifactArg(lib);
    run.addArg("--no-whole-archive");
    run.addFileArg(zig_obj_bin);
    run.addFileArg(b.path("src/build/prebuilt/liblolhtml.a"));
    const wk = opts.webkit.libs;
    run.addArtifactArg(wk.wtf);
    run.addArtifactArg(wk.jsc);
    run.addArtifactArg(wk.jsc_c);
    run.addArtifactArg(wk.bmalloc_cxx);
    run.addArtifactArg(wk.bmalloc_c);
    run.addArtifactArg(opts.icu.data);
    run.addArtifactArg(opts.icu.i18n);
    run.addArtifactArg(opts.icu.uc);
    for ([_][]const u8{ cxxrt.libcxxabi, cxxrt.libcxx, cxxrt.libunwind, cxxrt.compiler_rt }) |lib| {
        run.addFileArg(.{ .cwd_relative = lib });
    }

    run.addArgs(&.{
        "--eh-frame-hdr",
        "--as-needed",
        "-z",
        "stack-size=12800000",
        "-z",
        "lazy",
        "-z",
        "norelro",
        "--hash-style=both",
        "--build-id=sha1",
    });
    addDynamicExports(b, run);
    if (opts.mode == .release) {
        run.addArgs(&.{
            "--compress-debug-sections=zlib",
            "--gc-sections",
            "--icf=safe",
            "--sort-section=name",
        });
    }
    run.addArgs(&.{ "-L/usr/lib", "-L/lib", "-lc", "-lm", "-lpthread", "-ldl" });

    // Hardlink install: a copying install would rewrite (and, as a cached
    // step, content-hash) the gigabyte-scale binary every cycle. Always
    // runs; the script is its own no-op check.
    const install = b.addRunFile(deps.bun);
    install.addFileArg(b.path("src/build/install-exe.ts"));
    install.addFileArg(exe);
    install.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = exe_name } });
    if (debug_file) |f| {
        install.addFileArg(f);
        install.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = dbg_name } });
    }
    install.has_side_effects = true;
    install.step.name = b.fmt("install {s}", .{exe_name});
    install.step.dependOn(cg.sync_step);

    // Smoke test: catches load-time breakage (missing symbols, static
    // initializer failures) before anything else runs the binary. Always
    // runs: caching it would hash the whole binary to skip a millisecond
    // run.
    const smoke = b.addRunFile(exe);
    smoke.addArg("--revision");
    smoke.expectExitCode(0);
    smoke.has_side_effects = true;
    smoke.step.dependOn(&install.step);
    smoke.step.name = b.fmt("smoke test {s} --revision", .{exe_name});

    const step = b.step("bun", "Build the bun executable");
    step.dependOn(&smoke.step);

    if (opts.mode == .release) {
        const strip = b.addSystemCommand(&.{ "strip", "--strip-all", "--strip-debug", "--discard-all" });
        strip.addFileArg(exe);
        strip.addArg("-o");
        const stripped = strip.addOutputFileArg("bun");
        const install_stripped = b.addInstallBinFile(stripped, "bun");
        step.dependOn(&install_stripped.step);
    }

    return .{ .exe = exe, .step = step };
}
