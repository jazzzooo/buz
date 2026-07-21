threadlocal var parser_join_input_buffer: [4096]u8 = undefined;
threadlocal var parser_buffer: [1024]u8 = undefined;

pub fn dirnameWindowsWtf16(path: []const u16) ?[]const u16 {
    var it = std.fs.path.ComponentIterator(.windows, u16).init(path);
    _ = it.last() orelse return null;
    const parent = it.previous() orelse return it.root();
    return parent.path;
}

pub fn z(input: []const u8, output: *bun.PathBuffer) [:0]const u8 {
    if (input.len > bun.MAX_PATH_BYTES) {
        if (comptime bun.Environment.allow_assert) @panic("path too long");
        return "";
    }

    @memcpy(output[0..input.len], input);
    output[input.len] = 0;

    return output[0..input.len :0];
}

inline fn nqlAtIndex(comptime string_count: comptime_int, index: usize, input: []const []const u8) bool {
    comptime var string_index = 1;

    inline while (string_index < string_count) : (string_index += 1) {
        if (input[0][index] != input[string_index][index]) {
            return true;
        }
    }

    return false;
}

inline fn nqlAtIndexCaseInsensitive(comptime string_count: comptime_int, index: usize, input: []const []const u8) bool {
    comptime var string_index = 1;

    inline while (string_index < string_count) : (string_index += 1) {
        if (std.ascii.toLower(input[0][index]) != std.ascii.toLower(input[string_index][index])) {
            return true;
        }
    }

    return false;
}

inline fn @"is .."(slice: []const u8) bool {
    return slice.len >= 2 and @as(u16, @bitCast(slice[0..2].*)) == comptime std.mem.readInt(u16, "..", .little);
}

inline fn @"is .. with type"(comptime T: type, slice: []const T) bool {
    if (comptime T == u8) return @"is .."(slice);
    return slice.len >= 2 and slice[0] == '.' and slice[1] == '.';
}

const ParentEqual = enum {
    parent,
    equal,
    unrelated,
};

pub fn isParentOrEqual(parent_: []const u8, child: []const u8) ParentEqual {
    const parent = strings.withoutTrailingSlashWindowsPath(parent_);
    const normalized_child = strings.withoutTrailingSlashWindowsPath(child);
    const startsWith = if (comptime !bun.Environment.isLinux)
        strings.startsWithCaseInsensitiveAscii
    else
        strings.startsWith;
    if (!startsWith(normalized_child, parent)) return .unrelated;

    if (normalized_child.len == parent.len) return .equal;
    if (parent.len > 0 and std.fs.path.PathType.windows.isSep(u8, parent[parent.len - 1])) return .parent;
    if (std.fs.path.PathType.windows.isSep(u8, normalized_child[parent.len])) return .parent;
    return .unrelated;
}

fn getIfExistsLongestCommonPathGeneric(input: []const []const u8, comptime platform: Platform) ?[]const u8 {
    const separator = comptime platform.separator();
    const nqlAtIndexFn = switch (platform) {
        else => nqlAtIndex,
        .windows => nqlAtIndexCaseInsensitive,
    };

    var min_length: usize = std.math.maxInt(usize);
    for (input) |str| min_length = @min(str.len, min_length);

    var index: usize = 0;
    var last_common_separator: ?usize = null;
    switch (input.len) {
        0 => return "",
        1 => return input[0],
        inline 2, 3, 4, 5, 6, 7, 8 => |n| {
            while (index < min_length) : (index += 1) {
                if (nqlAtIndexFn(comptime n, index, input)) {
                    if (last_common_separator == null) return null;
                    break;
                }
                if (platform.isSeparator(input[0][index])) last_common_separator = index;
            }
        },
        else => {
            var string_index: usize = 1;
            while (string_index < input.len) : (string_index += 1) {
                while (index < min_length) : (index += 1) {
                    const differs = if (platform == .windows)
                        std.ascii.toLower(input[0][index]) != std.ascii.toLower(input[string_index][index])
                    else
                        input[0][index] != input[string_index][index];
                    if (differs) {
                        if (last_common_separator == null) return null;
                        break;
                    }
                }
                if (index == min_length) index -= 1;
                if (platform.isSeparator(input[0][index])) last_common_separator = index;
            }
        },
    }

    if (index == 0) return &([_]u8{separator});
    if (last_common_separator == null) return &([_]u8{'.'});

    for (input) |str| {
        if (str.len > index and platform.isSeparator(str[index])) return str[0 .. index + 1];
    }
    return input[0][0 .. last_common_separator.? + 1];
}

