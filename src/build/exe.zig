//! The `zig build` graph for the bun executable: pinned inputs, vendored
//! dependencies, codegen, Bun C/C++, link, and smoke test. x86_64-linux.
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

const schema_bindings_cpp_shard_count = 8;
const binding_rapidhash_source = "src/hash/rapidhash.zig";

pub const Mode = enum { debug, release };

pub const NodejsCompatibility = struct {
    version: std.SemanticVersion,
    abi_version: u32,
    v8_version: []const u8,
};

/// Patches applied to vendored dep sources before compiling. Entries that are
/// not .patch files are overlays copied into the source root.
const dep_patches = [_]struct { dep: []const u8, files: []const []const u8 }{
    .{ .dep = "boringssl", .files = &.{"patches/boringssl/transactional-server-name.patch"} },
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
    .{ .dep = "cares", .files = &.{"patches/cares/allocation-free-cancel.patch"} },
    .{ .dep = "highway", .files = &.{"patches/highway/silence-warnings.patch"} },
    .{ .dep = "lshpack", .files = &.{ "patches/lshpack/bss-huff-tables.patch", "patches/lshpack/encoder-clone.patch", "patches/lshpack/decoder-results.patch" } },
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
    "src/jsc/modules/BunJSCModule.cpp",
    "src/jsc/bindings/ZigGlobalObject.cpp",
    "src/jsc/bindings/BunObject.cpp",
    "src/jsc/bindings/EngineBindings.cpp",
    "src/jsc/bindings/DeepEqualityBindings.cpp",
    "src/jsc/bindings/PropertyBindings.cpp",
    "src/jsc/bindings/BunProcess.cpp",
    "src/jsc/bindings/JSBuffer.cpp",
    "src/jsc/bindings/napi.cpp",
    "src/jsc/bindings/webcore/SerializedScriptValue.cpp",
    "src/jsc/bindings/webcore/HTTPParsers.cpp",
    "src/jsc/bindings/webcore/JSWasmStreamingCompiler.cpp",
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
    "src/libc_sys/WindowsCompatibility.cpp",
    "src/libc_sys/LibCppAbort.cpp",
    "packages/bun-usockets/src/crypto/root_certs_windows.cpp",
    "packages/bun-usockets/src/crypto/root_certs_darwin.cpp",
    // Highway's per-target include guards require each dispatching kernel to
    // compile in its own translation unit.
    "src/image_sys/Kernels.cpp",
    "src/highway_sys/Hash.cpp",
    "src/highway_sys/Strings.cpp",
    "src/image_sys/CoreGraphics.cpp",
    "src/image_sys/Wic.cpp",
    "src/perf_sys/Signpost.cpp",
    "src/rescle_sys/Resources.cpp",
    "src/rescle_sys/rescle.cpp",
    "src/webview_sys/host_main.cpp",
    "src/webview_sys/ObjCRuntime.cpp",
    "src/webview_sys/WebViewHost.cpp",
};

/// Directories scanned (non-recursively) for bun's own C++ sources.
const cxx_dirs = [_][]const u8{
    "src/io",
    "src/libc_sys",
    "src/highway_sys",
    "src/image_sys",
    "src/perf_sys",
    "src/rescle_sys",
    "src/webview_sys",
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
    "src/runtime/valkey_jsc",
    "src/runtime/webview",
    "src/bake",
    "src/uws_sys",
    "src/simdutf_sys",
    "src/jsc/bindings/vm",
    "packages/bun-usockets/src/crypto",
};

/// Directories scanned (non-recursively) for bun's own C sources.
const c_dirs = [_][]const u8{
    "src/libc_sys",
    "src/lshpack_sys",
    "src/exe_format",
    "src/tcc_sys",
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
    optimize: std.builtin.Optimize,
    codegen_embed: bool,
    /// `Bun.version`, from package.json unless overridden.
    version: []const u8,
    /// 40-hex git sha or null. Baked into bun_dependency_versions.h for
    /// process.versions.uws/usockets; CI passes it, dev builds stay null so
    /// commits don't invalidate compiles.
    sha: ?[]const u8,
    nodejs: NodejsCompatibility,
    target: Build.ResolvedTarget,
    /// WTF/bmalloc/JSC compiled from vendor/webkit plus the vendored header
    /// set.
    webkit: *const @import("webkit.zig").Ctx,
    /// ICU compiled from the pinned source tarball.
    icu: *const @import("icu.zig").Ctx,
};

pub const BindingArtifacts = struct {
    step: *Step,
    headers_dir: LazyPath,
    wire_dir: LazyPath,
    typescript_dir: LazyPath,
    cpp_dir: LazyPath,
    wire_header: LazyPath,
    ir: LazyPath,
    fingerprint: LazyPath,
    implementations: LazyPath,
};

pub const BindingCodegen = struct {
    ir_module: *Build.Module,
    generator: *Step.Compile,
    sources: []const []const u8,
    artifacts: std.array_hash_map.String(*const BindingArtifacts) = .empty,
    posix_implementations: ?LazyPath = null,
    windows_implementations: ?LazyPath = null,
    wire_checks: std.ArrayList(struct {
        query: std.Target.Query,
        step: *Step,
    }) = .empty,

    pub fn forTarget(self: *BindingCodegen, b: *Build, target: Build.ResolvedTarget) ?*const BindingArtifacts {
        const name = bindingTargetName(target) orelse return null;
        if (self.artifacts.get(name)) |artifacts| return artifacts;

        const implementations = if (target.result.os.tag == .windows)
            &self.windows_implementations
        else
            &self.posix_implementations;
        if (implementations.* == null)
            implementations.* = bindingImplementationAggregator(b, self.sources, target);

        const emit_run = b.addRunArtifact(self.generator);
        emit_run.addArgs(&.{ "--target", name, "--cpp-shards", b.fmt("{d}", .{schema_bindings_cpp_shard_count}) });
        const headers_dir = emit_run.addPrefixedOutputDirectoryArg("--headers=", "schema-bindings-headers");
        const wire_dir = emit_run.addPrefixedOutputDirectoryArg("--wire=", "schema-bindings-wire");
        const typescript_dir = emit_run.addPrefixedOutputDirectoryArg("--typescript=", "schema-bindings-typescript");
        const cpp_dir = emit_run.addPrefixedOutputDirectoryArg("--cpp=", "schema-bindings-cpp");
        const artifacts = b.graph.arena.create(BindingArtifacts) catch @panic("OOM");
        artifacts.* = .{
            .step = &emit_run.step,
            .headers_dir = headers_dir,
            .wire_dir = wire_dir,
            .typescript_dir = typescript_dir,
            .cpp_dir = cpp_dir,
            .wire_header = wire_dir.path(b, "SchemaBindingsWire.h"),
            .ir = emit_run.addPrefixedOutputFileArg("--ir=", "BindingIR.zon"),
            .fingerprint = emit_run.addPrefixedOutputFileArg("--fingerprint=", "BindingFingerprint.zon"),
            .implementations = implementations.*.?,
        };
        self.artifacts.put(b.graph.arena, name, artifacts) catch @panic("OOM");
        return artifacts;
    }

    pub fn checkWireTypes(self: *BindingCodegen, b: *Build, target: Build.ResolvedTarget) *Step {
        for (self.wire_checks.items) |check| {
            if (check.query.eql(target.query)) return check.step;
        }
        const artifacts = self.forTarget(b, target).?;
        const translate = b.addTranslateC(.{
            .root_source_file = artifacts.wire_header,
            .target = target,
            .optimize = .debug,
            .link_libc = true,
        });
        const check = b.addObject(.{
            .name = "check-wire-types",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bindgen/wire_check_main.zig"),
                .target = target,
                .optimize = .debug,
                .imports = &.{
                    .{ .name = "bindgen_ir", .module = self.ir_module },
                    .{ .name = "binding_ir", .module = b.createModule(.{ .root_source_file = artifacts.ir }) },
                    .{ .name = "binding_wire", .module = b.createModule(.{ .root_source_file = translate.getOutput() }) },
                },
            }),
        });
        check.incremental = false;
        self.wire_checks.append(b.graph.arena, .{ .query = target.query, .step = &check.step }) catch @panic("OOM");
        return &check.step;
    }
};

