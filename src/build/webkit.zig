//! JavaScriptCore DerivedSources codegen from the vendored tree
//! (vendor/webkit, see VENDOR there). Replays the cmake add_custom_command
//! rules with the upstream ruby/python/perl generator scripts unmodified;
//! source lists are parsed out of the vendored CMakeLists.txt so syncs don't
//! need to touch this file. The `webkit-codegen` step installs the assembled
//! DerivedSources tree to <prefix>/webkit-derived.

const std = @import("std");
const exe = @import("exe.zig");

const Build = std.Build;
const Step = Build.Step;
const LazyPath = Build.LazyPath;

const jsc_root = "vendor/webkit/Source/JavaScriptCore";

const Named = struct { name: []const u8, file: LazyPath };

pub fn addStep(b: *Build, deps: *const exe.DepPkgs, optimize: std.builtin.OptimizeMode) *Step.WriteFile {
    const arena = b.graph.arena;
    const cmake = readCMakeLists(b);

    // ─── generator/main.rb: bytecode tables ───
    var bytecodes_outs: [5]Named = undefined;
    {
        const run = b.addSystemCommand(&.{"ruby"});
        run.addFileArg(jscPath(b, "generator/main.rb"));
        addListInputs(b, run, cmake, "GENERATOR");
        run.addArg("--bytecodes_h");
        bytecodes_outs[0] = .{ .name = "Bytecodes.h", .file = run.addOutputFileArg("Bytecodes.h") };
        run.addArg("--init_bytecodes_asm");
        bytecodes_outs[1] = .{ .name = "InitBytecodes.asm", .file = run.addOutputFileArg("InitBytecodes.asm") };
        run.addArg("--bytecode_structs_h");
        bytecodes_outs[2] = .{ .name = "BytecodeStructs.h", .file = run.addOutputFileArg("BytecodeStructs.h") };
        run.addArg("--bytecode_indices_h");
        bytecodes_outs[3] = .{ .name = "BytecodeIndices.h", .file = run.addOutputFileArg("BytecodeIndices.h") };
        run.addFileArg(jscPath(b, "bytecode/BytecodeList.rb"));
        run.addArg("--wasm_json");
        run.addFileArg(jscPath(b, "wasm/wasm.json"));
        run.addArg("--bytecode_dumper");
        bytecodes_outs[4] = .{ .name = "BytecodeDumperGenerated.cpp", .file = run.addOutputFileArg("BytecodeDumperGenerated.cpp") };
    }

    // ─── b3/air opcode generator (writes AirOpcode*.h into its cwd) ───
    const air_dir = blk: {
        const run = b.addSystemCommand(&.{ "sh", "-c", "gen=$(realpath \"$1\") && op=$(realpath \"$2\") && cd \"$0\" && exec ruby \"$gen\" \"$op\"" });
        const out = run.addOutputDirectoryArg("air");
        run.addFileArg(jscPath(b, "b3/air/opcode_generator.rb"));
        run.addFileArg(jscPath(b, "b3/air/AirOpcode.opcodes"));
        break :blk out;
    };

    // ─── wasm headers ───
    const wasm_ops_h = genPython(b, "wasm/generateWasmOpsHeader.py", "wasm/generateWasm.py", "wasm/wasm.json", "WasmOps.h");
    const wasm_omg_h = genPython(b, "wasm/generateWasmOMGIRGeneratorInlinesHeader.py", "wasm/generateWasm.py", "wasm/wasm.json", "WasmOMGIRGeneratorInlines.h");

    // ─── JSCBuiltins ───
    const builtins_dir = blk: {
        const run = addPythonCommand(b);
        run.addFileArg(jscPath(b, "Scripts/generate-js-builtins.py"));
        addTreeInputs(b, run, jsc_root ++ "/Scripts");
        run.addArgs(&.{ "--framework", "JavaScriptCore", "--output-directory" });
        const out = run.addOutputDirectoryArg("builtins");
        run.addArg("--combined");
        for (cmakeList(arena, cmake, "JavaScriptCore_BUILTINS_SOURCES")) |f| run.addFileArg(jscPath(b, f));
        break :blk out;
    };

    // ─── stdout-redirect generators ───
    const keyword_lookup_h = toolStdout(b, &.{ "python3", "-B" }, "KeywordLookupGenerator.py", "parser/Keywords.table", "KeywordLookup.h");
    var luts: std.ArrayList(Named) = .empty;
    for (cmakeList(arena, cmake, "JavaScriptCore_OBJECT_LUT_SOURCES")) |src| {
        const stem = std.fs.path.stem(std.fs.path.basename(src));
        const name = b.fmt("{s}.lut.h", .{stem});
        luts.append(arena, .{ .name = name, .file = toolStdout(b, &.{"perl"}, "create_hash_table", src, name) }) catch @panic("OOM");
    }
    luts.append(arena, .{ .name = "Lexer.lut.h", .file = toolStdout(b, &.{"perl"}, "create_hash_table", "parser/Keywords.table", "Lexer.lut.h") }) catch @panic("OOM");

    // ─── yarr + lexer tables ───
    const regexp_tables_h = blk: {
        const run = addPythonCommand(b);
        run.addFileArg(jscPath(b, "yarr/create_regex_tables"));
        break :blk run.addOutputFileArg("RegExpJitTables.h");
    };
    const yarr_unicode_h = blk: {
        const run = addPythonCommand(b);
        run.addFileArg(jscPath(b, "yarr/generateYarrUnicodePropertyTables.py"));
        run.addFileInput(jscPath(b, "yarr/hasher.py"));
        run.addDirectoryArg(jscPath(b, "ucd"));
        break :blk run.addOutputFileArg("UnicodePatternTables.h");
    };
    const yarr_canon_cpp = blk: {
        const run = addPythonCommand(b);
        run.addFileArg(jscPath(b, "yarr/generateYarrCanonicalizeUnicode"));
        run.addFileArg(jscPath(b, "ucd/CaseFolding.txt"));
        break :blk run.addOutputFileArg("YarrCanonicalizeUnicode.cpp");
    };
    const lexer_unicode_h = blk: {
        const run = addPythonCommand(b);
        run.addFileArg(jscPath(b, "parser/generateLexerUnicodePropertyTables.py"));
        run.addFileArg(jscPath(b, "ucd/UnicodeData.txt"));
        break :blk run.addOutputFileArg("LexerUnicodePropertyTables.h");
    };

    // ─── inspector protocol ───
    const combined_domains_json = blk: {
        const run = addPythonCommand(b);
        run.addFileArg(jscPath(b, "Scripts/generate-combined-inspector-json.py"));
        for (cmakeList(arena, cmake, "JavaScriptCore_INSPECTOR_DOMAINS")) |f| run.addFileArg(jscPath(b, f));
        // FEATURE_DEFINES_WITH_SPACE_SEPARATOR as the JSCOnly cmake
        // configure computes it (leading space included).
        run.addArg(" ENABLE_VIDEO ENABLE_WEBGL");
        break :blk run.addOutputFileArg("CombinedDomains.json");
    };
    const inspector_dir = blk: {
        const run = addPythonCommand(b);
        run.addFileArg(jscPath(b, "inspector/scripts/generate-inspector-protocol-bindings.py"));
        addTreeInputs(b, run, jsc_root ++ "/inspector/scripts");
        run.addArg("--outputDir");
        const out = run.addOutputDirectoryArg("inspector");
        run.addArgs(&.{ "--framework", "JavaScriptCore" });
        run.addFileArg(combined_domains_json);
        break :blk out;
    };

    // Generated files consumed via -I by the offlineasm stages and the
    // extractor compiles. cmakeconfig.h is the vendored copy of the cmake
    // configure output: a fixed set of feature defines for this
    // configuration.
    var base: std.ArrayList(Named) = .empty;
    base.appendSlice(arena, &bytecodes_outs) catch @panic("OOM");
    base.appendSlice(arena, &.{
        .{ .name = "AirOpcode.h", .file = air_dir.path(b, "AirOpcode.h") },
        .{ .name = "AirOpcodeGenerated.h", .file = air_dir.path(b, "AirOpcodeGenerated.h") },
        .{ .name = "AirOpcodeUtils.h", .file = air_dir.path(b, "AirOpcodeUtils.h") },
        .{ .name = "WasmOps.h", .file = wasm_ops_h },
        .{ .name = "WasmOMGIRGeneratorInlines.h", .file = wasm_omg_h },
        .{ .name = "JSCBuiltins.h", .file = builtins_dir.path(b, "JSCBuiltins.h") },
        .{ .name = "KeywordLookup.h", .file = keyword_lookup_h },
        .{ .name = "cmakeconfig.h", .file = b.path("vendor/webkit/cmakeconfig.h") },
    }) catch @panic("OOM");

    // ─── offlineasm: settings → settings extractor → offsets → offsets
    //     extractor → LLIntAssembly.h ───
    const wf0 = writeLayer(b, base.items, &.{});
    const settings_h = blk: {
        const run = b.addSystemCommand(&.{"ruby"});
        run.addFileArg(jscPath(b, "offlineasm/generate_settings_extractor.rb"));
        addListInputs(b, run, cmake, "OFFLINE_ASM");
        addListInputs(b, run, cmake, "LLINT_ASM");
        run.addPrefixedDirectoryArg("-I", wf0.path(b, "JavaScriptCore"));
        run.addFileArg(jscPath(b, "llint/LowLevelInterpreter.asm"));
        const out = run.addOutputFileArg("LLIntDesiredSettings.h");
        run.addArg("X86_64");
        break :blk out;
    };

    const wf1 = writeLayer(b, base.items, &.{.{ .name = "LLIntDesiredSettings.h", .file = settings_h }});
    const settings_obj = extractorObject(b, deps, optimize, cmake, "LLIntSettingsExtractor", wf1);

    const offsets_h = blk: {
        const run = b.addSystemCommand(&.{"ruby"});
        run.addFileArg(jscPath(b, "offlineasm/generate_offset_extractor.rb"));
        addListInputs(b, run, cmake, "OFFLINE_ASM");
        addListInputs(b, run, cmake, "LLINT_ASM");
        run.addPrefixedDirectoryArg("-I", wf1.path(b, "JavaScriptCore"));
        run.addFileArg(jscPath(b, "llint/LowLevelInterpreter.asm"));
        run.addFileArg(settings_obj.getEmittedBin());
        const out = run.addOutputFileArg("LLIntDesiredOffsets.h");
        run.addArgs(&.{ "X86_64", "normal" });
        break :blk out;
    };

    const wf2 = writeLayer(b, base.items, &.{
        .{ .name = "LLIntDesiredSettings.h", .file = settings_h },
        .{ .name = "LLIntDesiredOffsets.h", .file = offsets_h },
    });
    const offsets_obj = extractorObject(b, deps, optimize, cmake, "LLIntOffsetsExtractor", wf2);

    const llint_assembly_h = blk: {
        const run = b.addSystemCommand(&.{"ruby"});
        run.setEnvironmentVariable("CMAKE_CXX_COMPILER_ID", "Clang");
        run.addFileArg(jscPath(b, "offlineasm/asm.rb"));
        addListInputs(b, run, cmake, "OFFLINE_ASM");
        addListInputs(b, run, cmake, "LLINT_ASM");
        run.addPrefixedDirectoryArg("-I", wf2.path(b, "JavaScriptCore"));
        run.addFileArg(jscPath(b, "llint/LowLevelInterpreter.asm"));
        run.addFileArg(offsets_obj.getEmittedBin());
        const out = run.addOutputFileArg("LLIntAssembly.h");
        run.addArgs(&.{ "normal", "--binary-format=ELF" });
        break :blk out;
    };

    // ─── assembled DerivedSources tree, laid out as the stable dir the JSC
    //     compile includes from (single storage per header: flat spellings
    //     resolve via -I …/JavaScriptCore, angle spellings via its parent) ───
    const wf = b.addNamedWriteFiles("webkit-derived");
    for (base.items) |n| _ = wf.addCopyFile(n.file, b.fmt("JavaScriptCore/{s}", .{n.name}));
    for (luts.items) |n| _ = wf.addCopyFile(n.file, b.fmt("JavaScriptCore/{s}", .{n.name}));
    _ = wf.addCopyFile(builtins_dir.path(b, "JSCBuiltins.cpp"), "JavaScriptCore/JSCBuiltins.cpp");
    _ = wf.addCopyFile(regexp_tables_h, "JavaScriptCore/yarr/RegExpJitTables.h");
    _ = wf.addCopyFile(yarr_unicode_h, "JavaScriptCore/yarr/UnicodePatternTables.h");
    _ = wf.addCopyFile(yarr_canon_cpp, "JavaScriptCore/yarr/YarrCanonicalizeUnicode.cpp");
    _ = wf.addCopyFile(lexer_unicode_h, "JavaScriptCore/LexerUnicodePropertyTables.h");
    _ = wf.addCopyFile(combined_domains_json, "JavaScriptCore/CombinedDomains.json");
    _ = wf.addCopyDirectory(inspector_dir, "JavaScriptCore/inspector", .{});
    // Root-level wrappers for the inspector headers, as cmake writes them:
    // both include spellings funnel into the single stored copy.
    for ([_][]const u8{ "InspectorProtocolObjects.h", "InspectorFrontendDispatchers.h", "InspectorBackendDispatchers.h", "InspectorAlternateBackendDispatchers.h" }) |h| {
        _ = wf.add(b.fmt("JavaScriptCore/{s}", .{h}), b.fmt("#include \"inspector/{s}\"\n", .{h}));
    }
    _ = wf.addCopyFile(settings_h, "JavaScriptCore/LLIntDesiredSettings.h");
    _ = wf.addCopyFile(offsets_h, "JavaScriptCore/LLIntDesiredOffsets.h");
    _ = wf.addCopyFile(llint_assembly_h, "JavaScriptCore/LLIntAssembly.h");

    const install = b.addInstallDirectory(.{
        .source_dir = wf.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "webkit-derived",
    });
    b.step("webkit-codegen", "Generate JSC DerivedSources from vendor/webkit").dependOn(&install.step);
    return wf;
}