// TODO: is it faster to determine longest_common_separator in the while loop
// or as an extra step at the end?
// only boether to check if this function appears in benchmarking
fn longestCommonPathGeneric(input: []const []const u8, comptime platform: Platform) []const u8 {
    const separator = comptime platform.separator();

    const nqlAtIndexFn = switch (platform) {
        else => nqlAtIndex,
        .windows => nqlAtIndexCaseInsensitive,
    };

    var min_length: usize = std.math.maxInt(usize);
    for (input) |str| {
        min_length = @min(str.len, min_length);
    }

    var index: usize = 0;
    var last_common_separator: usize = 0;

    // try to use an unrolled version of this loop
    switch (input.len) {
        0 => {
            return "";
        },
        1 => {
            return input[0];
        },
        inline 2, 3, 4, 5, 6, 7, 8 => |n| {
            // If volume IDs do not match on windows, we can't have a common path
            if (platform == .windows) {
                const first_root = std.fs.path.parsePathWindows(u8, input[0]).root;
                comptime var i = 1;
                inline while (i < n) : (i += 1) {
                    const root = std.fs.path.parsePathWindows(u8, input[i]).root;
                    if (!strings.eqlCaseInsensitiveASCIIICheckLength(first_root, root)) {
                        return "";
                    }
                }
            }

            while (index < min_length) : (index += 1) {
                if (nqlAtIndexFn(comptime n, index, input)) {
                    break;
                }
                if (platform.isSeparator(input[0][index])) {
                    last_common_separator = index;
                }
            }
        },
        else => {
            // If volume IDs do not match on windows, we can't have a common path
            if (platform == .windows) {
                const first_root = std.fs.path.parsePathWindows(u8, input[0]).root;
                var i: usize = 1;
                while (i < input.len) : (i += 1) {
                    const root = std.fs.path.parsePathWindows(u8, input[i]).root;
                    if (!strings.eqlCaseInsensitiveASCIIICheckLength(first_root, root)) {
                        return "";
                    }
                }
            }

            var string_index: usize = 1;
            while (string_index < input.len) : (string_index += 1) {
                while (index < min_length) : (index += 1) {
                    if (platform == .windows) {
                        if (std.ascii.toLower(input[0][index]) != std.ascii.toLower(input[string_index][index])) {
                            break;
                        }
                    } else {
                        if (input[0][index] != input[string_index][index]) {
                            break;
                        }
                    }
                }
                if (index == min_length) index -= 1;
                if (platform.isSeparator(input[0][index])) {
                    last_common_separator = index;
                }
            }
        },
    }

    if (index == 0) {
        return &([_]u8{separator});
    }

    // The above won't work for a case like this:
    // /app/public/index.js
    // /app/public
    // It will return:
    // /app/
    // It should return:
    // /app/public/
    // To detect /app/public is actually a folder, we do one more loop through the strings
    // and say, "do one of you have a path separator after what we thought was the end?"
    var idx = input.len; // Use this value as an invalid value.
    for (input, 0..) |str, i| {
        if (str.len > index) {
            if (platform.isSeparator(str[index])) {
                idx = i;
            } else {
                idx = input.len;
                break;
            }
        }
    }
    if (idx != input.len) {
        return input[idx][0 .. index + 1];
    }

    return input[0][0 .. last_common_separator + 1];
}

pub fn longestCommonPath(input: []const []const u8) []const u8 {
    return longestCommonPathGeneric(input, Platform.auto);
}

pub fn getIfExistsLongestCommonPath(input: []const []const u8) ?[]const u8 {
    return getIfExistsLongestCommonPathGeneric(input, Platform.auto);
}

fn windowsVolume(comptime T: type, path: []const T) []const T {
    const parsed = std.fs.path.parsePathWindows(T, path);
    return switch (parsed.kind) {
        .drive_absolute, .drive_relative, .unc_absolute => std.mem.trimEnd(T, parsed.root, strings.literal(T, "/\\")),
        else => path[0..0],
    };
}

pub fn hasAnyIllegalChars(maybe_path: []const u8) bool {
    if (!bun.Environment.isWindows) return false;
    var maybe_path_ = maybe_path;
    const parsed = std.fs.path.parsePathWindows(u8, maybe_path_);
    if (parsed.kind == .drive_absolute or parsed.kind == .drive_relative)
        maybe_path_ = maybe_path_[windowsVolume(u8, maybe_path_).len..];
    // guard against OBJECT_NAME_INVALID => unreachable
    return bun.strings.indexAnyComptime(maybe_path_, "<>:\"|?*") != null;
}

