// Hardcoded module "node:path"
const { validateString } = require("internal/validators");
const StringPrototypeReplaceAll = String.prototype.replaceAll;
const toNamespacedPathWindowsString = $bindgenFn("Path.schema.zig", "toNamespacedPathWindows");

function formatPath(pathObject, separator) {
  const isArray = $isJSArray(pathObject);
  if (pathObject === null || typeof pathObject !== "object" || isArray) {
    throw $bindgenFn("ErrorCode.schema.zig", "createFromMessage")(
      "ERR_INVALID_ARG_TYPE",
      `The "pathObject" property must be of type object, got ${isArray ? "array" : typeof pathObject}`,
    );
  }

  let dir = pathObject.dir;
  if (!dir) dir = pathObject.root;

  let base = pathObject.base;
  if (!base) {
    const name = pathObject.name;
    const nameString = name ? String(name) : "";
    const extension = pathObject.ext;
    let extensionString = "";
    let prependDot = false;
    if (extension) {
      const first = extension[0];
      prependDot = typeof first !== "string" || String(first) !== ".";
      extensionString = String(extension);
    }
    base = `${nameString}${prependDot ? "." : ""}${extensionString}`;
  }

  if (!dir) return base;
  const root = pathObject.root;
  return `${String(dir)}${dir === root ? "" : separator}${String(base)}`;
}

function toNamespacedPathPosix(path) {
  return path;
}

function toNamespacedPathWin32(path) {
  return typeof path === "string" ? toNamespacedPathWindowsString(path) : path;
}
const posix = {
  resolve: $bindgenFn("Path.schema.zig", "resolvePosix"),
  normalize: $bindgenFn("Path.schema.zig", "normalizePosix"),
  isAbsolute: $bindgenFn("Path.schema.zig", "isAbsolutePosix"),
  join: $bindgenFn("Path.schema.zig", "joinPosix"),
  relative: $bindgenFn("Path.schema.zig", "relativePosix"),
  toNamespacedPath: toNamespacedPathPosix,
  dirname: $bindgenFn("Path.schema.zig", "dirnamePosix"),
  basename: $bindgenFn("Path.schema.zig", "basenamePosix"),
  extname: $bindgenFn("Path.schema.zig", "extnamePosix"),
  format: pathObject => formatPath(pathObject, "/"),
  parse: $bindgenFn("Path.schema.zig", "parsePosix"),
  sep: "/",
  delimiter: ":",
  win32: undefined as typeof win32,
  posix: undefined as typeof posix,
  _makeLong: toNamespacedPathPosix,
};
const win32 = {
  resolve: $bindgenFn("Path.schema.zig", "resolveWindows"),
  normalize: $bindgenFn("Path.schema.zig", "normalizeWindows"),
  isAbsolute: $bindgenFn("Path.schema.zig", "isAbsoluteWindows"),
  join: $bindgenFn("Path.schema.zig", "joinWindows"),
  relative: $bindgenFn("Path.schema.zig", "relativeWindows"),
  toNamespacedPath: toNamespacedPathWin32,
  dirname: $bindgenFn("Path.schema.zig", "dirnameWindows"),
  basename: $bindgenFn("Path.schema.zig", "basenameWindows"),
  extname: $bindgenFn("Path.schema.zig", "extnameWindows"),
  format: pathObject => formatPath(pathObject, "\\"),
  parse: $bindgenFn("Path.schema.zig", "parseWindows"),
  sep: "\\",
  delimiter: ";",
  win32: undefined as typeof win32,
  posix,
  _makeLong: toNamespacedPathWin32,
};
posix.win32 = win32.win32 = win32;
posix.posix = posix;

type Glob = import("bun").Glob;

// the most-recently used glob is memoized in case `matchesGlob` is called in a
// loop with the same pattern
let prevGlob: Glob | undefined;
let prevPattern: string | undefined;
function matchesGlob(isWindows, path, pattern) {
  validateString(path, "path");
  validateString(pattern, "pattern");
  if (isWindows) {
    path = StringPrototypeReplaceAll.$call(path, "\\", "/");
    pattern = StringPrototypeReplaceAll.$call(pattern, "\\", "/");
  }
  if (!prevGlob || prevPattern !== pattern) {
    prevGlob = new Bun.Glob(pattern);
    prevPattern = pattern;
  }
  return prevGlob.match(path);
}

posix.matchesGlob = matchesGlob.bind(null, false);
win32.matchesGlob = matchesGlob.bind(null, true);

export default (process.platform === "win32" ? win32 : posix) as any as typeof import("node:path");