/// Flags shared by every WebKit C/C++ TU, mirroring the oven-sh CI build
/// (Dockerfile DEFAULT_CFLAGS + cmake JSCOnly config, minus debug-info
/// tuning and warning flags that don't affect generated code).
const common_flags = [_][]const u8{
    // zig injects -Werror=date-time; JSCBytecodeCacheVersion.cpp derives the
    // bytecode cache key from __DATE__/__TIME__.
    "-Wno-date-time",
    // Static relocation model, as in deps.zig base_flags (zig's forced
    // module PIC would otherwise win).
    "-Xclang",
    "-mrelocation-model",
    "-Xclang",
    "static",
    "-fno-strict-aliasing",
    "-fno-exceptions",
    "-fvisibility=hidden",
    "-ffunction-sections",
    "-fdata-sections",
    "-fno-unwind-tables",
    "-fno-asynchronous-unwind-tables",
    "-fno-omit-frame-pointer",
    "-mno-omit-leaf-frame-pointer",
    "-DBUILDING_JSCONLY__",
    "-DBUILDING_WEBKIT=1",
    "-DBUILDING_WITH_CMAKE=1",
    "-DHAVE_CONFIG_H=1",
    "-DPAS_BMALLOC=1",
    "-DU_STATIC_IMPLEMENTATION=1",
};

