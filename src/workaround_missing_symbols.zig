pub const linux = struct {
    fn assertNativeStatLayout() void {
        const Stat = bun.c.struct_stat;
        const expected = switch (bun.Environment.arch) {
            .x64 => .{
                .size = 144,
                .dev = 0,
                .ino = 8,
                .nlink = 16,
                .mode = 24,
                .uid = 28,
                .gid = 32,
                .rdev = 40,
                .size_field = 48,
                .blksize = 56,
                .blocks = 64,
                .atim = 72,
                .mtim = 88,
                .ctim = 104,
            },
            .arm64 => .{
                .size = 128,
                .dev = 0,
                .ino = 8,
                .nlink = 20,
                .mode = 16,
                .uid = 24,
                .gid = 28,
                .rdev = 32,
                .size_field = 48,
                .blksize = 56,
                .blocks = 64,
                .atim = 72,
                .mtim = 88,
                .ctim = 104,
            },
            .wasm => unreachable,
        };
        comptime {
            std.debug.assert(@sizeOf(Stat) == expected.size);
            std.debug.assert(@offsetOf(Stat, "st_dev") == expected.dev);
            std.debug.assert(@offsetOf(Stat, "st_ino") == expected.ino);
            std.debug.assert(@offsetOf(Stat, "st_nlink") == expected.nlink);
            std.debug.assert(@offsetOf(Stat, "st_mode") == expected.mode);
            std.debug.assert(@offsetOf(Stat, "st_uid") == expected.uid);
            std.debug.assert(@offsetOf(Stat, "st_gid") == expected.gid);
            std.debug.assert(@offsetOf(Stat, "st_rdev") == expected.rdev);
            std.debug.assert(@offsetOf(Stat, "st_size") == expected.size_field);
            std.debug.assert(@offsetOf(Stat, "st_blksize") == expected.blksize);
            std.debug.assert(@offsetOf(Stat, "st_blocks") == expected.blocks);
            std.debug.assert(@offsetOf(Stat, "st_atim") == expected.atim);
            std.debug.assert(@offsetOf(Stat, "st_mtim") == expected.mtim);
            std.debug.assert(@offsetOf(Stat, "st_ctim") == expected.ctim);
        }
    }

    pub fn directFstatat(dirfd: i32, path: [*:0]const u8, buf: *bun.c.struct_stat, flags: u32) usize {
        assertNativeStatLayout();
        return std.os.linux.syscall4(
            .newfstatat,
            @as(u32, @bitCast(dirfd)),
            @intFromPtr(path),
            @intFromPtr(buf),
            flags,
        );
    }

    pub fn directFstat(fd: c_int, buf: *bun.c.struct_stat) usize {
        assertNativeStatLayout();
        return std.os.linux.syscall2(.fstat, @as(u32, @bitCast(fd)), @intFromPtr(buf));
    }

    pub const memmem = bun.c.memmem;
};
pub const darwin = struct {
    pub const memmem = bun.c.memmem;

    // The symbol name depends on the arch.

    pub const lstat = blk: {
        const T = *const fn (?[*:0]const u8, ?*std.c.Stat) callconv(.c) c_int;
        break :blk @extern(T, .{ .name = if (bun.Environment.isAarch64) "lstat" else "lstat64" });
    };
    pub const fstat = blk: {
        const T = *const fn (i32, ?*std.c.Stat) callconv(.c) c_int;
        break :blk @extern(T, .{ .name = if (bun.Environment.isAarch64) "fstat" else "fstat64" });
    };
    pub const stat = blk: {
        const T = *const fn (?[*:0]const u8, ?*std.c.Stat) callconv(.c) c_int;
        break :blk @extern(T, .{ .name = if (bun.Environment.isAarch64) "stat" else "stat64" });
    };
};
pub const windows = struct {
    /// Windows doesn't have memmem, so we need to implement it
    /// This is used in src/string/immutable.zig
    pub export fn memmem(haystack: ?[*]const u8, haystacklen: usize, needle: ?[*]const u8, needlelen: usize) ?[*]const u8 {
        // Handle null pointers
        if (haystack == null or needle == null) return null;

        // Handle empty needle case
        if (needlelen == 0) return haystack;

        // Handle case where needle is longer than haystack
        if (needlelen > haystacklen) return null;

        const hay = haystack.?[0..haystacklen];
        const nee = needle.?[0..needlelen];

        const i = std.mem.indexOf(u8, hay, nee) orelse return null;
        return hay.ptr + i;
    }

    /// lstat is implemented in workaround-missing-symbols.cpp
    pub const lstat = blk: {
        const T = *const fn ([*c]const u8, [*c]std.c.Stat) callconv(.c) c_int;
        break :blk @extern(T, .{ .name = "lstat64" });
    };
    /// fstat is implemented in workaround-missing-symbols.cpp
    pub const fstat = blk: {
        const T = *const fn ([*c]const u8, [*c]std.c.Stat) callconv(.c) c_int;
        break :blk @extern(T, .{ .name = "fstat64" });
    };
    /// stat is implemented in workaround-missing-symbols.cpp
    pub const stat = blk: {
        const T = *const fn ([*c]const u8, [*c]std.c.Stat) callconv(.c) c_int;
        break :blk @extern(T, .{ .name = "stat64" });
    };
};

pub const freebsd = struct {
    pub const memmem = bun.c.memmem;
    // FreeBSD has plain stat/fstat/lstat (no 64-suffix; off_t is always
    // 64-bit). Zig's std.c only exports darwin's `stat$INODE64`, so bind
    // them directly.
    pub extern "c" fn lstat(noalias path: [*:0]const u8, noalias buf: *std.c.Stat) c_int;
    pub extern "c" fn fstat(fd: c_int, buf: *std.c.Stat) c_int;
    pub extern "c" fn stat(noalias path: [*:0]const u8, noalias buf: *std.c.Stat) c_int;
};

pub const current = switch (bun.Environment.os) {
    .linux => linux,
    .windows => windows,
    .mac => darwin,
    .freebsd => freebsd,
    .wasm => struct {},
};

const bun = @import("bun");
const std = @import("std");