/// What downstream consumers need from host asset codegen.
pub const Codegen = struct {
    /// Generated .cpp files, compiled straight from their generating steps.
    cpp_sources: []const LazyPath,
    /// Raw schema artifacts used by compiler-adjacent native consumers.
    schema_bindings_dirs: []const LazyPath,
    /// Absolute path of the stable codegen dir; baked as
    /// build_options.codegen_path and used as -I for C/C++.
    codegen_install_abs: []const u8,
    /// Absolute path baked as BUN_DYNAMIC_JS_LOAD_PATH (debug builtin JS).
    js_install_abs: []const u8,
    /// Absolute path of the stable dir holding the precompiled header.
    pch_install_abs: []const u8,
    mysql_domain: *Build.Module,
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
    srcs: std.array_hash_map.String(LazyPath),
    /// dep name → absolute path of the pristine zon package, for
    /// configure-time reads of files patches don't touch (*.h.in templates).
    srcs_abs: std.array_hash_map.String([]const u8),
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
pub fn resolveDeps(b: *Build) ?DepPkgs {
    const arena = b.graph.arena;
    var ok = true;
    const bootstrap = lazyDep(b, "bun_bootstrap", &ok);
    const icu = lazyDep(b, "icu", &ok);
    const nodejs = lazyDep(b, "nodejs_headers", &ok);
    const mold = lazyDep(b, "mold", &ok);
    var pkgs: std.array_hash_map.String(*Build.Dependency) = .empty;
    for (recipes.all) |dep| {
        if (dep.in_tree) continue;
        const pkg = lazyDep(b, zonName(b, dep.name), &ok) orelse continue;
        pkgs.put(arena, dep.name, pkg) catch @panic("OOM");
    }
    if (!ok) return null;

    // The fetcher strips each archive's single root directory.
    const bun_exe = bootstrap.?.path("bun");
    var srcs: std.array_hash_map.String(LazyPath) = .empty;
    var srcs_abs: std.array_hash_map.String([]const u8) = .empty;
    for (pkgs.keys(), pkgs.values()) |name, pkg| {
        srcs.put(arena, name, patchedRoot(b, name, bun_exe, pkg.path(""))) catch @panic("OOM");
        srcs_abs.put(arena, name, depRootAbs(b, pkg)) catch @panic("OOM");
    }

    const nodejs_headers = blk: {
        const run = b.addRunFile(bun_exe);
        run.addFileArg(b.path("src/build/apply-patches.ts"));
        run.addDirectoryArg(nodejs.?.path(b.fmt("node-v{s}", .{zonRef(b, "nodejs_headers")})));
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
/// The engine metadata recorded in vendor/webkit/VENDOR.
fn webkitVendorMetadata(b: *Build) []const u8 {
    const path = "vendor/webkit/VENDOR";
    b.dependOnFileContents(b.path(path));
    return readRootFile(b, path);
}

fn webkitVendorCommit(b: *Build) []const u8 {
    const text = webkitVendorMetadata(b);
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

pub fn nodejsCompatibility(b: *Build) !NodejsCompatibility {
    return .{
        .version = try std.SemanticVersion.parse(zonRef(b, "nodejs_headers")),
        .abi_version = 147,
        .v8_version = "14.6.202.34-node.20",
    };
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

pub fn addBindingCodegen(b: *Build) *BindingCodegen {
    const arena = b.graph.arena;
    const binding_codegen = arena.create(BindingCodegen) catch @panic("OOM");
    const zig_sources = listFiles(b, "src", ".zig", true);

    const bindgen_ir = b.createModule(.{
        .root_source_file = b.path("src/bindgen/ir.zig"),
    });
    const bindgen_schema = b.createModule(.{
        .root_source_file = b.path("src/bindgen/schema.zig"),
    });
    bindgen_schema.addImport("bindgen_ir", bindgen_ir);

    checkGeneratorHostIndependence(b);
    const schema_graph = resolveSchemaGraph(b, listFiles(b, "src", ".schema.zig", true));
    const schema_imports = b.addWriteFiles();
    var schema_aggregator: std.ArrayList(u8) = .empty;
    for (schema_graph.order, 0..) |_, i| {
        schema_aggregator.print(arena, "const schema_{d} = @import(\"binding_schema_{d}\");\n", .{ i, i }) catch @panic("OOM");
    }
    schema_aggregator.appendSlice(arena, "\npub const modules = .{\n") catch @panic("OOM");
    for (schema_graph.order, 0..) |_, i| {
        schema_aggregator.print(arena, "    schema_{d}.schema,\n", .{i}) catch @panic("OOM");
    }
    schema_aggregator.appendSlice(arena, "};\n") catch @panic("OOM");
    schema_aggregator.appendSlice(arena, "\npub const source_stems = .{\n") catch @panic("OOM");
    for (schema_graph.order) |source_index| {
        const basename = std.fs.path.basename(schema_graph.sources[source_index]);
        const stem = basename[0 .. basename.len - ".schema.zig".len];
        schema_aggregator.print(arena, "    \"{s}\",\n", .{stem}) catch @panic("OOM");
    }
    schema_aggregator.appendSlice(arena, "};\n") catch @panic("OOM");
    const schema_aggregator_file = schema_imports.add("binding_schemas.zig", schema_aggregator.items);
    const binding_schemas = b.createModule(.{ .root_source_file = schema_aggregator_file });
    const schema_modules = createSchemaModules(b, schema_graph, bindgen_schema);
    for (schema_graph.order, 0..) |source_index, i| {
        binding_schemas.addImport(b.fmt("binding_schema_{d}", .{i}), schema_modules[source_index]);
    }
    const generator = b.addExecutable(.{
        .name = "binding-generator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bindgen/generator.zig"),
            .target = b.graph.host,
            .optimize = .debug,
            .strip = true,
            .imports = &.{
                .{ .name = "bindgen_ir", .module = bindgen_ir },
                .{ .name = "bindgen_schema", .module = bindgen_schema },
                .{ .name = "binding_schemas", .module = binding_schemas },
                .{ .name = "rapidhash", .module = b.createModule(.{ .root_source_file = b.path(binding_rapidhash_source) }) },
            },
        }),
    });
    generator.incremental = false;
    binding_codegen.* = .{
        .ir_module = bindgen_ir,
        .generator = generator,
        .sources = zig_sources,
    };
    return binding_codegen;
}

pub fn addCodegen(
    b: *Build,
    deps: *const DepPkgs,
    mode: Mode,
    binding_codegen: *BindingCodegen,
    zstd: *Step.Compile,
) *Codegen {
    const arena = b.graph.arena;
    const cg = arena.create(Codegen) catch @panic("OOM");
    const target = b.graph.host;
    const bindings = binding_codegen.forTarget(b, target).?;
    const mysql_domain = b.createModule(.{
        .root_source_file = b.path("src/sql/mysql/domain.zig"),
    });

    const stable_root = rootJoin(b, b.fmt("build/zig/{s}", .{@tagName(mode)}));
    const sync = b.addRunFile(deps.bun);
    sync.addFileArg(b.path("src/build/sync-dirs.ts"));
    sync.addArg(stable_root);
    sync.has_side_effects = true;
    sync.step.name = "sync codegen";
    var sp: SyncPairs = .{ .run = sync };

    cg.* = .{
        .cpp_sources = &.{},
        .schema_bindings_dirs = undefined,
        .codegen_install_abs = std.fs.path.join(arena, &.{ stable_root, "codegen" }) catch @panic("OOM"),
        .js_install_abs = std.fs.path.join(arena, &.{ stable_root, "js" }) catch @panic("OOM"),
        .pch_install_abs = std.fs.path.join(arena, &.{ stable_root, "pch" }) catch @panic("OOM"),
        .mysql_domain = mysql_domain,
        .sync_step = &sync.step,
    };

    var cpp_sources: std.ArrayList(LazyPath) = .empty;

    const install_root = bunInstall(b, deps, "");
    const install_bun_error = bunInstall(b, deps, "packages/bun-error");
    const install_node_fallbacks = bunInstall(b, deps, "src/node-fallbacks");

    const esbuild = b.path("node_modules/.bin/esbuild");
    const debug_flag = if (mode == .debug) "--debug=ON" else "--debug=OFF";

    // ─── compress-add-completions <input> <output> ───
    {
        const tool = b.addExecutable(.{
            .name = "compress-add-completions",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/build/compress-add-completions.zig"),
                .target = cppTarget(b, &.{}),
                .optimize = .debug,
                .link_libc = true,
            }),
        });
        tool.incremental = false;
        tool.root_module.linkLibrary(zstd);

        const run = b.addRunArtifact(tool);
        run.addFileArg(b.path("src/cli/add_completions.txt"));
        const out = run.addOutputFileArg("add-completions.txt.zst");
        sp.addFile(out, "codegen/add-completions.txt.zst");
    }

    // ─── schema bindings ───
    const schema_bindings_headers_dir = bindings.headers_dir;
    const schema_bindings_wire_dir = bindings.wire_dir;
    const schema_bindings_typescript_dir = bindings.typescript_dir;
    const schema_bindings_cpp_dir = bindings.cpp_dir;
    sync.step.dependOn(binding_codegen.checkWireTypes(b, target));
    for (0..schema_bindings_cpp_shard_count) |shard| {
        cpp_sources.append(
            arena,
            schema_bindings_cpp_dir.path(b, b.fmt("SchemaBindings{d}.cpp", .{shard})),
        ) catch @panic("OOM");
    }
    cpp_sources.append(arena, schema_bindings_wire_dir.path(b, "NativeModuleRegistry.cpp")) catch @panic("OOM");
    cpp_sources.append(arena, schema_bindings_wire_dir.path(b, "SchemaBindingsIdentifiers.cpp")) catch @panic("OOM");
    sp.add(schema_bindings_headers_dir, "codegen");
    sp.add(schema_bindings_wire_dir, "codegen");
    sp.add(schema_bindings_typescript_dir, "codegen");

    const node_error_types = blk: {
        const run = script(b, deps, "src/codegen/generate-node-errors.ts", .{ .use_run = true });
        const out = run.addOutputDirectoryArg("codegen");
        run.addFileArg(schema_bindings_wire_dir.path(b, "SchemaBindingsLinkMetadata.json"));
        run.addFileInput(b.path("src/js/builtins.d.ts"));
        break :blk out;
    };
    sp.add(node_error_types, "codegen");

    // ─── bundle-modules.ts --debug=X <BUILD_PATH> <NATIVE_MODULE_MANIFEST> <BINDGEN_LINK_METADATA> ───
    const bundle_dir = blk: {
        const run = script(b, deps, "src/codegen/bundle-modules.ts", .{ .use_run = true });
        run.addArg(debug_flag);
        const out = run.addOutputDirectoryArg("bundle-modules");
        run.addFileArg(schema_bindings_wire_dir.path(b, "NativeModuleManifest.json"));
        run.addFileArg(schema_bindings_wire_dir.path(b, "SchemaBindingsLinkMetadata.json"));
        for (listFiles(b, "src/js", ".ts", true)) |f| run.addFileInput(b.path(f));
        for (listFiles(b, "src/js", ".js", true)) |f| run.addFileInput(b.path(f));
        run.addFileInput(b.path("src/install/PackageManager/scanner-entry.ts"));
        run.addFileInput(b.path("src/jsc/bindings/InternalModuleRegistry.cpp"));
        break :blk out;
    };
    const bundle_codegen = bundle_dir.path(b, "codegen");
    cpp_sources.append(arena, bundle_codegen.path(b, "WebCoreJSBuiltins.cpp")) catch @panic("OOM");
    sp.add(bundle_codegen, "codegen");
    if (mode == .debug) sp.add(bundle_dir.path(b, "js"), "js");

    // ─── wire layout verification (checked builds) ───
    // Compares the clang-compiled sizeof/alignof/offsetof table against Zig's
    // view of the translated wire header; the two target compilers are the two
    // derivations of the physical ABI.
    if (mode == .debug) {
        const layout_module = b.createModule(.{
            .root_source_file = b.path("src/bindgen/layout_check.zig"),
            .target = target,
            .optimize = .debug,
            .link_libcpp = true,
        });
        const layout_wire_translate = b.addTranslateC(.{
            .root_source_file = bindings.wire_header,
            .target = target,
            .optimize = .debug,
            .link_libc = true,
        });
        layout_module.addImport("binding_wire", b.createModule(.{
            .root_source_file = layout_wire_translate.getOutput(),
        }));
        layout_module.addCSourceFile(.{
            .file = schema_bindings_wire_dir.path(b, "SchemaWireLayout.cpp"),
            .flags = &.{ "-std=c++20", "-fno-exceptions", "-fno-rtti" },
        });
        const layout_exe = b.addExecutable(.{
            .name = "check-wire-layout",
            .root_module = layout_module,
        });
        layout_exe.incremental = false;
        sync.step.dependOn(&b.addRunArtifact(layout_exe).step);
    }

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
        run.addFileInput(b.path("src/bake/DevServerProtocol.zig"));
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
        run.addFileInput(b.path("src/runtime.js"));
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
    cg.schema_bindings_dirs = arena.dupe(LazyPath, &.{ schema_bindings_headers_dir, schema_bindings_wire_dir }) catch @panic("OOM");
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

fn baseCFlags(b: *Build, mode: Mode, optimize: std.builtin.Optimize) []const []const u8 {
    const arena = b.graph.arena;
    const mode_flags: []const []const u8 = switch (mode) {
        .debug => recipes.base_flags_debug,
        .release => recipes.base_flags_release,
    };
    var flags: std.ArrayList([]const u8) = .empty;
    if (optimize == .safe or optimize == .fast) {
        flags.append(arena, "-O3") catch @panic("OOM");
    }
    flags.appendSlice(arena, mode_flags) catch @panic("OOM");
    flags.append(arena, "-Wno-date-time") catch @panic("OOM");
    return flags.items;
}

pub const CppDeps = struct {
    archives: []const *Step.Compile,
    zstd: *Step.Compile,
    gen_dirs: std.array_hash_map.String(LazyPath),
};

pub fn addCppDeps(
    b: *Build,
    deps: *const DepPkgs,
    mode: Mode,
    optimize: std.builtin.Optimize,
) CppDeps {
    const arena = b.graph.arena;
    const gen_dirs = makeGenDirs(b, deps);
    var archives: std.ArrayList(*Step.Compile) = .empty;
    var zstd: ?*Step.Compile = null;

    for (recipes.all) |dep| {
        const library_optimize: std.builtin.Optimize = if (mode == .debug) switch (dep.debug_optimize) {
            .debug => .debug,
            .safe => .safe,
        } else optimize;
        const base_flags = baseCFlags(b, mode, library_optimize);
        const root: ?LazyPath = if (dep.in_tree) null else deps.srcs.get(dep.name).?;
        for (dep.groups, 0..) |group, gi| {
            const group_flags = if (mode == .release and group.flags_release != null)
                group.flags_release.?
            else
                group.flags;
            const cxx_lang = group.cxx or hasLangOverride(group_flags);
            const name = if (dep.groups.len == 1) dep.name else b.fmt("{s}-{d}", .{ dep.name, gi });
            const lib = newCppLib(b, name, library_optimize, cxx_lang, groupFeatures(b, group_flags));

            var flags: std.ArrayList([]const u8) = .empty;
            if (!group.no_base) flags.appendSlice(arena, base_flags) catch @panic("OOM");
            var i: usize = 0;
            while (i < group_flags.len) : (i += 1) {
                if (std.mem.eql(u8, group_flags[i], "-x")) {
                    i += 1;
                    continue;
                }
                flags.append(arena, group_flags[i]) catch @panic("OOM");
            }

            for (group.includes) |inc| addCppDepInclude(b, lib, inc, deps, &gen_dirs);
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
            if (std.mem.eql(u8, dep.name, recipes.zstd.name)) zstd = lib;
        }
    }

    return .{
        .archives = archives.items,
        .zstd = zstd.?,
        .gen_dirs = gen_dirs,
    };
}

/// Static archives in link order (whole-archive).
pub fn addCpp(
    b: *Build,
    deps: *const DepPkgs,
    cg: *const Codegen,
    cpp_deps: CppDeps,
    opts: Options,
) []const *Step.Compile {
    const arena = b.graph.arena;
    var archives: std.ArrayList(*Step.Compile) = .empty;

    const base_flags = baseCFlags(b, opts.mode, opts.optimize);
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

        const lib_cxx = newCppLib(b, "bun-cxx", opts.optimize, true, &.{});
        const lib_c = newCppLib(b, "bun-c", opts.optimize, false, &.{});
        for (recipes.bun_includes) |inc| addInclude(b, lib_cxx, inc, deps, cg, opts.webkit, &cpp_deps.gen_dirs, versions_dir);
        for (recipes.bun_c_includes) |inc| addInclude(b, lib_c, inc, deps, cg, opts.webkit, &cpp_deps.gen_dirs, versions_dir);

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
            const pch_step = addPch(b, deps, cg, opts.webkit, cxx_flags.items, &cpp_deps.gen_dirs, versions_dir);
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

    archives.appendSlice(arena, cpp_deps.archives) catch @panic("OOM");

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
    gen_dirs: *const std.array_hash_map.String(LazyPath),
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

fn newCppLib(b: *Build, name: []const u8, optimize: std.builtin.Optimize, is_cxx: bool, extra_features: []const []const u8) *Step.Compile {
    const mod = b.createModule(.{
        .target = cppTarget(b, extra_features),
        .optimize = optimize,
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

fn bindingTargetName(target: Build.ResolvedTarget) ?[]const u8 {
    return switch (target.result.cpu.arch) {
        .x86_64 => switch (target.result.os.tag) {
            .linux => "x86_64-linux",
            .macos => "x86_64-macos",
            .windows => "x86_64-windows",
            else => null,
        },
        .aarch64 => switch (target.result.os.tag) {
            .linux => "aarch64-linux",
            .macos => "aarch64-macos",
            .windows => "aarch64-windows",
            else => null,
        },
        else => null,
    };
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
pub fn discoverZigCxxRuntime(b: *Build, optimize: std.builtin.Optimize) ZigCxxRuntime {
    const arena = b.graph.arena;
    if (zig_cxx_runtime_cache) |c| return c;
    const io = b.graph.io;
    const dir_abs = rootJoin(b, ".zig-cache");
    var dir = std.Io.Dir.openDirAbsolute(io, dir_abs, .{}) catch @panic("open .zig-cache");
    defer dir.close(io);
    dir.writeFile(io, .{ .sub_path = "cxx-runtime-probe.cpp", .data = "int main(){return 0;}\n" }) catch @panic("write cxx probe");
    // --verbose-link prints to stderr.
    const runtime_optimize: std.builtin.Optimize = if (optimize == .debug) .fast else optimize;
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
fn makeGenDirs(b: *Build, deps: *const DepPkgs) std.array_hash_map.String(LazyPath) {
    const arena = b.graph.arena;
    var dirs: std.array_hash_map.String(LazyPath) = .empty;

    {
        const root_abs = deps.srcs_abs.get("libffi").?;
        const wf = b.addWriteFiles();
        _ = wf.add("ffi.h", substFile(b, root_abs, "include/ffi.h.in", &.{
            .{ "@VERSION@", "3.8.0" },
            .{ "@TARGET@", "X86_64" },
            .{ "@HAVE_LONG_DOUBLE@", "1" },
            .{ "@FFI_EXEC_TRAMPOLINE_TABLE@", "0" },
            .{ "@FFI_VERSION_STRING@", "3.8.0" },
            .{ "@FFI_VERSION_NUMBER@", "30800" },
        }));
        _ = wf.addCopyFile(b.path("src/build/assets/libffi/fficonfig.h"), "fficonfig.h");
        _ = wf.addCopyFile(deps.srcs.get("libffi").?.path(b, "src/x86/ffitarget.h"), "ffitarget.h");
        dirs.put(arena, "libffi", wf.getDirectory()) catch @panic("OOM");
    }

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
        const tool_mod = b.createModule(.{ .target = b.graph.host, .optimize = .fast, .link_libc = true });
        tool_mod.addCSourceFile(.{
            .file = root.path(b, "conftest.c"),
            .flags = &.{ "-w", "-DC2STR" },
            .language = .c,
        });
        const tool = b.addExecutable(.{ .name = "tinycc-conftest", .root_module = tool_mod });
        tool.incremental = false;
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
    const nodejs_version = b.fmt("{f}", .{opts.nodejs.version});
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
        .{ "NODEJS_COMPAT_VERSION", nodejs_version },
        .{ "UWS", sha },
        .{ "USOCKETS", sha },
        .{ "ZIG", zig_ref },
    }) catch @panic("OOM");

    var text: std.ArrayList(u8) = .empty;
    text.appendSlice(arena,
        \\// Generated by src/build/exe.zig. Do not edit.
        \\#ifndef BUN_DEPENDENCY_VERSIONS_H
        \\#define BUN_DEPENDENCY_VERSIONS_H
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    ) catch @panic("OOM");
    text.print(arena,
        \\#define REPORTED_NODEJS_VERSION "{s}"
        \\#define REPORTED_NODEJS_ABI_VERSION {d}
        \\#define REPORTED_NODEJS_V8_VERSION "{s}"
        \\
    , .{ nodejs_version, opts.nodejs.abi_version, opts.nodejs.v8_version }) catch @panic("OOM");
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

fn addCppDepInclude(
    b: *Build,
    lib: *Step.Compile,
    inc: recipes.Include,
    deps: *const DepPkgs,
    gen_dirs: *const std.array_hash_map.String(LazyPath),
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
        .repo => |path| lib.root_module.addIncludePath(b.path(path)),
        else => @panic("vendored dependency has a late-bound include"),
    }
}

fn addInclude(
    b: *Build,
    lib: *Step.Compile,
    inc: recipes.Include,
    deps: *const DepPkgs,
    cg: *const Codegen,
    wk: *const @import("webkit.zig").Ctx,
    gen_dirs: *const std.array_hash_map.String(LazyPath),
    versions_dir: LazyPath,
) void {
    switch (inc) {
        .dep, .gen, .repo => addCppDepInclude(b, lib, inc, deps, gen_dirs),
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

    var skip: std.array_hash_map.String(void) = .empty;
    for (no_unify) |f| skip.put(arena, f, {}) catch @panic("OOM");

    var by_dir: std.array_hash_map.String(std.ArrayList([]const u8)) = .empty;
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

fn bindingImplementationAggregator(
    b: *Build,
    sources: []const []const u8,
    target: Build.ResolvedTarget,
) LazyPath {
    const arena = b.graph.arena;
    const public_paths = bindingPublicImportPaths(b);
    var contents: std.ArrayList(u8) = .empty;
    var missing_paths: std.ArrayList(u8) = .empty;
    var missing_forces: std.ArrayList(u8) = .empty;
    var invalid_escapes: std.ArrayList(u8) = .empty;
    contents.appendSlice(arena, "const bun = @import(\"bun\");\n\ncomptime {\n") catch @panic("OOM");
    for (sources) |source| {
        if (!bindingImplementationEnabled(source, target)) continue;
        const text = arena.dupeSentinel(u8, readRootFile(b, source), 0) catch @panic("OOM");
        const scan = scanBindingInstantiations(arena, text);
        for (scan.invalid_escape_lines) |line| {
            invalid_escapes.print(arena, "\n{s}:{d}", .{ source, line }) catch @panic("OOM");
        }
        if (!scan.any) continue;
        if (scan.top_level and !scan.top_level_comptime) {
            missing_forces.print(arena, "\n{s}: no top-level comptime block", .{source}) catch @panic("OOM");
        }
        for (scan.unforced) |name| {
            missing_forces.print(arena, "\n{s}: {s}", .{ source, name }) catch @panic("OOM");
        }
        const public_path = public_paths.get(source) orelse {
            missing_paths.print(arena, "\n{s}", .{source}) catch @panic("OOM");
            continue;
        };
        contents.print(arena, "    _ = &bun{s};\n", .{public_path}) catch @panic("OOM");
    }
    if (missing_paths.items.len != 0) std.debug.panic("binding implementations are not publicly reachable from src/bun.zig:{s}", .{missing_paths.items});
    if (missing_forces.items.len != 0) std.debug.panic("top-level binding implementations are not forced by a top-level comptime block:{s}", .{missing_forces.items});
    if (invalid_escapes.items.len != 0) std.debug.panic("binding escapes must be requested by a private top-level `const … = bindgen.Escape(@This());`:{s}", .{invalid_escapes.items});
    contents.appendSlice(arena, "}\n\npub const source_files = struct {\n") catch @panic("OOM");
    for (public_paths.keys(), public_paths.values()) |source, public_path| {
        if (!bindingImplementationEnabled(source, target)) continue;
        contents.print(arena, "    pub const @\"{s}\" = bun{s};\n", .{ source, public_path }) catch @panic("OOM");
    }
    contents.appendSlice(arena, "};\n") catch @panic("OOM");
    return b.addWriteFiles().add("binding_implementations.zig", contents.items);
}

fn bindingPublicImportPaths(b: *Build) std.array_hash_map.String([]const u8) {
    const arena = b.graph.arena;
    var paths: std.array_hash_map.String([]const u8) = .empty;
    var namespace_paths: std.array_hash_map.String([]const u8) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    paths.put(arena, "src/bun.zig", "") catch @panic("OOM");
    namespace_paths.put(arena, "src/bun.zig", "") catch @panic("OOM");
    pending.append(arena, "src/bun.zig") catch @panic("OOM");

    var pending_index: usize = 0;
    while (pending_index < pending.items.len) : (pending_index += 1) {
        const source = pending.items[pending_index];
        const parent_path = namespace_paths.get(source).?;
        const text = arena.dupeSentinel(u8, readRootFile(b, source), 0) catch @panic("OOM");
        var tokenizer = std.zig.Tokenizer.init(text);
        var tokens: std.ArrayList(std.zig.Token) = .empty;
        while (true) {
            const token = tokenizer.next();
            tokens.append(arena, token) catch @panic("OOM");
            if (token.tag == .eof) break;
        }

        var brace_depth: usize = 0;
        var i: usize = 0;
        while (i + 4 < tokens.items.len) : (i += 1) {
            const token = tokens.items[i];
            if (token.tag == .l_brace) {
                brace_depth += 1;
                continue;
            }
            if (token.tag == .r_brace) {
                brace_depth -= 1;
                continue;
            }
            if (brace_depth != 0 or token.tag != .keyword_pub) continue;
            if (tokens.items[i + 1].tag != .keyword_const or
                tokens.items[i + 2].tag != .identifier or
                tokens.items[i + 3].tag != .equal)
            {
                continue;
            }
            const name = text[tokens.items[i + 2].loc.start..tokens.items[i + 2].loc.end];
            var paren_depth: usize = 0;
            var bracket_depth: usize = 0;
            var rhs_brace_depth: usize = 0;
            var j = i + 4;
            while (j + 4 < tokens.items.len) : (j += 1) {
                const rhs_token = tokens.items[j];
                if (rhs_token.tag == .semicolon and paren_depth == 0 and bracket_depth == 0 and rhs_brace_depth == 0) break;
                switch (rhs_token.tag) {
                    .l_paren => paren_depth += 1,
                    .r_paren => paren_depth -= 1,
                    .l_bracket => bracket_depth += 1,
                    .r_bracket => bracket_depth -= 1,
                    .l_brace => rhs_brace_depth += 1,
                    .r_brace => rhs_brace_depth -= 1,
                    else => {},
                }
                if (rhs_token.tag != .builtin or
                    !std.mem.eql(u8, text[rhs_token.loc.start..rhs_token.loc.end], "@import") or
                    tokens.items[j + 1].tag != .l_paren or
                    tokens.items[j + 2].tag != .string_literal or
                    tokens.items[j + 3].tag != .r_paren)
                {
                    continue;
                }
                const literal_token = tokens.items[j + 2];
                const literal = text[literal_token.loc.start..literal_token.loc.end];
                if (literal.len < 3 or literal[0] != '"' or literal[literal.len - 1] != '"') continue;
                const import_path = literal[1 .. literal.len - 1];
                if (!std.mem.startsWith(u8, import_path, ".") or std.mem.indexOfScalar(u8, import_path, '\\') != null) continue;
                const absolute = std.fs.path.resolve(arena, &.{ rootJoin(b, std.fs.path.dirname(source).?), import_path }) catch @panic("OOM");
                const root = rootJoin(b, "");
                if (!std.mem.startsWith(u8, absolute, root) or absolute.len == root.len or absolute[root.len] != std.fs.path.sep) continue;
                const child_source = arena.dupe(u8, absolute[root.len + 1 ..]) catch @panic("OOM");
                if (std.fs.path.sep != '/') {
                    for (child_source) |*byte| if (byte.* == std.fs.path.sep) {
                        byte.* = '/';
                    };
                }
                if (!std.mem.endsWith(u8, child_source, ".zig")) continue;
                const child_path = b.fmt("{s}.{s}", .{ parent_path, name });
                const exposes_module = tokens.items[j + 4].tag != .period;
                if (exposes_module) {
                    if (paths.getPtr(child_source)) |path| {
                        path.* = child_path;
                    } else {
                        paths.put(arena, child_source, child_path) catch @panic("OOM");
                    }
                } else if (!paths.contains(child_source)) {
                    paths.put(arena, child_source, child_path) catch @panic("OOM");
                }
                if (exposes_module) {
                    if (!namespace_paths.contains(child_source)) {
                        namespace_paths.put(arena, child_source, child_path) catch @panic("OOM");
                        pending.append(arena, child_source) catch @panic("OOM");
                    }
                }
            }
            i = j;
        }
    }
    return paths;
}

fn bindingImplementationEnabled(source: []const u8, target: Build.ResolvedTarget) bool {
    if (std.mem.eql(u8, source, "src/bun.zig") or std.mem.startsWith(u8, source, "src/build/")) return false;
    const windows_only = std.mem.indexOf(u8, source, "/windows/") != null or
        std.mem.endsWith(u8, source, "_windows.zig");
    return !windows_only or target.result.os.tag == .windows;
}

const BindingInstantiationScan = struct {
    any: bool = false,
    top_level: bool = false,
    top_level_comptime: bool = false,
    unforced: []const []const u8 = &.{},
    invalid_escape_lines: []const usize = &.{},
};

/// Whether token `i` names `Escape` other than as `.Escape(@This());` ending a
/// top-level statement that starts with `const`. Escape checks the argument's
/// file identity, so the caller's own `@This()` is the only meaningful argument,
/// and a private declaration keeps the escape inside the requesting file.
fn invalidEscapeReference(text: [:0]const u8, tokens: []const std.zig.Token, i: usize, top_level: bool) bool {
    const lexeme = text[tokens[i].loc.start..tokens[i].loc.end];
    switch (tokens[i].tag) {
        .string_literal => return std.mem.eql(u8, lexeme, "\"Escape\""),
        .identifier => {
            if (std.mem.eql(u8, lexeme, "@\"Escape\"")) return true;
            if (!std.mem.eql(u8, lexeme, "Escape") or i == 0 or tokens[i - 1].tag != .period) return false;
        },
        else => return false,
    }
    const call = tokens[i + 1 ..];
    const own_file = call.len >= 6 and
        call[0].tag == .l_paren and
        call[1].tag == .builtin and std.mem.eql(u8, text[call[1].loc.start..call[1].loc.end], "@This") and
        call[2].tag == .l_paren and
        call[3].tag == .r_paren and
        call[4].tag == .r_paren and
        call[5].tag == .semicolon;
    if (!top_level or !own_file) return true;
    var start = i;
    while (start > 0) : (start -= 1) {
        switch (tokens[start - 1].tag) {
            .semicolon, .r_brace, .doc_comment, .container_doc_comment => break,
            else => {},
        }
    }
    return tokens[start].tag != .keyword_const;
}

fn scanBindingInstantiations(arena: std.mem.Allocator, text: [:0]const u8) BindingInstantiationScan {
    var tokenizer = std.zig.Tokenizer.init(text);
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    while (true) {
        const token = tokenizer.next();
        tokens.append(arena, token) catch @panic("OOM");
        if (token.tag == .eof) break;
    }

    var brace_depth: usize = 0;
    var scan: BindingInstantiationScan = .{};
    var current_declaration: ?[]const u8 = null;
    var pending_top_level_comptime = false;
    var top_level_comptime_depth: ?usize = null;
    var binding_names: std.ArrayList([]const u8) = .empty;
    var comptime_identifiers: std.StringHashMapUnmanaged(void) = .empty;
    var invalid_escape_lines: std.ArrayList(usize) = .empty;

    for (tokens.items, 0..) |token, i| {
        if (invalidEscapeReference(text, tokens.items, i, brace_depth == 0)) {
            const line = 1 + std.mem.count(u8, text[0..token.loc.start], "\n");
            invalid_escape_lines.append(arena, line) catch @panic("OOM");
        }

        if (top_level_comptime_depth != null and token.tag == .identifier) {
            const name = text[token.loc.start..token.loc.end];
            comptime_identifiers.put(arena, name, {}) catch @panic("OOM");
        }

        if (brace_depth == 0 and token.tag == .keyword_comptime) {
            scan.top_level_comptime = true;
            pending_top_level_comptime = true;
        }
        if (brace_depth == 0 and token.tag == .keyword_const and i + 1 < tokens.items.len and tokens.items[i + 1].tag == .identifier) {
            const name_token = tokens.items[i + 1];
            current_declaration = text[name_token.loc.start..name_token.loc.end];
        }

        if (token.tag == .identifier and
            std.mem.eql(u8, text[token.loc.start..token.loc.end], "bindgen") and
            i + 3 < tokens.items.len and
            tokens.items[i + 1].tag == .period and
            tokens.items[i + 2].tag == .identifier and
            tokens.items[i + 3].tag == .l_paren)
        {
            const declaration = text[tokens.items[i + 2].loc.start..tokens.items[i + 2].loc.end];
            if (std.mem.eql(u8, declaration, "Fn") or
                std.mem.eql(u8, declaration, "Class") or
                std.mem.eql(u8, declaration, "NativeExport"))
            {
                scan.any = true;
                if (brace_depth == 0) {
                    scan.top_level = true;
                    if (current_declaration) |name| binding_names.append(arena, name) catch @panic("OOM");
                }
            }
        }

        switch (token.tag) {
            .l_brace => {
                brace_depth += 1;
                if (pending_top_level_comptime) {
                    top_level_comptime_depth = brace_depth;
                    pending_top_level_comptime = false;
                }
            },
            .r_brace => {
                if (top_level_comptime_depth == brace_depth) top_level_comptime_depth = null;
                brace_depth -= 1;
            },
            .semicolon => if (brace_depth == 0) {
                current_declaration = null;
            },
            else => {},
        }
    }

    var unforced: std.ArrayList([]const u8) = .empty;
    for (binding_names.items) |name| {
        if (!comptime_identifiers.contains(name)) unforced.append(arena, name) catch @panic("OOM");
    }
    scan.unforced = unforced.items;
    scan.invalid_escape_lines = invalid_escape_lines.items;
    return scan;
}

const SchemaGraph = struct {
    sources: []const []const u8,
    import_names: []const []const u8,
    dependencies: []const []const usize,
    order: []const usize,
};

const SchemaVisit = enum {
    unseen,
    visiting,
    done,
};

fn resolveSchemaGraph(b: *Build, sources: []const []const u8) SchemaGraph {
    const arena = b.graph.arena;
    const suffix = ".schema.zig";
    const import_prefix = "binding_schema_";
    const import_names = arena.alloc([]const u8, sources.len) catch @panic("OOM");
    for (sources, 0..) |source, index| {
        const basename = std.fs.path.basename(source);
        const stem = basename[0 .. basename.len - suffix.len];
        if (stem.len == 0) std.debug.panic("binding schema has an empty file stem: {s}", .{source});
        if (!schemaStemIsIdentifier(stem)) std.debug.panic("binding schema file stem must be an identifier: {s}", .{source});
        import_names[index] = b.fmt("{s}{s}", .{ import_prefix, stem });
        for (import_names[0..index], 0..) |previous, previous_index| {
            if (std.mem.eql(u8, previous, import_names[index])) {
                std.debug.panic(
                    "binding schemas have the same import name: {s} and {s}",
                    .{ sources[previous_index], source },
                );
            }
        }
    }

    const dependencies = arena.alloc([]const usize, sources.len) catch @panic("OOM");
    for (sources, 0..) |source, source_index| {
        const text = arena.dupeSentinel(u8, readRootFile(b, source), 0) catch @panic("OOM");
        var tokenizer = std.zig.Tokenizer.init(text);
        var found: std.ArrayList(usize) = .empty;
        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) break;
            if (token.tag != .builtin or !std.mem.eql(u8, text[token.loc.start..token.loc.end], "@import")) continue;
            const left_paren = tokenizer.next();
            const literal_token = tokenizer.next();
            const right_paren = tokenizer.next();
            if (left_paren.tag != .l_paren or literal_token.tag != .string_literal or right_paren.tag != .r_paren) {
                std.debug.panic("binding schema imports must be direct string literals: {s}", .{source});
            }
            const literal = text[literal_token.loc.start..literal_token.loc.end];
            if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"' or
                std.mem.indexOfScalar(u8, literal, '\\') != null)
            {
                std.debug.panic("binding schema imports cannot use escapes: {s}", .{source});
            }
            const import_name = literal[1 .. literal.len - 1];
            if (std.mem.eql(u8, import_name, "std") or std.mem.eql(u8, import_name, "bindgen_schema")) continue;
            const dependency = schemaImportIndex(import_names, import_name) orelse
                std.debug.panic(
                    "binding schema {s} imports forbidden module {s}; only std, bindgen_schema, and discovered binding schemas are allowed",
                    .{ source, import_name },
                );
            if (dependency == source_index) {
                std.debug.panic("binding schema imports itself: {s}", .{source});
            }
            if (std.mem.indexOfScalar(usize, found.items, dependency) == null) {
                found.append(arena, dependency) catch @panic("OOM");
            }
        }
        dependencies[source_index] = found.items;
    }

    const states = arena.alloc(SchemaVisit, sources.len) catch @panic("OOM");
    @memset(states, .unseen);
    var order: std.ArrayList(usize) = .empty;
    for (sources, 0..) |_, index| {
        appendSchemaOrder(arena, sources, dependencies, states, &order, index);
    }
    return .{
        .sources = sources,
        .import_names = import_names,
        .dependencies = dependencies,
        .order = order.items,
    };
}

/// The normalizer and emitter must render the same artifacts on every host,
/// so their import closure may reach only `std`, bindgen sources, and the shared
/// runtime-independent `rapidhash` module. Every non-std import is checked
/// recursively; `builtin` and other modules are rejected.
fn checkGeneratorHostIndependence(b: *Build) void {
    const arena = b.graph.arena;
    var pending: std.ArrayList([]const u8) = .empty;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    for ([_][]const u8{ "src/bindgen/normalize.zig", "src/bindgen/emitter.zig" }) |root| {
        seen.put(arena, root, {}) catch @panic("OOM");
        pending.append(arena, root) catch @panic("OOM");
    }
    while (pending.pop()) |source| {
        const text = arena.dupeSentinel(u8, readRootFile(b, source), 0) catch @panic("OOM");
        var tokenizer = std.zig.Tokenizer.init(text);
        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) break;
            if (token.tag != .builtin or !std.mem.eql(u8, text[token.loc.start..token.loc.end], "@import")) continue;
            const left_paren = tokenizer.next();
            const literal_token = tokenizer.next();
            const right_paren = tokenizer.next();
            if (left_paren.tag != .l_paren or literal_token.tag != .string_literal or right_paren.tag != .r_paren) {
                std.debug.panic("binding generator imports must be direct string literals: {s}", .{source});
            }
            const literal = text[literal_token.loc.start..literal_token.loc.end];
            if (std.mem.indexOfScalar(u8, literal, '\\') != null) {
                std.debug.panic("binding generator imports cannot use escapes: {s}", .{source});
            }
            const import_name = literal[1 .. literal.len - 1];
            const dependency = if (std.mem.eql(u8, import_name, "std"))
                continue
            else if (std.mem.eql(u8, import_name, "bindgen_ir"))
                "src/bindgen/ir.zig"
            else if (std.mem.eql(u8, import_name, "bindgen_schema"))
                "src/bindgen/schema.zig"
            else if (std.mem.eql(u8, import_name, "rapidhash"))
                binding_rapidhash_source
            else if (std.mem.endsWith(u8, import_name, ".zig"))
                std.fs.path.resolvePosix(arena, &.{ std.fs.path.dirnamePosix(source).?, import_name }) catch @panic("OOM")
            else
                std.debug.panic(
                    "binding generator source {s} imports unsupported module {s}; only std, bindgen_ir, bindgen_schema, rapidhash, and generator sources are allowed",
                    .{ source, import_name },
                );
            if (!std.mem.startsWith(u8, dependency, "src/bindgen/") and
                !std.mem.eql(u8, dependency, binding_rapidhash_source))
            {
                std.debug.panic("binding generator source {s} imports unapproved source {s}", .{ source, dependency });
            }
            const entry = seen.getOrPut(arena, dependency) catch @panic("OOM");
            if (!entry.found_existing) pending.append(arena, dependency) catch @panic("OOM");
        }
    }
}

fn schemaStemIsIdentifier(stem: []const u8) bool {
    if (stem.len == 0 or !(std.ascii.isAlphabetic(stem[0]) or stem[0] == '_')) return false;
    for (stem[1..]) |char| {
        if (!(std.ascii.isAlphanumeric(char) or char == '_')) return false;
    }
    return true;
}

fn schemaImportIndex(import_names: []const []const u8, name: []const u8) ?usize {
    for (import_names, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, name)) return index;
    }
    return null;
}

