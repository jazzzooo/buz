const FileCloner = @This();

// macOS clonefileat only

cache_dir: FD,
cache_dir_subpath: *const bun.Path(.{}),
dest_subpath: *const bun.Path(.{ .unit = .os }),
io: std.Io,

fn clonefileat(this: *FileCloner) sys.Maybe(void) {
    return sys.clonefileat(this.cache_dir, this.cache_dir_subpath.sliceZ(), FD.cwd(), this.dest_subpath.sliceZ());
}

pub fn clone(this: *FileCloner) sys.Maybe(void) {
    switch (this.clonefileat()) {
        .result => return .success,
        .err => |err| {
            switch (err.getErrno()) {
                .EXIST => {
                    // Stale leftover (an earlier crash, or a re-run after the
                    // global-store staging directory wasn't cleaned). The
                    // global-store entry is published by an entry-level
                    // rename in `commitGlobalStoreEntry`, so it's always safe
                    // to wipe and re-clone here — we're only ever writing
                    // into a per-process staging directory or a project-local
                    // path, never into a published shared directory.
                    FD.cwd().deleteTree(this.io, this.dest_subpath.slice()) catch {};
                    return this.clonefileat();
                },

                .NOENT => {
                    const parent_dest_dir = std.fs.path.dirname(this.dest_subpath.slice()) orelse {
                        return .initErr(err);
                    };
                    FD.cwd().makePath(this.io, u8, parent_dest_dir) catch {};
                    return this.clonefileat();
                },
                else => {
                    return .initErr(err);
                },
            }
        },
    }
}

const bun = @import("bun");
const std = @import("std");
const FD = bun.FD;
const sys = bun.sys;
