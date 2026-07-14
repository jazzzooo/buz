/**
 * Zig build step.
 *
 * Uses the upstream compiler in vendor/zig-upstream/build/stage3.
 *
 * The Zig build is one `zig build obj` invocation. Zig's build system
 * (build.zig) handles the per-file compilation; our
 * ninja rule just invokes it and declares the output. restat lets zig's
 * incremental compilation prune downstream when nothing changed.
 */

import { existsSync } from "node:fs";
import { resolve } from "node:path";
import type { Config } from "./config.ts";
import { assert } from "./error.ts";
import { writeIfChanged } from "./fs.ts";
import type { Ninja } from "./ninja.ts";
import { quote, quoteArgs } from "./shell.ts";
import { streamPath } from "./stream.ts";

/**
 * Commit of the upstream checkout currently used to build the compiler.
 */
export const ZIG_COMMIT = "80d06578ac66bce3aa0a21e9610cdb782b9a0593";

/**
 * Output object file names for the zig step, matching what build.zig emits.
 * Shared between emitZig (zig-only/full) and emitLinkOnly so both sides of
 * the CI artifact split agree on filenames.
 */
export function zigObjectPaths(cfg: Config): string[] {
  return [resolve(cfg.buildDir, "bun-zig.o")];
}

// ───────────────────────────────────────────────────────────────────────────
// Target/optimize/CPU computation
// ───────────────────────────────────────────────────────────────────────────

/**
 * Zig target triple. Arch is always `x86_64`/`aarch64` (zig's naming),
 * not `x64`/`arm64`.
 */
export function zigTarget(cfg: Config): string {
  const arch = cfg.x64 ? "x86_64" : "aarch64";
  if (cfg.darwin) return `${arch}-macos-none`;
  if (cfg.windows) return `${arch}-windows-msvc`;
  if (cfg.freebsd) {
    assert(cfg.freebsdVersion !== undefined, "freebsd build missing version");
    return `${arch}-freebsd.${cfg.freebsdVersion}-none`;
  }
  // linux: abi is always set (resolveConfig asserts)
  assert(cfg.abi !== undefined, "linux build missing abi");
  if (cfg.abi === "android") {
    assert(cfg.androidApiLevel !== undefined, "android build missing api level");
    return `${arch}-linux-android.${cfg.androidApiLevel}`;
  }
  return `${arch}-linux-${cfg.abi}`;
}

/**
 * Zig doesn't bundle bionic or FreeBSD libc headers, so cross-compile
 * targets need an explicit libc file (`--libc`) pointing at the sysroot
 * for Compile steps, and the sysroot path passed separately for
 * translate-c. Writes the libc file at configure time (idempotent via
 * writeIfChanged).
 */
function crossLibcArgs(cfg: Config): string[] {
  if (cfg.abi === "android") {
    assert(cfg.sysroot !== undefined && cfg.androidApiLevel !== undefined, "android build missing sysroot");
    const archTriple = cfg.x64 ? "x86_64-linux-android" : "aarch64-linux-android";
    const libcFile = resolve(cfg.buildDir, "android-libc.txt");
    writeIfChanged(
      libcFile,
      [
        `include_dir=${cfg.sysroot}/usr/include`,
        `sys_include_dir=${cfg.sysroot}/usr/include/${archTriple}`,
        `crt_dir=${cfg.sysroot}/usr/lib/${archTriple}/${cfg.androidApiLevel}`,
        `msvc_lib_dir=`,
        `kernel32_lib_dir=`,
        `gcc_dir=`,
        ``,
      ].join("\n"),
    );
    return ["--libc", libcFile, `-Dandroid_ndk_sysroot=${cfg.sysroot}`];
  }
  if (cfg.freebsd) {
    // Native FreeBSD host: sysroot is "/". Cross-compile: extracted base.txz.
    // build.zig requires -Dfreebsd_sysroot for translate-c either way.
    const root = cfg.sysroot ?? "";
    const libcFile = resolve(cfg.buildDir, "freebsd-libc.txt");
    writeIfChanged(
      libcFile,
      [
        `include_dir=${root}/usr/include`,
        `sys_include_dir=${root}/usr/include`,
        `crt_dir=${root}/usr/lib`,
        `msvc_lib_dir=`,
        `kernel32_lib_dir=`,
        `gcc_dir=`,
        ``,
      ].join("\n"),
    );
    return ["--libc", libcFile, `-Dfreebsd_sysroot=${root || "/"}`];
  }
  return [];
}

