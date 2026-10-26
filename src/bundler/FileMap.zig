const FileMap = @This();

map: bun.StringHashMapUnmanaged([]const u8) = .empty,

pub fn deinit(self: *FileMap) void {
    var iter = self.map.iterator();
    while (iter.next()) |entry| {
        bun.default_allocator.free(entry.value_ptr.*);
        bun.default_allocator.free(entry.key_ptr.*);
    }
    self.map.deinit(bun.default_allocator);
}

pub fn get(self: *const FileMap, specifier: []const u8) ?[]const u8 {
    if (self.map.count() == 0) return null;

    if (comptime !bun.Environment.isWindows) {
        return self.map.get(specifier);
    }

    const buf = bun.path_buffer_pool.get();
    defer bun.path_buffer_pool.put(buf);
    const normalized = bun.path.pathToPosixBuf(u8, specifier, buf);
    return self.map.get(normalized);
}

pub fn contains(self: *const FileMap, specifier: []const u8) bool {
    if (self.map.count() == 0) return false;

    if (comptime !bun.Environment.isWindows) {
        return self.map.contains(specifier);
    }

    const buf = bun.path_buffer_pool.get();
    defer bun.path_buffer_pool.put(buf);
    const normalized = bun.path.pathToPosixBuf(u8, specifier, buf);
    return self.map.contains(normalized);
}

pub fn resolve(self: *const FileMap, source_file: []const u8, specifier: []const u8) ?Resolver.Result {
    if (self.map.count() == 0) return null;

    if (comptime !bun.Environment.isWindows) {
        if (self.map.getKey(specifier)) |key| {
            return .{
                .path_pair = .{
                    .primary = Fs.Path.initWithNamespace(key, "file"),
                },
                .module_type = .unknown,
            };
        }
    } else {
        const buf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(buf);
        const normalized_specifier = bun.path.pathToPosixBuf(u8, specifier, buf);

        if (self.map.getKey(normalized_specifier)) |key| {
            return .{
                .path_pair = .{
                    .primary = Fs.Path.initWithNamespace(key, "file"),
                },
                .module_type = .unknown,
            };
        }
    }

    if (specifier.len > 0 and specifier[0] != '/' and
        !(specifier.len >= 3 and specifier[1] == ':' and (specifier[2] == '/' or specifier[2] == '\\')))
    {
        const abs_source_buf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(abs_source_buf);
        const abs_source_file = if (isAbsolutePath(source_file))
            source_file
        else
            Fs.FileSystem.instance.absBuf(&.{source_file}, abs_source_buf);

        const source_file_buf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(source_file_buf);
        const normalized_source_file = bun.path.pathToPosixBuf(u8, abs_source_file, source_file_buf);

        const buf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(buf);
        const parsed = std.fs.path.parsePathWindows(u8, normalized_source_file);
        const joined = switch (parsed.kind) {
            .drive_absolute, .unc_absolute, .root_local_device, .local_device => bun.path.joinAbsStringBuf(
                std.fs.path.dirnameWindows(normalized_source_file) orelse parsed.root,
                buf,
                &.{specifier},
                .windows,
            ),
            else => bun.path.joinAbsStringBuf(
                std.fs.path.dirnamePosix(normalized_source_file) orelse Fs.FileSystem.instance.top_level_dir,
                buf,
                &.{specifier},
                .posix,
            ),
        };
        std.mem.replaceScalar(u8, buf[0..joined.len], '\\', '/');
        if (self.map.getKey(joined)) |key| {
            return .{
                .path_pair = .{
                    .primary = Fs.Path.initWithNamespace(key, "file"),
                },
                .module_type = .unknown,
            };
        }
    }

    return null;
}

fn isAbsolutePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return true;
    if (path.len >= 3 and path[1] == ':' and (path[2] == '/' or path[2] == '\\')) {
        return switch (path[0]) {
            'a'...'z', 'A'...'Z' => true,
            else => false,
        };
    }
    return path.len >= 2 and path[0] == '\\' and path[1] == '\\';
}

pub fn fromSchema(files: anytype) !FileMap {
    var self: FileMap = .{};
    errdefer self.deinit();

    const capacity = std.math.cast(u32, files.len()) orelse return error.OutOfMemory;
    try self.map.ensureTotalCapacity(bun.default_allocator, capacity);

    var index = files.len();
    while (index > 0) {
        index -= 1;
        const entry = files.at(index).?;

        if (entry.key.length() == 0) continue;

        const contents: []const u8 = switch (entry.value) {
            .blob => |*blob_ref| try bun.default_allocator.dupe(u8, blob_ref.get().sharedView()),
            .buffer => |buffer| try buffer.dupe(bun.default_allocator),
            .string => |*text| try text.toOwnedSlice(bun.default_allocator),
        };
        errdefer bun.default_allocator.free(contents);

        const key = try entry.key.toOwnedSlice(bun.default_allocator);
        bun.path.dangerouslyConvertPathToPosixInPlace(u8, key);
        const entry_result = self.map.getOrPutAssumeCapacity(key);
        if (entry_result.found_existing) {
            bun.default_allocator.free(key);
            bun.default_allocator.free(entry_result.value_ptr.*);
        }
        entry_result.value_ptr.* = contents;
    }

    return self;
}

const std = @import("std");
const bun = @import("bun");
const Fs = @import("../resolver/fs.zig");
const Resolver = @import("../resolver/resolver.zig");