const common_cxx_flags = common_flags ++ [_][]const u8{
    "-std=c++23",
    "-fno-rtti",
    "-fno-c++-static-destructors",
    "-fvisibility-inlines-hidden",
};

pub const Libs = struct {
    bmalloc_c: *Step.Compile,
    bmalloc_cxx: *Step.Compile,
    wtf: *Step.Compile,
    jsc: *Step.Compile,
    jsc_c: *Step.Compile,
};

pub const Ctx = struct {
    libs: Libs,
    /// Mirrors the DerivedSources tree into the stable dir; everything that
    /// compiles against the vendored headers must depend on it.
    sync: *Step,
    /// Include dirs replacing the prebuilt tarball's include/: source headers
    /// through the forwarding farm (same-inode for both include spellings),
    /// derived headers through the stable mirror, cmakeconfig.h at the vendor
    /// root, and the WTF/bmalloc source layouts.
    includes: []const LazyPath,
};

/// bmalloc and WTF compiled from the vendored sources. TU lists come from the
/// vendored compile_commands.json (the cmake build's own manifest), so a
/// WebKit sync updates them without touching this file. bmalloc splits into a
/// C and a C++ archive because the module-level libc-header policy differs
/// (see newCppLib in exe.zig).
pub fn addLibs(b: *Build, deps: *const exe.DepPkgs, mode: exe.Mode, optimize: std.builtin.OptimizeMode, derived_wf: *Step.WriteFile) Ctx {
    const arena = b.graph.arena;
    const cmake = readCMakeLists(b);
    const manifest = readManifest(b);

    const bmalloc_c = newLib(b, deps, optimize, "webkit-bmalloc-c", false, cmake);
    const bmalloc_cxx = newLib(b, deps, optimize, "webkit-bmalloc-cxx", true, cmake);
    const wtf = newLib(b, deps, optimize, "webkit-wtf", true, cmake);

    const bmalloc_includes = [_][]const u8{ "bmalloc", "bmalloc/bmalloc", "bmalloc/libpas/src/libpas" };
    const wtf_includes = [_][]const u8{ "WTF", "WTF/wtf", "WTF/wtf/dtoa", "WTF/wtf/fast_float", "WTF/wtf/persistence", "WTF/wtf/simdutf", "WTF/wtf/text", "WTF/wtf/text/icu", "WTF/wtf/threads", "WTF/wtf/unicode", "bmalloc" };
    for ([_]*Step.Compile{ bmalloc_c, bmalloc_cxx }) |lib| {
        for (bmalloc_includes) |inc| lib.root_module.addIncludePath(b.path(b.fmt("vendor/webkit/Source/{s}", .{inc})));
    }
    for (wtf_includes) |inc| wtf.root_module.addIncludePath(b.path(b.fmt("vendor/webkit/Source/{s}", .{inc})));

    const bmalloc_c_flags: []const []const u8 = &(common_flags ++ [_][]const u8{ "-D_GNU_SOURCE", "-DBUILDING_bmalloc" });
    const bmalloc_cxx_flags: []const []const u8 = blk: {
        var flags: std.ArrayList([]const u8) = .empty;
        flags.appendSlice(arena, &(common_cxx_flags ++ [_][]const u8{ "-D_GNU_SOURCE", "-DBUILDING_bmalloc" })) catch @panic("OOM");
        break :blk flags.items;
    };
    const wtf_flags: []const []const u8 = blk: {
        var flags: std.ArrayList([]const u8) = .empty;
        flags.appendSlice(arena, &(common_cxx_flags ++ [_][]const u8{ "-DBUILDING_WTF", "-DSTATICALLY_LINKED_WITH_bmalloc" })) catch @panic("OOM");
        break :blk flags.items;
    };

    for (manifest.bmalloc) |tu| {
        const lib = if (tu.cxx) bmalloc_cxx else bmalloc_c;
        const flags = if (tu.cxx) bmalloc_cxx_flags else bmalloc_c_flags;
        lib.root_module.addCSourceFile(.{
            .file = b.path(b.fmt("vendor/webkit/{s}", .{tu.path})),
            .flags = flags,
            .language = if (tu.cxx) .cpp else .c,
        });
    }
    for (manifest.wtf) |tu| {
        wtf.root_module.addCSourceFile(.{
            .file = b.path(b.fmt("vendor/webkit/{s}", .{tu.path})),
            .flags = wtf_flags,
            .language = .cpp,
        });
    }

    // ─── JavaScriptCore ───
    // The DerivedSources tree is mirrored to a stable dir so the unified
    // bundles (generated at configure time, exactly like cmake's
    // WEBKIT_COMPUTE_SOURCES) can #include derived sources from a fixed path.
    const stable_root = rootJoin(b, b.fmt("build/zig/{s}", .{@tagName(mode)}));
    const derived_stable = b.fmt("{s}/webkit-derived/JavaScriptCore", .{stable_root});
    const jsc_abs = rootJoin(b, jsc_root);
    // Sources.txt plus the USE_INSPECTOR_SOCKET_SERVER list (JSCOnly's
    // remote-inspector transport), matching the cmake configuration.
    const gusb_out = b.run(&.{
        "python3",
        "-B",
        rootJoin(b, "vendor/webkit/Source/WTF/Scripts/generate-unified-source-bundles.py"),
        "--derived-sources-path",
        derived_stable,
        "--source-tree-path",
        jsc_abs,
        b.fmt("{s}/Sources.txt", .{jsc_abs}),
        b.fmt("{s}/inspector/remote/SourcesSocket.txt", .{jsc_abs}),
    });

    const sync = b.addRunFile(deps.bun);
    sync.addFileArg(b.path("src/build/sync-dirs.ts"));
    sync.addArg(stable_root);
    sync.addDirectoryArg(derived_wf.getDirectory());
    sync.addArg("webkit-derived");
    // Self-pair: keeps the configure-time bundles out of the mirror's
    // stale-file deletion pass.
    sync.addArg(b.fmt("{s}/unified-sources", .{derived_stable}));
    sync.addArg("webkit-derived/JavaScriptCore/unified-sources");
    sync.has_side_effects = true;
    sync.step.name = "sync webkit-derived";

    const jsc = newLib(b, deps, optimize, "webkit-jsc", true, cmake);
    const jsc_c = newLib(b, deps, optimize, "webkit-jsc-c", false, cmake);
    for ([_]*Step.Compile{ jsc, jsc_c }) |lib| {
        lib.step.dependOn(&sync.step);
        const m = lib.root_module;
        m.addIncludePath(.{ .cwd_relative = derived_stable });
        m.addIncludePath(.{ .cwd_relative = b.fmt("{s}/webkit-derived", .{stable_root}) });
        m.addIncludePath(.{ .cwd_relative = b.fmt("{s}/inspector", .{derived_stable}) });
        m.addIncludePath(.{ .cwd_relative = b.fmt("{s}/yarr", .{derived_stable}) });
        for (cmakeList(arena, cmake, "JavaScriptCore_PRIVATE_INCLUDE_DIRECTORIES")) |dir| {
            m.addIncludePath(if (dir.len == 0) b.path(jsc_root) else jscPath(b, dir));
        }
        // Added by the remote-inspector cmake config, not the base list.
        m.addIncludePath(jscPath(b, "inspector/remote/socket"));
        m.addIncludePath(b.path("vendor/webkit/Source/WTF"));
        m.addIncludePath(b.path("vendor/webkit/Source/bmalloc"));
    }

    const jsc_defines = [_][]const u8{ "-DBUILDING_JavaScriptCore", "-DSTATICALLY_LINKED_WITH_WTF", "-DSTATICALLY_LINKED_WITH_bmalloc" };
    const jsc_cxx_flags: []const []const u8 = blk: {
        var flags: std.ArrayList([]const u8) = .empty;
        flags.appendSlice(arena, &(common_cxx_flags ++ jsc_defines ++ [_][]const u8{
            "-ffp-contract=off",
            "-fno-slp-vectorize",
        })) catch @panic("OOM");
        break :blk flags.items;
    };
    const low_level_interpreter_flags: []const []const u8 = blk: {
        if (mode != .debug) break :blk jsc_cxx_flags;
        var flags: std.ArrayList([]const u8) = .empty;
        flags.appendSlice(arena, jsc_cxx_flags) catch @panic("OOM");
        flags.append(arena, "-O") catch @panic("OOM");
        break :blk flags.items;
    };
    const jsc_c_flags: []const []const u8 = &(common_flags ++ jsc_defines);

    const addJscTu = struct {
        fn add(file: LazyPath, entry: []const u8, jsc_: *Step.Compile, jsc_c_: *Step.Compile, cxx_flags: []const []const u8, low_level_flags: []const []const u8, c_flags: []const []const u8) void {
            const is_c = std.mem.endsWith(u8, entry, ".c");
            (if (is_c) jsc_c_ else jsc_).root_module.addCSourceFile(.{
                .file = file,
                .flags = if (is_c)
                    c_flags
                else if (std.mem.endsWith(u8, entry, "llint/LowLevelInterpreter.cpp"))
                    low_level_flags
                else
                    cxx_flags,
                .language = if (is_c) .c else .cpp,
            });
        }
    }.add;

    var bundled = std.StringHashMapUnmanaged(void).empty;
    var tus = std.mem.splitScalar(u8, gusb_out, ';');
    while (tus.next()) |entry_raw| {
        const entry = std.mem.trim(u8, entry_raw, " \t\r\n");
        if (entry.len == 0) continue;
        // Sources.txt lists a few headers; cmake's add_library skips them.
        if (std.mem.endsWith(u8, entry, ".h")) continue;
        if (std.fs.path.isAbsolute(entry)) {
            addJscTu(.{ .cwd_relative = arena.dupe(u8, entry) catch @panic("OOM") }, entry, jsc, jsc_c, jsc_cxx_flags, low_level_interpreter_flags, jsc_c_flags);
        } else {
            const rel = arena.dupe(u8, entry) catch @panic("OOM");
            bundled.put(arena, rel, {}) catch @panic("OOM");
            addJscTu(jscPath(b, rel), rel, jsc, jsc_c, jsc_cxx_flags, low_level_interpreter_flags, jsc_c_flags);
        }
    }
    // TUs cmake adds outside Sources.txt: the LowLevelInterpreterLib object,
    // the derived JSCBuiltins.cpp, remote-inspector sources, and friends. The
    // manifest is the ground truth for what the upstream build compiled.
    for (manifest.jsc) |tu| {
        if (tu.derived) {
            addJscTu(.{ .cwd_relative = b.fmt("{s}/{s}", .{ derived_stable, tu.path }) }, tu.path, jsc, jsc_c, jsc_cxx_flags, low_level_interpreter_flags, jsc_c_flags);
        } else {
            const rel = tu.path["Source/JavaScriptCore/".len..];
            if (bundled.contains(rel)) continue;
            addJscTu(jscPath(b, rel), rel, jsc, jsc_c, jsc_cxx_flags, low_level_interpreter_flags, jsc_c_flags);
        }
    }

    const step = b.step("webkit-libs", "Compile bmalloc, WTF, and JSC from vendor/webkit");
    for ([_]*Step.Compile{ bmalloc_c, bmalloc_cxx, wtf, jsc, jsc_c }) |lib| {
        const install = b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = "webkit-libs" } } });
        step.dependOn(&install.step);
    }

    const fwd = forwardingDir(b, deps, cmake);
    const includes = arena.dupe(LazyPath, &.{
        fwd,
        .{ .cwd_relative = b.fmt("{s}/JavaScriptCore", .{fwd.cwd_relative}) },
        .{ .cwd_relative = b.fmt("{s}/webkit-derived", .{stable_root}) },
        .{ .cwd_relative = derived_stable },
        .{ .cwd_relative = b.fmt("{s}/inspector", .{derived_stable}) },
        b.path("vendor/webkit"),
        b.path("vendor/webkit/Source/WTF"),
        b.path("vendor/webkit/Source/bmalloc"),
        b.path("vendor/webkit/Source/WTF/wtf/unicode"),
    }) catch @panic("OOM");

    return .{
        .libs = .{ .bmalloc_c = bmalloc_c, .bmalloc_cxx = bmalloc_cxx, .wtf = wtf, .jsc = jsc, .jsc_c = jsc_c },
        .sync = &sync.step,
        .includes = includes,
    };
}

