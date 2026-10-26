const Path = @This();

const PATH_MIN_WIDE = 4096; // 4 KB
const stack_fallback_size_small = switch (Environment.os) {
    // Up to 4 KB, instead of MAX_PATH_BYTES which is 96 KB on Windows, ouch!
    .windows => PATH_MIN_WIDE,
    else => bun.MAX_PATH_BYTES,
};

/// Taken from Zig 0.11.0 zig/src/resinator/rc.zig
/// https://github.com/ziglang/zig/blob/776cd673f206099012d789fd5d05d49dd72b9faa/src/resinator/rc.zig#L266
///
/// Compares ASCII values case-insensitively, non-ASCII values are compared directly
fn eqlIgnoreCaseT(comptime T: type, a: []const T, b: []const T) bool {
    if (T != u16) {
        return bun.strings.eqlCaseInsensitiveASCII(a, b, true);
    }
    if (a.len != b.len) return false;
    for (a, b) |a_unit, b_unit| {
        if (toLowerT(T, a_unit) != toLowerT(T, b_unit)) return false;
    }
    return true;
}

/// Taken from Zig 0.11.0 zig/src/resinator/rc.zig
/// https://github.com/ziglang/zig/blob/776cd673f206099012d789fd5d05d49dd72b9faa/src/resinator/rc.zig#L266
///
/// Lowers ASCII values, non-ASCII values are returned directly
inline fn toLowerT(comptime T: type, a_c: T) T {
    if (T != u16) {
        return std.ascii.toLower(a_c);
    }
    return if (a_c < 128) @intCast(std.ascii.toLower(@intCast(a_c))) else a_c;
}

fn MaybeBuf(comptime T: type) type {
    return Syscall.Maybe([]T);
}

fn MaybeSlice(comptime T: type) type {
    return Syscall.Maybe([:0]const T);
}

fn validatePathT(comptime T: type, comptime methodName: []const u8) void {
    comptime switch (T) {
        u8, u16 => return,
        else => @compileError("Unsupported type for " ++ methodName ++ ": " ++ typeBaseNameT(T)),
    };
}

const CHAR_BACKWARD_SLASH = '\\';
const CHAR_COLON = ':';
const CHAR_DOT = '.';
const CHAR_FORWARD_SLASH = '/';
const CHAR_QUESTION_MARK = '?';

const CHAR_STR_BACKWARD_SLASH = "\\";
const CHAR_STR_FORWARD_SLASH = "/";
const CHAR_STR_DOT = ".";

/// Based on Node v21.6.1 path.parse:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L919
/// The structs returned by parse methods.
fn PathParsed(comptime T: type) type {
    return struct {
        root: []const T = &.{},
        dir: []const T = &.{},
        base: []const T = &.{},
        ext: []const T = &.{},
        name: []const T = &.{},

        pub fn toBindingResult(this: @This(), comptime Schema: type) bun.OOM!bun.bindgen.Return(Schema) {
            var root = try domStringFromCodeUnits(T, this.root);
            errdefer root.deinit();
            var dir = try domStringFromCodeUnits(T, this.dir);
            errdefer dir.deinit();
            var base = try domStringFromCodeUnits(T, this.base);
            errdefer base.deinit();
            var ext = try domStringFromCodeUnits(T, this.ext);
            errdefer ext.deinit();
            var name = try domStringFromCodeUnits(T, this.name);
            errdefer name.deinit();
            return .{
                .root = root,
                .dir = dir,
                .base = base,
                .ext = ext,
                .name = name,
            };
        }
    };
}

fn domStringFromCodeUnits(comptime T: type, value: []const T) bun.OOM!bun.bindgen.DOMString {
    return if (T == u8)
        bun.bindgen.DOMString.fromLatin1(value)
    else
        bun.bindgen.DOMString.fromUTF16(value);
}

fn hasUTF16(value: bun.bindgen.UnsafeStringCodeUnits) bool {
    return switch (value) {
        .latin1 => false,
        .utf16 => true,
    };
}

fn codeUnitsAs(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: bun.bindgen.UnsafeStringCodeUnits,
) bun.OOM![]const T {
    if (comptime T == u8) {
        return switch (value) {
            .latin1 => |units| units,
            .utf16 => unreachable,
        };
    }

    return switch (value) {
        .utf16 => |units| units,
        .latin1 => |units| widened: {
            const result = try allocator.alloc(u16, units.len);
            for (result, units) |*destination, source| destination.* = source;
            break :widened result;
        },
    };
}

fn cloneCodeUnitsAs(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: bun.bindgen.UnsafeStringCodeUnits,
) bun.OOM![]const T {
    if (comptime T == u8) {
        return switch (value) {
            .latin1 => |units| allocator.dupe(u8, units),
            .utf16 => unreachable,
        };
    }

    return switch (value) {
        .utf16 => |units| allocator.dupe(u16, units),
        .latin1 => |units| widened: {
            const result = try allocator.alloc(u16, units.len);
            for (result, units) |*destination, source| destination.* = source;
            break :widened result;
        },
    };
}

pub fn MAX_PATH_SIZE(comptime T: type) usize {
    return if (T == u16) windows.PATH_MAX_WIDE else bun.MAX_PATH_BYTES;
}

pub fn PATH_SIZE(comptime T: type) usize {
    return if (T == u16) PATH_MIN_WIDE else bun.MAX_PATH_BYTES;
}

pub const sep_posix = CHAR_FORWARD_SLASH;
pub const sep_windows = CHAR_BACKWARD_SLASH;
pub const sep_str_posix = CHAR_STR_FORWARD_SLASH;
pub const sep_str_windows = CHAR_STR_BACKWARD_SLASH;

/// Based on Node v21.6.1 private helper posixCwd:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L1074
inline fn posixCwdT(comptime T: type, buf: []T) MaybeBuf(T) {
    const cwd = switch (getCwdT(T, buf)) {
        .result => |r| r,
        .err => |e| return MaybeBuf(T){ .err = e },
    };
    const len = cwd.len;
    if (len == 0) {
        return MaybeBuf(T){ .result = cwd };
    }
    if (comptime Environment.isWindows) {
        // Converts Windows' backslash path separators to POSIX forward slashes
        // and truncates any drive indicator

        // Translated from the following JS code:
        //   const cwd = StringPrototypeReplace(process.cwd(), regexp, '/');
        for (0..len) |i| {
            if (cwd[i] == CHAR_BACKWARD_SLASH) {
                buf[i] = CHAR_FORWARD_SLASH;
            } else {
                buf[i] = cwd[i];
            }
        }
        var normalizedCwd = buf[0..len];

        // Translated from the following JS code:
        //   return StringPrototypeSlice(cwd, StringPrototypeIndexOf(cwd, '/'));
        const index = std.mem.indexOfScalar(T, normalizedCwd, CHAR_FORWARD_SLASH);
        // Account for the -1 case of String#slice in JS land
        if (index) |_index| {
            return MaybeBuf(T){ .result = normalizedCwd[_index..len] };
        }
        return MaybeBuf(T){ .result = normalizedCwd[len - 1 .. len] };
    }

    // We're already on POSIX, no need for any transformations
    return MaybeBuf(T){ .result = cwd };
}

const withoutTrailingSlash = if (Environment.isWindows) strings.withoutTrailingSlashWindowsPath else strings.withoutTrailingSlash;

pub fn getCwdWindowsU16(buf: []u16) MaybeBuf(u16) {
    const result = strings.convertUTF8toUTF16InBuffer(buf, withoutTrailingSlash(bun.fs.FileSystem.instance.top_level_dir));
    if (result.len == 0) {
        // Indirectly calls std.os.windows.kernel32.GetLastError().
        return MaybeBuf(u16).errnoSys(0, Syscall.Tag.getcwd).?;
    }
    return MaybeBuf(u16){ .result = result };
}

pub fn getCwdU8(buf: []u8) MaybeBuf(u8) {
    const cached_cwd = withoutTrailingSlash(bun.fs.FileSystem.instance.top_level_dir);
    @memcpy(buf[0..cached_cwd.len], cached_cwd);
    return MaybeBuf(u8){ .result = buf[0..cached_cwd.len] };
}

pub fn getCwdU16(buf: []u16) MaybeBuf(u16) {
    const result = strings.convertUTF8toUTF16InBuffer(buf, withoutTrailingSlash(bun.fs.FileSystem.instance.top_level_dir));
    return MaybeBuf(u16){ .result = result };
}

pub fn getCwdT(comptime T: type, buf: []T) MaybeBuf(T) {
    comptime validatePathT(T, "getCwdT");
    return if (T == u16)
        getCwdU16(buf)
    else
        getCwdU8(buf);
}

// Alias for naming consistency.
pub const getCwd = getCwdU8;

/// Based on Node v21.6.1 path.posix.basename:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L1309
pub fn basenamePosixT(comptime T: type, path: []const T, suffix: ?[]const T) []const T {
    comptime validatePathT(T, "basenamePosixT");

    const len = path.len;
    // Exit early for easier number type use.
    if (len == 0) {
        return &.{};
    }
    var start: usize = 0;
    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var end: ?usize = null;
    var matchedSlash: bool = true;

    const _suffix = if (suffix) |_s| _s else &.{};
    const _suffixLen = _suffix.len;
    if (suffix != null and _suffixLen > 0 and _suffixLen <= len) {
        if (std.mem.eql(T, _suffix, path)) {
            return &.{};
        }
        // We use an optional value instead of -1, as in Node code, for easier number type use.
        var extIdx: ?usize = _suffixLen - 1;
        // We use an optional value instead of -1, as in Node code, for easier number type use.
        var firstNonSlashEnd: ?usize = null;
        var i_i64 = @as(i64, @intCast(len - 1));
        while (i_i64 >= start) : (i_i64 -= 1) {
            const i = @as(usize, @intCast(i_i64));
            const byte = path[i];
            if (byte == CHAR_FORWARD_SLASH) {
                // If we reached a path separator that was not part of a set of path
                // separators at the end of the string, stop now
                if (!matchedSlash) {
                    start = i + 1;
                    break;
                }
            } else {
                if (firstNonSlashEnd == null) {
                    // We saw the first non-path separator, remember this index in case
                    // we need it if the extension ends up not matching
                    matchedSlash = false;
                    firstNonSlashEnd = i + 1;
                }
                if (extIdx) |_extIx| {
                    // Try to match the explicit extension
                    if (byte == _suffix[_extIx]) {
                        if (_extIx == 0) {
                            // We matched the extension, so mark this as the end of our path
                            // component
                            end = i;
                            extIdx = null;
                        } else {
                            extIdx = _extIx - 1;
                        }
                    } else {
                        // Extension does not match, so our result is the entire path
                        // component
                        extIdx = null;
                        end = firstNonSlashEnd;
                    }
                }
            }
        }

        if (end) |_end| {
            if (start == _end) {
                return path[start..firstNonSlashEnd.?];
            } else {
                return path[start.._end];
            }
        }
        return path[start..len];
    }

    var i_i64 = @as(i64, @intCast(len - 1));
    while (i_i64 > -1) : (i_i64 -= 1) {
        const i = @as(usize, @intCast(i_i64));
        const byte = path[i];
        if (byte == CHAR_FORWARD_SLASH) {
            // If we reached a path separator that was not part of a set of path
            // separators at the end of the string, stop now
            if (!matchedSlash) {
                start = i + 1;
                break;
            }
        } else if (end == null) {
            // We saw the first non-path separator, mark this as the end of our
            // path component
            matchedSlash = false;
            end = i + 1;
        }
    }

    return if (end) |_end|
        path[start.._end]
    else
        &.{};
}