// This function is based on Go's filepath.Clean function
// https://cs.opensource.google/go/go/+/refs/tags/go1.17.6:src/path/filepath/path.go;l=89
fn normalizeStringGenericT(
    comptime T: type,
    path_: []const T,
    buf: []T,
    comptime allow_above_root: bool,
    comptime separator: T,
    comptime path_type: std.fs.path.PathType,
    comptime preserve_trailing_slash: bool,
) []T {
    return normalizeStringGenericTZ(T, path_, buf, .{
        .allow_above_root = allow_above_root,
        .separator = separator,
        .path_type = path_type,
        .preserve_trailing_slash = preserve_trailing_slash,
        .zero_terminate = false,
        .add_nt_prefix = false,
    });
}

pub fn NormalizeOptions(comptime T: type) type {
    return struct {
        allow_above_root: bool = false,
        separator: T = std.fs.path.sep,
        path_type: std.fs.path.PathType = if (std.fs.path.sep == std.fs.path.sep_windows) .windows else .posix,
        preserve_trailing_slash: bool = false,
        zero_terminate: bool = false,
        add_nt_prefix: bool = false,
    };
}

pub fn normalizeStringGenericTZ(
    comptime T: type,
    path_: []const T,
    buf: []T,
    comptime options: NormalizeOptions(T),
) if (options.zero_terminate) [:0]T else []T {
    const isWindows, const sep_str = comptime .{ options.separator == std.fs.path.sep_windows, &[_]u8{options.separator} };

    if (isWindows and bun.Environment.isDebug) {
        // this is here to catch a potential mistake by the caller
        //
        // since it is theoretically possible to get here in release
        // we will not do this check in release.
        assert(!strings.hasPrefixComptimeType(T, path_, strings.literal(T, ":\\")));
    }

    var buf_i: usize = 0;
    var dotdot: usize = 0;
    var path_begin: usize = 0;

    const volLen = if (isWindows) windowsVolume(T, path_).len else 0;
    const indexOfThirdUNCSlash = if (isWindows and std.fs.path.parsePathWindows(T, path_).kind == .unc_absolute)
        std.mem.findAnyPos(T, path_, 2, strings.literal(T, "/\\")) orelse 0
    else
        0;

    if (isWindows) {
        if (volLen > 0) {
            if (options.add_nt_prefix) {
                @memcpy(buf[buf_i .. buf_i + 4], strings.literal(T, "\\??\\"));
                buf_i += 4;
            }
            if (path_[1] != ':') {
                // UNC paths
                if (options.add_nt_prefix) {
                    @memcpy(buf[buf_i .. buf_i + 4], strings.literal(T, "UNC" ++ sep_str));
                    buf_i += 2;
                } else {
                    @memcpy(buf[buf_i .. buf_i + 2], strings.literal(T, sep_str ++ sep_str));
                }
                if (indexOfThirdUNCSlash > 0) {
                    // we have the ending slash
                    @memcpy(buf[buf_i + 2 .. buf_i + indexOfThirdUNCSlash + 1], path_[2 .. indexOfThirdUNCSlash + 1]);
                    buf[buf_i + indexOfThirdUNCSlash] = options.separator;
                    @memcpy(
                        buf[buf_i + indexOfThirdUNCSlash + 1 .. buf_i + volLen],
                        path_[indexOfThirdUNCSlash + 1 .. volLen],
                    );
                } else {
                    // we dont have the ending slash
                    @memcpy(buf[buf_i + 2 .. buf_i + volLen], path_[2..volLen]);
                }
                buf[buf_i + volLen] = options.separator;
                buf_i += volLen + 1;
                path_begin = volLen + 1;

                // it is just a volume name
                if (path_begin >= path_.len) {
                    if (options.zero_terminate) {
                        buf[buf_i] = 0;
                        return buf[0..buf_i :0];
                    } else {
                        return buf[0..buf_i];
                    }
                }
            } else {
                // drive letter
                buf[buf_i] = std.ascii.toUpper(@truncate(path_[0]));
                buf[buf_i + 1] = ':';
                buf_i += 2;
                dotdot = buf_i;
                path_begin = 2;
            }
        } else if (path_.len > 0 and options.path_type.isSep(T, path_[0])) {
            buf[buf_i] = options.separator;
            buf_i += 1;
            dotdot = buf_i;
            path_begin = 1;
        }
    }

    var r: usize = 0;
    var path, const buf_start = if (isWindows)
        .{ path_[path_begin..], buf_i }
    else
        .{ path_, 0 };

    const n = path.len;

    if (isWindows and (options.allow_above_root or volLen > 0)) {
        // consume leading slashes on windows
        if (r < n and options.path_type.isSep(T, path[r])) {
            r += 1;
            buf[buf_i] = options.separator;
            buf_i += 1;

            // win32.resolve("C:\\Users\\bun", "C:\\Users\\bun", "/..\\bar")
            // should be "C:\\bar" not "C:bar"
            dotdot = buf_i;
        }
    }

    while (r < n) {
        // empty path element
        // or
        // . element
        if (options.path_type.isSep(T, path[r])) {
            r += 1;
            continue;
        }

        if (path[r] == '.' and (r + 1 == n or options.path_type.isSep(T, path[r + 1]))) {
            // skipping two is a windows-specific bugfix
            r += 1;
            continue;
        }

        if (@"is .. with type"(T, path[r..]) and (r + 2 == n or options.path_type.isSep(T, path[r + 2]))) {
            r += 2;
            // .. element: remove to last separator
            if (buf_i > dotdot) {
                buf_i -= 1;
                while (buf_i > dotdot and !options.path_type.isSep(T, buf[buf_i])) {
                    buf_i -= 1;
                }
            } else if (options.allow_above_root) {
                if (buf_i > buf_start) {
                    buf[buf_i..][0..3].* = (strings.literal(T, sep_str ++ "..")).*;
                    buf_i += 3;
                } else {
                    buf[buf_i..][0..2].* = (strings.literal(T, "..")).*;
                    buf_i += 2;
                }
                dotdot = buf_i;
            }

            continue;
        }

        // real path element.
        // add slash if needed
        if (buf_i != buf_start and buf_i > 0 and !options.path_type.isSep(T, buf[buf_i - 1])) {
            buf[buf_i] = options.separator;
            buf_i += 1;
        }

        const from = r;
        while (r < n and !options.path_type.isSep(T, path[r])) : (r += 1) {}
        const count = r - from;
        @memcpy(buf[buf_i..][0..count], path[from..][0..count]);
        buf_i += count;
    }

    if (options.preserve_trailing_slash) {
        // Was there a trailing slash? Let's keep it.
        if (buf_i > 0 and path_[path_.len - 1] == options.separator and buf[buf_i - 1] != options.separator) {
            buf[buf_i] = options.separator;
            buf_i += 1;
        }
    }

    if (isWindows and buf_i == 2 and buf[1] == ':') {
        // If the original path is just a relative path with a drive letter,
        // add .
        buf[buf_i] = if (path.len > 0 and path[0] == '\\') '\\' else '.';
        buf_i += 1;
    }

    if (options.zero_terminate) {
        buf[buf_i] = 0;
    }

    const result = if (options.zero_terminate) buf[0..buf_i :0] else buf[0..buf_i];

    if (bun.Environment.allow_assert and isWindows) {
        assert(!strings.hasPrefixComptimeType(T, result, strings.literal(T, "\\:\\")));
    }

    return result;
}