fn newLib(b: *Build, deps: *const exe.DepPkgs, optimize: std.builtin.OptimizeMode, name: []const u8, is_cxx: bool, cmake: []const u8) *Step.Compile {
    const mod = b.createModule(.{
        .target = exe.cppTarget(b, &.{}),
        .optimize = optimize,
        // Same libc++/libc policy as newCppLib in exe.zig.
        .link_libc = true,
        .link_libcpp = is_cxx,
        .sanitize_c = .off,
    });
    // cmakeconfig.h; the vendor root holds the copy.
    mod.addIncludePath(b.path("vendor/webkit"));
    mod.addIncludePath(forwardingDir(b, deps, cmake));
    const lib = b.addLibrary(.{ .name = name, .root_module = mod, .linkage = .static });
    lib.incremental = false;
    return lib;
}

const Tu = struct { path: []const u8, cxx: bool, derived: bool = false };
const Manifest = struct { bmalloc: []const Tu, wtf: []const Tu, jsc: []const Tu };

/// TU lists from the vendored compile_commands.json (the cmake build's own
/// manifest), excluding the offlineasm extractors, the TestWTF/gtest world,
/// the jsc shell, and precompiled-header TUs. `-x c++` marks the libpas C
/// files cmake compiles as C++. For JSC only non-bundle TUs are collected
/// (the bundles are regenerated by generate-unified-source-bundles.py);
/// `derived` marks TUs living in the DerivedSources dir rather than the
/// source tree.
fn readManifest(b: *Build) Manifest {
    const arena = b.graph.arena;
    const io = b.graph.io;
    var dir = std.Io.Dir.openDirAbsolute(io, rootJoin(b, "vendor/webkit"), .{}) catch @panic("open vendor/webkit");
    defer dir.close(io);
    const text = dir.readFileAlloc(io, "compile_commands.json", arena, .limited(16 << 20)) catch @panic("read compile_commands.json");
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch @panic("parse compile_commands.json");

    var bmalloc: std.ArrayList(Tu) = .empty;
    var wtf: std.ArrayList(Tu) = .empty;
    var jsc: std.ArrayList(Tu) = .empty;
    for (parsed.array.items) |entry| {
        const file = entry.object.get("file").?.string;
        const command = entry.object.get("command").?.string;
        if (std.mem.indexOf(u8, command, "-DBUILDING_Test") != null) continue;
        if (std.mem.indexOf(u8, file, "Extractor") != null) continue;
        if (std.mem.indexOf(u8, file, "cmake_pch") != null) continue;
        const is_cxx_cmd = std.mem.indexOf(u8, command, "-x c++") != null or !std.mem.endsWith(u8, file, ".c");
        if (std.mem.startsWith(u8, file, "/webkit/Source/")) {
            const rel = arena.dupe(u8, file["/webkit/".len..]) catch @panic("OOM");
            const tu: Tu = .{ .path = rel, .cxx = is_cxx_cmd };
            if (std.mem.startsWith(u8, rel, "Source/bmalloc/")) {
                bmalloc.append(arena, tu) catch @panic("OOM");
            } else if (std.mem.startsWith(u8, rel, "Source/WTF/")) {
                wtf.append(arena, tu) catch @panic("OOM");
            } else if (std.mem.startsWith(u8, rel, "Source/JavaScriptCore/") and
                std.mem.indexOf(u8, command, "-DBUILDING_jsc ") == null)
            {
                // The BUILDING_jsc TU is the jsc shell; LowLevelInterpreter.cpp
                // carries no BUILDING_* define at all (cmake object-lib quirk).
                jsc.append(arena, tu) catch @panic("OOM");
            }
        } else if (std.mem.startsWith(u8, file, "/webkitbuild/JavaScriptCore/DerivedSources/") and
            std.mem.indexOf(u8, file, "unified-sources") == null and
            std.mem.indexOf(u8, command, "-DBUILDING_jsc ") == null)
        {
            const rel = arena.dupe(u8, file["/webkitbuild/JavaScriptCore/DerivedSources/".len..]) catch @panic("OOM");
            jsc.append(arena, .{ .path = rel, .cxx = is_cxx_cmd, .derived = true }) catch @panic("OOM");
        }
    }
    return .{ .bmalloc = bmalloc.items, .wtf = wtf.items, .jsc = jsc.items };
}

