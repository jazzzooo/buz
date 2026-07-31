pub const FileCopier = struct {
    io: std.Io,
    src_path: *bun.Path(.{ .unit = .os }),
    dest_subpath: *bun.Path(.{ .unit = .os }),
    walker: DirectoryWalker,

    pub fn init(
        io: std.Io,
        src_dir: FD,
        src_path: *bun.Path(.{ .unit = .os }),
        dest_subpath: *bun.Path(.{ .unit = .os }),
        skip_dirnames: []const []const u8,
    ) OOM!FileCopier {
        return .{
            .io = io,
            .src_path = src_path,
            .dest_subpath = dest_subpath,
            .walker = try DirectoryWalker.init(src_dir.stdDir(), bun.default_allocator, .{
                .excluded_directories = skip_dirnames,
            }),
        };
    }

    pub fn deinit(this: *FileCopier) void {
        this.walker.deinit(this.io);
    }

    pub fn copy(this: *FileCopier) sys.Maybe(void) {
        const dest_dir = bun.MakePath.makeOpenPath(this.io, FD.cwd().stdDir(), this.dest_subpath.sliceZ(), .{}) catch |err| {
            var errno = bun.sys.Error.errnoFromStdIo(err, .PERM);
            if (Environment.isWindows and errno == .NOTDIR) {
                errno = .NOENT;
            }

            return .{ .err = bun.sys.Error.fromCode(errno, .copyfile) };
        };
        defer dest_dir.close(this.io);

        var copy_file_state: bun.CopyFileState = .{};
        var relative_path_buf: if (Environment.isWindows) bun.WPathBuffer else void = undefined;

        while (this.walker.next(this.io) catch |err| {
            return .initErr(bun.sys.Error.fromStdIo(err, .copyfile));
        }) |entry| {
            switch (entry.kind) {
                .directory => {
                    dest_dir.createDirPath(this.io, entry.path) catch |err| {
                        return .initErr(bun.sys.Error.fromStdIo(err, .copyfile));
                    };
                    continue;
                },
                .file => {},
                else => continue,
            }

            if (comptime Environment.isWindows) {
                const relative_path = bun.strings.toWPathWtf8(&relative_path_buf, entry.path) catch |err| {
                    return .initErr(bun.sys.Error.fromStdIo(err, .copyfile));
                };

                var src_path_save = this.src_path.save();
                defer src_path_save.restore();

                this.src_path.append(relative_path);

                var dest_subpath_save = this.dest_subpath.save();
                defer dest_subpath_save.restore();

                this.dest_subpath.append(relative_path);

                switch (bun.copyFile(this.src_path.sliceZ(), this.dest_subpath.sliceZ())) {
                    .result => {},
                    .err => |err| {
                        return .initErr(err);
                    },
                }
            } else {
                const src = entry.dir.openFile(this.io, entry.basename, .{}) catch |err| {
                    return .initErr(bun.sys.Error.fromStdIo(err, .copyfile));
                };
                defer src.close(this.io);
                const stat = src.stat(this.io) catch |err| {
                    return .initErr(bun.sys.Error.fromStdIo(err, .copyfile));
                };

                const dest = dest_dir.createFile(this.io, entry.path, .{}) catch |err| {
                    return .initErr(bun.sys.Error.fromStdIo(err, .copyfile));
                };
                defer dest.close(this.io);

                dest.setPermissions(this.io, stat.permissions) catch |err| {
                    return .initErr(bun.sys.Error.fromStdIo(err, .copyfile));
                };

                switch (bun.copyFileWithState(.fromStdFile(src), .fromStdFile(dest), &copy_file_state)) {
                    .result => {},
                    .err => |err| {
                        return .initErr(err);
                    },
                }
            }
        }

        return .success;
    }
};

const DirectoryWalker = @import("../../sys/DirectoryWalker.zig");
const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const FD = bun.FD;
const OOM = bun.OOM;
const sys = bun.sys;
