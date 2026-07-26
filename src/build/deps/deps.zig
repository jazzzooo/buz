//! Vendored-dependency compile recipes: shared types, static-link order,
//! and bun's own C/C++ flag data. Policy flags (optimize, debug info,
//! warnings-as-errors baseline) live in exe.zig; these files carry only
//! what is specific to each dependency or to bun's sources.

pub const Include = union(enum) {
    /// Path inside a vendored dep's source package: .{ dep_name, subpath }.
    dep: struct { []const u8, []const u8 },
    /// Path inside the dep's generated-config dir: .{ dep_name, subpath }.
    gen: struct { []const u8, []const u8 },
    /// Repo-root-relative path.
    repo: []const u8,
    /// The vendored WebKit header set (vendor/webkit sources, forwarding
    /// farm, and the stable DerivedSources mirror).
    webkit,
    /// Path inside the Node.js headers package.
    nodejs: []const u8,
    /// The merged codegen output directory.
    codegen,
    /// The directory holding bun_dependency_versions.h.
    builddir,
};

pub const Group = struct {
    cxx: bool = false,
    /// When true, `flags` is the complete flag list (assembly TUs, mimalloc);
    /// the per-mode base flags are not prepended.
    /// TODO: Audit assembly and mimalloc recipes so this policy is either exercised or removed.
    no_base: bool = false,
    flags: []const []const u8,
    /// Release-mode flags when they differ beyond what base factoring can
    /// express (mimalloc's MI_BUILD_RELEASE set). Null = use `flags`.
    flags_release: ?[]const []const u8 = null,
    includes: []const Include,
    /// Paths relative to the dep source package (repo-root-relative for
    /// in-tree deps).
    files: []const []const u8,
};

pub const Dep = struct {
    name: []const u8,
    in_tree: bool = false,
    groups: []const Group,
};

/// Static link order: providers come after users.
pub const all = [_]Dep{
    @import("picohttpparser.zig").dep,
    @import("zlib.zig").dep,
    @import("zstd.zig").dep,
    @import("brotli.zig").dep,
    @import("libdeflate.zig").dep,
    @import("libarchive.zig").dep,
    @import("libjpeg_turbo.zig").dep,
    @import("libspng.zig").dep,
    @import("libwebp.zig").dep,
    @import("cares.zig").dep,
    @import("hdrhistogram.zig").dep,
    @import("highway.zig").dep,
    @import("lshpack.zig").dep,
    @import("lsqpack.zig").dep,
    @import("mimalloc.zig").dep,
    @import("sqlite.zig").dep,
    @import("tinycc.zig").dep,
    @import("boringssl.zig").dep,
    @import("lsquic.zig").dep,
};

pub const base_flags_debug: []const []const u8 = &.{
    "-g3",
    "-gz=zstd",
    "-glldb",
    "-fno-exceptions",
    "-fno-rtti",
    "-fno-omit-frame-pointer",
    "-mno-omit-leaf-frame-pointer",
    "-fvisibility=hidden",
    "-fvisibility-inlines-hidden",
    "-fno-unwind-tables",
    "-fno-asynchronous-unwind-tables",
    "-Wno-c23-extensions",
    "-ffunction-sections",
    "-fdata-sections",
    "-faddrsig",
    "-fno-semantic-interposition",
    "-fno-delete-null-pointer-checks",
    "-fdiagnostics-color=always",
    "-ferror-limit=100",
    // zig forces module-level PIC when libc is linked on glibc targets and
    // its flag wins over -fno-pic; the cc1-level relocation model overrides
    // it back to the static code the non-PIE executable wants.
    "-Xclang",
    "-mrelocation-model",
    "-Xclang",
    "static",
};

pub const base_flags_release: []const []const u8 = &.{
    "-g1",
    "-glldb",
    "-fno-exceptions",
    "-fno-rtti",
    "-fno-omit-frame-pointer",
    "-mno-omit-leaf-frame-pointer",
    "-fvisibility=hidden",
    "-fvisibility-inlines-hidden",
    "-fno-unwind-tables",
    "-fno-asynchronous-unwind-tables",
    "-Wno-c23-extensions",
    "-ffunction-sections",
    "-fdata-sections",
    "-faddrsig",
    "-fno-semantic-interposition",
    "-fno-delete-null-pointer-checks",
    "-fdiagnostics-color=always",
    "-ferror-limit=100",
    // zig forces module-level PIC when libc is linked on glibc targets and
    // its flag wins over -fno-pic; the cc1-level relocation model overrides
    // it back to the static code the non-PIE executable wants.
    "-Xclang",
    "-mrelocation-model",
    "-Xclang",
    "static",
};