fn jscPath(b: *Build, sub: []const u8) LazyPath {
    return b.path(b.fmt(jsc_root ++ "/{s}", .{sub}));
}

fn genPython(b: *Build, generator: []const u8, extra_dep: []const u8, input: []const u8, out_name: []const u8) LazyPath {
    const run = addPythonCommand(b);
    run.addFileArg(jscPath(b, generator));
    run.addFileInput(jscPath(b, extra_dep));
    run.addFileArg(jscPath(b, input));
    return run.addOutputFileArg(out_name);
}

fn addPythonCommand(b: *Build) *Step.Run {
    return b.addSystemCommand(&.{ "python3", "-B" });
}

/// `command script input`, with captured stdout as the generated file.
fn toolStdout(b: *Build, command: []const []const u8, script: []const u8, input: []const u8, out_name: []const u8) LazyPath {
    const run = b.addSystemCommand(command);
    run.addFileArg(jscPath(b, script));
    run.addFileArg(jscPath(b, input));
    return run.captureStdOut(.{ .basename = out_name });
}

/// Generated headers are included both flat and as <JavaScriptCore/X.h>, so
/// each layer stores them once under JavaScriptCore/; consumers get the
/// subdir as the flat view and the root as the angle view, resolving both
/// spellings to the same inode (see forwardingDir).
fn writeLayer(b: *Build, base: []const Named, extra: []const Named) LazyPath {
    const wf = b.addWriteFiles();
    for (base) |n| _ = wf.addCopyFile(n.file, b.fmt("JavaScriptCore/{s}", .{n.name}));
    for (extra) |n| _ = wf.addCopyFile(n.file, b.fmt("JavaScriptCore/{s}", .{n.name}));
    return wf.getDirectory();
}

