pub const default_permission = if (Environment.isPosix)
    Syscall.S.IRUSR |
        Syscall.S.IWUSR |
        Syscall.S.IRGRP |
        Syscall.S.IWGRP |
        Syscall.S.IROTH |
        Syscall.S.IWOTH
else
    0;

pub const WriteFile = struct {
    encoding: NodeTypes.Encoding = .utf8,
    flag: NodeTypes.FileSystemFlags = .w,
    mode: bun.Mode = 0o666,
    file: NodeTypes.PathOrFileDescriptor,
    flush: bool = false,
    data: NodeTypes.StringOrBuffer,
    dirfd: bun.FD,
};

pub const Mkdir = struct {
    pub const DefaultMode = 0o777;

    path: NodeTypes.PathLike,
    recursive: bool = false,
    mode: bun.Mode = DefaultMode,
    always_return_none: bool = false,
};

pub const MkdirResult = union(enum) {
    string: bun.String,
    none: void,

    pub fn deinit(result: *@This()) void {
        switch (result.*) {
            .string => |value| value.deref(),
            .none => {},
        }
    }
};

pub const Utimes = struct {
    path: NodeTypes.PathLike,
    atime: TimeLike,
    mtime: TimeLike,
};

pub fn utimes(error_buffer: *bun.PathBuffer, args: anytype) bun.sys.Maybe(void) {
    if (Environment.isWindows) {
        var request: libuv.fs_t = .uninitialized;
        defer request.deinit();
        const result = libuv.uv_fs_utime(
            bun.Async.Loop.get(),
            &request,
            args.path.sliceZ(error_buffer).ptr,
            args.atime,
            args.mtime,
            null,
        );
        return if (result.errno()) |errno|
            .{ .err = .{
                .errno = errno,
                .syscall = .utime,
                .path = args.path.slice(),
            } }
        else
            .success;
    }

    return switch (Syscall.utimens(args.path.sliceZ(error_buffer), args.atime, args.mtime)) {
        .err => |err| .{ .err = err.withPath(args.path.slice()) },
        .result => .success,
    };
}

pub fn truncate(error_buffer: *bun.PathBuffer, path: *const NodeTypes.PathLike, len: u63) bun.sys.Maybe(void) {
    if (Environment.isWindows) {
        const opened = bun.sys.open(path.sliceZ(error_buffer), bun.O.WRONLY, 0o644);
        if (opened == .err) return .{ .err = .{
            .errno = opened.err.errno,
            .path = path.slice(),
            .syscall = .truncate,
        } };
        defer opened.result.close();
        return switch (Syscall.ftruncate(opened.result, len)) {
            .result => .success,
            .err => |err| .{ .err = err.withPathAndSyscall(path.slice(), .truncate) },
        };
    }

    return bun.sys.Maybe(void).errnoSysP(bun.c.truncate(path.sliceZ(error_buffer), len), .truncate, path.slice()) orelse
        .success;
}

pub fn ftruncate(fd: bun.FD, len: u63) bun.sys.Maybe(void) {
    return Syscall.ftruncate(fd, len);
}

pub noinline fn copyFileUsingReadWriteLoop(
    src: [:0]const u8,
    dest: [:0]const u8,
    src_fd: bun.FD,
    dest_fd: bun.FD,
    stat_size: usize,
    wrote: *u64,
) bun.sys.Maybe(void) {
    var stack_buffer: [64 * 1024]u8 = undefined;
    var allocated_buffer: []u8 = &.{};
    var buffer: []u8 = &stack_buffer;

    if (stat_size > stack_buffer.len * 16) {
        allocated_buffer = bun.default_allocator.alloc(u8, @min(stat_size, 8 * 1024 * 1024)) catch &.{};
        if (allocated_buffer.len > 0) buffer = allocated_buffer;
    }
    defer if (allocated_buffer.len > 0) bun.default_allocator.free(allocated_buffer);

    var remaining: u64 = @intCast(stat_size);
    while (true) {
        const read_size = if (remaining > 0) @min(buffer.len, remaining) else buffer.len;
        const amount = switch (Syscall.read(src_fd, buffer[0..read_size])) {
            .result => |result| result,
            .err => |err| return .{ .err = if (src.len > 0) err.withPath(src) else err },
        };
        if (amount == 0) break;
        remaining -|= amount;

        var unwritten = buffer[0..amount];
        while (unwritten.len > 0) {
            const amount_written = switch (Syscall.write(dest_fd, unwritten)) {
                .result => |result| result,
                .err => |err| return .{ .err = if (dest.len > 0) err.withPath(dest) else err },
            };
            if (amount_written == 0) {
                const err = bun.sys.Error.fromCode(.IO, .write).withFd(dest_fd);
                return .{ .err = if (dest.len > 0) err.withPath(dest) else err };
            }
            wrote.* += amount_written;
            unwritten = unwritten[amount_written..];
        }
    }

    return .success;
}

