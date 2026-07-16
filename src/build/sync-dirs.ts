// Mirror build outputs into the stable runtime-load directories. Invoked by
// build.zig (src/build/exe.zig) under the pinned bootstrap bun:
//
//   bun sync-dirs.ts <dest_root> [<src> <dest_rel>]...
//
// Each <src> may be a file or a directory; contents are copied into
// <dest_root>/<dest_rel> only when changed (mtime-preserving no-op
// otherwise), so debug binaries can load codegen output from a fixed path
// while the build graph keeps everything content-addressed. Files under the
// managed top-level subtrees that no pair produced are deleted, so removed
// generated files cannot linger and mask breakage.
import { mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const args = process.argv.slice(2);
if (args.length < 1 || (args.length - 1) % 2 !== 0) {
  console.error("usage: sync-dirs.ts <dest_root> [<src> <dest_rel>]...");
  process.exit(1);
}
// Absolute paths throughout: readdirSync normalizes `./`-prefixed parents,
// which would break the rel computation below.
const destRoot = resolve(args[0]!);
const pairs = args.slice(1);

const expected = new Set<string>();

function syncFile(src: string, destRel: string): void {
  expected.add(destRel);
  const dest = join(destRoot, destRel);
  const content = readFileSync(src);
  try {
    if (content.equals(readFileSync(dest))) return;
  } catch {}
  mkdirSync(dirname(dest), { recursive: true });
  // Write-then-rename: a running debug bun loads builtins from these
  // directories and must never see a partial write.
  const tmp = `${dest}.${process.pid}.tmp`;
  writeFileSync(tmp, content);
  renameSync(tmp, dest);
}

function listFiles(root: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(root, { withFileTypes: true, recursive: true })) {
    if (!entry.isFile()) continue;
    const parent = entry.parentPath;
    out.push(parent === root ? entry.name : join(parent.slice(root.length + 1), entry.name));
  }
  return out;
}

function syncTree(src: string, destRel: string): void {
  if (statSync(src).isFile()) {
    syncFile(src, destRel);
    return;
  }
  for (const rel of listFiles(src)) {
    syncFile(join(src, rel), join(destRel, rel));
  }
}

const roots = new Set<string>();
for (let i = 0; i < pairs.length; i += 2) {
  roots.add(pairs[i + 1]!.split("/")[0]!);
  syncTree(resolve(pairs[i]!), pairs[i + 1]!);
}

for (const root of roots) {
  let stale: string[];
  try {
    stale = listFiles(join(destRoot, root));
  } catch {
    continue;
  }
  for (const rel of stale) {
    const destRel = join(root, rel);
    if (!expected.has(destRel)) rmSync(join(destRoot, destRel), { force: true });
  }
}