fn appendSchemaOrder(
    arena: std.mem.Allocator,
    sources: []const []const u8,
    dependencies: []const []const usize,
    states: []SchemaVisit,
    order: *std.ArrayList(usize),
    index: usize,
) void {
    switch (states[index]) {
        .done => return,
        .visiting => std.debug.panic("binding schema dependency cycle reaches {s}", .{sources[index]}),
        .unseen => states[index] = .visiting,
    }
    for (dependencies[index]) |dependency| {
        appendSchemaOrder(arena, sources, dependencies, states, order, dependency);
    }
    states[index] = .done;
    order.append(arena, index) catch @panic("OOM");
}

fn createSchemaModules(
    b: *Build,
    graph: SchemaGraph,
    bindgen_schema: *Build.Module,
) []const *Build.Module {
    const modules = b.graph.arena.alloc(*Build.Module, graph.sources.len) catch @panic("OOM");
    for (graph.sources, 0..) |source, index| {
        modules[index] = b.createModule(.{ .root_source_file = b.path(source) });
        modules[index].addImport("bindgen_schema", bindgen_schema);
    }
    for (modules, 0..) |schema_module, index| {
        for (graph.dependencies[index]) |dependency| {
            schema_module.addImport(graph.import_names[dependency], modules[dependency]);
        }
    }
    return modules;
}

