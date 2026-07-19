//! ICU 75.1 compiled from the pinned source tarball, replacing the archives
//! that came with the WebKit prebuilt: libicuuc is every common/*.cpp,
//! libicui18n every i18n/*.cpp (the upstream archives match those sets
//! exactly), and the data archive wraps the shipped icudt75l.dat blob via
//! .incbin, reproducing genccode's single `icudt75_dat` rodata symbol.
//! Flags mirror the oven-sh CI invocation (-Os, no legacy conversion,
//! exceptions off); Debug also uses ICU's ReleaseFast configuration.

const std = @import("std");
const exe = @import("exe.zig");

const Build = std.Build;
const Step = Build.Step;
const LazyPath = Build.LazyPath;

const common_flags = [_][]const u8{
    "-Os",
    // Static relocation model, as in deps.zig base_flags.
    "-Xclang",
    "-mrelocation-model",
    "-Xclang",
    "static",

    "-fno-omit-frame-pointer",
    "-mno-omit-leaf-frame-pointer",
    "-ffunction-sections",
    "-fdata-sections",
    "-fno-unwind-tables",
    "-fno-asynchronous-unwind-tables",
    "-DU_STATIC_IMPLEMENTATION=1",
    "-DUCONFIG_NO_LEGACY_CONVERSION=1",
};

const cxx_flags = common_flags ++ [_][]const u8{
    "-std=c++20",
    "-fno-exceptions",
    "-fno-c++-static-destructors",
};

pub const Ctx = struct {
    uc: *Step.Compile,
    i18n: *Step.Compile,
    data: *Step.Compile,
};

pub fn addLibs(b: *Build, deps: *const exe.DepPkgs, optimize: std.builtin.OptimizeMode) Ctx {
    const library_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseFast else optimize;
    const uc = newLib(b, "icuuc", library_optimize);
    const i18n = newLib(b, "icui18n", library_optimize);
    for ([_]*Step.Compile{ uc, i18n }) |lib| {
        lib.root_module.addIncludePath(deps.icu.path("icu/source/common"));
    }
    i18n.root_module.addIncludePath(deps.icu.path("icu/source/i18n"));

    for (listCpp(b, deps, "icu/source/common")) |f| {
        uc.root_module.addCSourceFile(.{ .file = deps.icu.path(f), .flags = ucFlags(b), .language = .cpp });
    }
    for (listCpp(b, deps, "icu/source/i18n")) |f| {
        i18n.root_module.addCSourceFile(.{ .file = deps.icu.path(f), .flags = i18nFlags(b), .language = .cpp });
    }

    // Data archive: one rodata symbol pointing at the filtered .dat blob, as
    // genccode emits it. Filtering drops the converter/transliteration/rbnf
    // data bun cannot reach (TextCodecICU removed, no legacy conversion),
    // ~7.4MB, matching the oven-sh CI pipeline.
    const filtered_dat = filterData(b, deps, uc, i18n);
    const data = blk: {
        const mod = b.createModule(.{
            .target = exe.cppTarget(b, &.{}),
            .optimize = library_optimize,
        });
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(filtered_dat, "icudt75l.dat");
        const asm_file = wf.add("icudata.S",
            \\    .section .note.GNU-stack,"",%progbits
            \\    .section .rodata
            \\    .balign 16
            \\    .globl icudt75_dat
            \\icudt75_dat:
            \\    .incbin "icudt75l.dat"
            \\
        );
        // .incbin resolves through the assembler include path.
        mod.addIncludePath(wf.getDirectory());
        mod.addAssemblyFile(asm_file);
        const lib = b.addLibrary(.{ .name = "icudata", .root_module = mod, .linkage = .static });
        lib.incremental = false;
        break :blk lib;
    };

    return .{ .uc = uc, .i18n = i18n, .data = data };
}