pub const Platform = enum {
    windows,
    posix,
    nt,

    pub const auto: Platform = switch (bun.Environment.os) {
        .windows => .windows,
        .linux, .mac, .freebsd => .posix,
        .wasm => .posix,
    };

    pub fn isAbsolute(comptime platform: Platform, path: []const u8) bool {
        return isAbsoluteT(platform, u8, path);
    }

    pub fn isAbsoluteT(comptime platform: Platform, comptime T: type, path: []const T) bool {
        if (T != u8 and T != u16) @compileError("Unsupported type given to isAbsoluteT");
        return switch (platform) {
            .posix => path.len > 0 and path[0] == '/',
            .nt,
            .windows,
            => if (T == u8)
                std.fs.path.isAbsoluteWindows(path)
            else
                std.fs.path.isAbsoluteWindowsWtf16(path),
        };
    }

    pub inline fn separator(comptime platform: Platform) u8 {
        return switch (platform) {
            .posix => std.fs.path.sep_posix,
            .nt, .windows => std.fs.path.sep_windows,
        };
    }

    pub inline fn separatorString(comptime platform: Platform) []const u8 {
        return switch (platform) {
            .posix => std.fs.path.sep_str_posix,
            .nt, .windows => std.fs.path.sep_str_windows,
        };
    }

    pub inline fn pathType(comptime platform: Platform) std.fs.path.PathType {
        return switch (platform) {
            .nt, .windows => .windows,
            .posix => .posix,
        };
    }

    pub fn lastIndexOfSeparator(comptime platform: Platform, comptime T: type, path: []const T) ?usize {
        return switch (platform) {
            .nt, .windows => std.mem.lastIndexOfAny(T, path, strings.literal(T, "/\\")),
            .posix => std.mem.lastIndexOfScalar(T, path, std.fs.path.sep_posix),
        };
    }

    pub inline fn isSeparator(comptime platform: Platform, char: u8) bool {
        return isSeparatorT(platform, u8, char);
    }

    pub inline fn isSeparatorT(comptime platform: Platform, comptime T: type, char: T) bool {
        return platform.pathType().isSep(T, char);
    }

    pub fn trailingSeparator(comptime platform: Platform) [2]u8 {
        return switch (platform) {
            .nt, .windows => ".\\".*,
            .posix => "./".*,
        };
    }

    pub fn leadingSeparatorIndex(comptime platform: Platform, path: anytype) ?usize {
        switch (platform) {
            .nt, .windows => {
                if (path.len < 1)
                    return null;

                if (path[0] == '/')
                    return 0;

                if (path[0] == '\\')
                    return 0;

                if (path.len < 3)
                    return null;

                // C:\
                // C:/
                if (path[0] >= 'A' and path[0] <= 'Z' and path[1] == ':') {
                    if (path[2] == '/')
                        return 2;
                    if (path[2] == '\\')
                        return 2;

                    return 1;
                }

                return null;
            },
            .posix => {
                if (path.len > 0 and path[0] == '/') {
                    return 0;
                } else {
                    return null;
                }
            },
        }
    }
};