pub const bun_cxx_flags_debug: []const []const u8 = &.{
    "-fno-c++-static-destructors",
    "-std=gnu++23",
    "-fconstexpr-steps=2542484",
    "-fconstexpr-depth=54",
    "-fno-pic",
    "-fno-pie",
    "-Werror=return-type",
    "-Werror=return-stack-address",
    "-Werror=implicit-function-declaration",
    "-Werror=uninitialized",
    "-Werror=conditional-uninitialized",
    "-Werror=suspicious-memaccess",
    "-Werror=int-conversion",
    "-Werror=nonnull",
    "-Werror=move",
    "-Werror=sometimes-uninitialized",
    "-Wno-c++23-lambda-attributes",
    "-Wno-nullability-completeness",
    "-Wno-character-conversion",
    "-Werror",
    "-Werror=unused",
    "-Wno-unused-function",
    "-D_HAS_EXCEPTIONS=0",
    "-DLIBUS_USE_OPENSSL=1",
    "-DLIBUS_USE_BORINGSSL=1",
    "-DWITH_BORINGSSL=1",
    "-DSTATICALLY_LINKED_WITH_JavaScriptCore=1",
    "-DSTATICALLY_LINKED_WITH_BMALLOC=1",
    "-DBUILDING_WITH_CMAKE=1",
    "-DJSC_OBJC_API_ENABLED=0",
    "-DBUN_SINGLE_THREADED_PER_VM_ENTRY_SCOPE=1",
    "-DNAPI_EXPERIMENTAL=ON",
    "-DNOMINMAX",
    "-DIS_BUILD",
    "-DBUILDING_JSCONLY__",
    "-DUSE_BUN_MIMALLOC=1",
    "-DASSERT_ENABLED=1",
    "-DBUN_DEBUG=1",
    "-DLAZY_LOAD_SQLITE=0",
};

pub const bun_cxx_flags_release: []const []const u8 = &.{
    "-fno-c++-static-destructors",
    "-std=gnu++23",
    "-fconstexpr-steps=2542484",
    "-fconstexpr-depth=54",
    "-fno-pic",
    "-fno-pie",
    "-Werror=return-type",
    "-Werror=return-stack-address",
    "-Werror=implicit-function-declaration",
    "-Werror=uninitialized",
    "-Werror=conditional-uninitialized",
    "-Werror=suspicious-memaccess",
    "-Werror=int-conversion",
    "-Werror=nonnull",
    "-Werror=move",
    "-Werror=sometimes-uninitialized",
    "-Wno-c++23-lambda-attributes",
    "-Wno-nullability-completeness",
    "-Wno-character-conversion",
    "-Werror",
    "-D_HAS_EXCEPTIONS=0",
    "-DLIBUS_USE_OPENSSL=1",
    "-DLIBUS_USE_BORINGSSL=1",
    "-DWITH_BORINGSSL=1",
    "-DSTATICALLY_LINKED_WITH_JavaScriptCore=1",
    "-DSTATICALLY_LINKED_WITH_BMALLOC=1",
    "-DBUILDING_WITH_CMAKE=1",
    "-DJSC_OBJC_API_ENABLED=0",
    "-DBUN_SINGLE_THREADED_PER_VM_ENTRY_SCOPE=1",
    "-DNAPI_EXPERIMENTAL=ON",
    "-DNOMINMAX",
    "-DIS_BUILD",
    "-DBUILDING_JSCONLY__",
    "-DUSE_BUN_MIMALLOC=1",
    "-DLAZY_LOAD_SQLITE=0",
};

pub const bun_c_flags_debug: []const []const u8 = &.{
    "-std=gnu17",
    "-fno-pic",
    "-fno-pie",
    "-Werror=return-type",
    "-Werror=return-stack-address",
    "-Werror=implicit-function-declaration",
    "-Werror=uninitialized",
    "-Werror=conditional-uninitialized",
    "-Werror=suspicious-memaccess",
    "-Werror=int-conversion",
    "-Werror=nonnull",
    "-Werror=move",
    "-Werror=sometimes-uninitialized",
    "-Wno-c++23-lambda-attributes",
    "-Wno-nullability-completeness",
    "-Wno-character-conversion",
    "-Werror",
    "-Werror=unused",
    "-Wno-unused-function",
    "-D_HAS_EXCEPTIONS=0",
    "-DLIBUS_USE_OPENSSL=1",
    "-DLIBUS_USE_BORINGSSL=1",
    "-DWITH_BORINGSSL=1",
    "-DSTATICALLY_LINKED_WITH_JavaScriptCore=1",
    "-DSTATICALLY_LINKED_WITH_BMALLOC=1",
    "-DBUILDING_WITH_CMAKE=1",
    "-DJSC_OBJC_API_ENABLED=0",
    "-DBUN_SINGLE_THREADED_PER_VM_ENTRY_SCOPE=1",
    "-DNAPI_EXPERIMENTAL=ON",
    "-DNOMINMAX",
    "-DIS_BUILD",
    "-DBUILDING_JSCONLY__",
    "-DUSE_BUN_MIMALLOC=1",
    "-DASSERT_ENABLED=1",
    "-DBUN_DEBUG=1",
    "-DLAZY_LOAD_SQLITE=0",
};