/**
 * Zig optimize level.
 *
 * The Windows ReleaseFast → ReleaseSafe downgrade is intentional: since
 * Bun 1.1, Windows builds use ReleaseSafe because it caught more crashes.
 * This is a load-bearing workaround; don't "fix" it.
 */
export function zigOptimize(cfg: Config): "Debug" | "ReleaseFast" | "ReleaseSafe" | "ReleaseSmall" {
  let opt: "Debug" | "ReleaseFast" | "ReleaseSafe" | "ReleaseSmall";
  switch (cfg.buildType) {
    case "Debug":
      opt = "Debug";
      break;
    case "Release":
      opt = cfg.asan ? "ReleaseSafe" : "ReleaseFast";
      break;
    case "RelWithDebInfo":
      opt = "ReleaseSafe";
      break;
    case "MinSizeRel":
      opt = "ReleaseSmall";
      break;
  }
  // Windows: never ReleaseFast. See header comment.
  if (cfg.windows && opt === "ReleaseFast") {
    opt = "ReleaseSafe";
  }
  return opt;
}

/**
 * Zig CPU target.
 *
 * arm64: apple_m1 (darwin), cortex_a76 (windows — no ARMv9 windows yet),
 *   native (linux — no baseline arm64 builds needed).
 * x64: nehalem (baseline, pre-AVX), haswell (AVX2).
 */
export function zigCpu(cfg: Config): string {
  if (cfg.arm64) {
    if (cfg.darwin) return "apple_m1";
    if (cfg.windows) return "cortex_a76";
    return "native";
  }
  // x64
  return cfg.baseline ? "nehalem" : "haswell";
}

/**
 * Whether codegen outputs should be @embedFile'd into the binary (release)
 * or loaded at runtime (debug — faster iteration, no relink on codegen change).
 */
export function codegenEmbed(cfg: Config): boolean {
  return cfg.release || cfg.ci;
}

// ───────────────────────────────────────────────────────────────────────────
// Paths
// ───────────────────────────────────────────────────────────────────────────

function zigPath(cfg: Config): string {
  return resolve(cfg.vendorDir, "zig-upstream", "build", "stage3");
}

function zigExecutable(cfg: Config): string {
  return resolve(zigPath(cfg), "bin", "zig" + cfg.host.exeSuffix);
}

function zigLibDir(cfg: Config): string {
  return resolve(zigPath(cfg), "lib", "zig");
}

/**
 * Zig cache directories — where zig stores incremental compilation state.
 */
function zigCacheDirs(cfg: Config): { local: string; global: string } {
  return {
    local: resolve(cfg.buildDir, "cache", "zig", "local"),
    global: resolve(cfg.cacheDir, "zig", "global"),
  };
}

// ───────────────────────────────────────────────────────────────────────────
// Ninja rules
// ───────────────────────────────────────────────────────────────────────────

export function registerZigRules(n: Ninja, cfg: Config): void {
  const hostWin = cfg.host.os === "windows";
  const q = (p: string) => quote(p, hostWin);
  const stream = `${cfg.jsRuntime} ${q(streamPath)} zig`;

  // Zig's build system handles source dependency tracking and incremental
  // compilation; Ninja tracks the installed object consumed by the final link.
  //
  // Default: --console + pool=console. Zig gets direct TTY, its native
  // spinner works. Ninja defers [N/M] while the console job owns the
  // terminal, so cxx progress is hidden during zig's compile. Matches
  // the old cmake build's behavior.
  //
  const interleave = false;
  const consoleMode = !interleave || hostWin;
  n.rule("zig_build", {
    command: `${stream} ${consoleMode ? "--console" : "--zig-progress"} --env=ZIG_LOCAL_CACHE_DIR=$zig_local_cache --env=ZIG_GLOBAL_CACHE_DIR=$zig_global_cache $zig build $step $args`,
    description: "zig $step → $label",
    ...(consoleMode && { pool: "console" }),
    restat: true,
  });

  // Zig semantic check — `zig build check[-*]`. Type-checks without
  // emitting object code; output is a stamp file created by --stamp so
  // ninja can track completion. Same cache dirs as the main zig build —
  // zig keys by hash, the two coexist cleanly.
  n.rule("zig_check", {
    command: `${stream} --console --stamp=$out --env=ZIG_LOCAL_CACHE_DIR=$zig_local_cache --env=ZIG_GLOBAL_CACHE_DIR=$zig_global_cache $zig build $step $args`,
    description: "zig $step",
    pool: "console",
    restat: true,
  });
}

// ───────────────────────────────────────────────────────────────────────────
// Zig build emission
// ───────────────────────────────────────────────────────────────────────────

