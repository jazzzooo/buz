const Hardlinker = @This();

io: std.Io,
src: *bun.Path(.{ .unit = .os }),
dest: *bun.Path(.{ .unit = .os }),
walker: DirectoryWalker,

pub fn init(
    io: std.Io,
    folder_dir: FD,
    src: *bun.Path(.{ .unit = .os }),
    dest: *bun.Path(.{ .unit = .os }),
    skip_dirnames: []const []const u8,
) OOM!Hardlinker {
    return .{
        .io = io,
        .src = src,
        .dest = dest,
        .walker = try DirectoryWalker.init(folder_dir.stdDir(), bun.default_allocator, .{
            .excluded_directories = skip_dirnames,
        }),
    };
}

pub fn deinit(this: *Hardlinker) void {
    this.walker.deinit(this.io);
}

pub fn link(this: *Hardlinker) OOM!sys.Maybe(void) {
    if (bun.install.PackageManager.verbose_install) {
        bun.Output.prettyErrorln(
            \\Hardlinking {f} to {f}
        ,
            .{
                bun.fmt.fmtOSPath(this.src.slice(), .{ .path_sep = .auto }),
                bun.fmt.fmtOSPath(this.dest.slice(), .{ .path_sep = .auto }),
            },
        );
        bun.Output.flush();
    }

    const destination_dir = bun.MakePath.makeOpenPath(this.io, std.Io.Dir.cwd(), this.dest.sliceZ(), .{}) catch |err| {
        return .initErr(bun.sys.Error.fromStdIo(err, .link));
    };
    defer destination_dir.close(this.io);

    if (comptime Environment.isWindows) {
        const cwd_buf = bun.w_path_buffer_pool.get();
        defer bun.w_path_buffer_pool.put(cwd_buf);
        const relative_path_buf = bun.w_path_buffer_pool.get();
        defer bun.w_path_buffer_pool.put(relative_path_buf);
        const dest_cwd = FD.cwd().getFdPathW(cwd_buf) catch {
            return .initErr(bun.sys.Error.fromCode(bun.sys.E.ACCES, .link));
        };

        while (this.walker.next(this.io) catch |err| {
            return .initErr(bun.sys.Error.fromStdIo(err, .link));
        }) |entry| {
            switch (entry.kind) {
                .directory => {
                    destination_dir.createDirPath(this.io, entry.path) catch |err| {
                        return .initErr(bun.sys.Error.fromStdIo(err, .link));
                    };
                    continue;
                },
                .file => {},
                else => continue,
            }

            const relative_path = bun.strings.toWPathWtf8(relative_path_buf, entry.path) catch |err| {
                return .initErr(bun.sys.Error.fromStdIo(err, .link));
            };

            var src_save = this.src.save();
            defer src_save.restore();

            this.src.append(relative_path);

            var dest_save = this.dest.save();
            defer dest_save.restore();

            this.dest.append(relative_path);

            const destfile_path_buf = bun.w_path_buffer_pool.get();
            defer bun.w_path_buffer_pool.put(destfile_path_buf);
            const dest_is_absolute = this.dest.len() > 0 and bun.path.Platform.windows.isAbsoluteT(u16, this.dest.slice());
            var dest_abs: bun.Path(.{ .unit = .os }) = .fromLongPath(dest_cwd);
            defer dest_abs.deinit();
            if (!dest_is_absolute) dest_abs.append(this.dest.slice());
            const dest_path = if (dest_is_absolute)
                this.dest.sliceZ()
            else
                dest_abs.sliceZ();
            const destfile_path = bun.strings.addNTPathPrefixIfNeeded(destfile_path_buf, dest_path);

            switch (sys.link(u16, this.src.sliceZ(), destfile_path)) {
                .result => {},
                .err => |link_err1| switch (link_err1.getErrno()) {
                    .UV_EEXIST,
                    .EXIST,
                    => {
                        if (bun.install.PackageManager.verbose_install) {
                            bun.Output.prettyErrorln(
                                \\Hardlinking {f} to a path that already exists: {f}
                            ,
                                .{
                                    bun.fmt.fmtOSPath(this.src.slice(), .{ .path_sep = .auto }),
                                    bun.fmt.fmtOSPath(destfile_path, .{ .path_sep = .auto }),
                                },
                            );
                        }

                        destination_dir.deleteTree(this.io, entry.path) catch {};
                        switch (sys.link(u16, this.src.sliceZ(), destfile_path)) {
                            .result => {},
                            .err => |link_err2| return .initErr(link_err2),
                        }
                    },
                    else => return .initErr(link_err1),
                },
            }
        }

        return .success;
    }

    while (this.walker.next(this.io) catch |err| {
        return .initErr(bun.sys.Error.fromStdIo(err, .link));
    }) |entry| {
        switch (entry.kind) {
            .directory => {
                destination_dir.createDirPath(this.io, entry.path) catch |err| {
                    return .initErr(bun.sys.Error.fromStdIo(err, .link));
                };
            },
            .file => {
                entry.dir.hardLink(entry.basename, destination_dir, entry.path, this.io, .{}) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        destination_dir.deleteTree(this.io, entry.path) catch {};
                        entry.dir.hardLink(entry.basename, destination_dir, entry.path, this.io, .{}) catch |retry_err| {
                            return .initErr(bun.sys.Error.fromStdIo(retry_err, .link));
                        };
                    },
                    else => return .initErr(bun.sys.Error.fromStdIo(err, .link)),
                };
            },
            else => {},
        }
    }

    return .success;
}

const DirectoryWalker = @import("../../sys/DirectoryWalker.zig");
const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const FD = bun.FD;
const OOM = bun.OOM;
const sys = bun.sys;