/// Target-compiled C++ whose object file the offlineasm scripts scan for
/// magic-marker constant arrays; never linked or executed.
fn extractorObject(b: *Build, deps: *const exe.DepPkgs, optimize: std.builtin.OptimizeMode, cmake: []const u8, comptime name: []const u8, derived: LazyPath) *Step.Compile {
    const arena = b.graph.arena;

    const mod = b.createModule(.{
        .target = exe.cppTarget(b, &.{}),
        .optimize = optimize,
        // libc++, like every other C++ TU: the offsets it encodes must match
        // the real JSC compile.
        .link_libc = true,
        .link_libcpp = true,
        .sanitize_c = .off,
    });

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(arena, &(common_cxx_flags ++ [_][]const u8{
        "-DSTATICALLY_LINKED_WITH_WTF",
        "-DSTATICALLY_LINKED_WITH_bmalloc",
        "-DBUILDING_" ++ name,
    })) catch @panic("OOM");

    mod.addIncludePath(derived.path(b, "JavaScriptCore"));
    mod.addIncludePath(derived);
    for (cmakeList(arena, cmake, "JavaScriptCore_PRIVATE_INCLUDE_DIRECTORIES")) |dir| {
        mod.addIncludePath(if (dir.len == 0) b.path(jsc_root) else jscPath(b, dir));
    }
    mod.addIncludePath(b.path("vendor/webkit/Source/WTF"));
    mod.addIncludePath(b.path("vendor/webkit/Source/bmalloc"));
    mod.addIncludePath(forwardingDir(b, deps, cmake));

    mod.addCSourceFile(.{ .file = jscPath(b, "llint/" ++ name ++ ".cpp"), .flags = flags.items, .language = .cpp });

    const obj = b.addObject(.{ .name = name, .root_module = mod });
    obj.incremental = false;
    return obj;
}