pub fn normalizeString(str: []const u8, comptime allow_above_root: bool, comptime platform: Platform) []u8 {
    return normalizeStringBuf(str, &parser_buffer, allow_above_root, platform, false);
}
pub fn normalizeBuf(str: []const u8, buf: []u8, comptime platform: Platform) []u8 {
    return normalizeBufT(u8, str, buf, platform);
}

pub fn normalizeBufZ(str: []const u8, buf: []u8, comptime platform: Platform) [:0]u8 {
    const norm = normalizeBufT(u8, str, buf, platform);
    buf[norm.len] = 0;
    return buf[0..norm.len :0];
}

pub fn normalizeBufT(comptime T: type, str: []const T, buf: []T, comptime platform: Platform) []T {
    if (str.len == 0) {
        buf[0] = '.';
        return buf[0..1];
    }

    const is_absolute = platform.isAbsoluteT(T, str);

    const trailing_separator = platform.lastIndexOfSeparator(T, str) == str.len - 1;

    if (is_absolute and trailing_separator)
        return normalizeStringBufT(T, str, buf, true, platform, true);

    if (is_absolute and !trailing_separator)
        return normalizeStringBufT(T, str, buf, true, platform, false);

    if (!is_absolute and !trailing_separator)
        return normalizeStringBufT(T, str, buf, false, platform, false);

    return normalizeStringBufT(T, str, buf, false, platform, true);
}

pub fn normalizeStringBuf(
    str: []const u8,
    buf: []u8,
    comptime allow_above_root: bool,
    comptime platform: Platform,
    comptime preserve_trailing_slash: bool,
) []u8 {
    return normalizeStringBufT(u8, str, buf, allow_above_root, platform, preserve_trailing_slash);
}

pub fn normalizeStringBufT(
    comptime T: type,
    str: []const T,
    buf: []T,
    comptime allow_above_root: bool,
    comptime platform: Platform,
    comptime preserve_trailing_slash: bool,
) []T {
    switch (platform) {
        .nt => @compileError("not implemented"),
        .windows => {
            return normalizeStringWindowsT(
                T,
                str,
                buf,
                allow_above_root,
                preserve_trailing_slash,
            );
        },
        .posix => {
            return normalizeStringPosixT(
                T,
                str,
                buf,
                allow_above_root,
                preserve_trailing_slash,
            );
        },
    }
}

/// Convert parts of potentially invalid file paths into a single valid filpeath
/// without querying the filesystem
/// This is the equivalent of path.resolve
///
/// Returned path is stored in a temporary buffer. It must be copied if it needs to be stored.
pub fn joinAbsString(_cwd: []const u8, parts: anytype, comptime platform: Platform) []const u8 {
    return joinAbsStringBuf(
        _cwd,
        &parser_join_input_buffer,
        parts,
        platform,
    );
}

/// Convert parts of potentially invalid file paths into a single valid filpeath
/// without querying the filesystem
/// This is the equivalent of path.resolve
///
/// Returned path is stored in a temporary buffer. It must be copied if it needs to be stored.
pub fn joinAbsStringZ(_cwd: []const u8, parts: anytype, comptime platform: Platform) [:0]const u8 {
    return joinAbsStringBufZ(
        _cwd,
        &parser_join_input_buffer,
        parts,
        platform,
    );
}

pub fn joinAbsStringBuf(cwd: []const u8, buf: []u8, _parts: anytype, comptime platform: Platform) []const u8 {
    return resolveBuf(cwd, buf, _parts, platform) orelse @panic("resolved path exceeds buffer");
}