/**
 * Inputs to the zig build step. Assembled by the caller from
 * resolved deps + emitted codegen outputs.
 */
export interface ZigBuildInputs {
  /**
   * Generated files zig needs (content tracked). From CodegenOutputs.zigInputs.
   * Changes here must trigger a zig rebuild.
   */
  codegenInputs: string[];
  /**
   * All `*.zig` source files (globbed at configure time, codegen-into-src
   * files already filtered out by caller). Implicit inputs for ninja's
   * staleness check — zig discovers sources itself, this is just so ninja
   * knows when to re-invoke.
   */
  zigSources: string[];
  /**
   * Generated files zig needs to EXIST but doesn't track content of.
   * From CodegenOutputs.zigOrderOnly — specifically the bake runtime .js
   * files in debug mode (runtime-loaded, not embedded).
   */
  codegenOrderOnly: string[];
  /**
   * zstd source fetch stamp. build.zig `@cImport`s headers from
   * vendor/zstd/lib/ directly — doesn't need zstd BUILT, just FETCHED.
   * Order-only because the headers don't change often and zig's own
   * translate-c caching handles the inner dependency.
   */
  zstdStamp: string;
}

/**
 * Emit the Zig build step. Returns the output object file.
 */
export function emitZig(n: Ninja, cfg: Config, inputs: ZigBuildInputs): string[] {
  n.comment("─── Zig ───");
  n.blank();

  const zigExe = zigExecutable(cfg);
  assert(existsSync(zigExe), `upstream zig has not been built: ${zigExe}`);
  assert(existsSync(zigLibDir(cfg)), `upstream zig standard library not found: ${zigLibDir(cfg)}`);
  n.phony("zig-compiler", [zigExe]);

  // ─── Build ───
  const cacheDirs = zigCacheDirs(cfg);
  const outputs = zigObjectPaths(cfg);
  const args = zigBuildArgs(cfg);

  n.build({
    outputs,
    rule: "zig_build",
    inputs: [],
    implicitInputs: zigBuildImplicitInputs(cfg, inputs),
    orderOnlyInputs: zigBuildOrderOnlyInputs(inputs),
    vars: {
      zig: zigExe,
      step: "obj",
      args: quoteArgs(args, cfg.host.os === "windows"),
      zig_local_cache: cacheDirs.local,
      zig_global_cache: cacheDirs.global,
      label: "bun-zig.o",
    },
  });
  n.phony("bun-zig", outputs);
  n.blank();

  return outputs;
}

// ───────────────────────────────────────────────────────────────────────────
// Shared `zig build` invocation helpers (obj + check)
// ───────────────────────────────────────────────────────────────────────────

/**
 * `zig build` CLI args shared by both the obj build and the check steps.
 * build.zig options have `orelse` defaults, so unknown-to-a-step options
 * (e.g. -Dtarget for check-all, which sets targets internally) are ignored
 * silently — we pass them uniformly for simplicity and diffability.
 */
function zigBuildArgs(cfg: Config): string[] {
  const bool = (b: boolean): string => (b ? "true" : "false");
  return [
    "--prefix",
    cfg.buildDir,

    // Target/optimize/cpu
    "-Dobj_format=obj",
    `-Dtarget=${zigTarget(cfg)}`,
    `-Doptimize=${zigOptimize(cfg)}`,
    `-Dcpu=${zigCpu(cfg)}`,
    ...crossLibcArgs(cfg),

    // Feature flags
    `-Denable_logs=${bool(cfg.logs)}`,
    `-Denable_asan=${bool(cfg.zigAsan)}`,
    `-Denable_fuzzilli=${bool(cfg.fuzzilli)}`,
    `-Denable_valgrind=${bool(cfg.valgrind)}`,
    `-Denable_tinycc=${bool(cfg.tinycc)}`,
    `-Dlto=${bool(cfg.lto)}`,
    // Always ON — bun uses mimalloc as its default allocator. The flag
    // exists for experimentation; in practice it's never OFF.
    `-Duse_mimalloc=true`,
    // Versioning
    `-Dversion=${cfg.version}`,
    `-Dreported_nodejs_version=${cfg.nodejsVersion}`,
    `-Dcanary=${cfg.canaryRevision}`,
    `-Dcodegen_path=${cfg.codegenDir}`,
    `-Dcodegen_embed=${bool(codegenEmbed(cfg))}`,

    // Git sha (optional — empty on dirty builds).
    ...(cfg.revision !== "unknown" && cfg.revision !== "" ? [`-Dsha=${cfg.revision}`] : []),

    // Output formatting
    "--summary",
    "all",
  ];
}

