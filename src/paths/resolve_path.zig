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

pub const AncestorRelation = enum {
    ancestor,
    equal,
    unrelated,
};

pub fn ancestorRelation(ancestor: []const u8, descendant: []const u8) AncestorRelation {
    if (!rootsEqual(ancestor, descendant)) return .unrelated;

    var ancestor_components = std.fs.path.componentIterator(ancestor);
    var descendant_components = std.fs.path.componentIterator(descendant);
    while (ancestor_components.next()) |ancestor_component| {
        const descendant_component = descendant_components.next() orelse return .unrelated;
        if (!componentsEqual(ancestor_component.name, descendant_component.name)) return .unrelated;
    }

    return if (descendant_components.next() == null) .equal else .ancestor;
}

const CommonPath = struct {
    path: []const u8,
    all_equal: bool,
};

fn windowsRootsEqual(a: []const u8, b: []const u8) bool {
    const parsed_a = std.fs.path.parsePathWindows(u8, a);
    const parsed_b = std.fs.path.parsePathWindows(u8, b);
    if (parsed_a.kind != parsed_b.kind) return false;

    var a_components = std.mem.tokenizeAny(u8, parsed_a.root, "/\\");
    var b_components = std.mem.tokenizeAny(u8, parsed_b.root, "/\\");
    while (a_components.next()) |a_component| {
        const b_component = b_components.next() orelse return false;
        if (!std.os.windows.eqlIgnoreCaseWtf8(a_component, b_component)) return false;
    }
    return b_components.next() == null;
}

fn rootsEqual(a: []const u8, b: []const u8) bool {
    if (comptime bun.Environment.isWindows) return windowsRootsEqual(a, b);

    const a_root = std.fs.path.componentIterator(a).root();
    const b_root = std.fs.path.componentIterator(b).root();
    if (a_root) |root| return b_root != null and std.mem.eql(u8, root, b_root.?);
    return b_root == null;
}

fn componentsEqual(a: []const u8, b: []const u8) bool {
    if (comptime bun.Environment.isWindows) return std.os.windows.eqlIgnoreCaseWtf8(a, b);
    return std.mem.eql(u8, a, b);
}

fn commonPathInfo(input: []const []const u8) ?CommonPath {
    if (input.len == 0) return null;
    if (input.len == 1) return .{ .path = input[0], .all_equal = true };

    const first = input[0];
    var first_components = std.fs.path.componentIterator(first);
    var common_component_count: usize = 0;
    while (first_components.next()) |_| common_component_count += 1;

    var all_equal = true;
    for (input[1..]) |path| {
        if (!rootsEqual(first, path)) return null;

        var a_components = std.fs.path.componentIterator(first);
        var b_components = std.fs.path.componentIterator(path);
        var matched: usize = 0;
        const equal = while (true) {
            const a_component = a_components.next();
            const b_component = b_components.next();
            if (a_component == null or b_component == null) break a_component == null and b_component == null;
            if (!componentsEqual(a_component.?.name, b_component.?.name)) break false;
            matched += 1;
        };

        common_component_count = @min(common_component_count, matched);
        all_equal = all_equal and equal;
    }

    if (all_equal) return .{ .path = first, .all_equal = true };

    var components = std.fs.path.componentIterator(first);
    if (common_component_count == 0) {
        return if (components.root()) |root| .{ .path = root, .all_equal = false } else null;
    }

    var common = components.next().?;
    for (1..common_component_count) |_| common = components.next().?;
    return .{ .path = common.path, .all_equal = false };
}

pub fn commonPath(input: []const []const u8) ?[]const u8 {
    return (commonPathInfo(input) orelse return null).path;
}

pub fn commonDirectory(input: []const []const u8) ?[]const u8 {
    const common = commonPathInfo(input) orelse return null;
    if (!common.all_equal or (common.path.len > 0 and std.fs.path.isSep(common.path[common.path.len - 1]))) return common.path;
    return std.fs.path.dirname(common.path);
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
