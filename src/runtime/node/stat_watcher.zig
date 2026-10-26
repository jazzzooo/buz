pub fn read(path: [:0]const u8) bun.sys.Maybe(bun.sys.PosixStat) {
    if (bun.Environment.isLinux and bun.sys.supports_statx_on_linux.load(.monotonic)) {
        return bun.sys.statx(path, &.{ .type, .mode, .nlink, .uid, .gid, .atime, .mtime, .ctime, .btime, .ino, .size, .blocks });
    }
    return switch (bun.sys.stat(path)) {
        .result => |stat| .{ .result = .init(&stat) },
        .err => |err| .{ .err = err },
    };
}

pub fn equivalent(left: *const bun.sys.PosixStat, right: *const bun.sys.PosixStat) bool {
    // Access-time changes do not trigger watchFile listeners.
    return left.dev == right.dev and
        left.ino == right.ino and
        left.mode == right.mode and
        left.nlink == right.nlink and
        left.uid == right.uid and
        left.gid == right.gid and
        left.rdev == right.rdev and
        left.size == right.size and
        left.blksize == right.blksize and
        left.blocks == right.blocks and
        left.mtim.sec == right.mtim.sec and
        left.mtim.nsec == right.mtim.nsec and
        left.ctim.sec == right.ctim.sec and
        left.ctim.nsec == right.ctim.nsec and
        left.birthtim.sec == right.birthtim.sec and
        left.birthtim.nsec == right.birthtim.nsec;
}

const bun = @import("bun");