pub fn copyFileDataOnLinux(
    src: [:0]const u8,
    dest: [:0]const u8,
    src_fd: bun.FD,
    dest_fd: bun.FD,
    stat_size: usize,
    wrote: *u64,
) bun.sys.Maybe(void) {
    if (!bun.canUseCopyFileRangeSyscall()) {
        return copyFileUsingSendfileOnLinuxWithReadWriteFallback(src, dest, src_fd, dest_fd, stat_size, wrote);
    }

    var remaining = stat_size;
    while (stat_size == 0 or remaining > 0) {
        const count = if (stat_size == 0) std.heap.pageSize() else remaining;
        // Descriptor offsets preserve progress when a later iteration falls back.
        const amount = std.os.linux.copy_file_range(src_fd.cast(), null, dest_fd.cast(), null, count, 0);
        if (bun.sys.Maybe(void).errnoSysP(amount, .copy_file_range, dest)) |err| {
            switch (err.getErrno()) {
                .INTR => continue,
                .XDEV, .NOSYS, .INVAL, .OPNOTSUPP => |errno| {
                    if (errno == .NOSYS or errno == .OPNOTSUPP) bun.disableCopyFileRangeSyscall();
                    return copyFileUsingSendfileOnLinuxWithReadWriteFallback(src, dest, src_fd, dest_fd, remaining, wrote);
                },
                else => return err,
            }
        }
        if (amount == 0) break;
        wrote.* +|= amount;
        remaining -|= amount;
    }
    return .success;
}

noinline fn copyFileUsingSendfileOnLinuxWithReadWriteFallback(
    src: [:0]const u8,
    dest: [:0]const u8,
    src_fd: bun.FD,
    dest_fd: bun.FD,
    stat_size: usize,
    wrote: *u64,
) bun.sys.Maybe(void) {
    while (true) {
        const amount = switch (bun.sys.sendfile(src_fd, dest_fd, std.math.maxInt(i32) - 1)) {
            .err => return copyFileUsingReadWriteLoop(src, dest, src_fd, dest_fd, stat_size, wrote),
            .result => |value| value,
        };
        wrote.* += amount;
        if (amount == 0) return .success;
    }
}

pub fn mkdir(error_buffer: *bun.PathBuffer, args: Mkdir) bun.sys.Maybe(MkdirResult) {
    return mkdirFromArgs(error_buffer, &args, void, {});
}

pub fn mkdirFromArgs(error_buffer: *bun.PathBuffer, args: anytype, comptime Context: type, context: Context) bun.sys.Maybe(MkdirResult) {
    if (args.path.slice().len == 0) return .{ .err = .{
        .errno = @backingInt(bun.sys.E.NOENT),
        .syscall = .mkdir,
        .path = "",
    } };
    if (!args.recursive) return mkdirNonRecursiveFromArgs(error_buffer, args);

    return mkdirRecursiveFromArgs(error_buffer, args, Context, context);
}

pub fn mkdirRecursiveFromArgs(error_buffer: *bun.PathBuffer, args: anytype, comptime Context: type, context: Context) bun.sys.Maybe(MkdirResult) {
    const buffer = bun.path_buffer_pool.get();
    defer bun.path_buffer_pool.put(buffer);
    const path = args.path.osPathKernel32(buffer);
    return switch (args.always_return_none) {
        inline else => |always_return_none| mkdirRecursiveOSPath(
            error_buffer,
            Context,
            context,
            path,
            args.mode,
            !always_return_none,
        ),
    };
}