/// Like `joinAbsStringBuf`, but returns null when the *normalized* result is
/// too large for `buf`. Use this when `parts` may contain user-controlled
/// input of arbitrary length. `..` segments are handled correctly: a path
/// whose unnormalized length exceeds `buf.len` but normalizes down will still
/// succeed.
pub fn joinAbsStringBufChecked(cwd: []const u8, buf: []u8, parts: []const []const u8, comptime platform: Platform) ?[]const u8 {
    return resolveBuf(cwd, buf, parts, platform);
}

pub fn joinAbsStringBufZ(cwd: []const u8, buf: []u8, _parts: anytype, comptime platform: Platform) [:0]const u8 {
    if (buf.len == 0) @panic("resolved path exceeds buffer");
    const resolved = resolveBuf(cwd, buf[0 .. buf.len - 1], _parts, platform) orelse @panic("resolved path exceeds buffer");
    buf[resolved.len] = 0;
    return buf[0..resolved.len :0];
}

fn resolveBuf(
    cwd: []const u8,
    buf: []u8,
    _parts: anytype,
    comptime platform: Platform,
) ?[]u8 {
    comptime if (platform == .nt) @compileError("NT path resolution is unsupported");

    const parts: []const []const u8 = _parts;
    var paths_buf: [8][]const u8 = undefined;
    var paths_allocator: std.heap.BufferFirstAllocator = .init(@ptrCast(&paths_buf), bun.default_allocator);
    const paths_alloc = paths_allocator.allocator();
    const paths = bun.handleOom(paths_alloc.alloc([]const u8, parts.len + 1));
    defer paths_alloc.free(paths);
    paths[0] = cwd;
    @memcpy(paths[1..], parts);

    var output_allocator: std.heap.BufferFirstAllocator = .init(buf, bun.default_allocator);
    const output_alloc = output_allocator.allocator();
    const resolved = bun.handleOom(switch (platform) {
        .posix => std.fs.path.resolvePosix(output_alloc, paths),
        .windows => std.fs.path.resolveWindows(output_alloc, paths),
        .nt => unreachable,
    });
    defer if (!output_allocator.fixed_buffer_allocator.ownsPtr(resolved.ptr)) output_alloc.free(resolved);

    if (resolved.len > buf.len) return null;
    @memmove(buf[0..resolved.len], resolved);
    return buf[0..resolved.len];
}

pub fn normalizeStringPosixT(
    comptime T: type,
    str: []const T,
    buf: []T,
    comptime allow_above_root: bool,
    comptime preserve_trailing_slash: bool,
) []T {
    return normalizeStringGenericT(
        T,
        str,
        buf,
        allow_above_root,
        std.fs.path.sep_posix,
        .posix,
        preserve_trailing_slash,
    );
}

pub fn normalizeStringWindowsT(
    comptime T: type,
    str: []const T,
    buf: []T,
    comptime allow_above_root: bool,
    comptime preserve_trailing_slash: bool,
) []T {
    return normalizeStringGenericT(
        T,
        str,
        buf,
        allow_above_root,
        std.fs.path.sep_windows,
        .windows,
        preserve_trailing_slash,
    );
}

