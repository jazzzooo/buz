pub const Symlinker = struct {
    io: std.Io,
    dest: [:0]const u8,
    target: [:0]const u8,
    fallback_junction_target: [:0]const u8,

    pub fn symlink(this: *const @This()) sys.Maybe(void) {
        if (comptime Environment.isWindows) {
            return sys.symlinkOrJunction(this.dest, this.target, this.fallback_junction_target);
        }
        return sys.symlink(this.target, this.dest);
    }

    pub const Strategy = enum {
        expect_existing,
        expect_missing,
        ignore_failure,
    };

    pub fn ensureSymlink(
        this: *const @This(),
        strategy: Strategy,
    ) sys.Maybe(void) {
        return switch (strategy) {
            .ignore_failure => {
                return switch (this.symlink()) {
                    .result => .success,
                    .err => |symlink_err| switch (symlink_err.getErrno()) {
                        .NOENT => {
                            const dest_parent = std.fs.path.dirname(this.dest) orelse {
                                return .success;
                            };

                            FD.cwd().makePath(this.io, u8, dest_parent) catch {};
                            _ = this.symlink();
                            return .success;
                        },
                        else => .success,
                    },
                };
            },
            .expect_missing => {
                return switch (this.symlink()) {
                    .result => .success,
                    .err => |symlink_err1| switch (symlink_err1.getErrno()) {
                        .NOENT => {
                            const dest_parent = std.fs.path.dirname(this.dest) orelse {
                                return .initErr(symlink_err1);
                            };

                            FD.cwd().makePath(this.io, u8, dest_parent) catch {};
                            return this.symlink();
                        },
                        .EXIST => {
                            FD.cwd().deleteTree(this.io, this.dest) catch {};
                            return this.symlink();
                        },
                        else => .initErr(symlink_err1),
                    },
                };
            },
            .expect_existing => {
                const current_link_buf = bun.path_buffer_pool.get();
                defer bun.path_buffer_pool.put(current_link_buf);
                var current_link: []const u8 = switch (sys.readlink(this.dest, current_link_buf)) {
                    .result => |res| res,
                    .err => |readlink_err| return switch (readlink_err.getErrno()) {
                        .NOENT => switch (this.symlink()) {
                            .result => .success,
                            .err => |symlink_err| switch (symlink_err.getErrno()) {
                                .NOENT => {
                                    const dest_parent = std.fs.path.dirname(this.dest) orelse {
                                        return .initErr(symlink_err);
                                    };

                                    FD.cwd().makePath(this.io, u8, dest_parent) catch {};
                                    return this.symlink();
                                },
                                else => .initErr(symlink_err),
                            },
                        },
                        // readlink failed for a reason other than NOENT —
                        // dest exists but isn't a symlink. If it's a real
                        // directory, leave it: this is the `bun patch <pkg>`
                        // workspace (a detached copy the user is editing
                        // before `--commit`), and `deleteTree` here would
                        // silently destroy their in-progress edits. If it's
                        // a regular file, replace it.
                        else => {
                            const is_dir = if (comptime Environment.isWindows)
                                if (sys.getFileAttributes(this.dest)) |a| a.is_directory and !a.is_reparse_point else false
                            else if (sys.lstat(this.dest).asValue()) |st|
                                std.posix.S.ISDIR(@intCast(st.mode))
                            else
                                false;
                            if (is_dir) return .success;
                            _ = sys.unlink(this.dest);
                            return this.symlink();
                        },
                    },
                };

                // libuv adds a trailing slash to junctions.
                current_link = strings.withoutTrailingSlash(current_link);

                if (strings.eqlLong(current_link, this.target, true)) {
                    return .success;
                }

                if (comptime Environment.isWindows) {
                    if (strings.eqlLong(current_link, this.fallback_junction_target, true)) {
                        return .success;
                    }

                    // this existing link is pointing to the wrong package.
                    // on windows rmdir must be used for symlinks created to point
                    // at directories, even if the target no longer exists
                    switch (sys.rmdir(this.dest)) {
                        .result => {},
                        .err => |err| switch (err.getErrno()) {
                            .PERM => {
                                _ = sys.unlink(this.dest);
                            },
                            else => {},
                        },
                    }
                } else {
                    // this existing link is pointing to the wrong package
                    _ = sys.unlink(this.dest);
                }

                return this.symlink();
            },
        };
    }
};

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const FD = bun.FD;
const strings = bun.strings;
const sys = bun.sys;