pub fn mkdirNonRecursive(error_buffer: *bun.PathBuffer, args: Mkdir) bun.sys.Maybe(MkdirResult) {
    return mkdirNonRecursiveFromArgs(error_buffer, &args);
}

pub fn mkdirNonRecursiveFromArgs(error_buffer: *bun.PathBuffer, args: anytype) bun.sys.Maybe(MkdirResult) {
    const path = args.path.sliceZ(error_buffer);
    return switch (Syscall.mkdir(path, args.mode)) {
        .result => .{ .result = .{ .none = {} } },
        .err => |err| .{ .err = err.withPath(args.path.slice()) },
    };
}

pub fn mkdirRecursiveOSPath(
    error_buffer: *bun.PathBuffer,
    comptime Context: type,
    context: Context,
    path: bun.OSPathSliceZ,
    mode: bun.Mode,
    comptime return_path: bool,
) bun.sys.Maybe(MkdirResult) {
    const Char = bun.OSPathChar;
    const len: u16 = @intCast(path.len);

    switch (Syscall.mkdirOSPath(path, mode)) {
        .err => |err| switch (err.getErrno()) {
            else => return .{ .err = err.withPath(osPathIntoErrorBuffer(error_buffer, path[0..len])) },
            .ISDIR, .EXIST => return switch (bun.sys.directoryExistsAt(bun.invalid_fd, path)) {
                .err => .{ .err = .{
                    .errno = err.errno,
                    .syscall = .mkdir,
                    .path = osPathIntoErrorBuffer(error_buffer, strings.withoutNTPrefix(Char, path[0..len])),
                } },
                .result => |is_directory| if (is_directory)
                    .{ .result = .{ .none = {} } }
                else
                    .{ .err = .{
                        .errno = err.errno,
                        .syscall = .mkdir,
                        .path = osPathIntoErrorBuffer(error_buffer, strings.withoutNTPrefix(Char, path[0..len])),
                    } },
            },
            .NOENT => if (len == 0) return .{ .err = err },
        },
        .result => {
            if (Context != void) context.onCreateDir(path);
            if (!return_path) return .{ .result = .{ .none = {} } };
            return .{ .result = .{ .string = bun.String.createFromOSPath(path) } };
        },
    }

    var working_memory: *bun.OSPathBuffer = @ptrCast(@alignCast(error_buffer));
    @memcpy(working_memory[0..len], path[0..len]);

    var index: u16 = len - 1;
    while (index > 0) : (index -= 1) {
        if (!isSeparator(path[index])) continue;
        working_memory[index] = 0;
        const parent: [:0]Char = working_memory[0..index :0];

        switch (Syscall.mkdirOSPath(parent, mode)) {
            .err => |err| {
                working_memory[index] = std.fs.path.sep;
                switch (err.getErrno()) {
                    .EXIST => {
                        if (Environment.isWindows) {
                            switch (bun.sys.directoryExistsAt(bun.invalid_fd, parent)) {
                                .err => {},
                                .result => |is_directory| if (!is_directory) return .{ .err = .{
                                    .errno = @backingInt(bun.sys.E.NOTDIR),
                                    .syscall = .mkdir,
                                    .path = osPathIntoErrorBuffer(error_buffer, strings.withoutNTPrefix(Char, path[0..len])),
                                } },
                            }
                        }
                        break;
                    },
                    .NOENT => continue,
                    else => return .{ .err = err.withPath(if (Environment.isWindows)
                        osPathIntoErrorBufferOverlap(error_buffer, strings.withoutNTPrefix(Char, parent))
                    else
                        strings.withoutNTPrefix(Char, parent)) },
                }
            },
            .result => {
                if (Context != void) context.onCreateDir(parent);
                working_memory[index] = std.fs.path.sep;
                break;
            },
        }
    }
    const first_created: u16 = index;

    index += 1;
    while (index < len) : (index += 1) {
        if (!isSeparator(path[index])) continue;
        working_memory[index] = 0;
        const parent: [:0]Char = working_memory[0..index :0];

        switch (Syscall.mkdirOSPath(parent, mode)) {
            .err => |err| {
                working_memory[index] = std.fs.path.sep;
                if (err.getErrno() != .EXIST) return .{ .err = err.withPath(
                    osPathIntoErrorBuffer(error_buffer, strings.withoutNTPrefix(Char, path)),
                ) };
            },
            .result => {
                if (Context != void) context.onCreateDir(parent);
                working_memory[index] = std.fs.path.sep;
            },
        }
    }

    working_memory[len] = 0;
    switch (Syscall.mkdirOSPath(working_memory[0..len :0], mode)) {
        .err => |err| if (err.getErrno() != .EXIST) return .{ .err = err.withPath(
            osPathIntoErrorBuffer(error_buffer, strings.withoutNTPrefix(Char, path)),
        ) },
        .result => {},
    }

    if (Context != void) context.onCreateDir(working_memory[0..len :0]);
    if (!return_path) return .{ .result = .{ .none = {} } };
    return .{ .result = .{ .string = bun.String.createFromOSPath(working_memory[0..first_created]) } };
}