/// The use case of this is when you do
///     "import '/hello/world'"
/// The windows disk designator is missing!
///
/// Defaulting to C would work but the correct behavior is to use a known disk designator,
/// via an absolute path from the referrer or what not.
///
/// I've made it so that trying to read a file with a posix path is a debug assertion failure.
///
/// To use this, stack allocate the following struct, and then call `resolve`.
///
///     var normalizer = PosixToWinNormalizer{};
///     const result = normalizer.resolve("C:\\dev\\bun", "/dev/bun/test/etc.js");
///
/// When you are certain that using the current working directory is fine, you can use
///
///     const result = normalizer.resolveCWD("/dev/bun/test/etc.js");
///
/// This API does nothing on Linux (it has a size of zero)
pub const PosixToWinNormalizer = struct {
    const Buf = if (bun.Environment.isWindows) bun.PathBuffer else void;

    _raw_bytes: Buf = undefined,

    // methods on PosixToWinNormalizer, to be minimal yet stack allocate the PathBuffer
    // these do not force inline of much code
    pub inline fn resolve(
        this: *PosixToWinNormalizer,
        source_dir: []const u8,
        maybe_posix_path: []const u8,
    ) []const u8 {
        return resolveWithExternalBuf(&this._raw_bytes, source_dir, maybe_posix_path);
    }

    pub inline fn resolveZ(
        this: *PosixToWinNormalizer,
        source_dir: []const u8,
        maybe_posix_path: [:0]const u8,
    ) [:0]const u8 {
        return resolveWithExternalBufZ(&this._raw_bytes, source_dir, maybe_posix_path);
    }

    pub inline fn resolveCWD(
        this: *PosixToWinNormalizer,
        maybe_posix_path: []const u8,
    ) ![]const u8 {
        return resolveCWDWithExternalBuf(&this._raw_bytes, maybe_posix_path);
    }

    pub inline fn resolveCWDZ(
        this: *PosixToWinNormalizer,
        maybe_posix_path: []const u8,
    ) ![:0]const u8 {
        return resolveCWDWithExternalBufZ(&this._raw_bytes, maybe_posix_path);
    }

    // underlying implementation:

    fn resolveWithExternalBuf(
        buf: *Buf,
        source_dir: []const u8,
        maybe_posix_path: []const u8,
    ) []const u8 {
        assert(std.fs.path.isAbsoluteWindows(maybe_posix_path));
        if (bun.Environment.isWindows) {
            const root = std.fs.path.parsePathWindows(u8, maybe_posix_path).root;
            if (root.len == 1) {
                assert(Platform.windows.isSeparator(root[0]));
                if (bun.strings.isWindowsAbsolutePathMissingDriveLetter(u8, maybe_posix_path)) {
                    const source_root = std.fs.path.parsePathWindows(u8, source_dir).root;
                    @memcpy(buf[0..source_root.len], source_root);
                    @memcpy(buf[source_root.len..][0 .. maybe_posix_path.len - 1], maybe_posix_path[1..]);
                    const res = buf[0 .. source_root.len + maybe_posix_path.len - 1];
                    assert(!bun.strings.isWindowsAbsolutePathMissingDriveLetter(u8, res));
                    assert(std.fs.path.isAbsoluteWindows(res));
                    return res;
                }
            }
            assert(!bun.strings.isWindowsAbsolutePathMissingDriveLetter(u8, maybe_posix_path));
        }
        return maybe_posix_path;
    }

    fn resolveWithExternalBufZ(
        buf: *Buf,
        source_dir: []const u8,
        maybe_posix_path: [:0]const u8,
    ) [:0]const u8 {
        assert(std.fs.path.isAbsoluteWindows(maybe_posix_path));
        if (bun.Environment.isWindows) {
            const root = std.fs.path.parsePathWindows(u8, maybe_posix_path).root;
            if (root.len == 1) {
                assert(Platform.windows.isSeparator(root[0]));
                if (bun.strings.isWindowsAbsolutePathMissingDriveLetter(u8, maybe_posix_path)) {
                    const source_root = std.fs.path.parsePathWindows(u8, source_dir).root;
                    @memcpy(buf[0..source_root.len], source_root);
                    @memcpy(buf[source_root.len..][0 .. maybe_posix_path.len - 1], maybe_posix_path[1..]);
                    buf[source_root.len + maybe_posix_path.len - 1] = 0;
                    const res = buf[0 .. source_root.len + maybe_posix_path.len - 1 :0];
                    assert(!bun.strings.isWindowsAbsolutePathMissingDriveLetter(u8, res));
                    assert(std.fs.path.isAbsoluteWindows(res));
                    return res;
                }
            }
            assert(!bun.strings.isWindowsAbsolutePathMissingDriveLetter(u8, maybe_posix_path));
        }
        return maybe_posix_path;
    }

    pub fn resolveCWDWithExternalBuf(
        buf: *Buf,
        maybe_posix_path: []const u8,
    ) ![]const u8 {
        assert(std.fs.path.isAbsoluteWindows(maybe_posix_path));

        if (bun.Environment.isWindows) {
            const root = std.fs.path.parsePathWindows(u8, maybe_posix_path).root;
            if (root.len == 1) {
                assert(Platform.windows.isSeparator(root[0]));
                if (bun.strings.isWindowsAbsolutePathMissingDriveLetter(u8, maybe_posix_path)) {
                    const cwd = try bun.getcwd(buf);
                    assert(cwd.ptr == buf.ptr);
                    const source_root = std.fs.path.parsePathWindows(u8, cwd).root;
                    assert(source_root.ptr == source_root.ptr);
                    @memcpy(buf[source_root.len..][0 .. maybe_posix_path.len - 1], maybe_posix_path[1..]);
                    const res = buf[0 .. source_root.len + maybe_posix_path.len - 1];
                    assert(!bun.strings.isWindowsAbsolutePathMissingDriveLetter(u8, res));
                    assert(std.fs.path.isAbsoluteWindows(res));
                    return res;
                }
            }
            assert(!bun.strings.isWindowsAbsolutePathMissingDriveLetter(u8, maybe_posix_path));
        }

        return maybe_posix_path;
    }

    pub fn resolveCWDWithExternalBufZ(
        buf: *bun.PathBuffer,
        maybe_posix_path: []const u8,
    ) ![:0]u8 {
        assert(std.fs.path.isAbsoluteWindows(maybe_posix_path));

        if (bun.Environment.isWindows) {
            const root = std.fs.path.parsePathWindows(u8, maybe_posix_path).root;
            if (root.len == 1) {
                assert(Platform.windows.isSeparator(root[0]));
                if (bun.strings.isWindowsAbsolutePathMissingDriveLetter(u8, maybe_posix_path)) {
                    const cwd = try bun.getcwd(buf);
                    assert(cwd.ptr == buf.ptr);
                    const source_root = std.fs.path.parsePathWindows(u8, cwd).root;
                    assert(source_root.ptr == source_root.ptr);
                    @memcpy(buf[source_root.len..][0 .. maybe_posix_path.len - 1], maybe_posix_path[1..]);
                    buf[source_root.len + maybe_posix_path.len - 1] = 0;
                    const res = buf[0 .. source_root.len + maybe_posix_path.len - 1 :0];
                    assert(!bun.strings.isWindowsAbsolutePathMissingDriveLetter(u8, res));
                    assert(std.fs.path.isAbsoluteWindows(res));
                    return res;
                }
            }

            assert(!bun.strings.isWindowsAbsolutePathMissingDriveLetter(u8, maybe_posix_path));
        }

        @memcpy(buf.ptr, maybe_posix_path);
        buf[maybe_posix_path.len] = 0;
        return buf[0..maybe_posix_path.len :0];
    }
};

