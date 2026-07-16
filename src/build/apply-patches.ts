// Copy a dependency source tree and apply patches / overlay files into the
// copy. Invoked by build.zig (src/build/exe.zig) under the pinned bootstrap
// bun:
//
//   bun apply-patches.ts <src_dir> <out_dir> [--delete=rel]... [patch-or-overlay...]
//
// .patch files are applied with `git apply` (works outside a repository);
// --delete=rel removes a path from the copy (e.g. the OpenSSL headers the
// Node.js headers package ships, which would shadow BoringSSL's); anything
// else is copied into the tree root (overlay, e.g. jbun_stubs.c).
import { cpSync, copyFileSync, mkdirSync, rmSync } from "node:fs";
import { basename, join, resolve } from "node:path";

// git apply runs with cwd=out; argv paths are build-root-relative.
const [src, out, ...patches] = process.argv.slice(2).map(p => (p.startsWith("--delete=") ? p : resolve(p)));
if (!src || !out) {
  console.error("usage: apply-patches.ts <src_dir> <out_dir> [patches...]");
  process.exit(1);
}

mkdirSync(out, { recursive: true });
cpSync(src, out, { recursive: true });

for (const p of patches) {
  if (p.startsWith("--delete=")) {
    rmSync(join(out, p.slice("--delete=".length)), { recursive: true, force: true });
  } else if (p.endsWith(".patch")) {
    const result = Bun.spawnSync({ cmd: ["git", "apply", p], cwd: out, stdio: ["ignore", "inherit", "inherit"] });
    if (result.exitCode !== 0) {
      console.error(`git apply failed: ${p}`);
      process.exit(1);
    }
  } else {
    copyFileSync(p, join(out, basename(p)));
  }
}