/**
 * Implicit inputs for any zig build invocation (obj or check). Same set
 * in both cases — the compiler, build.zig, every .zig source, and every
 * codegen file zig imports or embeds.
 */
function zigBuildImplicitInputs(cfg: Config, inputs: ZigBuildInputs): string[] {
  // Extra embed: scanner-entry.ts is @embedFile'd by the zig code directly.
  // A genuinely odd cross-language embed; there's no cleaner way.
  const scannerEntry = resolve(cfg.cwd, "src", "install", "PackageManager", "scanner-entry.ts");
  return [
    // Compiler itself — rebuild on zig version bump.
    zigExecutable(cfg),
    // build.zig — the zig build script.
    resolve(cfg.cwd, "build.zig"),
    // All zig source files (codegen outputs already filtered by caller).
    ...inputs.zigSources,
    // Codegen outputs zig imports/embeds.
    ...inputs.codegenInputs,
    // The odd cross-language embed.
    scannerEntry,
  ];
}

/**
 * Order-only inputs for any zig build invocation — files that must EXIST
 * but whose content is tracked elsewhere (zig's translate-c cache, or
 * they're runtime-loaded not embedded).
 */
function zigBuildOrderOnlyInputs(inputs: ZigBuildInputs): string[] {
  return [
    // zstd headers — must exist for @cImport, but content is tracked by
    // zig's translate-c cache, not ninja.
    inputs.zstdStamp,
    // Debug-mode bake runtime — must exist at runtime-load path, but
    // zig doesn't track content (not embedded).
    ...inputs.codegenOrderOnly,
  ];
}

// ───────────────────────────────────────────────────────────────────────────
// Zig semantic check — `zig build check[-*]`
// ───────────────────────────────────────────────────────────────────────────

/**
 * `zig build` check steps exposed as ninja targets. Each becomes a phony
 * `zig-<step>` plus a stamp file, invokable via `bun bd --target=zig-check`
 * (etc.). See build.zig for what each step covers.
 *
 * `check` type-checks the current platform (uses -Dtarget/-Dcpu). The
 * `check-*` variants iterate multiple targets internally — our -Dtarget
 * is inert for them.
 */
const CHECK_STEPS = [
  "check",
  "check-debug",
  "check-all",
  "check-all-debug",
  "check-windows",
  "check-windows-debug",
  "check-macos",
  "check-macos-debug",
  "check-linux",
  "check-linux-debug",
] as const;

/**
 * Emit one ninja edge per `zig build check[-*]` step. Each depends on
 * the same codegen + zig source set as the obj build, so users can run
 * `bun bd --target=zig-check` and ninja will rebuild any stale codegen
 * before invoking zig. Output is a stamp file (stream.ts --stamp writes
 * it on exit 0); restat lets the no-op case prune downstream.
 *
 * Assumes the zig compiler download edge (from `emitZig`) has already
 * been emitted — we depend on zigExecutable but don't re-emit the fetch.
 */
export function emitZigCheck(n: Ninja, cfg: Config, inputs: ZigBuildInputs): void {
  n.comment("─── Zig semantic check ───");
  n.blank();

  const zigExe = zigExecutable(cfg);
  const cacheDirs = zigCacheDirs(cfg);
  // `--summary new` instead of `all`: check is a fast-iteration workflow
  // (mostly cache hits), so skip the "cached" rows zig would otherwise
  // print for every unchanged step. Matches the pre-ninja `zig:check`
  // scripts. zigBuildArgs ends with `--summary all`; swap the last arg.
  const args = zigBuildArgs(cfg);
  args[args.length - 1] = "new";
  const hostWin = cfg.host.os === "windows";

  for (const step of CHECK_STEPS) {
    const stamp = resolve(cfg.buildDir, `.zig-${step}.stamp`);
    n.build({
      outputs: [stamp],
      rule: "zig_check",
      inputs: [],
      implicitInputs: zigBuildImplicitInputs(cfg, inputs),
      orderOnlyInputs: zigBuildOrderOnlyInputs(inputs),
      vars: {
        zig: zigExe,
        step,
        args: quoteArgs(args, hostWin),
        zig_local_cache: cacheDirs.local,
        zig_global_cache: cacheDirs.global,
      },
    });
    n.phony(`zig-${step}`, [stamp]);
  }
  n.blank();
}

// ───────────────────────────────────────────────────────────────────────────
// ───────────────────────────────────────────────────────────────────────────