/// Based on Node v21.6.1 path.win32.basename:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L753
pub fn basenameWindowsT(comptime T: type, path: []const T, suffix: ?[]const T) []const T {
    comptime validatePathT(T, "basenameWindowsT");

    const len = path.len;
    // Exit early for easier number type use.
    if (len == 0) {
        return &.{};
    }

    const isSepT = isSepWindowsT;

    var start: usize = 0;
    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var end: ?usize = null;
    var matchedSlash: bool = true;

    // Check for a drive letter prefix so as not to mistake the following
    // path separator as an extra separator at the end of the path that can be
    // disregarded
    if (len >= 2 and isWindowsDeviceRootT(T, path[0]) and path[1] == CHAR_COLON) {
        start = 2;
    }

    const _suffix = if (suffix) |_s| _s else &.{};
    const _suffixLen = _suffix.len;
    if (suffix != null and _suffixLen > 0 and _suffixLen <= len) {
        if (std.mem.eql(T, _suffix, path)) {
            return &.{};
        }
        // We use an optional value instead of -1, as in Node code, for easier number type use.
        var extIdx: ?usize = _suffixLen - 1;
        // We use an optional value instead of -1, as in Node code, for easier number type use.
        var firstNonSlashEnd: ?usize = null;
        var i_i64 = @as(i64, @intCast(len - 1));
        while (i_i64 >= start) : (i_i64 -= 1) {
            const i = @as(usize, @intCast(i_i64));
            const byte = path[i];
            if (isSepT(T, byte)) {
                // If we reached a path separator that was not part of a set of path
                // separators at the end of the string, stop now
                if (!matchedSlash) {
                    start = i + 1;
                    break;
                }
            } else {
                if (firstNonSlashEnd == null) {
                    // We saw the first non-path separator, remember this index in case
                    // we need it if the extension ends up not matching
                    matchedSlash = false;
                    firstNonSlashEnd = i + 1;
                }
                if (extIdx) |_extIx| {
                    // Try to match the explicit extension
                    if (byte == _suffix[_extIx]) {
                        if (_extIx == 0) {
                            // We matched the extension, so mark this as the end of our path
                            // component
                            end = i;
                            extIdx = null;
                        } else {
                            extIdx = _extIx - 1;
                        }
                    } else {
                        // Extension does not match, so our result is the entire path
                        // component
                        extIdx = null;
                        end = firstNonSlashEnd;
                    }
                }
            }
        }

        if (end) |_end| {
            if (start == _end) {
                return path[start..firstNonSlashEnd.?];
            } else {
                return path[start.._end];
            }
        }
        return path[start..len];
    }

    var i_i64 = @as(i64, @intCast(len - 1));
    while (i_i64 >= start) : (i_i64 -= 1) {
        const i = @as(usize, @intCast(i_i64));
        const byte = path[i];
        if (isSepT(T, byte)) {
            if (!matchedSlash) {
                start = i + 1;
                break;
            }
        } else if (end == null) {
            matchedSlash = false;
            end = i + 1;
        }
    }

    return if (end) |_end|
        path[start.._end]
    else
        &.{};
}

/// Based on Node v21.6.1 path.posix.dirname:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L1278
pub fn dirnamePosixT(comptime T: type, path: []const T) []const T {
    comptime validatePathT(T, "dirnamePosixT");

    const len = path.len;
    if (len == 0) {
        return comptime L(T, CHAR_STR_DOT);
    }

    const hasRoot = path[0] == CHAR_FORWARD_SLASH;
    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var end: ?usize = null;
    var matchedSlash: bool = true;
    var i: usize = len - 1;
    while (i >= 1) : (i -= 1) {
        if (path[i] == CHAR_FORWARD_SLASH) {
            if (!matchedSlash) {
                end = i;
                break;
            }
        } else {
            // We saw the first non-path separator
            matchedSlash = false;
        }
    }

    if (end) |_end| {
        return if (hasRoot and _end == 1)
            comptime L(T, "//")
        else
            path[0.._end];
    }
    return if (hasRoot)
        comptime L(T, CHAR_STR_FORWARD_SLASH)
    else
        comptime L(T, CHAR_STR_DOT);
}

/// Based on Node v21.6.1 path.win32.dirname:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L657
pub fn dirnameWindowsT(comptime T: type, path: []const T) []const T {
    comptime validatePathT(T, "dirnameWindowsT");

    const len = path.len;
    if (len == 0) {
        return comptime L(T, CHAR_STR_DOT);
    }

    const isSepT = isSepWindowsT;

    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var rootEnd: ?usize = null;
    var offset: usize = 0;
    const byte0 = path[0];

    if (len == 1) {
        // `path` contains just a path separator, exit early to avoid
        // unnecessary work or a dot.
        return if (isSepT(T, byte0)) path else comptime L(T, CHAR_STR_DOT);
    }

    // Try to match a root
    if (isSepT(T, byte0)) {
        // Possible UNC root

        rootEnd = 1;
        offset = 1;

        if (isSepT(T, path[1])) {
            // Matched double path separator at the beginning
            var j: usize = 2;
            var last: usize = j;

            // Match 1 or more non-path separators
            while (j < len and !isSepT(T, path[j])) {
                j += 1;
            }

            if (j < len and j != last) {
                // Matched!
                last = j;

                // Match 1 or more path separators
                while (j < len and isSepT(T, path[j])) {
                    j += 1;
                }

                if (j < len and j != last) {
                    // Matched!
                    last = j;

                    // Match 1 or more non-path separators
                    while (j < len and !isSepT(T, path[j])) {
                        j += 1;
                    }

                    if (j == len) {
                        // We matched a UNC root only
                        return path;
                    }

                    if (j != last) {
                        // We matched a UNC root with leftovers

                        // Offset by 1 to include the separator after the UNC root to
                        // treat it as a "normal root" on top of a (UNC) root
                        offset = j + 1;
                        rootEnd = offset;
                    }
                }
            }
        }
        // Possible device root
    } else if (isWindowsDeviceRootT(T, byte0) and path[1] == CHAR_COLON) {
        offset = if (len > 2 and isSepT(T, path[2])) 3 else 2;
        rootEnd = offset;
    }

    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var end: ?usize = null;
    var matchedSlash: bool = true;

    var i_i64 = @as(i64, @intCast(len - 1));
    while (i_i64 >= offset) : (i_i64 -= 1) {
        const i = @as(usize, @intCast(i_i64));
        if (isSepT(T, path[i])) {
            if (!matchedSlash) {
                end = i;
                break;
            }
        } else {
            // We saw the first non-path separator
            matchedSlash = false;
        }
    }

    if (end) |_end| {
        return path[0.._end];
    }

    return if (rootEnd) |_rootEnd|
        path[0.._rootEnd]
    else
        comptime L(T, CHAR_STR_DOT);
}

/// Based on Node v21.6.1 path.posix.extname:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L1388
pub fn extnamePosixT(comptime T: type, path: []const T) []const T {
    comptime validatePathT(T, "extnamePosixT");

    const len = path.len;
    // Exit early for easier number type use.
    if (len == 0) {
        return &.{};
    }
    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var startDot: ?usize = null;
    var startPart: usize = 0;
    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var end: ?usize = null;
    var matchedSlash: bool = true;
    // Track the state of characters (if any) we see before our first dot and
    // after any path separator we find

    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var preDotState: ?usize = 0;

    var i_i64 = @as(i64, @intCast(len - 1));
    while (i_i64 > -1) : (i_i64 -= 1) {
        const i = @as(usize, @intCast(i_i64));
        const byte = path[i];
        if (byte == CHAR_FORWARD_SLASH) {
            // If we reached a path separator that was not part of a set of path
            // separators at the end of the string, stop now
            if (!matchedSlash) {
                startPart = i + 1;
                break;
            }
            continue;
        }

        if (end == null) {
            // We saw the first non-path separator, mark this as the end of our
            // extension
            matchedSlash = false;
            end = i + 1;
        }

        if (byte == CHAR_DOT) {
            // If this is our first dot, mark it as the start of our extension
            if (startDot == null) {
                startDot = i;
            } else if (preDotState != null and preDotState.? != 1) {
                preDotState = 1;
            }
        } else if (startDot != null) {
            // We saw a non-dot and non-path separator before our dot, so we should
            // have a good chance at having a non-empty extension
            preDotState = null;
        }
    }

    const _end = if (end) |_e| _e else 0;
    const _preDotState = if (preDotState) |_p| _p else 0;
    const _startDot = if (startDot) |_s| _s else 0;
    if (startDot == null or
        end == null or
        // We saw a non-dot character immediately before the dot
        (preDotState != null and _preDotState == 0) or
        // The (right-most) trimmed path component is exactly '..'
        (_preDotState == 1 and
            _startDot == _end - 1 and
            _startDot == startPart + 1))
    {
        return &.{};
    }

    return path[_startDot.._end];
}

/// Based on Node v21.6.1 path.win32.extname:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L840
pub fn extnameWindowsT(comptime T: type, path: []const T) []const T {
    comptime validatePathT(T, "extnameWindowsT");

    const len = path.len;
    // Exit early for easier number type use.
    if (len == 0) {
        return &.{};
    }
    var start: usize = 0;
    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var startDot: ?usize = null;
    var startPart: usize = 0;
    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var end: ?usize = null;
    var matchedSlash: bool = true;
    // Track the state of characters (if any) we see before our first dot and
    // after any path separator we find

    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var preDotState: ?usize = 0;

    // Check for a drive letter prefix so as not to mistake the following
    // path separator as an extra separator at the end of the path that can be
    // disregarded

    if (len >= 2 and
        path[1] == CHAR_COLON and
        isWindowsDeviceRootT(T, path[0]))
    {
        start = 2;
        startPart = start;
    }

    var i_i64 = @as(i64, @intCast(len - 1));
    while (i_i64 >= start) : (i_i64 -= 1) {
        const i = @as(usize, @intCast(i_i64));
        const byte = path[i];
        if (isSepWindowsT(T, byte)) {
            // If we reached a path separator that was not part of a set of path
            // separators at the end of the string, stop now
            if (!matchedSlash) {
                startPart = i + 1;
                break;
            }
            continue;
        }
        if (end == null) {
            // We saw the first non-path separator, mark this as the end of our
            // extension
            matchedSlash = false;
            end = i + 1;
        }
        if (byte == CHAR_DOT) {
            // If this is our first dot, mark it as the start of our extension
            if (startDot == null) {
                startDot = i;
            } else if (preDotState) |_preDotState| {
                if (_preDotState != 1) {
                    preDotState = 1;
                }
            }
        } else if (startDot != null) {
            // We saw a non-dot and non-path separator before our dot, so we should
            // have a good chance at having a non-empty extension
            preDotState = null;
        }
    }

    const _end = if (end) |_e| _e else 0;
    const _preDotState = if (preDotState) |_p| _p else 0;
    const _startDot = if (startDot) |_s| _s else 0;
    if (startDot == null or
        end == null or
        // We saw a non-dot character immediately before the dot
        (preDotState != null and _preDotState == 0) or
        // The (right-most) trimmed path component is exactly '..'
        (_preDotState == 1 and
            _startDot == _end - 1 and
            _startDot == startPart + 1))
    {
        return &.{};
    }

    return path[_startDot.._end];
}

/// Based on Node v21.6.1 path.posix.isAbsolute:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L1159
pub fn isAbsolutePosixT(comptime T: type, path: []const T) bool {
    return path.len > 0 and path[0] == CHAR_FORWARD_SLASH;
}

/// Based on Node v21.6.1 path.win32.isAbsolute:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L406
pub fn isAbsoluteWindowsT(comptime T: type, path: []const T) bool {
    const len = path.len;
    if (len == 0)
        return false;

    const byte0 = path[0];
    return isSepWindowsT(T, byte0) or
        // Possible device root
        (len > 2 and
            isWindowsDeviceRootT(T, byte0) and
            path[1] == CHAR_COLON and
            isSepWindowsT(T, path[2]));
}

fn isSepWindowsT(comptime T: type, byte: T) bool {
    return std.fs.path.PathType.windows.isSep(T, byte);
}

