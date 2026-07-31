const DirectoryWalker = @This();

inner: std.Io.Dir.SelectiveWalker,
excluded_files: []const []const u8,
excluded_directories: []const []const u8,

pub const Options = struct {
    excluded_files: []const []const u8 = &.{},
    excluded_directories: []const []const u8 = &.{},
};

pub fn init(dir: std.Io.Dir, allocator: std.mem.Allocator, options: Options) std.mem.Allocator.Error!DirectoryWalker {
    return .{
        .inner = try dir.walkSelectively(allocator),
        .excluded_files = options.excluded_files,
        .excluded_directories = options.excluded_directories,
    };
}

pub fn deinit(self: *DirectoryWalker, io: std.Io) void {
    self.inner.deinit(io);
}

pub fn next(self: *DirectoryWalker, io: std.Io) !?std.Io.Dir.Walker.Entry {
    while (try self.inner.next(io)) |entry_unresolved| {
        var entry = entry_unresolved;
        if (entry.kind == .unknown) {
            entry.kind = (try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false })).kind;
        }

        if (self.isExcluded(entry.basename, entry.kind)) continue;
        if (entry.kind == .directory) try self.inner.enter(io, entry);
        return entry;
    }
    return null;
}

fn isExcluded(self: DirectoryWalker, basename: []const u8, kind: std.Io.File.Kind) bool {
    return switch (kind) {
        .directory => contains(self.excluded_directories, basename),
        .file => contains(self.excluded_files, basename),
        .sym_link => contains(self.excluded_directories, basename) or contains(self.excluded_files, basename),
        else => false,
    };
}

fn contains(names: []const []const u8, basename: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, basename)) return true;
    }
    return false;
}

const std = @import("std");