/// The icupkg-based data filter: build the tool from the same source tree
/// (zig c++ links it so the C++ ABI matches the archives), list the package
/// contents, and strip the unreachable entries.
fn filterData(b: *Build, deps: *const exe.DepPkgs, uc: *Step.Compile, i18n: *Step.Compile) LazyPath {
    const tool_lib = newLib(b, "icupkg-tool", .ReleaseFast);
    tool_lib.root_module.addIncludePath(deps.icu.path("icu/source/common"));
    tool_lib.root_module.addIncludePath(deps.icu.path("icu/source/i18n"));
    tool_lib.root_module.addIncludePath(deps.icu.path("icu/source/tools/toolutil"));
    const tool_flags = libFlags(b, "-DU_TOOLUTIL_IMPLEMENTATION");
    for (listCpp(b, deps, "icu/source/tools/toolutil")) |f| {
        tool_lib.root_module.addCSourceFile(.{ .file = deps.icu.path(f), .flags = tool_flags, .language = .cpp });
    }
    for ([_][]const u8{ "icu/source/tools/icupkg/icupkg.cpp", "icu/source/stubdata/stubdata.cpp" }) |f| {
        tool_lib.root_module.addCSourceFile(.{ .file = deps.icu.path(f), .flags = tool_flags, .language = .cpp });
    }

    const link = b.addSystemCommand(&.{ b.graph.zig_exe, "c++", "-no-pie", "-o" });
    const tool_exe = link.addOutputFileArg("icupkg");
    link.addArg("-Wl,--start-group");
    link.addArtifactArg(tool_lib);
    link.addArtifactArg(uc);
    link.addArtifactArg(i18n);
    link.addArg("-Wl,--end-group");
    link.step.name = "link icupkg";

    const dat = deps.icu.path("icu/source/data/in/icudt75l.dat");

    const list = b.addSystemCommand(&.{
        "sh", "-c",
        \\"$0" -l "$1" | grep -E '\.(cnv|spp|cfu)$|^cnvalias\.icu$|^translit/|^rbnf/|^unames\.icu$' > "$2"
    });
    list.addFileArg(tool_exe);
    list.addFileArg(dat);
    const rm_lst = list.addOutputFileArg("rm.lst");

    const filter = Step.Run.create(b, "icupkg filter");
    filter.addFileArg(tool_exe);
    filter.addArg("--auto_toc_prefix");
    filter.addArg("-r");
    filter.addFileArg(rm_lst);
    filter.addFileArg(dat);
    return filter.addOutputFileArg("icudt75l.dat");
}

fn newLib(b: *Build, name: []const u8, optimize: std.builtin.OptimizeMode) *Step.Compile {
    const mod = b.createModule(.{
        .target = exe.cppTarget(b, &.{}),
        .optimize = optimize,
        // libc++, matching the rest of the C++ world.
        .link_libc = true,
        .link_libcpp = true,
        .sanitize_c = .off,
    });
    const lib = b.addLibrary(.{ .name = name, .root_module = mod, .linkage = .static });
    lib.incremental = false;
    return lib;
}

fn ucFlags(b: *Build) []const []const u8 {
    return libFlags(b, "-DU_COMMON_IMPLEMENTATION");
}

fn i18nFlags(b: *Build) []const []const u8 {
    return libFlags(b, "-DU_I18N_IMPLEMENTATION");
}

fn libFlags(b: *Build, impl_define: []const u8) []const []const u8 {
    const arena = b.graph.arena;
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(arena, &cxx_flags) catch @panic("OOM");
    flags.append(arena, impl_define) catch @panic("OOM");
    return flags.items;
}

/// Package-relative paths of every .cpp directly in `dir` (the upstream
/// archives contain exactly these sets).
fn listCpp(b: *Build, deps: *const exe.DepPkgs, dir: []const u8) []const []const u8 {
    const arena = b.graph.arena;
    const io = b.graph.io;
    const abs = std.fs.path.join(arena, &.{ depRootAbs(b, deps.icu), dir }) catch @panic("OOM");
    var handle = std.Io.Dir.openDirAbsolute(io, abs, .{ .iterate = true }) catch std.debug.panic("open {s}", .{abs});
    defer handle.close(io);
    var out: std.ArrayList([]const u8) = .empty;
    var it = handle.iterate();
    while (it.next(io) catch @panic("iterate")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".cpp")) continue;
        out.append(arena, std.fs.path.join(arena, &.{ dir, entry.name }) catch @panic("OOM")) catch @panic("OOM");
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.lt);
    return out.items;
}

fn depRootAbs(b: *Build, dep: *Build.Dependency) []const u8 {
    const root = dep.builder.root.toString(b.graph.arena) catch @panic("OOM");
    if (std.fs.path.isAbsolute(root)) return root;
    const b_root = b.root.toString(b.graph.arena) catch @panic("OOM");
    return std.fs.path.join(b.graph.arena, &.{ b_root, root }) catch @panic("OOM");
}