// ResolvePath__joinAbsStringBufCurrentPlatformBunString: see src/jsc/resolve_path_jsc.zig
// (reaches into the VM for cwd; paths/ is JSC-free).

pub fn platformToPosixInPlace(comptime T: type, path_buffer: []T) void {
    if (std.fs.path.sep == '/') return;
    var idx: usize = 0;
    while (std.mem.indexOfScalarPos(T, path_buffer, idx, std.fs.path.sep)) |index| : (idx = index + 1) {
        path_buffer[index] = '/';
    }
}

pub fn dangerouslyConvertPathToPosixInPlace(comptime T: type, path: []T) void {
    var idx: usize = 0;
    if (comptime bun.Environment.isWindows) {
        if (std.fs.path.parsePathWindows(T, path).kind == .drive_absolute) {
            switch (path[0]) {
                'a'...'z' => path[0] = 'A' + (path[0] - 'a'),
                else => {},
            }
        }
    }

    while (std.mem.indexOfScalarPos(T, path, idx, std.fs.path.sep_windows)) |index| : (idx = index + 1) {
        path[index] = '/';
    }
}

pub fn dangerouslyConvertPathToWindowsInPlace(comptime T: type, path: []T) void {
    var idx: usize = 0;
    while (std.mem.indexOfScalarPos(T, path, idx, std.fs.path.sep_posix)) |index| : (idx = index + 1) {
        path[index] = '\\';
    }
}

pub fn pathToPosixBuf(comptime T: type, path: []const T, buf: []T) []T {
    var idx: usize = 0;
    while (std.mem.indexOfScalarPos(T, path, idx, std.fs.path.sep_windows)) |index| : (idx = index + 1) {
        @memcpy(buf[idx..index], path[idx..index]);
        buf[index] = std.fs.path.sep_posix;
    }
    @memcpy(buf[idx..path.len], path[idx..path.len]);
    return buf[0..path.len];
}

pub fn platformToPosixBuf(comptime T: type, path: []const T, buf: []T) []const T {
    if (std.fs.path.sep == '/') return path;
    var idx: usize = 0;
    while (std.mem.indexOfScalarPos(T, path, idx, std.fs.path.sep)) |index| : (idx = index + 1) {
        @memcpy(buf[idx..index], path[idx..index]);
        buf[index] = '/';
    }
    @memcpy(buf[idx..path.len], path[idx..path.len]);
    return buf[0..path.len];
}

pub fn posixToPlatformInPlace(comptime T: type, path_buffer: []T) void {
    if (std.fs.path.sep == '/') return;
    var idx: usize = 0;
    while (std.mem.indexOfScalarPos(T, path_buffer, idx, '/')) |index| : (idx = index + 1) {
        path_buffer[index] = std.fs.path.sep;
    }
}

const std = @import("std");

const bun = @import("bun");
const assert = bun.assert;
const strings = bun.strings;