pub const bun_c_flags_release: []const []const u8 = &.{
    "-std=gnu17",
    "-fno-pic",
    "-fno-pie",
    "-Werror=return-type",
    "-Werror=return-stack-address",
    "-Werror=implicit-function-declaration",
    "-Werror=uninitialized",
    "-Werror=conditional-uninitialized",
    "-Werror=suspicious-memaccess",
    "-Werror=int-conversion",
    "-Werror=nonnull",
    "-Werror=move",
    "-Werror=sometimes-uninitialized",
    "-Wno-c++23-lambda-attributes",
    "-Wno-nullability-completeness",
    "-Wno-character-conversion",
    "-Werror",
    "-D_HAS_EXCEPTIONS=0",
    "-DLIBUS_USE_OPENSSL=1",
    "-DLIBUS_USE_BORINGSSL=1",
    "-DWITH_BORINGSSL=1",
    "-DSTATICALLY_LINKED_WITH_JavaScriptCore=1",
    "-DSTATICALLY_LINKED_WITH_BMALLOC=1",
    "-DBUILDING_WITH_CMAKE=1",
    "-DJSC_OBJC_API_ENABLED=0",
    "-DBUN_SINGLE_THREADED_PER_VM_ENTRY_SCOPE=1",
    "-DNAPI_EXPERIMENTAL=ON",
    "-DNOMINMAX",
    "-DIS_BUILD",
    "-DBUILDING_JSCONLY__",
    "-DUSE_BUN_MIMALLOC=1",
    "-DLAZY_LOAD_SQLITE=0",
};

pub const bun_includes: []const Include = &.{ .{ .repo = "packages" }, .{ .repo = "packages/bun-usockets" }, .{ .repo = "packages/bun-usockets/src" }, .{ .repo = "src/jsc/bindings" }, .{ .repo = "src/jsc/bindings/webcore" }, .{ .repo = "src/jsc/bindings/webcrypto" }, .{ .repo = "src/jsc/bindings/node/crypto" }, .{ .repo = "src/jsc/bindings/node/http" }, .{ .repo = "src/jsc/bindings/sqlite" }, .{ .repo = "src/jsc/bindings/v8" }, .{ .repo = "src/jsc/modules" }, .{ .repo = "src/js/builtins" }, .{ .repo = "src/napi" }, .{ .repo = "src/uws_sys" }, .codegen, .{ .repo = "vendor" }, .{ .dep = .{ "picohttpparser", "" } }, .{ .dep = .{ "zlib", "" } }, .{ .repo = "src/jsc/bindings/libuv" }, .builddir, .{ .nodejs = "include" }, .{ .nodejs = "include/node" }, .{ .gen = .{ "zlib", "" } }, .{ .dep = .{ "zstd", "lib" } }, .{ .dep = .{ "brotli", "c/include" } }, .{ .dep = .{ "libdeflate", "" } }, .{ .dep = .{ "libarchive", "libarchive" } }, .{ .dep = .{ "libjpeg-turbo", "src" } }, .{ .gen = .{ "libjpeg-turbo", "" } }, .{ .dep = .{ "libspng", "spng" } }, .{ .dep = .{ "libwebp", "src" } }, .{ .dep = .{ "cares", "include" } }, .{ .gen = .{ "cares", "" } }, .{ .dep = .{ "hdrhistogram", "include" } }, .{ .dep = .{ "highway", "" } }, .{ .dep = .{ "highway", "hwy" } }, .{ .dep = .{ "lshpack", "" } }, .{ .dep = .{ "lsqpack", "" } }, .{ .dep = .{ "mimalloc", "include" } }, .{ .dep = .{ "boringssl", "include" } }, .{ .dep = .{ "lsquic", "include" } }, .webkit };

pub const bun_c_includes: []const Include = &.{
    .{ .repo = "packages/bun-usockets/src" },
    .{ .repo = "src/jsc/bindings" },
    .{ .repo = "src/jsc/bindings/libuv" },
    .{ .dep = .{ "lshpack", "" } },
    .{ .dep = .{ "boringssl", "include" } },
    .{ .dep = .{ "lsquic", "include" } },
    .webkit,
};
