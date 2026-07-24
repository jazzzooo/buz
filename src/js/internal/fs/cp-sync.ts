// Taken and modified from node.js: https://github.com/nodejs/node/blob/main/lib/internal/fs/cp/cp-sync.js

const ArrayPrototypeEvery = Array.prototype.every;
const ArrayPrototypeFilter = Array.prototype.filter;
const StringPrototypeSplit = String.prototype.split;

function areIdentical(srcStat, destStat) {
  return destStat.ino && destStat.dev && destStat.ino === srcStat.ino && destStat.dev === srcStat.dev;
}

const normalizePathToArray = path =>
  ArrayPrototypeFilter.$call(StringPrototypeSplit.$call(resolve(path), sep), Boolean);

function isSrcSubdir(src, dest) {
  const srcArr = normalizePathToArray(src);
  const destArr = normalizePathToArray(dest);
  return ArrayPrototypeEvery.$call(srcArr, (cur, i) => destArr[i] === cur);
}

const {
  chmodSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readlinkSync,
  statSync,
  symlinkSync,
  unlinkSync,
  utimesSync,
} = require("node:fs");
const { dirname, isAbsolute, join, parse, resolve, sep } = require("node:path");

function cpSyncFn(src, dest, opts) {
  // Warn about using preserveTimestamps on 32-bit node
  // if (opts.preserveTimestamps && process.arch === "ia32") {
  //   const warning = "Using the preserveTimestamps option in 32-bit " + "node is not recommended";
  //   process.emitWarning(warning, "TimestampPrecisionWarning");
  // }
  const { srcStat, destStat, skipped } = checkPathsSync(src, dest, opts);
  if (skipped) return;
  checkParentPathsSync(src, srcStat, dest);
  return checkParentDir(destStat, src, dest, opts);
}

function checkPathsSync(src, dest, opts) {
  if (opts.filter) {
    const shouldCopy = opts.filter(src, dest);
    if ($isPromise(shouldCopy)) {
      throw $ERR_INVALID_RETURN_VALUE("boolean", "filter", shouldCopy);
    }
    if (!shouldCopy) return { __proto__: null, skipped: true };
  }
  const { srcStat, destStat } = getStatsSync(src, dest, opts);

  if (destStat) {
    if (areIdentical(srcStat, destStat)) {
      throw $ERR_FS_CP_EINVAL(`src and dest cannot be the same ${dest}`);
    }
    if (srcStat.isDirectory() && !destStat.isDirectory()) {
      throw $ERR_FS_CP_DIR_TO_NON_DIR(`cannot overwrite non-directory ${dest} with directory ${src}`);
    }
    if (!srcStat.isDirectory() && destStat.isDirectory()) {
      throw $ERR_FS_CP_NON_DIR_TO_DIR(`cannot overwrite directory ${dest} with non-directory ${src}`);
    }
  }

  if (srcStat.isDirectory() && isSrcSubdir(src, dest)) {
    throw $ERR_FS_CP_EINVAL(`cannot copy ${src} to a subdirectory of self ${dest}`);
  }
  return { __proto__: null, srcStat, destStat, skipped: false };
}

function getStatsSync(src, dest, opts) {
  let destStat;
  const statFunc = opts.dereference
    ? file => statSync(file, { bigint: true })
    : file => lstatSync(file, { bigint: true });
  const srcStat = statFunc(src);
  try {
    destStat = statFunc(dest);
  } catch (err: any) {
    if (err.code === "ENOENT") return { srcStat, destStat: null };
    throw err;
  }
  return { srcStat, destStat };
}

function checkParentPathsSync(src, srcStat, dest) {
  const srcParent = resolve(dirname(src));
  const destParent = resolve(dirname(dest));
  if (destParent === srcParent || destParent === parse(destParent).root) return;
  let destStat;
  try {
    destStat = statSync(destParent, { bigint: true });
  } catch (err: any) {
    if (err.code === "ENOENT") return;
    throw err;
  }
  if (areIdentical(srcStat, destStat)) {
    throw $ERR_FS_CP_EINVAL(`cannot copy ${src} to a subdirectory of self ${dest}`);
  }
  return checkParentPathsSync(src, srcStat, destParent);
}

function checkParentDir(destStat, src, dest, opts) {
  const destParent = dirname(dest);
  if (!existsSync(destParent)) mkdirSync(destParent, { recursive: true });
  return getStats(destStat, src, dest, opts);
}