fn isSeparator(char: bun.OSPathChar) bool {
    return if (Environment.isWindows) char == '/' or char == '\\' else char == '/';
}

fn osPathIntoErrorBuffer(error_buffer: *bun.PathBuffer, path: anytype) []const u8 {
    if (Environment.isWindows) return strings.fromWPath(error_buffer, path);
    @memcpy(error_buffer[0..path.len], path);
    return error_buffer[0..path.len];
}

fn osPathIntoErrorBufferOverlap(error_buffer: *bun.PathBuffer, path: anytype) []const u8 {
    if (!Environment.isWindows) return osPathIntoErrorBuffer(error_buffer, path);
    const temporary = bun.os_path_buffer_pool.get();
    defer bun.os_path_buffer_pool.put(temporary);
    @memcpy(temporary[0..path.len], path);
    return strings.fromWPath(error_buffer, temporary[0..path.len]);
}

pub fn writeFileWithPathBuffer(pathbuf: *bun.PathBuffer, args: WriteFile) bun.sys.Maybe(void) {
    return writeFileWithPathBufferFromArgs(pathbuf, &args, false);
}

pub fn writeFileWithPathBufferFromArgs(pathbuf: *bun.PathBuffer, args: anytype, aborted: bool) bun.sys.Maybe(void) {
    const fd = switch (args.file) {
        .path => blk: {
            const path = args.file.path.sliceZWithForceCopy(pathbuf, true);
            break :blk switch (bun.sys.openat(args.dirfd, path, args.flag.asInt(), args.mode)) {
                .err => |err| return .{ .err = err.withPath(args.file.path.slice()) },
                .result => |result| result,
            };
        },
        .fd => |fd| fd,
    };
    defer if (args.file == .path) fd.close();

    if (aborted) return .aborted;

    var remaining = args.data.slice();
    var written: usize = 0;

    if (bun.sys.preallocate_supported and remaining.len >= bun.sys.preallocate_length) preallocate: {
        const offset: usize = if (args.file == .path)
            0
        else switch (Syscall.lseek(fd, 0, std.os.linux.SEEK.CUR)) {
            .err => break :preallocate,
            .result => |position| @intCast(position),
        };

        bun.sys.preallocate_file(
            fd.cast(),
            @intCast(offset),
            @intCast(remaining.len),
        ) catch {};
    }

    while (remaining.len > 0) {
        switch (bun.sys.write(fd, remaining)) {
            .err => |err| return .{ .err = err },
            .result => |amount| {
                remaining = remaining[amount..];
                written += amount;
                if (amount == 0) break;
            },
        }
    }

    if ((@backingInt(args.flag) & bun.O.APPEND) == 0 and args.file != .fd) {
        if (Environment.isWindows) {
            _ = bun.windows.SetEndOfFile(fd.cast());
        } else {
            _ = Syscall.ftruncate(fd, @intCast(@as(u63, @truncate(written))));
        }
    }

    if (args.flush) {
        if (Environment.isWindows) {
            _ = bun.c.FlushFileBuffers(fd.cast());
        } else {
            _ = std.posix.system.fsync(fd.cast());
        }
    }

    return .success;
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const strings = bun.strings;
const NodeTypes = @import("./types.zig");
const TimeLike = @import("./time_like.zig").TimeLike;
const Syscall = if (Environment.isWindows) bun.sys.sys_uv else bun.sys;
const libuv = bun.windows.libuv;
