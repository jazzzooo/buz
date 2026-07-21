threadlocal var parser_join_input_buffer: [4096]u8 = undefined;

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

pub fn hasAnyIllegalChars(maybe_path: []const u8) bool {
    if (!bun.Environment.isWindows) return false;
    var maybe_path_ = maybe_path;
    const parsed = std.fs.path.parsePathWindows(u8, maybe_path_);
    if (parsed.kind == .drive_absolute or parsed.kind == .drive_relative)
        maybe_path_ = maybe_path_[std.mem.trimEnd(u8, parsed.root, "/\\").len..];
    // guard against OBJECT_NAME_INVALID => unreachable
    return bun.strings.indexAnyComptime(maybe_path_, "<>:\"|?*") != null;
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
};

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

pub fn joinAbsStringBufZ(cwd: []const u8, buf: []u8, _parts: anytype, comptime platform: Platform) [:0]u8 {
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