/// Based on Node v21.6.1 private helper isWindowsDeviceRoot:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L60C10-L60C29
pub fn isWindowsDeviceRootT(comptime T: type, byte: T) bool {
    return (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z');
}

/// Based on Node v21.6.1 path.posix.join:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L1169
pub fn joinPosixT(comptime T: type, paths: []const []const T, buf: []T, buf2: []T) []const T {
    comptime validatePathT(T, "joinPosixT");

    if (paths.len == 0) {
        return comptime L(T, CHAR_STR_DOT);
    }

    var bufSize: usize = 0;
    var bufOffset: usize = 0;

    // Back joined by expandable buf2 in case it is long.
    var joined: []const T = &.{};

    for (paths) |path| {
        // Back our virtual "joined" string by expandable buf2 in
        // case it is long.
        const len = path.len;
        if (len > 0) {
            // Translated from the following JS code:
            //   if (joined === undefined)
            //     joined = arg;
            //   else
            //     joined += `/${arg}`;
            if (bufSize != 0) {
                bufOffset = bufSize;
                bufSize += 1;
                buf2[bufOffset] = CHAR_FORWARD_SLASH;
            }
            bufOffset = bufSize;
            bufSize += len;
            bun.copy(T, buf2[bufOffset..bufSize], path);

            joined = buf2[0..bufSize];
        }
    }
    if (bufSize == 0) {
        return comptime L(T, CHAR_STR_DOT);
    }
    return normalizePosixT(T, joined, buf);
}

fn bindNodePathJoinCurrentPlatform(
    _: bun.bindgen.CallContext(NodePathJoinCurrentPlatformSchema),
    args: bun.bindgen.Args(NodePathJoinCurrentPlatformSchema),
) bun.JSError!bun.bindgen.Return(NodePathJoinCurrentPlatformSchema) {
    const lhs = try args.lhs.toUTF8(bun.default_allocator);
    defer lhs.deinit();
    const rhs = try args.rhs.toUTF8(bun.default_allocator);
    defer rhs.deinit();

    const paths = [_][]const u8{ lhs.slice(), rhs.slice() };
    const buffer_len = try joinBufferLength(u8, &paths, Environment.isWindows, 0);

    var first_stack: [4096]u8 = undefined;
    var first_allocator: std.heap.BufferFirstAllocator = .init(&first_stack, bun.default_allocator);
    const first = first_allocator.allocator();
    const buf = try first.alloc(u8, buffer_len);
    defer first.free(buf);

    var second_stack: [4096]u8 = undefined;
    var second_allocator: std.heap.BufferFirstAllocator = .init(&second_stack, bun.default_allocator);
    const second = second_allocator.allocator();
    const buf2 = try second.alloc(u8, buffer_len);
    defer second.free(buf2);

    const joined = if (Environment.isWindows)
        joinWindowsT(u8, &paths, buf, buf2)
    else
        joinPosixT(u8, &paths, buf, buf2);
    return bun.bindgen.DOMString.fromUTF8(joined);
}

/// Based on Node v21.6.1 path.win32.join:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L425
pub fn joinWindowsT(comptime T: type, paths: []const []const T, buf: []T, buf2: []T) []const T {
    comptime validatePathT(T, "joinWindowsT");

    if (paths.len == 0) {
        return comptime L(T, CHAR_STR_DOT);
    }

    const isSepT = isSepWindowsT;

    var bufSize: usize = 0;
    var bufOffset: usize = 0;

    // Backed by expandable buf2 in case it is long.
    var joined: []const T = &.{};
    var firstPart: []const T = &.{};

    for (paths) |path| {
        const len = path.len;
        if (len > 0) {
            // Translated from the following JS code:
            //   if (joined === undefined)
            //     joined = firstPart = arg;
            //   else
            //     joined += `\\${arg}`;
            bufOffset = bufSize;
            if (bufSize == 0) {
                bufSize = len;
                bun.copy(T, buf2[0..bufSize], path);

                joined = buf2[0..bufSize];
                firstPart = joined;
            } else {
                bufOffset = bufSize;
                bufSize += 1;
                buf2[bufOffset] = CHAR_BACKWARD_SLASH;
                bufOffset = bufSize;
                bufSize += len;
                bun.copy(T, buf2[bufOffset..bufSize], path);

                joined = buf2[0..bufSize];
            }
        }
    }
    if (bufSize == 0) {
        return comptime L(T, CHAR_STR_DOT);
    }

    // Make sure that the joined path doesn't start with two slashes, because
    // normalize() will mistake it for a UNC path then.
    //
    // This step is skipped when it is very clear that the user actually
    // intended to point at a UNC path. This is assumed when the first
    // non-empty string arguments starts with exactly two slashes followed by
    // at least one more non-slash character.
    //
    // Note that for normalize() to treat a path as a UNC path it needs to
    // have at least 2 components, so we don't filter for that here.
    // This means that the user can use join to construct UNC paths from
    // a server name and a share name; for example:
    //   path.join('//server', 'share') -> '\\\\server\\share\\')
    var needsReplace: bool = true;
    var slashCount: usize = 0;
    if (isSepT(T, firstPart[0])) {
        slashCount += 1;
        const firstLen = firstPart.len;
        if (firstLen > 1 and
            isSepT(T, firstPart[1]))
        {
            slashCount += 1;
            if (firstLen > 2) {
                if (isSepT(T, firstPart[2])) {
                    slashCount += 1;
                } else {
                    // We matched a UNC path in the first part
                    needsReplace = false;
                }
            }
        }
    }
    if (needsReplace) {
        // Find any more consecutive slashes we need to replace
        while (slashCount < bufSize and
            isSepT(T, joined[slashCount]))
        {
            slashCount += 1;
        }
        // Replace the slashes if needed
        if (slashCount >= 2) {
            // Translated from the following JS code:
            //   joined = `\\${StringPrototypeSlice(joined, slashCount)}`;
            bufOffset = 1;
            bufSize = bufOffset + (bufSize - slashCount);
            // Move all bytes to the right by slashCount - 1.
            // Use bun.copy because joined and buf2 overlap.
            bun.copy(T, buf2[bufOffset..bufSize], joined[slashCount..]);
            // Prepend the separator.
            buf2[0] = CHAR_BACKWARD_SLASH;

            joined = buf2[0..bufSize];
        }
    }
    return normalizeWindowsT(T, joined, buf);
}

fn joinBufferLength(comptime T: type, paths: []const []const T, is_windows: bool, minimum: usize) bun.OOM!usize {
    var len: usize = if (is_windows) 8 else 0;
    for (paths) |path| {
        len = std.math.add(usize, len, path.len) catch return error.OutOfMemory;
        if (path.len > 0) len = std.math.add(usize, len, 1) catch return error.OutOfMemory;
    }
    return @max(len, minimum);
}

/// Based on Node v21.6.1 private helper normalizeString:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L65C1-L66C77
///
/// Resolves . and .. elements in a path with directory names
fn normalizeStringT(comptime T: type, path: []const T, allowAboveRoot: bool, separator: T, comptime platform: bun.path.Platform, buf: []T) [:0]T {
    const len = path.len;
    const path_type = comptime platform.pathType();

    var bufOffset: usize = 0;
    var bufSize: usize = 0;

    var lastSegmentLength: usize = 0;
    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var lastSlash: ?usize = null;
    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var dots: ?usize = 0;
    var byte: T = 0;

    var i: usize = 0;
    while (i <= len) : (i += 1) {
        if (i < len) {
            byte = path[i];
        } else if (path_type.isSep(T, byte)) {
            break;
        } else {
            byte = CHAR_FORWARD_SLASH;
        }

        if (path_type.isSep(T, byte)) {
            // Translated from the following JS code:
            //   if (lastSlash === i - 1 || dots === 1) {
            if ((lastSlash == null and i == 0) or
                (lastSlash != null and i > 0 and lastSlash.? == i - 1) or
                (dots != null and dots.? == 1))
            {
                // NOOP
            } else if (dots != null and dots.? == 2) {
                if (bufSize < 2 or
                    lastSegmentLength != 2 or
                    buf[bufSize - 1] != CHAR_DOT or
                    buf[bufSize - 2] != CHAR_DOT)
                {
                    if (bufSize > 2) {
                        const lastSlashIndex = std.mem.lastIndexOfScalar(T, buf[0..bufSize], separator);
                        if (lastSlashIndex == null) {
                            bufSize = 0;
                            lastSegmentLength = 0;
                        } else {
                            bufSize = lastSlashIndex.?;
                            // Translated from the following JS code:
                            //   lastSegmentLength =
                            //     res.length - 1 - StringPrototypeLastIndexOf(res, separator);
                            const lastIndexOfSep = std.mem.lastIndexOfScalar(T, buf[0..bufSize], separator);
                            if (lastIndexOfSep == null) {
                                // Yes (>ლ), Node relies on the -1 result of
                                // StringPrototypeLastIndexOf(res, separator).
                                // A - -1 is a positive 1.
                                // So the code becomes
                                //   lastSegmentLength = res.length - 1 + 1;
                                // or
                                //   lastSegmentLength = res.length;
                                lastSegmentLength = bufSize;
                            } else {
                                lastSegmentLength = bufSize - 1 - lastIndexOfSep.?;
                            }
                        }
                        lastSlash = i;
                        dots = 0;
                        continue;
                    } else if (bufSize != 0) {
                        bufSize = 0;
                        lastSegmentLength = 0;
                        lastSlash = i;
                        dots = 0;
                        continue;
                    }
                }
                if (allowAboveRoot) {
                    // Translated from the following JS code:
                    //   res += res.length > 0 ? `${separator}..` : '..';
                    if (bufSize > 0) {
                        bufOffset = bufSize;
                        bufSize += 1;
                        buf[bufOffset] = separator;
                        bufOffset = bufSize;
                        bufSize += 2;
                        buf[bufOffset] = CHAR_DOT;
                        buf[bufOffset + 1] = CHAR_DOT;
                    } else {
                        bufSize = 2;
                        buf[0] = CHAR_DOT;
                        buf[1] = CHAR_DOT;
                    }

                    lastSegmentLength = 2;
                }
            } else {
                // Translated from the following JS code:
                //   if (res.length > 0)
                //     res += `${separator}${StringPrototypeSlice(path, lastSlash + 1, i)}`;
                //   else
                //     res = StringPrototypeSlice(path, lastSlash + 1, i);
                if (bufSize > 0) {
                    bufOffset = bufSize;
                    bufSize += 1;
                    buf[bufOffset] = separator;
                }
                const sliceStart = if (lastSlash != null) lastSlash.? + 1 else 0;
                const slice = path[sliceStart..i];

                bufOffset = bufSize;
                bufSize += slice.len;
                bun.copy(T, buf[bufOffset..bufSize], slice);

                // Translated from the following JS code:
                //   lastSegmentLength = i - lastSlash - 1;
                lastSegmentLength = if (lastSlash) |slash| i - slash - 1 else i;
            }
            lastSlash = i;
            dots = 0;
            continue;
        } else if (byte == CHAR_DOT and dots != null) {
            dots = if (dots != null) dots.? + 1 else 0;
            continue;
        } else {
            dots = null;
        }
    }

    buf[bufSize] = 0;
    return buf[0..bufSize :0];
}

/// Based on Node v21.6.1 path.posix.normalize
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L1130
pub fn normalizePosixT(comptime T: type, path: []const T, buf: []T) []const T {
    comptime validatePathT(T, "normalizePosixT");

    const len = path.len;
    if (len == 0) {
        return comptime L(T, CHAR_STR_DOT);
    }

    // Prefix with _ to avoid shadowing the identifier in the outer scope.
    const _isAbsolute = path[0] == CHAR_FORWARD_SLASH;
    const trailingSeparator = path[len - 1] == CHAR_FORWARD_SLASH;

    // Normalize the path
    var normalizedPath = normalizeStringT(T, path, !_isAbsolute, CHAR_FORWARD_SLASH, .posix, buf);

    var bufSize: usize = normalizedPath.len;
    if (bufSize == 0) {
        if (_isAbsolute) {
            return comptime L(T, CHAR_STR_FORWARD_SLASH);
        }
        return if (trailingSeparator)
            comptime L(T, "./")
        else
            comptime L(T, CHAR_STR_DOT);
    }

    var bufOffset: usize = 0;

    // Translated from the following JS code:
    //   if (trailingSeparator)
    //     path += '/';
    if (trailingSeparator) {
        bufOffset = bufSize;
        bufSize += 1;
        buf[bufOffset] = CHAR_FORWARD_SLASH;
        buf[bufSize] = 0;
        normalizedPath = buf[0..bufSize :0];
    }

    // Translated from the following JS code:
    //   return isAbsolute ? `/${path}` : path;
    if (_isAbsolute) {
        bufOffset = 1;
        bufSize += 1;
        // Move all bytes to the right by 1 for the separator.
        // Use bun.copy because normalizedPath and buf overlap.
        bun.copy(T, buf[bufOffset..bufSize], normalizedPath);
        // Prepend the separator.
        buf[0] = CHAR_FORWARD_SLASH;
        buf[bufSize] = 0;
        normalizedPath = buf[0..bufSize :0];
    }
    return normalizedPath;
}

/// Based on Node v21.6.1 path.win32.normalize
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L308
pub fn normalizeWindowsT(comptime T: type, path: []const T, buf: []T) []const T {
    comptime validatePathT(T, "normalizeWindowsT");

    const len = path.len;
    if (len == 0) {
        return comptime L(T, CHAR_STR_DOT);
    }

    const isSepT = isSepWindowsT;

    // Moved `rootEnd`, `device`, and `_isAbsolute` initialization after
    // the `if (len == 1)` check.
    const byte0: T = path[0];

    // Try to match a root
    if (len == 1) {
        // `path` contains just a single char, exit early to avoid
        // unnecessary work
        return if (isSepT(T, byte0)) comptime L(T, CHAR_STR_BACKWARD_SLASH) else path;
    }

    var rootEnd: usize = 0;
    // Backed by buf.
    var device: ?[]const T = null;
    // Prefix with _ to avoid shadowing the identifier in the outer scope.
    var _isAbsolute: bool = false;

    var bufOffset: usize = 0;
    var bufSize: usize = 0;

    if (isSepT(T, byte0)) {
        // Possible UNC root

        // If we started with a separator, we know we at least have an absolute
        // path of some kind (UNC or otherwise)
        _isAbsolute = true;

        if (isSepT(T, path[1])) {
            // Matched double path separator at beginning
            var j: usize = 2;
            var last: usize = j;
            // Match 1 or more non-path separators
            while (j < len and
                !isSepT(T, path[j]))
            {
                j += 1;
            }
            if (j < len and j != last) {
                const firstPart: []const T = path[last..j];
                // Matched!
                last = j;
                // Match 1 or more path separators
                while (j < len and
                    isSepT(T, path[j]))
                {
                    j += 1;
                }
                if (j < len and j != last) {
                    // Matched!
                    last = j;
                    // Match 1 or more non-path separators
                    while (j < len and
                        !isSepT(T, path[j]))
                    {
                        j += 1;
                    }
                    if (j == len) {
                        // We matched a UNC root only
                        // Return the normalized version of the UNC root since there
                        // is nothing left to process

                        // Translated from the following JS code:
                        //   return `\\\\${firstPart}\\${StringPrototypeSlice(path, last)}\\`;
                        bufSize = 2;
                        buf[0] = CHAR_BACKWARD_SLASH;
                        buf[1] = CHAR_BACKWARD_SLASH;
                        bufOffset = bufSize;
                        bufSize += firstPart.len;
                        bun.copy(T, buf[bufOffset..bufSize], firstPart);
                        bufOffset = bufSize;
                        bufSize += 1;
                        buf[bufOffset] = CHAR_BACKWARD_SLASH;
                        bufOffset = bufSize;
                        bufSize += len - last;
                        bun.copy(T, buf[bufOffset..bufSize], path[last..len]);
                        bufOffset = bufSize;
                        bufSize += 1;
                        buf[bufOffset] = CHAR_BACKWARD_SLASH;
                        return buf[0..bufSize];
                    }
                    if (j != last) {
                        // We matched a UNC root with leftovers

                        // Translated from the following JS code:
                        //   device =
                        //     `\\\\${firstPart}\\${StringPrototypeSlice(path, last, j)}`;
                        //   rootEnd = j;
                        bufSize = 2;
                        buf[0] = CHAR_BACKWARD_SLASH;
                        buf[1] = CHAR_BACKWARD_SLASH;
                        bufOffset = bufSize;
                        bufSize += firstPart.len;
                        bun.copy(T, buf[bufOffset..bufSize], firstPart);
                        bufOffset = bufSize;
                        bufSize += 1;
                        buf[bufOffset] = CHAR_BACKWARD_SLASH;
                        bufOffset = bufSize;
                        bufSize += j - last;
                        bun.copy(T, buf[bufOffset..bufSize], path[last..j]);

                        device = buf[0..bufSize];
                        rootEnd = j;
                    }
                }
            }
        } else {
            rootEnd = 1;
        }
    } else if (isWindowsDeviceRootT(T, byte0) and
        path[1] == CHAR_COLON)
    {
        // Possible device root
        buf[0] = byte0;
        buf[1] = CHAR_COLON;
        device = buf[0..2];
        rootEnd = 2;
        if (len > 2 and isSepT(T, path[2])) {
            // Treat separator following drive name as an absolute path
            // indicator
            _isAbsolute = true;
            rootEnd = 3;
        }
    }

    bufOffset = (if (device) |_d| _d.len else 0) + @intFromBool(_isAbsolute);
    // Backed by buf at an offset of  device.len + 1 if _isAbsolute is true.
    var tailLen = if (rootEnd < len) normalizeStringT(T, path[rootEnd..len], !_isAbsolute, CHAR_BACKWARD_SLASH, .windows, buf[bufOffset..]).len else 0;
    if (tailLen == 0 and !_isAbsolute) {
        buf[bufOffset] = CHAR_DOT;
        tailLen = 1;
    }

    if (tailLen > 0 and
        isSepT(T, path[len - 1]))
    {
        // Translated from the following JS code:
        //   tail += '\\';
        buf[bufOffset + tailLen] = CHAR_BACKWARD_SLASH;
        tailLen += 1;
    }

    bufSize = bufOffset + tailLen;
    // Translated from the following JS code:
    //   if (device === undefined) {
    //     return isAbsolute ? `\\${tail}` : tail;
    //   }
    //   return isAbsolute ? `${device}\\${tail}` : `${device}${tail}`;
    if (_isAbsolute) {
        bufOffset -= 1;
        // Prepend the separator.
        buf[bufOffset] = CHAR_BACKWARD_SLASH;
    }
    return buf[0..bufSize];
}

// Based on Node v21.6.1 path.posix.parse
// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L1452
pub fn parsePosixT(comptime T: type, path: []const T) PathParsed(T) {
    comptime validatePathT(T, "parsePosixT");

    const len = path.len;
    if (len == 0) {
        return .{};
    }

    var root: []const T = &.{};
    var dir: []const T = &.{};
    var base: []const T = &.{};
    var ext: []const T = &.{};
    // Prefix with _ to avoid shadowing the identifier in the outer scope.
    var _name: []const T = &.{};
    // Prefix with _ to avoid shadowing the identifier in the outer scope.
    const _isAbsolute = path[0] == CHAR_FORWARD_SLASH;
    var start: usize = 0;
    if (_isAbsolute) {
        root = comptime L(T, CHAR_STR_FORWARD_SLASH);
        start = 1;
    }

    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var startDot: ?usize = null;
    var startPart: usize = 0;
    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var end: ?usize = null;
    var matchedSlash = true;
    var i_i64 = @as(i64, @intCast(len - 1));

    // Track the state of characters (if any) we see before our first dot and
    // after any path separator we find

    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var preDotState: ?usize = 0;

    // Get non-dir info
    while (i_i64 >= start) : (i_i64 -= 1) {
        const i = @as(usize, @intCast(i_i64));
        const byte = path[i];
        if (byte == CHAR_FORWARD_SLASH) {
            // If we reached a path separator that was not part of a set of path
            // separators at the end of the string, stop now
            if (!matchedSlash) {
                startPart = i + 1;
                break;
            }
            continue;
        }
        if (end == null) {
            // We saw the first non-path separator, mark this as the end of our
            // extension
            matchedSlash = false;
            end = i + 1;
        }
        if (byte == CHAR_DOT) {
            // If this is our first dot, mark it as the start of our extension
            if (startDot == null) {
                startDot = i;
            } else if (preDotState) |_preDotState| {
                if (_preDotState != 1) {
                    preDotState = 1;
                }
            }
        } else if (startDot != null) {
            // We saw a non-dot and non-path separator before our dot, so we should
            // have a good chance at having a non-empty extension
            preDotState = null;
        }
    }

    if (end) |_end| {
        const _preDotState = if (preDotState) |_p| _p else 0;
        const _startDot = if (startDot) |_s| _s else 0;
        start = if (startPart == 0 and _isAbsolute) 1 else startPart;
        if (startDot == null or
            // We saw a non-dot character immediately before the dot
            (preDotState != null and _preDotState == 0) or
            // The (right-most) trimmed path component is exactly '..'
            (_preDotState == 1 and
                _startDot == _end - 1 and
                _startDot == startPart + 1))
        {
            _name = path[start.._end];
            base = _name;
        } else {
            _name = path[start.._startDot];
            base = path[start.._end];
            ext = path[_startDot.._end];
        }
    }

    if (startPart > 0) {
        dir = path[0..(startPart - 1)];
    } else if (_isAbsolute) {
        dir = comptime L(T, CHAR_STR_FORWARD_SLASH);
    }

    return .{ .root = root, .dir = dir, .base = base, .ext = ext, .name = _name };
}

// Based on Node v21.6.1 path.win32.parse
// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L916
pub fn parseWindowsT(comptime T: type, path: []const T) PathParsed(T) {
    comptime validatePathT(T, "parseWindowsT");

    var root: []const T = &.{};
    var dir: []const T = &.{};
    var base: []const T = &.{};
    var ext: []const T = &.{};
    // Prefix with _ to avoid shadowing the identifier in the outer scope.
    var _name: []const T = &.{};

    const len = path.len;
    if (len == 0) {
        return .{ .root = root, .dir = dir, .base = base, .ext = ext, .name = _name };
    }

    const isSepT = isSepWindowsT;

    var rootEnd: usize = 0;
    var byte = path[0];

    if (len == 1) {
        if (isSepT(T, byte)) {
            // `path` contains just a path separator, exit early to avoid
            // unnecessary work
            root = path;
            dir = path;
        } else {
            base = path;
            _name = path;
        }
        return .{ .root = root, .dir = dir, .base = base, .ext = ext, .name = _name };
    }

    // Try to match a root
    if (isSepT(T, byte)) {
        // Possible UNC root

        rootEnd = 1;
        if (isSepT(T, path[1])) {
            // Matched double path separator at the beginning
            var j: usize = 2;
            var last: usize = j;
            // Match 1 or more non-path separators
            while (j < len and
                !isSepT(T, path[j]))
            {
                j += 1;
            }
            if (j < len and j != last) {
                // Matched!
                last = j;
                // Match 1 or more path separators
                while (j < len and
                    isSepT(T, path[j]))
                {
                    j += 1;
                }
                if (j < len and j != last) {
                    // Matched!
                    last = j;
                    // Match 1 or more non-path separators
                    while (j < len and
                        !isSepT(T, path[j]))
                    {
                        j += 1;
                    }
                    if (j == len) {
                        // We matched a UNC root only
                        rootEnd = j;
                    } else if (j != last) {
                        // We matched a UNC root with leftovers
                        rootEnd = j + 1;
                    }
                }
            }
        }
    } else if (isWindowsDeviceRootT(T, byte) and
        path[1] == CHAR_COLON)
    {
        // Possible device root
        if (len <= 2) {
            // `path` contains just a drive root, exit early to avoid
            // unnecessary work
            root = path;
            dir = path;
            return .{ .root = root, .dir = dir, .base = base, .ext = ext, .name = _name };
        }
        rootEnd = 2;
        if (isSepT(T, path[2])) {
            if (len == 3) {
                // `path` contains just a drive root, exit early to avoid
                // unnecessary work
                root = path;
                dir = path;
                return .{ .root = root, .dir = dir, .base = base, .ext = ext, .name = _name };
            }
            rootEnd = 3;
        }
    }
    if (rootEnd > 0) {
        root = path[0..rootEnd];
    }

    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var startDot: ?usize = null;
    var startPart = rootEnd;
    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var end: ?usize = null;
    var matchedSlash = true;
    var i_i64 = @as(i64, @intCast(len - 1));

    // Track the state of characters (if any) we see before our first dot and
    // after any path separator we find

    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var preDotState: ?usize = 0;

    // Get non-dir info
    while (i_i64 >= rootEnd) : (i_i64 -= 1) {
        const i = @as(usize, @intCast(i_i64));
        byte = path[i];
        if (isSepT(T, byte)) {
            // If we reached a path separator that was not part of a set of path
            // separators at the end of the string, stop now
            if (!matchedSlash) {
                startPart = i + 1;
                break;
            }
            continue;
        }
        if (end == null) {
            // We saw the first non-path separator, mark this as the end of our
            // extension
            matchedSlash = false;
            end = i + 1;
        }
        if (byte == CHAR_DOT) {
            // If this is our first dot, mark it as the start of our extension
            if (startDot == null) {
                startDot = i;
            } else if (preDotState) |_preDotState| {
                if (_preDotState != 1) {
                    preDotState = 1;
                }
            }
        } else if (startDot != null) {
            // We saw a non-dot and non-path separator before our dot, so we should
            // have a good chance at having a non-empty extension
            preDotState = null;
        }
    }

    if (end) |_end| {
        const _preDotState = if (preDotState) |_p| _p else 0;
        const _startDot = if (startDot) |_s| _s else 0;
        if (startDot == null or
            // We saw a non-dot character immediately before the dot
            (preDotState != null and _preDotState == 0) or
            // The (right-most) trimmed path component is exactly '..'
            (_preDotState == 1 and
                _startDot == _end - 1 and
                _startDot == startPart + 1))
        {
            // Prefix with _ to avoid shadowing the identifier in the outer scope.
            _name = path[startPart.._end];
            base = _name;
        } else {
            _name = path[startPart.._startDot];
            base = path[startPart.._end];
            ext = path[_startDot.._end];
        }
    }

    // If the directory is the root, use the entire root as the `dir` including
    // the trailing slash if any (`C:\abc` -> `C:\`). Otherwise, strip out the
    // trailing slash (`C:\abc\def` -> `C:\abc`).
    if (startPart > 0 and startPart != rootEnd) {
        dir = path[0..(startPart - 1)];
    } else {
        dir = root;
    }

    return .{ .root = root, .dir = dir, .base = base, .ext = ext, .name = _name };
}

/// Based on Node v21.6.1 path.posix.relative:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L1193
pub fn relativePosixT(comptime T: type, from: []const T, to: []const T, buf: []T, buf2: []T, buf3: []T) MaybeSlice(T) {
    comptime validatePathT(T, "relativePosixT");

    if (std.mem.eql(T, from, to)) {
        return MaybeSlice(T){ .result = &.{} };
    }

    // Trim leading forward slashes.
    // Backed by expandable buf2 because fromOrig may be long.
    const fromOrig = switch (resolvePosixT(T, &.{from}, buf2, buf3)) {
        .result => |r| r,
        .err => |e| return MaybeSlice(T){ .err = e },
    };
    const fromOrigLen = fromOrig.len;
    // Backed by buf.
    const toOrig = switch (resolvePosixT(T, &.{to}, buf, buf3)) {
        .result => |r| r,
        .err => |e| return MaybeSlice(T){ .err = e },
    };

    if (std.mem.eql(T, fromOrig, toOrig)) {
        return MaybeSlice(T){ .result = &.{} };
    }

    const fromStart = 1;
    const fromEnd = fromOrigLen;
    const fromLen = fromEnd - fromStart;
    const toOrigLen = toOrig.len;
    var toStart: usize = 1;
    const toLen = toOrigLen - toStart;

    // Compare paths to find the longest common path from root
    const smallestLength = @min(fromLen, toLen);
    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var lastCommonSep: ?usize = null;

    var matchesAllOfSmallest = false;
    // Add a block to isolate `i`.
    {
        var i: usize = 0;
        while (i < smallestLength) : (i += 1) {
            const fromByte = fromOrig[fromStart + i];
            if (fromByte != toOrig[toStart + i]) {
                break;
            } else if (fromByte == CHAR_FORWARD_SLASH) {
                lastCommonSep = i;
            }
        }
        matchesAllOfSmallest = i == smallestLength;
    }
    if (matchesAllOfSmallest) {
        if (toLen > smallestLength) {
            if (toOrig[toStart + smallestLength] == CHAR_FORWARD_SLASH) {
                // We get here if `from` is the exact base path for `to`.
                // For example: from='/foo/bar'; to='/foo/bar/baz'
                return MaybeSlice(T){ .result = toOrig[toStart + smallestLength + 1 .. toOrigLen :0] };
            }
            if (smallestLength == 0) {
                // We get here if `from` is the root
                // For example: from='/'; to='/foo'
                return MaybeSlice(T){ .result = toOrig[toStart + smallestLength .. toOrigLen :0] };
            }
        } else if (fromLen > smallestLength) {
            if (fromOrig[fromStart + smallestLength] == CHAR_FORWARD_SLASH) {
                // We get here if `to` is the exact base path for `from`.
                // For example: from='/foo/bar/baz'; to='/foo/bar'
                lastCommonSep = smallestLength;
            } else if (smallestLength == 0) {
                // We get here if `to` is the root.
                // For example: from='/foo/bar'; to='/'
                lastCommonSep = 0;
            }
        }
    }

    var bufOffset: usize = 0;
    var bufSize: usize = 0;

    // Backed by buf3.
    var out: []const T = &.{};
    // Add a block to isolate `i`.
    {
        // Generate the relative path based on the path difference between `to`
        // and `from`.

        // Translated from the following JS code:
        //  for (i = fromStart + lastCommonSep + 1; i <= fromEnd; ++i) {
        var i: usize = fromStart + (if (lastCommonSep != null) lastCommonSep.? + 1 else 0);
        while (i <= fromEnd) : (i += 1) {
            if (i == fromEnd or fromOrig[i] == CHAR_FORWARD_SLASH) {
                // Translated from the following JS code:
                //   out += out.length === 0 ? '..' : '/..';
                if (out.len > 0) {
                    bufOffset = bufSize;
                    bufSize += 3;
                    buf3[bufOffset] = CHAR_FORWARD_SLASH;
                    buf3[bufOffset + 1] = CHAR_DOT;
                    buf3[bufOffset + 2] = CHAR_DOT;
                } else {
                    bufSize = 2;
                    buf3[0] = CHAR_DOT;
                    buf3[1] = CHAR_DOT;
                }
                out = buf3[0..bufSize];
            }
        }
    }

    // Lastly, append the rest of the destination (`to`) path that comes after
    // the common path parts.

    // Translated from the following JS code:
    //   return `${out}${StringPrototypeSlice(to, toStart + lastCommonSep)}`;
    toStart = if (lastCommonSep != null) toStart + lastCommonSep.? else 0;
    const sliceSize = toOrigLen - toStart;
    const outLen = out.len;
    bufSize = outLen;
    if (sliceSize > 0) {
        bufOffset = bufSize;
        bufSize += sliceSize;
        // Use bun.copy because toOrig and buf overlap.
        bun.copy(T, buf[bufOffset..bufSize], toOrig[toStart..toOrigLen]);
    }
    if (outLen > 0) {
        bun.copy(T, buf[0..outLen], out);
    }
    buf[bufSize] = 0;
    return MaybeSlice(T){ .result = buf[0..bufSize :0] };
}

/// Based on Node v21.6.1 path.win32.relative:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L500
pub fn relativeWindowsT(comptime T: type, from: []const T, to: []const T, buf: []T, buf2: []T, buf3: []T) MaybeSlice(T) {
    comptime validatePathT(T, "relativeWindowsT");

    if (std.mem.eql(T, from, to)) {
        return MaybeSlice(T){ .result = &.{} };
    }

    // Backed by expandable buf2 because fromOrig may be long.
    const fromOrig = switch (resolveWindowsT(T, &.{from}, buf2, buf3)) {
        .result => |r| r,
        .err => |e| return MaybeSlice(T){ .err = e },
    };
    const fromOrigLen = fromOrig.len;
    // Backed by buf.
    const toOrig = switch (resolveWindowsT(T, &.{to}, buf, buf3)) {
        .result => |r| r,
        .err => |e| return MaybeSlice(T){ .err = e },
    };

    if (std.mem.eql(T, fromOrig, toOrig) or
        eqlIgnoreCaseT(T, fromOrig, toOrig))
    {
        return MaybeSlice(T){ .result = &.{} };
    }

    const toOrigLen = toOrig.len;

    // Trim leading backslashes
    var fromStart: usize = 0;
    while (fromStart < fromOrigLen and
        fromOrig[fromStart] == CHAR_BACKWARD_SLASH)
    {
        fromStart += 1;
    }

    // Trim trailing backslashes (applicable to UNC paths only)
    var fromEnd = fromOrigLen;
    while (fromEnd - 1 > fromStart and
        fromOrig[fromEnd - 1] == CHAR_BACKWARD_SLASH)
    {
        fromEnd -= 1;
    }

    const fromLen = fromEnd - fromStart;

    // Trim leading backslashes
    var toStart: usize = 0;
    while (toStart < toOrigLen and
        toOrig[toStart] == CHAR_BACKWARD_SLASH)
    {
        toStart = toStart + 1;
    }

    // Trim trailing backslashes (applicable to UNC paths only)
    var toEnd = toOrigLen;
    while (toEnd - 1 > toStart and
        toOrig[toEnd - 1] == CHAR_BACKWARD_SLASH)
    {
        toEnd -= 1;
    }

    const toLen = toEnd - toStart;

    // Compare paths to find the longest common path from root
    const smallestLength = @min(fromLen, toLen);
    // We use an optional value instead of -1, as in Node code, for easier number type use.
    var lastCommonSep: ?usize = null;

    var matchesAllOfSmallest = false;
    // Add a block to isolate `i`.
    {
        var i: usize = 0;
        while (i < smallestLength) : (i += 1) {
            const fromByte = fromOrig[fromStart + i];
            if (toLowerT(T, fromByte) != toLowerT(T, toOrig[toStart + i])) {
                break;
            } else if (fromByte == CHAR_BACKWARD_SLASH) {
                lastCommonSep = i;
            }
        }
        matchesAllOfSmallest = i == smallestLength;
    }

    // We found a mismatch before the first common path separator was seen, so
    // return the original `to`.
    if (!matchesAllOfSmallest) {
        if (lastCommonSep == null) {
            return MaybeSlice(T){ .result = toOrig };
        }
    } else {
        if (toLen > smallestLength) {
            if (toOrig[toStart + smallestLength] == CHAR_BACKWARD_SLASH) {
                // We get here if `from` is the exact base path for `to`.
                // For example: from='C:\foo\bar'; to='C:\foo\bar\baz'
                return MaybeSlice(T){ .result = toOrig[toStart + smallestLength + 1 .. toOrigLen :0] };
            }
            if (smallestLength == 2) {
                // We get here if `from` is the device root.
                // For example: from='C:\'; to='C:\foo'
                return MaybeSlice(T){ .result = toOrig[toStart + smallestLength .. toOrigLen :0] };
            }
        }
        if (fromLen > smallestLength) {
            if (fromOrig[fromStart + smallestLength] == CHAR_BACKWARD_SLASH) {
                // We get here if `to` is the exact base path for `from`.
                // For example: from='C:\foo\bar'; to='C:\foo'
                lastCommonSep = smallestLength;
            } else if (smallestLength == 2) {
                // We get here if `to` is the device root.
                // For example: from='C:\foo\bar'; to='C:\'
                lastCommonSep = 3;
            }
        }
        if (lastCommonSep == null) {
            lastCommonSep = 0;
        }
    }

    var bufOffset: usize = 0;
    var bufSize: usize = 0;

    // Backed by buf3.
    var out: []const T = &.{};
    // Add a block to isolate `i`.
    {
        // Generate the relative path based on the path difference between `to`
        // and `from`.
        var i: usize = fromStart + (if (lastCommonSep != null) lastCommonSep.? + 1 else 0);
        while (i <= fromEnd) : (i += 1) {
            if (i == fromEnd or fromOrig[i] == CHAR_BACKWARD_SLASH) {
                // Translated from the following JS code:
                //   out += out.length === 0 ? '..' : '\\..';
                if (out.len > 0) {
                    bufOffset = bufSize;
                    bufSize += 3;
                    buf3[bufOffset] = CHAR_BACKWARD_SLASH;
                    buf3[bufOffset + 1] = CHAR_DOT;
                    buf3[bufOffset + 2] = CHAR_DOT;
                } else {
                    bufSize = 2;
                    buf3[0] = CHAR_DOT;
                    buf3[1] = CHAR_DOT;
                }
                out = buf3[0..bufSize];
            }
        }
    }

    // Translated from the following JS code:
    //   toStart += lastCommonSep;
    if (lastCommonSep == null) {
        // If toStart would go negative make it toOrigLen - 1 to
        // mimic String#slice with a negative start.
        toStart = if (toStart > 0) toStart - 1 else toOrigLen - 1;
    } else {
        toStart = @min(toStart + lastCommonSep.?, toEnd);
    }

    // Lastly, append the rest of the destination (`to`) path that comes after
    // the common path parts
    const outLen = out.len;
    if (outLen > 0) {
        const sliceSize = toEnd - toStart;
        bufSize = outLen;
        if (sliceSize > 0) {
            bufOffset = bufSize;
            bufSize += sliceSize;
            // Use bun.copy because toOrig and buf overlap.
            bun.copy(T, buf[bufOffset..bufSize], toOrig[toStart..toEnd]);
        }
        bun.copy(T, buf[0..outLen], out);
        buf[bufSize] = 0;
        return MaybeSlice(T){ .result = buf[0..bufSize :0] };
    }

    if (toStart == toEnd) {
        return MaybeSlice(T){ .result = toOrig[toEnd..toEnd :0] };
    }
    if (toOrig[toStart] == CHAR_BACKWARD_SLASH) {
        toStart += 1;
    }
    return MaybeSlice(T){ .result = toOrig[toStart..toEnd :0] };
}

/// Based on Node v21.6.1 path.posix.resolve:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L1095
pub fn resolvePosixT(comptime T: type, paths: []const []const T, buf: []T, buf2: []T) MaybeSlice(T) {
    comptime validatePathT(T, "resolvePosixT");

    // Backed by expandable buf2 because resolvedPath may be long.
    // We use buf2 here because resolvePosixT is called by other methods and using
    // buf2 here avoids stepping on others' toes.
    var resolvedPath: [:0]const T = undefined;
    resolvedPath.len = 0;
    var resolvedPathLen: usize = 0;
    var resolvedAbsolute: bool = false;

    var bufOffset: usize = 0;
    var bufSize: usize = 0;

    var i_i64: i64 = if (paths.len == 0) -1 else @as(i64, @intCast(paths.len - 1));
    while (i_i64 > -2 and !resolvedAbsolute) : (i_i64 -= 1) {
        var path: []const T = &.{};
        if (i_i64 >= 0) {
            path = paths[@as(usize, @intCast(i_i64))];
        } else {
            // cwd is limited to MAX_PATH_BYTES.
            var tmpBuf: [MAX_PATH_SIZE(T)]T = undefined;
            path = switch (posixCwdT(T, &tmpBuf)) {
                .result => |r| r,
                .err => |e| return MaybeSlice(T){ .err = e },
            };
        }
        const len = path.len;

        // Skip empty paths.
        if (len == 0) {
            continue;
        }

        // Translated from the following JS code:
        //   resolvedPath = `${path}/${resolvedPath}`;
        if (resolvedPathLen > 0) {
            bufOffset = len + 1;
            bufSize = bufOffset + resolvedPathLen;
            // Move all bytes to the right by path.len + 1 for the separator.
            // Use bun.copy because resolvedPath and buf2 overlap.
            bun.copy(T, buf2[bufOffset..bufSize], resolvedPath);
        }
        bufSize = len;
        bun.copy(T, buf2[0..bufSize], path);
        bufSize += 1;
        buf2[len] = CHAR_FORWARD_SLASH;
        bufSize += resolvedPathLen;

        buf2[bufSize] = 0;
        resolvedPath = buf2[0..bufSize :0];
        resolvedPathLen = bufSize;
        resolvedAbsolute = path[0] == CHAR_FORWARD_SLASH;
    }

    // Exit early for empty path.
    if (resolvedPathLen == 0) {
        return MaybeSlice(T){ .result = comptime L(T, CHAR_STR_DOT) };
    }

    // At this point the path should be resolved to a full absolute path, but
    // handle relative paths to be safe (might happen when process.cwd() fails)

    // Normalize the path
    resolvedPath = normalizeStringT(T, resolvedPath, !resolvedAbsolute, CHAR_FORWARD_SLASH, .posix, buf);
    // resolvedPath is now backed by buf.
    resolvedPathLen = resolvedPath.len;

    // Translated from the following JS code:
    //   if (resolvedAbsolute) {
    //     return `/${resolvedPath}`;
    //   }
    if (resolvedAbsolute) {
        bufSize = resolvedPathLen + 1;
        // Use bun.copy because resolvedPath and buf overlap.
        bun.copy(T, buf[1..bufSize], resolvedPath);
        buf[0] = CHAR_FORWARD_SLASH;
        buf[bufSize] = 0;
        return MaybeSlice(T){ .result = buf[0..bufSize :0] };
    }
    // Translated from the following JS code:
    //   return resolvedPath.length > 0 ? resolvedPath : '.';
    return MaybeSlice(T){ .result = if (resolvedPathLen > 0) resolvedPath else comptime L(T, CHAR_STR_DOT) };
}

/// Based on Node v21.6.1 path.win32.resolve:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L162
pub fn resolveWindowsT(comptime T: type, paths: []const []const T, buf: []T, buf2: []T) MaybeSlice(T) {
    comptime validatePathT(T, "resolveWindowsT");

    const isSepT = isSepWindowsT;
    var tmpBuf: [MAX_PATH_SIZE(T):0]T = undefined;

    // Backed by tmpBuf.
    var resolvedDevice: []const T = &.{};
    var resolvedDeviceLen: usize = 0;
    // Backed by expandable buf2 because resolvedTail may be long.
    // We use buf2 here because resolvePosixT is called by other methods and using
    // buf2 here avoids stepping on others' toes.
    var resolvedTail: []const T = &.{};
    var resolvedTailLen: usize = 0;
    var resolvedAbsolute: bool = false;

    var bufOffset: usize = 0;
    var bufSize: usize = 0;
    var envPath: ?[]const T = null;

    var i_i64: i64 = if (paths.len == 0) -1 else @as(i64, @intCast(paths.len - 1));
    while (i_i64 > -2) : (i_i64 -= 1) {
        // Backed by expandable buf2, to not conflict with buf2 backed resolvedTail,
        // because path may be long.
        var path: []const T = &.{};
        if (i_i64 >= 0) {
            path = paths[@as(usize, @intCast(i_i64))];

            // Skip empty paths.
            if (path.len == 0) {
                continue;
            }
        } else if (resolvedDeviceLen == 0) {
            // cwd is limited to MAX_PATH_BYTES.
            path = switch (getCwdT(T, &tmpBuf)) {
                .result => |r| r,
                .err => |e| return MaybeSlice(T){ .err = e },
            };
        } else {
            // Translated from the following JS code:
            //   path = process.env[`=${resolvedDevice}`] || process.cwd();
            if (comptime Environment.isWindows) {
                var u16Buf: bun.WPathBuffer = undefined;
                // Windows has the concept of drive-specific current working
                // directories. If we've resolved a drive letter but not yet an
                // absolute path, get cwd for that drive, or the process cwd if
                // the drive cwd is not available. We're sure the device is not
                // a UNC path at this points, because UNC paths are always absolute.

                // Translated from the following JS code:
                //   process.env[`=${resolvedDevice}`]
                const key_w: [*:0]const u16 = brk: {
                    if (resolvedDeviceLen == 2 and resolvedDevice[1] == CHAR_COLON) {
                        // Fast path for device roots
                        break :brk &[3:0]u16{ '=', resolvedDevice[0], CHAR_COLON };
                    }
                    bufSize = 1;
                    // Reuse buf2 for the env key because it's used to get the path.
                    buf2[0] = '=';
                    bufOffset = bufSize;
                    bufSize += resolvedDeviceLen;
                    bun.copy(T, buf2[bufOffset..bufSize], resolvedDevice);
                    if (T == u16) {
                        buf2[bufSize] = 0;
                        break :brk buf2[0..bufSize :0];
                    } else {
                        bufSize = std.unicode.wtf8ToWtf16Le(&u16Buf, buf2[0..bufSize]) catch unreachable;
                        u16Buf[bufSize] = 0;
                        break :brk u16Buf[0..bufSize :0];
                    }
                };
                // Zig's std.posix.getenvW has logic to support keys like `=${resolvedDevice}`:
                // https://github.com/ziglang/zig/blob/7bd8b35a3dfe61e59ffea39d464e84fbcdead29a/lib/std/os.zig#L2126-L2130
                //
                // TODO: Enable test once spawnResult.stdout works on Windows.
                // test/js/node/path/resolve.test.js
                var value_w: bun.WPathBuffer = undefined;
                if (bun.windows.GetEnvironmentVariableW(@constCast(key_w), &value_w, @intCast(value_w.len))) |value_len| {
                    const r = value_w[0..@intCast(value_len)];
                    if (T == u16) {
                        bufSize = r.len;
                        bun.copy(T, buf2[0..bufSize], r);
                    } else {
                        // Reuse buf2 because it's used for path.
                        bufSize = std.unicode.wtf16LeToWtf8(buf2, r);
                    }
                    envPath = buf2[0..bufSize];
                } else |_| {}
            }
            if (envPath) |_envPath| {
                path = _envPath;
            } else {
                // cwd is limited to MAX_PATH_BYTES.
                path = switch (getCwdT(T, &tmpBuf)) {
                    .result => |r| r,
                    .err => |e| return MaybeSlice(T){ .err = e },
                };
                // We must set envPath here so that it doesn't hit the null check just below.
                envPath = path;
            }

            // Verify that a cwd was found and that it actually points
            // to our drive. If not, default to the drive's root.

            // Translated from the following JS code:
            //   if (path === undefined ||
            //     (StringPrototypeToLowerCase(StringPrototypeSlice(path, 0, 2)) !==
            //     StringPrototypeToLowerCase(resolvedDevice) &&
            //     StringPrototypeCharCodeAt(path, 2) === CHAR_BACKWARD_SLASH)) {
            if (envPath == null or
                (path[2] == CHAR_BACKWARD_SLASH and
                    !eqlIgnoreCaseT(T, path[0..2], resolvedDevice)))
            {
                // Translated from the following JS code:
                //   path = `${resolvedDevice}\\`;
                bufSize = resolvedDeviceLen;
                bun.copy(T, buf2[0..bufSize], resolvedDevice);
                bufOffset = bufSize;
                bufSize += 1;
                buf2[bufOffset] = CHAR_BACKWARD_SLASH;
                path = buf2[0..bufSize];
            }
        }

        const len = path.len;
        var rootEnd: usize = 0;
        // Backed by tmpBuf or an anonymous buffer.
        var device: []const T = &.{};
        // Prefix with _ to avoid shadowing the identifier in the outer scope.
        var _isAbsolute: bool = false;
        const byte0 = if (len > 0) path[0] else 0;

        // Try to match a root
        if (len == 1) {
            if (isSepT(T, byte0)) {
                // `path` contains just a path separator
                rootEnd = 1;
                _isAbsolute = true;
            }
        } else if (isSepT(T, byte0)) {
            // Possible UNC root

            // If we started with a separator, we know we at least have an
            // absolute path of some kind (UNC or otherwise)
            _isAbsolute = true;

            if (isSepT(T, path[1])) {
                // Matched double path separator at the beginning
                var j: usize = 2;
                var last: usize = j;
                // Match 1 or more non-path separators
                while (j < len and
                    !isSepT(T, path[j]))
                {
                    j += 1;
                }
                if (j < len and j != last) {
                    const firstPart = path[last..j];
                    // Matched!
                    last = j;
                    // Match 1 or more path separators
                    while (j < len and
                        isSepT(T, path[j]))
                    {
                        j += 1;
                    }
                    if (j < len and j != last) {
                        // Matched!
                        last = j;
                        // Match 1 or more non-path separators
                        while (j < len and
                            !isSepT(T, path[j]))
                        {
                            j += 1;
                        }
                        if (j == len or j != last) {
                            // We matched a UNC root

                            if (resolvedDeviceLen > 0) {
                                // resolvedDevice is already set to a drive
                                // letter (`X:`). A UNC device can never match
                                // it, and building the UNC string below would
                                // overwrite tmpBuf which backs resolvedDevice.
                                continue;
                            }

                            // Translated from the following JS code:
                            //   device =
                            //     `\\\\${firstPart}\\${StringPrototypeSlice(path, last, j)}`;
                            //   rootEnd = j;
                            bufSize = 2;
                            tmpBuf[0] = CHAR_BACKWARD_SLASH;
                            tmpBuf[1] = CHAR_BACKWARD_SLASH;
                            bufOffset = bufSize;
                            bufSize += firstPart.len;
                            bun.copy(T, tmpBuf[bufOffset..bufSize], firstPart);
                            bufOffset = bufSize;
                            bufSize += 1;
                            tmpBuf[bufOffset] = CHAR_BACKWARD_SLASH;
                            const slice = path[last..j];
                            bufOffset = bufSize;
                            bufSize += slice.len;
                            bun.copy(T, tmpBuf[bufOffset..bufSize], slice);

                            device = tmpBuf[0..bufSize];
                            rootEnd = j;
                        }
                    }
                }
            } else {
                rootEnd = 1;
            }
        } else if (isWindowsDeviceRootT(T, byte0) and
            path[1] == CHAR_COLON)
        {
            // Possible device root
            device = &[2]T{ byte0, CHAR_COLON };
            rootEnd = 2;
            if (len > 2 and isSepT(T, path[2])) {
                // Treat separator following the drive name as an absolute path
                // indicator
                _isAbsolute = true;
                rootEnd = 3;
            }
        }

        const deviceLen = device.len;
        if (deviceLen > 0) {
            if (resolvedDeviceLen > 0) {
                // Translated from the following JS code:
                //   if (StringPrototypeToLowerCase(device) !==
                //     StringPrototypeToLowerCase(resolvedDevice))
                if (!eqlIgnoreCaseT(T, device, resolvedDevice)) {
                    // This path points to another device, so it is not applicable
                    continue;
                }
            } else {
                // Translated from the following JS code:
                //   resolvedDevice = device;
                bufSize = device.len;
                // Copy device over if it's backed by an anonymous buffer.
                if (device.ptr != tmpBuf[0..].ptr) {
                    bun.copy(T, tmpBuf[0..bufSize], device);
                }
                resolvedDevice = tmpBuf[0..bufSize];
                resolvedDeviceLen = bufSize;
            }
        }

        if (resolvedAbsolute) {
            if (resolvedDeviceLen > 0) {
                break;
            }
        } else {
            // Translated from the following JS code:
            //   resolvedTail = `${StringPrototypeSlice(path, rootEnd)}\\${resolvedTail}`;
            const sliceLen = len - rootEnd;
            if (resolvedTailLen > 0) {
                bufOffset = sliceLen + 1;
                bufSize = bufOffset + resolvedTailLen;
                // Move all bytes to the right by path slice.len + 1 for the separator
                // Use bun.copy because resolvedTail and buf2 overlap.
                bun.copy(T, buf2[bufOffset..bufSize], resolvedTail);
            }
            bufSize = sliceLen;
            if (sliceLen > 0) {
                bun.copy(T, buf2[0..bufSize], path[rootEnd..len]);
            }
            bufOffset = bufSize;
            bufSize += 1;
            buf2[bufOffset] = CHAR_BACKWARD_SLASH;
            bufSize += resolvedTailLen;

            resolvedTail = buf2[0..bufSize];
            resolvedTailLen = bufSize;
            resolvedAbsolute = _isAbsolute;

            if (_isAbsolute and resolvedDeviceLen > 0) {
                break;
            }
        }
    }

    // Exit early for empty path.
    if (resolvedTailLen == 0) {
        return MaybeSlice(T){ .result = comptime L(T, CHAR_STR_DOT) };
    }

    // At this point, the path should be resolved to a full absolute path,
    // but handle relative paths to be safe (might happen when std.process.cwdAlloc()
    // fails)

    // Normalize the tail path
    resolvedTail = normalizeStringT(T, resolvedTail, !resolvedAbsolute, CHAR_BACKWARD_SLASH, .windows, buf);
    // resolvedTail is now backed by buf.
    resolvedTailLen = resolvedTail.len;

    // Translated from the following JS code:
    //   resolvedAbsolute ? `${resolvedDevice}\\${resolvedTail}`
    if (resolvedAbsolute) {
        bufOffset = resolvedDeviceLen + 1;
        bufSize = bufOffset + resolvedTailLen;
        // Use bun.copy because resolvedTail and buf overlap.
        bun.copy(T, buf[bufOffset..bufSize], resolvedTail);
        buf[resolvedDeviceLen] = CHAR_BACKWARD_SLASH;
        bun.copy(T, buf[0..resolvedDeviceLen], resolvedDevice);
        buf[bufSize] = 0;
        return MaybeSlice(T){ .result = buf[0..bufSize :0] };
    }
    // Translated from the following JS code:
    //   : `${resolvedDevice}${resolvedTail}` || '.'
    if ((resolvedDeviceLen + resolvedTailLen) > 0) {
        bufOffset = resolvedDeviceLen;
        bufSize = bufOffset + resolvedTailLen;
        // Use bun.copy because resolvedTail and buf overlap.
        bun.copy(T, buf[bufOffset..bufSize], resolvedTail);
        bun.copy(T, buf[0..resolvedDeviceLen], resolvedDevice);
        buf[bufSize] = 0;
        return MaybeSlice(T){ .result = buf[0..bufSize :0] };
    }
    return MaybeSlice(T){ .result = comptime L(T, CHAR_STR_DOT) };
}

/// Based on Node v21.6.1 path.win32.toNamespacedPath:
/// https://github.com/nodejs/node/blob/6ae20aa63de78294b18d5015481485b7cd8fbb60/lib/path.js#L622
pub fn toNamespacedPathWindowsT(comptime T: type, path: []const T, buf: []T, buf2: []T) MaybeSlice(T) {
    comptime validatePathT(T, "toNamespacedPathWindowsT");

    // Backed by buf.
    const resolvedPath = switch (resolveWindowsT(T, &.{path}, buf, buf2)) {
        .result => |r| r,
        .err => |e| return MaybeSlice(T){ .err = e },
    };

    const len = resolvedPath.len;
    if (len <= 2) {
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        return MaybeSlice(T){ .result = buf[0..path.len :0] };
    }

    var bufOffset: usize = 0;
    var bufSize: usize = 0;

    const byte0 = resolvedPath[0];
    if (byte0 == CHAR_BACKWARD_SLASH) {
        // Possible UNC root
        if (resolvedPath[1] == CHAR_BACKWARD_SLASH) {
            const byte2 = resolvedPath[2];
            if (byte2 != CHAR_QUESTION_MARK and byte2 != CHAR_DOT) {
                // Matched non-long UNC root, convert the path to a long UNC path

                // Translated from the following JS code:
                //   return `\\\\?\\UNC\\${StringPrototypeSlice(resolvedPath, 2)}`;
                bufOffset = 6;
                bufSize = len + 6;
                // Move all bytes to the right by 6 so that the first two bytes are
                // overwritten by "\\\\?\\UNC\\" which is 8 bytes long.
                // Use bun.copy because resolvedPath and buf overlap.
                bun.copy(T, buf[bufOffset..bufSize], resolvedPath);
                // Equiv to std.os.windows.NamespacePrefix.verbatim
                // https://github.com/ziglang/zig/blob/dcaf43674e35372e1d28ab12c4c4ff9af9f3d646/lib/std/os/windows.zig#L2358-L2374
                buf[0] = CHAR_BACKWARD_SLASH;
                buf[1] = CHAR_BACKWARD_SLASH;
                buf[2] = CHAR_QUESTION_MARK;
                buf[3] = CHAR_BACKWARD_SLASH;
                buf[4] = 'U';
                buf[5] = 'N';
                buf[6] = 'C';
                buf[7] = CHAR_BACKWARD_SLASH;
                buf[bufSize] = 0;
                return MaybeSlice(T){ .result = buf[0..bufSize :0] };
            }
        }
    } else if (isWindowsDeviceRootT(T, byte0) and
        resolvedPath[1] == CHAR_COLON and
        resolvedPath[2] == CHAR_BACKWARD_SLASH)
    {
        // Matched device root, convert the path to a long UNC path

        // Translated from the following JS code:
        //   return `\\\\?\\${resolvedPath}`
        bufOffset = 4;
        bufSize = len + 4;
        // Move all bytes to the right by 4
        // Use bun.copy because resolvedPath and buf overlap.
        bun.copy(T, buf[bufOffset..bufSize], resolvedPath);
        // Equiv to std.os.windows.NamespacePrefix.verbatim
        // https://github.com/ziglang/zig/blob/dcaf43674e35372e1d28ab12c4c4ff9af9f3d646/lib/std/os/windows.zig#L2358-L2374
        buf[0] = CHAR_BACKWARD_SLASH;
        buf[1] = CHAR_BACKWARD_SLASH;
        buf[2] = CHAR_QUESTION_MARK;
        buf[3] = CHAR_BACKWARD_SLASH;
        buf[bufSize] = 0;
        return MaybeSlice(T){ .result = buf[0..bufSize :0] };
    }
    return MaybeSlice(T){ .result = resolvedPath };
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const Syscall = bun.sys;
const windows = bun.windows;
const typeBaseNameT = bun.meta.typeBaseNameT;

const strings = bun.strings;
const L = strings.literal;

fn dirnameBound(comptime is_windows: bool, path: anytype) bun.OOM!bun.bindgen.DOMString {
    return switch (path.unsafePtr("the generated entry frame owns the path string until dirname copies its result")) {
        .latin1 => |value| domStringFromCodeUnits(u8, if (is_windows) dirnameWindowsT(u8, value) else dirnamePosixT(u8, value)),
        .utf16 => |value| domStringFromCodeUnits(u16, if (is_windows) dirnameWindowsT(u16, value) else dirnamePosixT(u16, value)),
    };
}

fn extnameBound(comptime is_windows: bool, path: bun.bindgen.DOMStringView) bun.OOM!bun.bindgen.DOMString {
    return switch (path.unsafePtr("the generated entry frame owns the path string until extname copies its result")) {
        .latin1 => |value| domStringFromCodeUnits(u8, if (is_windows) extnameWindowsT(u8, value) else extnamePosixT(u8, value)),
        .utf16 => |value| domStringFromCodeUnits(u16, if (is_windows) extnameWindowsT(u16, value) else extnamePosixT(u16, value)),
    };
}

fn isAbsoluteBound(comptime is_windows: bool, path: bun.bindgen.DOMStringView) bool {
    return switch (path.unsafePtr("the generated entry frame owns the path string until isAbsolute finishes inspecting it")) {
        .latin1 => |value| if (is_windows) isAbsoluteWindowsT(u8, value) else isAbsolutePosixT(u8, value),
        .utf16 => |value| if (is_windows) isAbsoluteWindowsT(u16, value) else isAbsolutePosixT(u16, value),
    };
}

fn basenameBound(
    comptime is_windows: bool,
    path: bun.bindgen.DOMStringView,
    suffix: ?bun.bindgen.DOMStringView,
) bun.OOM!bun.bindgen.DOMString {
    var arena = bun.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path_units = path.unsafePtr("the generated entry frame owns the path string until basename copies its result");
    const suffix_units = if (suffix) |value|
        value.unsafePtr("the generated entry frame owns the suffix string until basename finishes comparing it")
    else
        null;
    if (hasUTF16(path_units) or (suffix_units != null and hasUTF16(suffix_units.?))) {
        return basenameCodeUnits(u16, is_windows, allocator, path_units, suffix_units);
    }
    return basenameCodeUnits(u8, is_windows, allocator, path_units, suffix_units);
}

fn basenameCodeUnits(
    comptime T: type,
    comptime is_windows: bool,
    allocator: std.mem.Allocator,
    path: bun.bindgen.UnsafeStringCodeUnits,
    suffix: ?bun.bindgen.UnsafeStringCodeUnits,
) bun.OOM!bun.bindgen.DOMString {
    const path_units = try codeUnitsAs(T, allocator, path);
    const suffix_units = if (suffix) |value| try codeUnitsAs(T, allocator, value) else null;
    const result = if (is_windows)
        basenameWindowsT(T, path_units, suffix_units)
    else
        basenamePosixT(T, path_units, suffix_units);
    return domStringFromCodeUnits(T, result);
}

fn normalizeCodeUnits(
    comptime T: type,
    comptime is_windows: bool,
    path: []const T,
) bun.OOM!bun.bindgen.DOMString {
    var stack_buffer: [stack_fallback_size_small]u8 = undefined;
    var stack_allocator: std.heap.BufferFirstAllocator = .init(&stack_buffer, bun.default_allocator);
    const allocator = stack_allocator.allocator();
    const buffer = try allocator.alloc(T, @max(path.len, PATH_SIZE(T)) + 1);
    defer allocator.free(buffer);
    const result = if (is_windows)
        normalizeWindowsT(T, path, buffer)
    else
        normalizePosixT(T, path, buffer);
    return domStringFromCodeUnits(T, result);
}

fn normalizeBound(comptime is_windows: bool, path: bun.bindgen.DOMStringView) bun.OOM!bun.bindgen.DOMString {
    return switch (path.unsafePtr("the generated entry frame owns the path string until normalize copies its result")) {
        .latin1 => |value| normalizeCodeUnits(u8, is_windows, value),
        .utf16 => |value| normalizeCodeUnits(u16, is_windows, value),
    };
}

fn parseBound(
    comptime Schema: type,
    comptime is_windows: bool,
    path: bun.bindgen.DOMStringView,
) bun.OOM!bun.bindgen.Return(Schema) {
    return switch (path.unsafePtr("the generated entry frame owns the path string until parse copies every result component")) {
        .latin1 => |input| (if (is_windows) parseWindowsT(u8, input) else parsePosixT(u8, input)).toBindingResult(Schema),
        .utf16 => |input| (if (is_windows) parseWindowsT(u16, input) else parsePosixT(u16, input)).toBindingResult(Schema),
    };
}

fn joinBound(comptime is_windows: bool, paths: anytype) bun.OOM!bun.bindgen.DOMString {
    if (paths.len() == 0) return bun.bindgen.DOMString.fromLatin1(CHAR_STR_DOT);

    var arena = bun.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const values = try allocator.alloc(bun.bindgen.UnsafeStringCodeUnits, paths.len());
    var use_utf16 = false;
    for (values, 0..) |*value, index| {
        value.* = paths.at(index).?.unsafePtr("the generated entry frame owns the rest-argument strings until join copies the combined path");
        use_utf16 = use_utf16 or hasUTF16(value.*);
    }

    return if (use_utf16)
        joinCodeUnits(u16, is_windows, allocator, values)
    else
        joinCodeUnits(u8, is_windows, allocator, values);
}

fn joinCodeUnits(
    comptime T: type,
    comptime is_windows: bool,
    allocator: std.mem.Allocator,
    values: []const bun.bindgen.UnsafeStringCodeUnits,
) bun.OOM!bun.bindgen.DOMString {
    const slices = try allocator.alloc([]const T, values.len);
    for (slices, values) |*slice, value| slice.* = try codeUnitsAs(T, allocator, value);
    const buffer_len = try joinBufferLength(T, slices, is_windows, PATH_SIZE(T));
    const buffer = try allocator.alloc(T, buffer_len);
    const second_buffer = try allocator.alloc(T, buffer_len);
    const result = if (is_windows)
        joinWindowsT(T, slices, buffer, second_buffer)
    else
        joinPosixT(T, slices, buffer, second_buffer);
    return domStringFromCodeUnits(T, result);
}

fn relativeBound(
    context: anytype,
    comptime is_windows: bool,
    from: bun.bindgen.DOMStringView,
    to: bun.bindgen.DOMStringView,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.DOMString {
    var arena = bun.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const from_slice = try codeUnitsAs(
        u16,
        allocator,
        from.unsafePtr("the generated entry frame owns the source path until relative copies its result"),
    );
    const to_slice = try codeUnitsAs(
        u16,
        allocator,
        to.unsafePtr("the generated entry frame owns the destination path until relative copies its result"),
    );
    const buffer_len = @max((from_slice.len + MAX_PATH_SIZE(u16) + 1) * 2 + to_slice.len + MAX_PATH_SIZE(u16) + 1, PATH_SIZE(u16));
    const buffer = try allocator.alloc(u16, buffer_len + 1);
    const second_buffer = try allocator.alloc(u16, buffer_len + 1);
    const third_buffer = try allocator.alloc(u16, buffer_len + 1);
    const result = if (is_windows)
        relativeWindowsT(u16, from_slice, to_slice, buffer, second_buffer, third_buffer)
    else
        relativePosixT(u16, from_slice, to_slice, buffer, second_buffer, third_buffer);
    return switch (result) {
        .result => |value| bun.bindgen.DOMString.fromUTF16(value),
        .err => |err| context.fail(.system, try bun.bindgen.SystemError.fromSysError(err)),
    };
}

const WindowsResolveRoot = struct {
    device: []const u16 = &.{},
    is_absolute: bool = false,
};

fn windowsResolveRoot(allocator: std.mem.Allocator, path: []const u16) bun.OOM!WindowsResolveRoot {
    if (path.len == 0) return .{};
    if (!isSepWindowsT(u16, path[0])) {
        if (path.len >= 2 and isWindowsDeviceRootT(u16, path[0]) and path[1] == CHAR_COLON) {
            return .{
                .device = path[0..2],
                .is_absolute = path.len > 2 and isSepWindowsT(u16, path[2]),
            };
        }
        return .{};
    }

    if (path.len < 2 or !isSepWindowsT(u16, path[1])) {
        return .{ .is_absolute = true };
    }

    var server_end: usize = 2;
    while (server_end < path.len and !isSepWindowsT(u16, path[server_end])) : (server_end += 1) {}
    if (server_end == 2 or server_end == path.len) return .{ .is_absolute = true };

    var share_start = server_end;
    while (share_start < path.len and isSepWindowsT(u16, path[share_start])) : (share_start += 1) {}
    if (share_start == path.len) return .{ .is_absolute = true };

    var share_end = share_start;
    while (share_end < path.len and !isSepWindowsT(u16, path[share_end])) : (share_end += 1) {}
    if (share_end == share_start) return .{ .is_absolute = true };

    const device = try allocator.alloc(u16, 3 + (server_end - 2) + (share_end - share_start));
    device[0] = CHAR_BACKWARD_SLASH;
    device[1] = CHAR_BACKWARD_SLASH;
    @memcpy(device[2..server_end], path[2..server_end]);
    device[server_end] = CHAR_BACKWARD_SLASH;
    @memcpy(device[server_end + 1 ..], path[share_start..share_end]);
    return .{ .device = device, .is_absolute = true };
}

fn resolveBound(
    context: anytype,
    comptime is_windows: bool,
    paths: anytype,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.DOMString {
    var arena = bun.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path_buffer = try allocator.alloc([]const u16, paths.len());
    var path_offset = paths.len();
    var resolved_absolute = false;
    var resolved_device: []const u16 = &.{};
    var can_stop = false;

    var index = paths.len();
    while (index > 0) {
        index -= 1;
        if (can_stop) break;

        const converted = try paths.convert(index, context);
        const path = try cloneCodeUnitsAs(
            u16,
            allocator,
            converted.value.unsafePtr("the binding frame owns the converted string while resolve copies its code units"),
        );
        if (path.len == 0) continue;

        if (!is_windows) {
            path_offset -= 1;
            path_buffer[path_offset] = path;
            can_stop = path[0] == CHAR_FORWARD_SLASH;
            continue;
        }

        const root = try windowsResolveRoot(allocator, path);
        if (root.device.len > 0) {
            if (resolved_device.len > 0) {
                if (!eqlIgnoreCaseT(u16, root.device, resolved_device)) continue;
            } else {
                resolved_device = root.device;
            }
        }
        path_offset -= 1;
        path_buffer[path_offset] = path;
        resolved_absolute = resolved_absolute or root.is_absolute;
        can_stop = resolved_absolute and resolved_device.len > 0;
    }

    const selected_paths = path_buffer[path_offset..];
    var buffer_len: usize = if (is_windows) 8 else 0;
    for (selected_paths) |path| {
        buffer_len = std.math.add(usize, buffer_len, path.len) catch return error.OutOfMemory;
        if (buffer_len > 0 and path.len > 0) {
            buffer_len = std.math.add(usize, buffer_len, 1) catch return error.OutOfMemory;
        }
    }
    buffer_len = std.math.add(usize, buffer_len, MAX_PATH_SIZE(u16) + 1) catch return error.OutOfMemory;
    buffer_len = @max(buffer_len, PATH_SIZE(u16));
    const buffer = try allocator.alloc(u16, buffer_len + 2);
    const second_buffer = try allocator.alloc(u16, buffer_len + 2);
    const result = if (is_windows)
        resolveWindowsT(u16, selected_paths, buffer, second_buffer)
    else
        resolvePosixT(u16, selected_paths, buffer, second_buffer);
    return switch (result) {
        .result => |value| bun.bindgen.DOMString.fromUTF16(value),
        .err => |err| context.fail(.system, try bun.bindgen.SystemError.fromSysError(err)),
    };
}

fn namespacedStringBound(
    context: anytype,
    comptime is_windows: bool,
    path: bun.bindgen.DOMStringView,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.DOMString {
    if (!is_windows or path.length() == 0) return path.toOwned();

    var arena = bun.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const input = try codeUnitsAs(
        u16,
        allocator,
        path.unsafePtr("the generated entry frame owns the path string until toNamespacedPath copies its result"),
    );
    const buffer_len = @max(input.len + MAX_PATH_SIZE(u16) + 1, PATH_SIZE(u16));
    const buffer = try allocator.alloc(u16, buffer_len + 9);
    const second_buffer = try allocator.alloc(u16, buffer_len + 9);
    return switch (toNamespacedPathWindowsT(u16, input, buffer, second_buffer)) {
        .result => |value| bun.bindgen.DOMString.fromUTF16(value),
        .err => |err| context.fail(.system, try bun.bindgen.SystemError.fromSysError(err)),
    };
}

const PathOperation = enum {
    basename,
    dirname,
    extname,
    is_absolute,
    join,
    normalize,
    parse,
    relative,
    resolve,
    to_namespaced_path,
};

const PathFunctionEntry = struct {
    name: []const u8,
    operation: PathOperation,
    is_windows: bool,
};

const path_functions = [_]PathFunctionEntry{
    .{ .name = "basenamePosix", .operation = .basename, .is_windows = false },
    .{ .name = "basenameWindows", .operation = .basename, .is_windows = true },
    .{ .name = "dirnamePosix", .operation = .dirname, .is_windows = false },
    .{ .name = "dirnameWindows", .operation = .dirname, .is_windows = true },
    .{ .name = "extnamePosix", .operation = .extname, .is_windows = false },
    .{ .name = "extnameWindows", .operation = .extname, .is_windows = true },
    .{ .name = "isAbsolutePosix", .operation = .is_absolute, .is_windows = false },
    .{ .name = "isAbsoluteWindows", .operation = .is_absolute, .is_windows = true },
    .{ .name = "joinPosix", .operation = .join, .is_windows = false },
    .{ .name = "joinWindows", .operation = .join, .is_windows = true },
    .{ .name = "normalizePosix", .operation = .normalize, .is_windows = false },
    .{ .name = "normalizeWindows", .operation = .normalize, .is_windows = true },
    .{ .name = "parsePosix", .operation = .parse, .is_windows = false },
    .{ .name = "parseWindows", .operation = .parse, .is_windows = true },
    .{ .name = "relativePosix", .operation = .relative, .is_windows = false },
    .{ .name = "relativeWindows", .operation = .relative, .is_windows = true },
    .{ .name = "resolvePosix", .operation = .resolve, .is_windows = false },
    .{ .name = "resolveWindows", .operation = .resolve, .is_windows = true },
    .{ .name = "toNamespacedPathWindows", .operation = .to_namespaced_path, .is_windows = true },
};

fn PathFunctionBinding(comptime Schema: type, comptime operation: PathOperation, comptime is_windows: bool) type {
    return struct {
        fn call(
            context: bun.bindgen.CallContext(Schema),
            args: bun.bindgen.Args(Schema),
        ) bun.bindgen.CallError(Schema)!bun.bindgen.Return(Schema) {
            switch (comptime operation) {
                .basename => return basenameBound(is_windows, args.path, args.suffix),
                .dirname => return dirnameBound(is_windows, args.path),
                .extname => return extnameBound(is_windows, args.path),
                .is_absolute => return isAbsoluteBound(is_windows, args.path),
                .join => return joinBound(is_windows, args.path),
                .normalize => return normalizeBound(is_windows, args.path),
                .parse => return parseBound(Schema, is_windows, args.path),
                .relative => return relativeBound(context, is_windows, args.from, args.to),
                .resolve => return resolveBound(context, is_windows, args.paths),
                .to_namespaced_path => return namespacedStringBound(context, is_windows, args.path),
            }
        }
    };
}

fn NativeDirnameBinding(comptime Schema: type, comptime is_windows: bool) type {
    return struct {
        fn call(
            _: bun.bindgen.CallContext(Schema),
            args: bun.bindgen.Args(Schema),
        ) bun.JSError!bun.bindgen.Return(Schema) {
            return dirnameBound(is_windows, args.path);
        }
    };
}

const PathBindings = bun.bindgen.Module("Path");
const DirnamePosixSchema = PathBindings.nativeExport("dirnamePosix");
const DirnameWindowsSchema = PathBindings.nativeExport("dirnameWindows");
const NodePathJoinCurrentPlatformSchema = PathBindings.nativeExport("nodePathJoinCurrentPlatform");
const DirnamePosixBinding = bun.bindgen.Fn(DirnamePosixSchema, NativeDirnameBinding(DirnamePosixSchema, false).call);
const DirnameWindowsBinding = bun.bindgen.Fn(DirnameWindowsSchema, NativeDirnameBinding(DirnameWindowsSchema, true).call);
const NodePathJoinCurrentPlatformBinding = bun.bindgen.Fn(NodePathJoinCurrentPlatformSchema, bindNodePathJoinCurrentPlatform);

comptime {
    for (path_functions) |entry| {
        const Schema = PathBindings.function(entry.name);
        _ = bun.bindgen.Fn(Schema, PathFunctionBinding(Schema, entry.operation, entry.is_windows).call);
    }
    _ = DirnamePosixBinding;
    _ = DirnameWindowsBinding;
    _ = NodePathJoinCurrentPlatformBinding;
}
