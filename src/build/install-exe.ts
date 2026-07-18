// Install linked build products by hardlink. Invoked by build.zig
// (src/build/exe.zig) under the pinned bootstrap bun:
//
//   bun install-exe.ts <src> <dest> [<src> <dest>...]
//
// Link-then-rename: the destination is never truncated in place, a running
// binary keeps its complete old inode, and the installed separate-debug
// file stays tied to the inode mold's detached writer is still filling.
// Falls back to a copy across filesystems.
import { copyFileSync, linkSync, mkdirSync, renameSync, rmSync, statSync } from "node:fs";
import { dirname } from "node:path";

const args = process.argv.slice(2);
if (args.length < 2 || args.length % 2 !== 0) {
  console.error("usage: install-exe.ts <src> <dest> [<src> <dest>...]");
  process.exit(1);
}

for (let i = 0; i < args.length; i += 2) {
  const src = args[i]!;
  const dest = args[i + 1]!;
  // Same inode already: skip — rename() of a hardlink onto its own inode is
  // a POSIX no-op that would leave the temp name behind.
  const srcStat = statSync(src);
  const destStat = statSync(dest, { throwIfNoEntry: false });
  if (destStat && srcStat.dev === destStat.dev && srcStat.ino === destStat.ino) continue;
  mkdirSync(dirname(dest), { recursive: true });
  const tmp = `${dest}.${process.pid}.tmp`;
  rmSync(tmp, { force: true });
  try {
    linkSync(src, tmp);
  } catch {
    copyFileSync(src, tmp);
  }
  renameSync(tmp, dest);
}