/// The angle-form `<JavaScriptCore/X.h>` includes resolve through cmake's
/// copied-headers dir in the upstream build. Recreate that layout with
/// symlinks into the vendored tree instead: both spellings of an include then
/// land on the same inode, so `#pragma once` deduplicates them (the copies
/// rely on include-order consistency and break down here). Also forwards the
/// prebuilt tarball's ICU headers, the only part of it still consumed.
fn forwardingDir(b: *Build, deps: *const exe.DepPkgs, cmake: []const u8) LazyPath {
    const arena = b.graph.arena;
    const io = b.graph.io;
    if (forwarding_dir_cache) |p| return .{ .cwd_relative = p };
    const fwd = rootJoin(b, ".zig-cache/webkit-fwd");
    const cwd: std.Io.Dir = .cwd();
    cwd.deleteTree(io, fwd) catch {};
    cwd.createDirPath(io, b.fmt("{s}/JavaScriptCore", .{fwd})) catch @panic("mkdir webkit-fwd");
    const jsc_abs = rootJoin(b, jsc_root);
    for ([_][]const u8{ "JavaScriptCore_PUBLIC_FRAMEWORK_HEADERS", "JavaScriptCore_PRIVATE_FRAMEWORK_HEADERS" }) |list| {
        for (cmakeList(arena, cmake, list)) |h| {
            cwd.symLink(
                io,
                b.fmt("{s}/{s}", .{ jsc_abs, h }),
                b.fmt("{s}/JavaScriptCore/{s}", .{ fwd, std.fs.path.basename(h) }),
                .{},
            ) catch |err| switch (err) {
                // Public and private lists overlap on a few headers.
                error.PathAlreadyExists => {},
                else => std.debug.panic("symlink {s}: {t}", .{ h, err }),
            };
        }
    }
    cwd.createDirPath(io, b.fmt("{s}/bmalloc", .{fwd})) catch @panic("mkdir webkit-fwd/bmalloc");
    const bmalloc_abs = rootJoin(b, "vendor/webkit/Source/bmalloc");
    const bmalloc_cmake = readCmakeFile(b, "vendor/webkit/Source/bmalloc/CMakeLists.txt");
    for ([_][]const u8{ "bmalloc_PUBLIC_HEADERS", "bmalloc_PRIVATE_HEADERS" }) |list| {
        for (cmakeList(arena, bmalloc_cmake, list)) |h| {
            cwd.symLink(
                io,
                b.fmt("{s}/{s}", .{ bmalloc_abs, h }),
                b.fmt("{s}/bmalloc/{s}", .{ fwd, std.fs.path.basename(h) }),
                .{},
            ) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => std.debug.panic("symlink {s}: {t}", .{ h, err }),
            };
        }
    }
    // ICU headers live in two source dirs; merge them into one unicode/ view.
    cwd.createDirPath(io, b.fmt("{s}/unicode", .{fwd})) catch @panic("mkdir webkit-fwd/unicode");
    const icu_abs = depRootAbs(b, deps.icu);
    for ([_][]const u8{ "icu/source/common/unicode", "icu/source/i18n/unicode" }) |sub| {
        const dir_abs = b.fmt("{s}/{s}", .{ icu_abs, sub });
        var dir = std.Io.Dir.openDirAbsolute(io, dir_abs, .{ .iterate = true }) catch std.debug.panic("open {s}", .{dir_abs});
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch @panic("iterate icu headers")) |entry| {
            if (entry.kind != .file) continue;
            cwd.symLink(
                io,
                b.fmt("{s}/{s}", .{ dir_abs, entry.name }),
                b.fmt("{s}/unicode/{s}", .{ fwd, entry.name }),
                .{},
            ) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => std.debug.panic("symlink unicode/{s}: {t}", .{ entry.name, err }),
            };
        }
    }
    forwarding_dir_cache = fwd;
    return .{ .cwd_relative = fwd };
}