fn listFilesAny(b: *Build, dir: []const u8, suffixes: []const []const u8, recursive: bool) []const []const u8 {
    const arena = b.graph.arena;
    const io = b.graph.io;
    b.dependOnDirectoryContents(b.path(dir));
    var out: std.ArrayList([]const u8) = .empty;
    var handle = std.Io.Dir.openDirAbsolute(io, rootJoin(b, dir), .{ .iterate = true }) catch
        std.debug.panic("cannot open source dir: {s}", .{dir});
    defer handle.close(io);
    if (recursive) {
        var walker = handle.walk(arena) catch @panic("OOM");
        defer walker.deinit(io);
        while (walker.next(io) catch @panic("walk failed")) |entry| {
            if (entry.kind == .directory) {
                b.dependOnDirectoryContents(b.path(b.fmt("{s}/{s}", .{ dir, entry.path })));
            }
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
    b.dependOnDirectoryContents(b.path(dir));
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
    const arena = b.graph.arena;
    var version_script: std.ArrayList(u8) = .empty;
    version_script.appendSlice(arena, "BUN_1.2 {\n    global:\n") catch @panic("OOM");
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
        version_script.print(arena, "        {s}\n", .{line}) catch @panic("OOM");
    }
    if (!opened or !closed) @panic("invalid dynamic export list");
    run.addPrefixedFileArg("--export-dynamic-symbol-list=", b.path(path));
    version_script.appendSlice(arena, "    local:\n        *;\n};\n") catch @panic("OOM");
    const write_files = b.addWriteFiles();
    run.addPrefixedFileArg("--version-script=", write_files.add("linker.lds", version_script.items));
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

    // Wait for the separate debug file before installing either artifact.
    // Inherited stdio makes this a side-effect step, reusing one output
    // directory instead of retaining a gigabyte-sized one per watch cycle.
    const dbg_name = b.fmt("{s}.dbg", .{exe_name});
    const debug_file: ?LazyPath = if (opts.mode == .debug) dbg: {
        run.addArg("--no-detach");
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