function getStats(destStat, src, dest, opts) {
  const statSyncFn = opts.dereference ? statSync : lstatSync;
  const srcStat = statSyncFn(src);

  if (srcStat.isDirectory() && opts.recursive) {
    return onDir(srcStat, destStat, src, dest, opts);
  } else if (srcStat.isDirectory()) {
    throw $ERR_FS_EISDIR(`${src} is a directory (not copied)`);
  } else if (srcStat.isFile() || srcStat.isCharacterDevice() || srcStat.isBlockDevice()) {
    return onFile(srcStat, destStat, src, dest, opts);
  } else if (srcStat.isSymbolicLink()) {
    return onLink(destStat, src, dest, opts);
  } else if (srcStat.isSocket()) {
    throw $ERR_FS_CP_SOCKET(`cannot copy a socket file: ${dest}`);
  } else if (srcStat.isFIFO()) {
    throw $ERR_FS_CP_FIFO_PIPE(`cannot copy a FIFO pipe: ${dest}`);
  }
  throw $ERR_FS_CP_UNKNOWN(`cannot copy an unknown file type: ${dest}`);
}

function onFile(srcStat, destStat, src, dest, opts) {
  if (!destStat) return copyFile(srcStat, src, dest, opts);
  return mayCopyFile(srcStat, src, dest, opts);
}

function mayCopyFile(srcStat, src, dest, opts) {
  if (opts.force) {
    unlinkSync(dest);
    return copyFile(srcStat, src, dest, opts);
  } else if (opts.errorOnExist) {
    throw $ERR_FS_CP_EEXIST(`${dest} already exists`);
  }
}

function copyFile(srcStat, src, dest, opts) {
  copyFileSync(src, dest, opts.mode);
  if (opts.preserveTimestamps) handleTimestamps(srcStat.mode, src, dest);
  return setDestMode(dest, srcStat.mode);
}

function handleTimestamps(srcMode, src, dest) {
  // Make sure the file is writable before setting the timestamp
  // otherwise open fails with EPERM when invoked with 'r+'
  // (through utimes call)
  if (fileIsNotWritable(srcMode)) makeFileWritable(dest, srcMode);
  return setDestTimestamps(src, dest);
}

function fileIsNotWritable(srcMode) {
  return (srcMode & 0o200) === 0;
}

function makeFileWritable(dest, srcMode) {
  return setDestMode(dest, srcMode | 0o200);
}

function setDestMode(dest, srcMode) {
  return chmodSync(dest, srcMode);
}

function setDestTimestamps(src, dest) {
  // The initial srcStat.atime cannot be trusted
  // because it is modified by the read(2) system call
  // (See https://nodejs.org/api/fs.html#fs_stat_time_values)
  const updatedSrcStat = statSync(src);
  return utimesSync(dest, updatedSrcStat.atime, updatedSrcStat.mtime);
}

function onDir(srcStat, destStat, src, dest, opts) {
  if (!destStat) return mkDirAndCopy(srcStat.mode, src, dest, opts);
  return copyDir(src, dest, opts);
}

function mkDirAndCopy(srcMode, src, dest, opts) {
  mkdirSync(dest);
  copyDir(src, dest, opts);
  return setDestMode(dest, srcMode);
}

function copyDir(src, dest, opts) {
  for (const dirent of readdirSync(src, { withFileTypes: true })) {
    const { name } = dirent;
    const srcItem = join(src, name);
    const destItem = join(dest, name);
    const { destStat, skipped } = checkPathsSync(srcItem, destItem, opts);
    if (!skipped) getStats(destStat, srcItem, destItem, opts);
  }
}

function onLink(destStat, src, dest, opts) {
  let resolvedSrc = readlinkSync(src);
  if (!opts.verbatimSymlinks && !isAbsolute(resolvedSrc)) {
    resolvedSrc = resolve(dirname(src), resolvedSrc);
  }
  if (!destStat) {
    return symlinkSync(resolvedSrc, dest);
  }
  let resolvedDest;
  try {
    resolvedDest = readlinkSync(dest);
  } catch (err: any) {
    // Dest exists and is a regular file or directory,
    // Windows may throw UNKNOWN error. If dest already exists,
    // fs throws error anyway, so no need to guard against it here.
    if (err.code === "EINVAL" || err.code === "UNKNOWN") {
      return symlinkSync(resolvedSrc, dest);
    }
    throw err;
  }
  if (!isAbsolute(resolvedDest)) {
    resolvedDest = resolve(dirname(dest), resolvedDest);
  }
  if (isSrcSubdir(resolvedSrc, resolvedDest)) {
    throw $ERR_FS_CP_EINVAL(`cannot copy ${resolvedSrc} to a subdirectory of self ${resolvedDest}`);
  }
  // Prevent copy if src is a subdir of dest since unlinking
  // dest in this case would result in removing src contents
  // and therefore a broken symlink would be created.
  if (statSync(dest).isDirectory() && isSrcSubdir(resolvedDest, resolvedSrc)) {
    throw $ERR_FS_CP_SYMLINK_TO_SUBDIRECTORY(`cannot overwrite ${resolvedDest} with ${resolvedSrc}`);
  }
  return copyLink(resolvedSrc, dest);
}

function copyLink(resolvedSrc, dest) {
  unlinkSync(dest);
  return symlinkSync(resolvedSrc, dest);
}

export default cpSyncFn;