var forwarding_dir_cache: ?[]const u8 = null;

fn depRootAbs(b: *Build, dep: *Build.Dependency) []const u8 {
    const root = dep.builder.root.toString(b.graph.arena) catch @panic("OOM");
    if (std.fs.path.isAbsolute(root)) return root;
    return rootJoin(b, root);
}

var cmake_files: std.StringHashMapUnmanaged([]const u8) = .empty;

fn readCMakeLists(b: *Build) []const u8 {
    return readCmakeFile(b, jsc_root ++ "/CMakeLists.txt");
}

fn readCmakeFile(b: *Build, rel: []const u8) []const u8 {
    const arena = b.graph.arena;
    if (cmake_files.get(rel)) |t| return t;
    const io = b.graph.io;
    const abs = rootJoin(b, rel);
    var dir = std.Io.Dir.openDirAbsolute(io, std.fs.path.dirname(abs).?, .{}) catch std.debug.panic("open {s}", .{rel});
    defer dir.close(io);
    const t = dir.readFileAlloc(io, std.fs.path.basename(abs), arena, .limited(4 << 20)) catch std.debug.panic("read {s}", .{rel});
    cmake_files.put(arena, rel, t) catch @panic("OOM");
    return t;
}

fn rootJoin(b: *Build, rel: []const u8) []const u8 {
    const root = b.root.toString(b.graph.arena) catch @panic("OOM");
    return std.fs.path.join(b.graph.arena, &.{ root, rel }) catch @panic("OOM");
}

/// Entries of a `set(<name> ...)` block, with the `${JAVASCRIPTCORE_DIR}`
/// prefix stripped ("" = the JSC root itself). Entries using any other cmake
/// variable are skipped.
fn cmakeList(arena: std.mem.Allocator, text: []const u8, name: []const u8) []const []const u8 {
    const header = std.fmt.allocPrint(arena, "set({s}", .{name}) catch @panic("OOM");
    const start = std.mem.indexOf(u8, text, header) orelse std.debug.panic("cmake list not found: {s}", .{name});
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text[start + header.len ..], '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r\"");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == ')') break;
        if (std.mem.startsWith(u8, line, "${JAVASCRIPTCORE_DIR}")) {
            line = std.mem.trimStart(u8, line["${JAVASCRIPTCORE_DIR}".len..], "/");
        }
        if (std.mem.indexOf(u8, line, "${") != null) continue;
        out.append(arena, line) catch @panic("OOM");
    }
    return out.items;
}

fn addListInputs(b: *Build, run: *Step.Run, cmake: []const u8, list_name: []const u8) void {
    for (cmakeList(b.graph.arena, cmake, list_name)) |f| run.addFileInput(jscPath(b, f));
}

fn addTreeInputs(b: *Build, run: *Step.Run, root: []const u8) void {
    const io = b.graph.io;
    var dir = std.Io.Dir.openDirAbsolute(io, rootJoin(b, root), .{ .iterate = true }) catch std.debug.panic("open {s}", .{root});
    defer dir.close(io);
    var walker = dir.walk(b.graph.arena) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch @panic("walk")) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(u8, entry.path, "__pycache__") != null) continue;
        run.addFileInput(b.path(b.fmt("{s}/{s}", .{ root, entry.path })));
    }
}
